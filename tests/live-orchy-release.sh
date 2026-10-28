#!/usr/bin/env bash
# Live, read-only check of start-orchy's release derivation and `act ... --check` on real repositories. Every gh call goes
# through a shim that lets only reads reach GitHub and records a refusal for anything else, which fails the run.
#   ORCHY_LIVE_REPOS="<owner/name> ..." [ORCHY_LIVE_EXPECT="<owner/name>=<shape> ..."] bash tests/live-orchy-release.sh
# Without ORCHY_LIVE_REPOS it prints skip and exits 0.
set -euo pipefail
[ -n "${ORCHY_LIVE_REPOS:-}" ] || { echo skip; exit 0; }
HERE=$(cd "$(dirname "$0")/.." && pwd); K="$HERE/skills/start-orchy"; ORCHY="$K/scripts/orchy.sh"
SCHEMA="$HERE/tests/mocks/orchy/release/schema.jq"
fail() { echo "FAIL: $*" >&2; exit 1; }
for c in bun gh jq git timeout; do command -v "$c" >/dev/null || fail "$c not found"; done
T=$(mktemp -d -t orchy-live-XXXX); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/cap" "$T/asks"
cat > "$T/bin/gh" <<'SHIM'
#!/usr/bin/env bash
# Only reads reach GitHub: gh api with no method, field or input flag (headers: Accept only, and never graphql), gh repo
# view and gh pr view. A value flag takes the next word whatever it is, as gh's parser does.
set -u
args=("$@"); ok=1; n=0
case "${1:-}" in
  api) shift; vals=" -H --header --jq -q --cache "; bools=" --paginate --slurp -i --include --silent ";;
  repo|pr) [ "${2:-}" = view ] || ok=0; shift; shift; vals=" --json --jq -q --repo -R "; bools=" ";;
  *) ok=0; vals=" "; bools=" ";;
esac
while [ "$ok" = 1 ] && [ $# -gt 0 ]; do
  if [[ "$vals" == *" $1 "* ]]; then
    if [ $# -lt 2 ]; then ok=0; elif [[ "$1" =~ ^(-H|--header)$ && ! "$2" =~ ^Accept:\ application/vnd\.github ]]; then ok=0; else shift 2; fi
  elif [[ "$bools" == *" $1 "* ]]; then shift
  elif [[ "$1" == -* || ( "${args[0]}" = api && "$1" == graphql* ) ]]; then ok=0
  else n=$((n + 1)); shift; fi
done
[ "$n" -le 1 ] || ok=0
if [ "$ok" = 1 ]; then printf 'READ\t%s\n' "${args[*]}" >> "$LIVE_GH_LOG"; exec "$LIVE_GH" "${args[@]}"; fi
printf 'REFUSED\t%s\n' "${args[*]}" >> "$LIVE_GH_LOG"; echo "live shim: refused: gh ${args[*]}" >&2; exit 1
SHIM
chmod +x "$T/bin/gh"
LIVE_GH=$(command -v gh); export LIVE_GH LIVE_GH_LOG="$T/gh.log" PATH="$T/bin:$PATH"
expected() { local e; for e in ${ORCHY_LIVE_EXPECT:-}; do [ "${e%%=*}" = "$1" ] && { echo "${e#*=}"; return; }; done; return 0; }
checked() { # checked <act> <output> <exit>: act ended in a result or a refusal, never a crash
  [[ "$3" =~ ^[01]$ && "$(tail -n 1 <<<"$2")" =~ ^(checked|refused):\  ]] || fail "$r: act $1 --check ended with exit $3: $2"; }

for r in $ORCHY_LIVE_REPOS; do
  [[ "$r" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]] || fail "$r is not owner/name"
  s=${r//\//-}; p="$T/$s.json"; rc=0
  bun "$K/scripts/release-profile.ts" --repo "$r" > "$p" 2> "$T/$s.err" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || fail "$r: the derivation exited $rc: $(tail -n 3 "$T/$s.err")"
  jq -e --arg repo "$r" --arg rc "$rc" -f "$SCHEMA" "$p" >/dev/null || fail "$r: not an orchy.release/1 profile: $(head -c 400 "$p")"
  d=$(gh repo view "$r" --json defaultBranchRef --jq .defaultBranchRef.name); t=$(jq -r .trunk.name "$p")
  [ "$t" = "$d" ] || fail "$r: trunk.name is $t, the default branch $d"
  w=$(expected "$r"); [ -z "$w" ] || [ "$(jq -r .shape "$p")" = "$w" ] || fail "$r: shape $(jq -r .shape "$p"), expected $w"

  # a throwaway home configured as the bootstrap would: merge.branches only from known checks, no review, no queue, one method
  H="$T/cap/$s"; mkdir -p "$H"; git init -q "$T/repo-$s"
  jq --slurpfile p "$p" '$p[0] as $p | .trunk = $p.trunk.name | .release = $p | .merge.required_checks = ($p.trunk.checks // [])
    | .merge.trunk_methods = ($p.trunk.methods // [.merge.method]) | .merge.branches = (($p.branch // {}) as $b
      | if ($b.checks // [] | length > 0) and $b.reviews == 0 and $b.queue == false and ($b.methods // [] | length == 1)
        then {($b.name): {method: $b.methods[0], required_checks: $b.checks}} else {} end)' "$K/examples/orchy.example.json" > "$H/orchy.json"
  A() { ORCHY_ROOT="$T/repo-$s" ORCHY_REPO="$r" ORCHY_CAPACITY_ROOT="$T/cap" ORCHY_HOME="$H" ORCHY_ASKS_DIR="$T/asks" \
    ORCHY_ACCOUNTS="$T/accounts.json" "$ORCHY" act "$@" --check 2>&1; }
  pr=""; sha=""; base=""; run=""; att=""
  read -r pr sha base < <(gh api "repos/$r/pulls?state=closed&per_page=30" \
    --jq '[.[] | select(.merged_at != null)][0] // empty | "\(.number) \(.head.sha) \(.base.ref)"') || true
  lm="no merged PR"; if [ -n "$pr" ]; then
    m=$(jq -r --arg b "$base" 'if $b == .trunk then .merge.trunk_methods[0] else .merge.branches[$b].method // "merge" end' "$H/orchy.json")
    o=$(A merge "$pr" "$sha" "$base" "$m") && c=0 || c=$?; checked "merge $pr" "$o" "$c"; lm=$(tail -n 1 <<<"$o"); fi
  read -r run att < <(gh api "repos/$r/actions/runs?status=completed&per_page=1" \
    --jq '.workflow_runs[0] // empty | "\(.id) \(.run_attempt)"') || true
  env=$(jq -r '[(.environments // [])[].name | select(test("^[A-Za-z0-9._-]{1,100}$"))][0] // "production"' "$p")
  la="no completed run"; if [ -n "$run" ]; then
    o=$(A approve "$run" "$att" "$env") && c=0 || c=$?; checked "approve $run" "$o" "$c"; la=$(tail -n 1 <<<"$o"); fi
  echo "$r: $(jq -r '"\(.shape), tool \(.tool.kind), \(.unknown | length) unknown"' "$p") (exit $rc); merge: $lm; approve: $la"
  jq -r '.unknown[] | "  unknown: \(.)"' "$p"
done
! grep -q '^REFUSED' "$LIVE_GH_LOG" || fail "the shim refused: $(grep '^REFUSED' "$LIVE_GH_LOG" | cut -f2 | head -n 5)"
echo "live-orchy-release: ok"
