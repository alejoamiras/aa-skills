# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Text that leaves the machine: template rendering, the ban, copy and public checks, and the PR scan.
OVERLAP="$SCRIPTS/overlap.sh"
orchy_render() {
  # the shared briefs keep <LANE>, <KEY>, <WORKTREE> and <BRANCH>: each spawn prompt binds them for its lead
  keep=; [ "${1:-}" = --keep ] && { keep=${2:-}; shift 2; }
  name=${1:-}; t=$name; shift; [ -f "$t" ] || t="$(dirname "$0")/../templates/$t"
  [ -f "$t" ] || { echo "orchy: no template $name" >&2; exit 1; }
  abs_path t; ts_run render "$t" "$keep" "$@"
}
orchy_check_text() {
  ban=$(lcl '.prompt_ban // empty'); [ -n "$ban" ] || { echo "orchy: local.json has no prompt_ban" >&2; exit 2; }
  grep -qE "$ban" /dev/null 2>/dev/null; [ $? -le 1 ] || { echo "orchy: prompt_ban is not a valid regex" >&2; exit 2; }
  # the live roster joins the ban, so an account added after the bootstrap is banned too; the slot label main never is
  rr=$(roster_re) || exit 2; [ -z "$rr" ] || ban="($ban)|$rr"
  rc=0; for f in "$@"; do [ -r "$f" ] || { echo "orchy: cannot read $f" >&2; rc=2; continue; }
    hits=$(grep -nE "$ban" "$f"); [ $? -le 1 ] || { echo "orchy: cannot scan $f" >&2; rc=2; continue; }
    [ -z "$hits" ] || { echo "orchy: $f carries banned text:"; head -5 <<<"$hits" | cut -c1-160; rc=1; }; done; exit $rc
}
public_ok() { # public_ok <file> <what>: check-public, its refusal as one line naming the patterns hit
  local o; o=$("$0" check-public "$1" 2>&1)
  case $? in 0) ;; 1) echo "refused: $2 fails check-public ($(grep -oE '^(LEAK|SENSITIVE|SECRET)|copies the owner' <<<"$o" | sort -u | paste -sd, -))" >&2; return 1;;
    *) echo "refused: check-public could not run" >&2; return 1;; esac
}
orchy_check_private() { [ $# -gt 0 ] || { echo "usage: check-private <file>..." >&2; exit 2; }; bash "$OVERLAP" "$LEDGER" "$@"; }
orchy_check_public() {
  # Fails closed: a check that cannot run refuses (exit 2), unlike scan, which reports what it could read.
  sens=1; [ "${1:-}" = --no-sensitive ] && { sens=0; shift; }
  f=${1:-}; [ -r "$f" ] || { echo "usage: check-public [--no-sensitive] <file>" >&2; exit 2; }
  bash "$OVERLAP" "$LEDGER" "$f"; rc=$?; [ "$rc" -le 1 ] || { echo "refused: the copy check could not run" >&2; exit 2; }
  # a policy file that cannot be parsed refuses: an empty pattern would pass everything
  if ! leakre=$(cfg '.scan.leak // empty') || ! ban=$(jq -r '.prompt_ban // empty' "$LOCAL"); then echo "refused: orchy.json or local.json cannot be read" >&2; exit 2; fi
  [ -n "$ban" ] && leakre="${leakre:+($leakre)|}($ban)"
  rr=$(roster_re) || { echo "refused: the roster cannot be read" >&2; exit 2; }; [ -z "$rr" ] || leakre="${leakre:+($leakre)|}$rr"
  [ -n "$leakre" ] || { echo "refused: neither scan.leak nor prompt_ban is set" >&2; exit 2; }
  # the default pattern only on confirmed absence: -e is also false behind an unsearchable page/
  dj="$H/page/decisions.json"; sre=
  if [ -e "$dj" ]; then sre=$(jq -r '.site.sensitive // empty' "$dj") || { echo "refused: decisions.json cannot be read" >&2; exit 2; }
  elif [ ! -d "$H/page" ] || [ ! -x "$H/page" ]; then echo "refused: cannot tell whether decisions.json exists" >&2; exit 2; fi
  : "${sre:=\\bfindings?\\b|advisor(y|ies)|GHSA|vulnerab|exploit|\\battack|confidential}"   # apply-decisions.ts's default
  for kind in LEAK SENSITIVE; do
    if [ $kind = LEAK ]; then hits=$(grep -nE -- "$leakre" "$f"); r=$?; else [ $sens = 1 ] || continue; hits=$(grep -niE -- "$sre" "$f"); r=$?; fi
    [ "$r" -le 1 ] || { echo "refused: the $kind pattern is not a valid grep -E regex" >&2; exit 2; }
    [ -z "$hits" ] || { echo "$kind:"; cut -c1-160 <<<"$hits" | head -5; rc=1; }
  done
  gl=$(tool "${ORCHY_GITLEAKS:-}" gitleaks "${HOME:-}/.local/bin/gitleaks"); command -v "$gl" >/dev/null || { echo "refused: $gl not found, so the secret check cannot run" >&2; exit 2; }
  "$gl" stdin --no-banner --redact --exit-code 3 -l error < "$f" >/dev/null 2>&1; r=$?
  case $r in 0) ;; 3) echo "SECRET: gitleaks found a secret"; rc=1;; *) echo "refused: gitleaks failed (exit $r)" >&2; exit 2;; esac
  exit $rc
}
orchy_scan() {
  need gh; quick=0; a=(); for x in "$@"; do if [ "$x" = --quick ]; then quick=1; else a+=("$x"); fi; done
  n=${a[0]:-}; pin=${a[1]:-}
  [[ "$n" =~ ^[1-9][0-9]*$ ]] && { [ -z "$pin" ] || sha_ok "$pin"; } && [ "${#a[@]}" -le 2 ] || { echo "usage: scan <pr> [<full-sha>] [--quick]" >&2; exit 2; }
  hb=$(gh pr view "$n" --repo "$REPO" --json headRefOid,baseRefName --jq '"\(.headRefOid) \(.baseRefName)"') || { echo "SCAN FAILED: gh pr view #$n"; exit 2; }
  read -r h base <<<"$hb"; pin=${pin:-$h}
  [ "$h" = "$pin" ] || { echo "SCAN FAILED: head moved"; exit 2; }
  [[ "$base" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] && sha_ok "$pin" || { echo "SCAN FAILED: #$n's base or head is unreadable"; exit 2; }
  # the content is read at the sha, never through the PR: a head can move during the reads and back before the last check
  c="repos/$REPO/compare/$base...$pin"
  d=$(gh api "$c" -H 'Accept: application/vnd.github.diff') || { echo "SCAN FAILED: the diff of #$n"; exit 2; }
  cj=$(gh api "$c") || { echo "SCAN FAILED: the files of #$n"; exit 2; }
  # compare stops at 300 files and 250 commits without saying so
  jq -e '(.files | type) == "array" and (.files | length) < 300 and .total_commits == (.commits | length)' <<<"$cj" >/dev/null \
    || { echo "SCAN FAILED: #$n is more than one compare lists (300 files, 250 commits); read it by hand"; exit 2; }
  files=$(jq -r '.files[] | .filename, (.previous_filename // empty)' <<<"$cj" | sort -u)   # a rename touches its old path too
  nf=$(jq '[.files[] | .filename, (.previous_filename // empty)] | unique | length' <<<"$cj")   # a name with a newline is one file
  meta=$(gh pr view "$n" --repo "$REPO" --json title,body --jq '.title, .body') || { echo "SCAN FAILED: gh pr view #$n"; exit 2; }
  meta=$meta$'\n'$(jq -r '.commits[].commit.message' <<<"$cj")
  h=$(gh pr view "$n" --repo "$REPO" --json headRefOid --jq .headRefOid) || { echo "SCAN FAILED: gh pr view #$n"; exit 2; }
  [ "$h" = "$pin" ] || { echo "SCAN FAILED: head moved"; exit 2; }
  # the local ban (roster names, page ids) never sits in the committed config, so it joins the leak pattern here
  leakre=$(cfg '.scan.leak'); ban=$(lcl '.prompt_ban // empty'); [ -n "$ban" ] && leakre="($leakre)|($ban)"
  rr=$(roster_re) || { echo "SCAN FAILED: the roster cannot be read"; exit 2; }; [ -z "$rr" ] || leakre="($leakre)|$rr"
  gf=$(echo "$files" | grep -E "$(cfg '.scan.gate_files')" || true)
  add=$(echo "$d" | grep -E '^\+' | grep -v '^+++' | grep -E "$(cfg '.scan.weakening')" || true)
  leak=$( (echo "$d" | grep -E '^\+'; echo "$meta") | grep -E "$leakre" || true)
  echo "#$n files=$nf gatefiles=$(echo -n "$gf" | grep -c .) added=$(echo -n "$add" | grep -c .) leaks=$(echo -n "$leak" | grep -c .)"
  [ -n "$gf" ] && echo "$gf" | sed 's/^/  GATE FILE: /'
  [ -n "$add" ] && echo "$add" | cut -c1-200 | sed 's/^/  ADDED: /'
  [ -n "$leak" ] && echo "$leak" | cut -c1-200 | sed 's/^/  LEAK: /'
  [ "$quick" = 1 ] || exit 0
  # the bounds a script can see: a manifest holds the dependencies and the scripts the gates run. One surface, persisted
  # shapes, a dependency no manifest names (a URL import) and what a person sees are the reader's.
  why=$( { [ -n "$gf" ] && echo "a gate file"
    grep -qE '(^|/)([^/]*\.lockb?|[^/]*-lock\.(json|yaml)|npm-shrinkwrap\.json|go\.sum|[^/]*\.lockfile)$' <<<"$files" && echo "a lockfile"
    grep -qE '(^|/)(package\.json|deno\.jsonc?|Cargo\.toml|go\.mod|pyproject\.toml|Pipfile|requirements[^/]*\.txt|Gemfile|composer\.json)$' <<<"$files" && echo "a manifest"
    grep -qE '^\.github/(workflows|actions)/' <<<"$files" && echo "a workflow"
    [ "$nf" -le 5 ] || echo "$nf files"; } | paste -sd, | sed 's/,/, /g')
  [ -z "$why" ] && { echo "QUICK: within bounds"; exit 0; }
  echo "QUICK: past the bounds: $why"; exit 3
}
