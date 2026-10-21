#!/usr/bin/env bash
# orchy: the backlog-program orchestrator's shell half. One entry point, subcommands below.
# State lives in $ORCHY_HOME (default ~/.cache/orchy/<owner>-<repo>): orchy.json (policy), local.json (accounts, caps),
# briefs, prompts, reports, leads, watch, wt, page. Nothing in the repo.
set -u
usage() { sed -n '/^# Subcommands/,/^# End/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
# Subcommands
#   home                         print ORCHY_HOME
#   config <jq-expr>             read $ORCHY_HOME/orchy.json ('.trunk', '.merge.required_checks[]')
#   local <jq-expr>              read $ORCHY_HOME/local.json (accounts, caps)
#   lock | unlock                claim this repo's orchestrator seat (refuses while another session holds it)
#   render <template> K=V ...    substitute <K> tokens in a template file to stdout; exit 1 on a token left over
#   check-text <file>...         refuse a file carrying a banned string (local.json prompt_ban: roster names, page ids)
#   wt-new <slug>...             create worktrees from origin/<trunk> and install deps; sequential; refuses an existing slug
#   launch [--light] <key> <slug> <account>            start a headless lead on prompts/<key>.md inside the lane worktree
#   resume [--light] <key> <slug> <account> <session>  resume a lead's session with prompts/<key>.md
#   session-id <key>             the session id a lead's log recorded
#   snapshot                     the tick's facts: reports, leads, watchers, PRs, worktrees, load, headroom
#   wait [seconds]               block until a report, lead, watcher or open-PR state changes (default 1500)
#   scan <pr>                    gate-weakening and leak scan of a PR's diff, body and commit messages
#   watch-merge <pr> <full-sha> <lane> <report> [archive-name]   merge on the standing policy, then tear the lane down
#   arm-merge  <pr> <full-sha> <lane> <report> [archive-name] [delay-s]   watch-merge detached (nohup, .out + .pid)
#   disarm [<pr>]                stop one merge watcher, or every one
#   teardown <slug>              remove a lane worktree whose HEAD is exactly a merged PR's head and whose tree is clean
# End
need() { command -v "$1" >/dev/null 2>&1 || { echo "orchy: $1 not found" >&2; exit 1; }; }
need jq; need git
ROOT=${ORCHY_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}
[ -n "$ROOT" ] || { echo "orchy: not inside a git repository (or set ORCHY_ROOT)" >&2; exit 1; }
origin=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
REPO=${ORCHY_REPO:-$(printf '%s' "$origin" | sed -E 's#^(git@|ssh://git@|https?://)[^/:]+[:/]##; s#\.git$##')}
[ -n "$REPO" ] || { echo "orchy: no origin remote; set ORCHY_REPO=owner/name" >&2; exit 1; }
slug=$(echo "$REPO" | tr '/' '-')
ORCHY_HOME=${ORCHY_HOME:-$HOME/.cache/orchy/$slug}
H="$ORCHY_HOME"; CFG="$H/orchy.json"; LOCAL="$H/local.json"
cmd=${1:-help}; shift || true
case "$cmd" in help|-h|--help) usage 0;; home) echo "$H"; exit 0;; esac
[ -f "$CFG" ] || { echo "orchy: no $CFG (run /start-orchy in the repo first)" >&2; exit 1; }
cfg() { jq -r "$1" "$CFG"; }
lcl() { [ -f "$LOCAL" ] && jq -r "$1" "$LOCAL" || echo ""; }
TRUNK=$(cfg '.trunk // "main"')
mkdir -p "$H"/{briefs,prompts,reports,leads,watch,wt,scratch,page/shots,page/build}
WT_ROOT="$ROOT/$(cfg '.worktrees.root // ".claude/worktrees"')"
ARCHIVE=$(cfg '.plans.archive // "implementations-plan/archive"')
now() { date -u +%FT%TZ; }
pstart() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null || echo ""; }   # a pid is reused; its start time is not
alive() { # alive <pid> [<start>]: the process exists, is a claude or claude-usage run, and has the recorded start time
  local p=$1 s=${2:-}; [ -n "$p" ] || return 1
  ps -o args= -p "$p" 2>/dev/null | grep -qE '(^|/)(claude|claude-usage)( |$)' || return 1
  [ -z "$s" ] || [ "$(pstart "$p")" = "$s" ]
}
watcher_alive() { local f=$1; [ -f "$f" ] || return 1; read -r p s < "$f"; [ -n "$p" ] && [ -d "/proc/$p" ] && { [ -z "${s:-}" ] || [ "$(pstart "$p")" = "$s" ]; }; }
lead_rows() { for f in "$H"/leads/*.started; do [ -f "$f" ] || continue; read -r pid st acct t weight _ < "$f"; alive "$pid" "$st" && echo "$(basename "$f" .started) $acct ${weight:-heavy} $pid"; done; }
refuse_account() {
  local a=$1; [ -n "$a" ] || { echo "refused: empty account" >&2; return 1; }
  if [ -f "$LOCAL" ] && jq -e --arg a "$a" '.accounts.never // [] | index($a)' "$LOCAL" >/dev/null; then echo "refused: $a is on accounts.never" >&2; return 1; fi
  if [ -f "$LOCAL" ] && [ "$(jq -r '.accounts.use // [] | length' "$LOCAL")" != "0" ] && ! jq -e --arg a "$a" '.accounts.use | index($a)' "$LOCAL" >/dev/null; then echo "refused: $a is not on accounts.use" >&2; return 1; fi
}
refuse_cap() { # refuse_cap <account> <heavy|light>
  local a=$1 w=$2 cap n
  cap=$(lcl ".accounts.${w}_per_account // empty"); [ -n "$cap" ] || return 0
  n=$(lead_rows | awk -v a="$a" -v w="$w" '$2==a && $3==w' | wc -l)
  [ "$n" -lt "$cap" ] || { echo "refused: $a already runs $n $w lead(s) (cap $cap); pass --force-cap to override" >&2; return 1; }
}
sha_ok() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
session_pid() { # the nearest `claude` ancestor is the orchestrator session; without one (a test, a plain shell) the caller's parent
  local p=$PPID c; while [ "$p" -gt 1 ] 2>/dev/null; do c=$(ps -o comm= -p "$p" 2>/dev/null); [ "$c" = claude ] && { echo "$p"; return; }; p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 1); done; echo "$PPID"
}
case "$cmd" in
config) cfg "$1";;
local) lcl "$1";;
lock)
  f="$H/orchestrator.lock"; me=$(session_pid)
  for try in 1 2; do
    if ( set -o noclobber; echo "$me $(pstart "$me") $(now) ${ORCHY_SESSION:-}" > "$f" ) 2>/dev/null; then echo "locked $REPO for session pid $me"; exit 0; fi
    read -r p st t _ < "$f"
    [ "$p" = "$me" ] && { echo "already locked by this session (pid $me)"; exit 0; }
    if [ -d "/proc/$p" ] && [ "$(pstart "$p")" = "$st" ]; then echo "refused: another orchestrator holds $REPO (pid $p since $t)"; exit 2; fi
    rm -f "$f"   # stale: the holder is gone
  done; echo "lock: could not claim $f"; exit 2;;
unlock) rm -f "$H/orchestrator.lock"; echo "unlocked";;
render)
  t=$1; shift; [ -f "$t" ] || t="$(dirname "$0")/../templates/$t"
  [ -f "$t" ] || { echo "orchy: no template $1" >&2; exit 1; }
  # values may carry newlines, '|', '&' or '/': a plain string replace, never sed
  python3 -I - "$t" "$@" <<'PY'
import sys, re
t = open(sys.argv[1]).read()
for kv in sys.argv[2:]:
    k, _, v = kv.partition("="); t = t.replace(f"<{k}>", v)
sys.stdout.write(t)
left = sorted(set(re.findall(r"<[A-Z_]{3,}>", t)))
if left: print("orchy: unrendered tokens: " + " ".join(left), file=sys.stderr); sys.exit(1)
PY
  ;;
check-text)
  ban=$(lcl '.prompt_ban // empty'); [ -n "$ban" ] || { echo "orchy: local.json has no prompt_ban" >&2; exit 2; }
  grep -qE "$ban" /dev/null 2>/dev/null; [ $? -le 1 ] || { echo "orchy: prompt_ban is not a valid regex" >&2; exit 2; }
  rc=0; for f in "$@"; do [ -r "$f" ] || { echo "orchy: cannot read $f" >&2; rc=2; continue; }
    hits=$(grep -nE "$ban" "$f" | head -5); [ -z "$hits" ] || { echo "orchy: $f carries banned text:"; echo "$hits" | cut -c1-160; rc=1; }; done; exit $rc;;
wt-new)
  need agent-worktree; install=$(cfg '.install // empty'); rc=0
  git -C "$ROOT" fetch -q origin "$TRUNK" || { echo "fetch failed"; exit 1; }
  for s in "$@"; do
    out="$H/wt/$s.out"; w="$WT_ROOT/$s"
    [ -d "$w" ] && { echo "$s: worktree exists at $w; refusing"; rc=1; continue; }
    { echo "== $(now) new $s"; } >> "$out"
    # never pipe `agent-worktree new` into head: SIGPIPE kills it after the branch exists and before the directory does
    if ! (cd "$ROOT" && agent-worktree new "$s" --no-start) >> "$out" 2>&1; then echo "$s: agent-worktree new failed (see $out)"; rc=1; continue; fi
    [ -d "$w" ] || { echo "$s: no directory at $w (see $out)"; rc=1; continue; }
    if (cd "$w" && git fetch -q origin "$TRUNK" && git reset -q --hard "origin/$TRUNK" && { [ -z "$install" ] || eval "$install"; }) >> "$out" 2>&1; then
      echo "install exit 0 $(git -C "$w" rev-parse --short HEAD) $(git -C "$w" rev-parse --abbrev-ref HEAD)" >> "$out"
    else echo "install exit 1" >> "$out"; rc=1; fi
    echo "$s: $(tail -n 1 "$out")"
  done; exit $rc;;
launch|resume)
  need claude-usage; weight=heavy; force=0
  while [ "${1:-}" = --light ] || [ "${1:-}" = --force-cap ]; do [ "$1" = --light ] && weight=light; [ "$1" = --force-cap ] && force=1; shift; done
  k=$1; w=$2; a=$3; sid=${4:-}; refuse_account "$a" || exit 1
  [ "$force" = 1 ] || refuse_cap "$a" "$weight" || exit 1
  [ "$cmd" = resume ] && [ -z "$sid" ] && { echo "usage: resume <key> <slug> <account> <session-id>" >&2; exit 1; }
  if [ -f "$H/leads/$k.started" ]; then read -r pid st _ < "$H/leads/$k.started"; alive "$pid" "$st" && { echo "refused: lead $k is alive (pid $pid)" >&2; exit 1; }; fi
  p="$H/prompts/$k.md"; [ -f "$p" ] || { echo "orchy: no prompt $p" >&2; exit 1; }
  "$0" check-text "$p" || exit 1
  d="$WT_ROOT/$w"; [ -d "$d" ] || { echo "orchy: no worktree $d" >&2; exit 3; }
  model=$(cfg '.leads.model // "opus"'); l1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")
  extra=(); [ "$cmd" = resume ] && extra=(--resume "$sid")
  # PRINT_BG_WAIT_CEILING=0: a headless turn that yields to a background task ends the session; the brief tells leads to poll inside one tool call instead.
  ( cd "$d" && exec env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 nohup claude-usage run "=$a" "${extra[@]}" -p "$(cat "$p")" --model "$model" --dangerously-skip-permissions --verbose --output-format stream-json > "$H/leads/$k.log" 2>&1 ) &
  pid=$!; sleep 1; echo "$pid $(pstart "$pid") $a $(now) $weight prompts/$k.md" > "$H/leads/$k.started"
  echo "$k ${cmd}d on $a pid $pid ($weight, load1 $l1)";;
session-id) grep -oE '"session_id":"[0-9a-f-]{36}"' "$H/leads/$1.log" 2>/dev/null | head -1 | cut -d'"' -f4;;
snapshot)
  need gh
  echo "== $(now) load1 $(cut -d' ' -f1 /proc/loadavg 2>/dev/null) nproc $(nproc 2>/dev/null)"
  echo "-- reports (newest first)"; ls -t "$H"/reports/*.md 2>/dev/null | head -12 | while read -r f; do printf '%s %s %s\n' "$(date -u -r "$f" +%m-%dT%H:%MZ)" "$(basename "$f")" "$(grep -xE 'LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*|SHOTS_READY.*|SHOTS_BLOCKED:.*' "$f" | tail -1 | cut -c1-80)"; done
  echo "-- progress"; for f in "$H"/reports/*.progress; do [ -f "$f" ] && printf '%s: %s\n' "$(basename "$f" .progress)" "$(tail -c 200 "$f" | tr '\n' ' ')"; done
  echo "-- leads"; lead_rows | while read -r k a w p; do echo "alive $k $a $w pid $p"; done
  echo "-- watchers"; for f in "$H"/watch/*.pid; do [ -f "$f" ] || continue; n=$(basename "$f" .pid); if watcher_alive "$f"; then echo "alive $n pid $(cut -d' ' -f1 "$f")"; else echo "ended $n: $(tail -n 1 "$H/watch/$n.out" 2>/dev/null | cut -c1-120)"; fi; done
  echo "-- open PRs"; gh pr list --repo "$REPO" --state open --json number,title,headRefOid,mergeable,mergeStateStatus,isDraft,baseRefName --jq '.[]|"#\(.number) \(.headRefOid[0:8]) \(.mergeable) \(.mergeStateStatus) draft=\(.isDraft) -> \(.baseRefName) \(.title)"' 2>/dev/null || echo "(gh pr list failed)"
  echo "-- worktrees"; git -C "$ROOT" worktree list | tail -n +2
  echo "-- headroom"; claude-usage 2>/dev/null | head -12;;
wait)
  LIMIT=${1:-1500}
  snap() {
    ls -l --time-style=+%s "$H"/reports/*.md 2>/dev/null | awk '{print $6, $7}'
    lead_rows | awk '{print "alive", $1}'
    for f in "$H"/watch/*.pid; do watcher_alive "$f" && echo "watcher $(basename "$f" .pid)"; done
  }
  prs() { gh pr list --repo "$REPO" --state open --json number,headRefOid,mergeable,isDraft --jq '.[]|"\(.number) \(.headRefOid[0:8]) \(.mergeable) \(.isDraft)"' 2>/dev/null; }
  a=$(snap); pa=$(prs); t0=$(date +%s); n=0
  while :; do
    sleep 20; n=$((n+1)); b=$(snap)
    if [ "$a" != "$b" ]; then echo "CHANGED (reports/leads/watchers):"; diff <(echo "$a") <(echo "$b") | grep '^[<>]' | head -20; exit 0; fi
    if [ $((n % 6)) -eq 0 ]; then pb=$(prs)
      # GitHub answers UNKNOWN while it recomputes mergeability; that is not a change
      pa=$(awk 'NR==FNR{m[$1]=$3; next} ($1 in m) && $3=="UNKNOWN"{$3=m[$1]} {print}' <(echo "$pb") <(echo "$pa")); pb=$(awk 'NR==FNR{m[$1]=$3; next} ($1 in m) && $3=="UNKNOWN"{$3=m[$1]} {print}' <(echo "$pa") <(echo "$pb"))
      [ -n "$pb" ] && [ "$pa" != "$pb" ] && { echo "CHANGED (PRs):"; diff <(echo "$pa") <(echo "$pb") | grep '^[<>]'; exit 0; }
    fi
    [ $(( $(date +%s) - t0 )) -ge "$LIMIT" ] && { echo "TIMEOUT after ${LIMIT}s, no change"; exit 0; }
  done;;
scan)
  need gh; n=$1
  d=$(gh pr diff "$n" --repo "$REPO") || { echo "SCAN FAILED: gh pr diff #$n"; exit 2; }
  files=$(gh pr diff "$n" --repo "$REPO" --name-only) || { echo "SCAN FAILED: gh pr diff --name-only #$n"; exit 2; }
  meta=$(gh pr view "$n" --repo "$REPO" --json body,commits --jq '.body, (.commits[].messageHeadline), (.commits[].messageBody)') || { echo "SCAN FAILED: gh pr view #$n"; exit 2; }
  gf=$(echo "$files" | grep -E "$(cfg '.scan.gate_files')" || true)
  add=$(echo "$d" | grep -E '^\+' | grep -v '^+++' | grep -E "$(cfg '.scan.weakening')" || true)
  leak=$( (echo "$d" | grep -E '^\+'; echo "$meta") | grep -E "$(cfg '.scan.leak')" || true)
  echo "#$n files=$(echo "$files" | grep -c .) gatefiles=$(echo -n "$gf" | grep -c .) added=$(echo -n "$add" | grep -c .) leaks=$(echo -n "$leak" | grep -c .)"
  [ -n "$gf" ] && echo "$gf" | sed 's/^/  GATE FILE: /'
  [ -n "$add" ] && echo "$add" | cut -c1-200 | sed 's/^/  ADDED: /'
  [ -n "$leak" ] && echo "$leak" | cut -c1-200 | sed 's/^/  LEAK: /'
  exit 0;;
watch-merge)
  need gh; N=$1; PIN=$2; LANE=$3; REPORT=$4; ARCH=${5:-$3}
  sha_ok "$PIN" || { echo "REFUSED: pin must be the full 40-hex head sha"; exit 4; }
  mapfile -t REQ < <(cfg '.merge.required_checks[]'); [ "${#REQ[@]}" -gt 0 ] || { echo "REFUSED: merge.required_checks is empty"; exit 4; }
  method=$(cfg '.merge.method // "squash"'); rounds=$(cfg '.merge.watch_rounds // 300'); WS=${ORCHY_WATCH_SLEEP:-60}
  pr_state() { gh pr view "$N" --repo "$REPO" --json state,isDraft,baseRefName,headRefOid,mergeable,mergeStateStatus --jq '"\(.state) \(.isDraft) \(.baseRefName) \(.headRefOid) \(.mergeable) \(.mergeStateStatus)"' 2>/dev/null; }
  checks() { # name<TAB>status<TAB>conclusion: the newest check-run per name, then a commit status only for a name no check-run carries; exit 1 on an API failure
    local cr st
    cr=$(gh api "repos/$REPO/commits/$1/check-runs" --paginate --jq '.check_runs[] | {id, name, status, conclusion}' 2>/dev/null) || return 1
    st=$(gh api "repos/$REPO/commits/$1/status" --jq '.statuses[] | "\(.context)\tcompleted\t\(.state)"' 2>/dev/null) || return 1
    cr=$(jq -rs 'group_by(.name) | map(max_by(.id)) | .[] | "\(.name)\t\(.status)\t\(.conclusion)"' <<<"$cr")
    printf '%s\n' "$cr"
    [ -z "$st" ] || awk -F'\t' 'NR==FNR{seen[$1]=1; next} !($1 in seen)' <(printf '%s\n' "$cr") <(printf '%s\n' "$st" | sed 's/\terror$/\tfailure/')
  }
  report_done() { # the LAST marker line of the report decides; it must be exactly LEAD_DONE, with a PR line for this PR and a full-sha HEAD line equal to the pin
    local r="$H/reports/$REPORT"; [ -f "$r" ] || return 1
    [ "$(grep -xE 'LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*' "$r" | tail -1)" = "LEAD_DONE" ] || return 1
    grep -qE "^PR #$N( |$)" "$r" || return 1
    [ "$(grep -oE '^HEAD [0-9a-f]{40}$' "$r" | tail -1 | cut -d' ' -f2)" = "$PIN" ]
  }
  st=$(pr_state) || { echo "REFUSED: cannot read #$N"; exit 4; }
  read -r state draft base head _ <<<"$st"
  [ "$base" = "$TRUNK" ] || { echo "REFUSED: #$N targets $base, not $TRUNK"; exit 4; }
  [ "$state" = OPEN ] || { echo "REFUSED: #$N is $state"; exit 4; }
  m=""; ok=0; missing_rounds=0; api_fail=0
  for i in $(seq 1 "$rounds"); do
    st=$(pr_state) || { api_fail=$((api_fail+1)); [ "$api_fail" = 10 ] && echo "$(date -u +%H:%MZ) API FAILURE: gh pr view failed 10 rounds running"; sleep "$WS"; continue; }; read -r state draft base head _ <<<"$st"
    [ "$head" = "$PIN" ] || { echo "HEAD MOVED to $head (scanned $PIN); rescan before merging"; exit 2; }
    runs=$(checks "$head") || { api_fail=$((api_fail+1)); [ "$api_fail" = 10 ] && echo "$(date -u +%H:%MZ) API FAILURE: check-runs unreadable 10 rounds running"; sleep "$WS"; continue; }; api_fail=0; ok=0; bad=""; absent=""
    for name in "${REQ[@]}"; do
      line=$(awk -F'\t' -v n="$name" '$1==n' <<<"$runs" | tail -1)
      case "$line" in "") absent="$absent $name";; *$'\t'completed$'\t'success) ok=$((ok+1));; *$'\t'completed$'\t'failure|*$'\t'completed$'\t'cancelled|*$'\t'completed$'\t'timed_out) bad="$bad $name";; esac
    done
    [ -n "$bad" ] && { echo "$(date -u +%H:%MZ) REQUIRED FAILED:$bad"; echo "$runs"; exit 1; }
    if [ -n "$absent" ]; then missing_rounds=$((missing_rounds+1)); [ "$missing_rounds" = 10 ] && echo "$(date -u +%H:%MZ) MISSING REQUIRED CHECK (no run or status after 10 rounds):$absent; a renamed check waits here until the timeout"; else missing_rounds=0; fi
    if [ "$ok" = "${#REQ[@]}" ] && report_done; then
      read -r state draft base head mergeable mstate <<<"$(pr_state)"; m="$mergeable $mstate"
      [ "$m" = "MERGEABLE CLEAN" ] && break
      case "$m" in CONFLICTING*|*DIRTY) echo "$(date -u +%H:%MZ) DIRTY: $m"; exit 5;; esac
    fi
    sleep "$WS"
  done
  echo "$(date -u +%H:%MZ) required ok=$ok/${#REQ[@]} report_done=$(report_done && echo yes || echo no) state: $m"
  [ "$m" = "MERGEABLE CLEAN" ] || { echo "TIMEOUT; not merged"; exit 3; }
  read -r state draft base head _ <<<"$(pr_state)"
  [ "$state" = OPEN ] && [ "$draft" = false ] && [ "$base" = "$TRUNK" ] && [ "$head" = "$PIN" ] || { echo "REFUSED at merge time: state=$state draft=$draft base=$base head=$head"; exit 4; }
  merged=0; for try in 1 2 3; do
    out=$(gh pr merge "$N" --repo "$REPO" "--$method" --delete-branch --match-head-commit "$PIN" 2>&1 | tail -1); echo "$out"
    sleep $((WS/10)); [ "$(gh pr view "$N" --repo "$REPO" --json state --jq .state)" = MERGED ] && { merged=1; break; }
    echo "$out" | grep -q "Base branch was modified" || break; sleep $((WS/2))
  done
  [ "$merged" = 1 ] || { echo "NOT MERGED; check #$N by hand"; exit 6; }
  gh pr view "$N" --repo "$REPO" --json state,mergeCommit --jq '"#'"$N"' \(.state) \(.mergeCommit.oid)"'
  echo "--- teardown $LANE once the archived plan is on $TRUNK"
  on_trunk=0; for t in 1 2 3 4 5 6; do git -C "$ROOT" fetch -q origin "$TRUNK"; git -C "$ROOT" cat-file -e "FETCH_HEAD:$ARCHIVE/$ARCH/plan.md" 2>/dev/null && { on_trunk=1; break; }; sleep $((WS/4)); done
  if [ $on_trunk = 1 ]; then "$0" teardown "$LANE" 2>&1 | tail -3; else echo "archived plan not on $TRUNK yet; teardown skipped"; fi;;
arm-merge)
  N=$1; sha_ok "$2" || { echo "refused: pin must be the full 40-hex head sha"; exit 4; }
  delay=${6:-0}; args=("$1" "$2" "$3" "$4"); [ -n "${5:-}" ] && args+=("$5")
  watcher_alive "$H/watch/merge-$N.pid" && { echo "refused: merge-$N is already armed (pid $(cut -d' ' -f1 "$H/watch/merge-$N.pid"))"; exit 1; }
  ( cd "$ROOT" && ORCHY_ROOT="$ROOT" ORCHY_HOME="$H" setsid nohup bash -c "sleep $delay; exec bash '$(realpath "$0")' watch-merge $(printf '%q ' "${args[@]}")" > "$H/watch/merge-$N.out" 2>&1 & p=$!; sleep 1; echo "$p $(pstart "$p")" > "$H/watch/merge-$N.pid" )
  echo "armed merge-$N pid $(cut -d' ' -f1 "$H/watch/merge-$N.pid") (delay ${delay}s) -> $H/watch/merge-$N.out";;
disarm)
  for f in "$H"/watch/merge-${1:-*}.pid; do [ -f "$f" ] || continue; n=$(basename "$f" .pid); if watcher_alive "$f"; then p=$(cut -d' ' -f1 "$f"); kill -- "-$p" 2>/dev/null || kill "$p"; echo "stopped $n"; else echo "$n not running"; fi; done;;
teardown)
  need gh; need agent-worktree; s=$1; W="$WT_ROOT/$s"; q="$(basename "$ROOT")/$s"
  [ -d "$W" ] || { echo "$s: no worktree dir"; (cd "$ROOT" && agent-worktree done "$q" --forget 2>&1 | tail -1); exit 0; }
  lead_rows | awk -v s="$s" '$1 ~ "^"s"(-|$)"' | grep -q . && { echo "$s: a lead of this lane is alive; refusing"; exit 4; }
  b=$(git -C "$W" rev-parse --abbrev-ref HEAD); head=$(git -C "$W" rev-parse HEAD); dirty=$(git -C "$W" status --short | wc -l)
  [ "$dirty" = "0" ] || { echo "$s: $dirty uncommitted files; refusing"; exit 3; }
  if out=$(cd "$ROOT" && agent-worktree done "$q" --merged --trunk "$TRUNK" 2>&1); then echo "$out" | tail -2; exit 0; fi
  echo "$out" | grep -qi 'refus' || { echo "$s: agent-worktree failed: $(echo "$out" | tail -1)"; exit 5; }
  # the squash proof can fail after a later PR rewrote a file the squash carried; a HEAD that IS a merged PR's head is proof enough, when the config allows a hand removal
  [ "$(cfg '.teardown.hand_remove // false')" = true ] || { echo "$out" | tail -2; echo "$s: hand removal is off (teardown.hand_remove); relay the refusal"; exit 2; }
  pr=$(gh pr list --repo "$REPO" --head "$b" --state merged --json number,headRefOid,baseRefName --jq ".[] | select(.headRefOid==\"$head\" and .baseRefName==\"$TRUNK\") | .number" | head -1)
  [ -n "$pr" ] || { echo "$s: HEAD $head is not the head of a PR merged into $TRUNK from $b; refusing"; exit 2; }
  (cd "$ROOT" && git worktree remove --force "$W" && git branch -D "$b" >/dev/null && agent-worktree done "$q" --forget >/dev/null 2>&1; git worktree prune); echo "$s: hand-removed (branch $b at $head = merged PR #$pr)";;
*) echo "orchy: unknown subcommand $cmd" >&2; usage 1;;
esac
