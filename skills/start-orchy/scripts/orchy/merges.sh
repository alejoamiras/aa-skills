# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Merge watchers: the merge policy checked mechanically on a pinned head, armed detached and disarmed by pid.
ARCHIVE=$(cfg '.plans.archive // "implementations-plan/archive"')
# A watcher log's newest marker line, not its last line (a runs table or status lines often follow), as the
# state reports it: a merge reads MERGED, an unreadable post-merge state AMBIGUOUS, a closed PR or a disarm nothing.
watch_marker() {
  # a marker counts only at a line's start, and MERGED, a stop and DISARMED only after the watcher's own stamp: check names
  # and gh output are untrusted and the runs table is indented, so neither can end a hand-back or forge a merge
  local mk; mk=$(grep -oE '^#[0-9]+ (MERGED|is (MERGED|CLOSED); watcher stopped$)|^[0-9]{2}:[0-9]{2}Z DISARMED$|^(([0-9]{2}:[0-9]{2}Z|#[0-9]+) )?(HEAD MOVED|DIRTY|TRUNK RED|TRUNK UNREADABLE|REQUIRED FAILED|MISSING REQUIRED CHECK|NOT MERGED|TIMEOUT|REFUSED|state unreadable after the merge call)' "$1" 2>/dev/null | tail -n 1)
  [[ "$mk" =~ ^([0-9]{2}:[0-9]{2}Z|#[0-9]+)\ (.*)$ ]] && mk=${BASH_REMATCH[2]}
  case $mk in
    MERGED | "is MERGED; watcher stopped") echo MERGED;;
    "is CLOSED; watcher stopped" | DISARMED | "") ;;
    "state unreadable"*) echo AMBIGUOUS;;
    *) echo "$mk";;
  esac
}
merge_arg_err() { # <pr> <pin> <lane> <report> <archive|->: why a watcher must not take these, or nothing; each lands in a path or gh's argv
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || { echo "the PR must be a number"; return; }
  sha_ok "$2" || { echo "pin must be the full 40-hex head sha"; return; }
  name_ok "$3" || { echo "the lane must be a slug"; return; }
  name_ok "$4" || { echo "the report must be a file name under reports/"; return; }
  [ "$5" = - ] || name_ok "$5" || echo "the archive must be a plan name, or - for none"
}
arm_watch() { # arm_watch <delay-s> <pr> <watch-merge args>...: the watcher detached in its own session, its .pid and .out under watch/
  local d=$1 n=$2 p; shift
  watcher_alive "$H/watch/merge-$n.pid" && { echo "refused: merge-$n is already armed (pid $(cut -d' ' -f1 "$H/watch/merge-$n.pid"))"; return 1; }
  # every value is an argument, never part of the script bash -c reads
  ( cd "$ROOT" && exec env ORCHY_ROOT="$ROOT" ORCHY_HOME="$H" setsid nohup bash -c 'sleep "$1"; shift; exec bash "$@"' _ "$d" "$(realpath "$0")" watch-merge "$@" ) > "$H/watch/merge-$n.out" 2>&1 &
  p=$!; echo "$p $(pid_start "$p")" > "$H/watch/merge-$n.pid"; sleep 1; }   # the watcher overwrites this with its own identity once it runs
checks() { # name<TAB>status<TAB>conclusion: the newest check-run per name, then a commit status only for a name no check-run carries; exit 1 on an API failure
  local cr st
  cr=$(gh api "repos/$REPO/commits/$1/check-runs" --paginate --jq '.check_runs[] | {id, name, status, conclusion}' 2>/dev/null) || return 1
  st=$(gh api "repos/$REPO/commits/$1/status" --paginate --jq '.statuses[] | "\(.context)\tcompleted\t\(.state)"' 2>/dev/null) || return 1
  cr=$(jq -rs 'group_by(.name) | map(max_by(.id)) | .[] | "\(.name)\t\(.status)\t\(.conclusion)"' <<<"$cr")
  printf '%s\n' "$cr"
  [ -z "$st" ] || awk -F'\t' 'NR==FNR{seen[$1]=1; next} !($1 in seen)' <(printf '%s\n' "$cr") <(printf '%s\n' "$st" | sed 's/\terror$/\tfailure/')
}
base_state() { # base_state <branch> <check>...: the branch head's sha, then one line per check that concluded failure or timed_out there; exit 1 when unreadable
  local b=$1 sha runs n; shift; sha=$(gh api "repos/$REPO/commits/$b" --jq .sha 2>/dev/null) && sha_ok "$sha" || return 1
  runs=$(checks "$sha") || return 1; echo "$sha"
  for n in "$@"; do awk -F'\t' -v n="$n" '$1==n' <<<"$runs" | tail -1 | grep -qE $'\tcompleted\t(failure|timed_out)$' && echo "$n"; done
  return 0
}
trunk_state() { local c; mapfile -t c < <(cfg '(.merge.trunk_checks // .merge.required_checks)[]'); base_state "$TRUNK" "${c[@]}"; }
orchy_watch_merge() {
  need gh; need timeout; N=${1:-}; PIN=${2:-}; ACT=""; BASE=$TRUNK
  if [ "${3:-}" = --act ]; then   # armed by act merge: its base's checks and method, no report, no teardown, the authority re-read before the call
    method=${5:-}; AUTH=${6:-}; AASK=${7:-}; LANE=${8:--}
    ACT=$(act_norm merge "$N" "$PIN" "${4:-}" "$method" 2>/dev/null) && [[ "$AUTH" =~ ^(go|ok|grant)$ && "$AASK" =~ ^ask[0-9]+$ ]] \
      && { [ "$LANE" = - ] || name_ok "$LANE"; } || { echo "REFUSED: the act's arguments"; exit 4; }
    BASE=$4; rj=$(base_req "$BASE" "$method") || { echo "REFUSED: $rj"; exit 4; }
    mapfile -t REQ < <(jq -r '.req[]' <<<"$rj"); mapfile -t BCHK < <(jq -r '.base[]' <<<"$rj")
  else
    LANE=${3:-}; REPORT=${4:-}; ARCH=${5:-${3:-}}
    e=$(merge_arg_err "$N" "$PIN" "$LANE" "$REPORT" "$ARCH"); [ -z "$e" ] || { echo "REFUSED: $e"; exit 4; }
    mapfile -t REQ < <(cfg '.merge.required_checks[]'); [ "${#REQ[@]}" -gt 0 ] || { echo "REFUSED: merge.required_checks is empty"; exit 4; }
    mapfile -t BCHK < <(cfg '(.merge.trunk_checks // .merge.required_checks)[]')
    # spliced into `--$method`, so any other value could be --admin
    method=$(cfg '.merge.method // "squash"'); case $method in squash|merge|rebase) ;; *) echo "REFUSED: merge.method must be squash, merge or rebase"; exit 4;; esac
  fi
  rounds=$(cfg '.merge.watch_rounds // 300'); WS=${ORCHY_WATCH_SLEEP:-60}; SCANNED=$PIN
  grace=$(cfg '.merge.check_grace_sec // 600'); [[ "$grace" =~ ^[0-9]{1,6}$ ]] || { echo "REFUSED: merge.check_grace_sec must be whole seconds"; exit 4; }
  echo "$$ $(pid_start $$)" > "$H/watch/merge-$N.pid"   # the watcher's own identity, whatever wrapper started it
  trunk_said=""
  st=$(pr_state) || { echo "REFUSED: cannot read #$N"; exit 4; }
  read -r state draft base head _ <<<"$st"
  [ "$base" = "$BASE" ] || { echo "REFUSED: #$N targets $base, not $BASE"; exit 4; }
  [ "$state" = OPEN ] || { echo "REFUSED: #$N is $state"; exit 4; }
  # lane PRs share the owner's login, so the branch, not the author, is the provenance; a fork or an app's PR is never a lane's
  pv=$(gh pr view "$N" --repo "$REPO" --json isCrossRepository,author,headRefName --jq '[.isCrossRepository, .author.is_bot, .author.login, .headRefName] | @tsv' 2>/dev/null) \
    || { echo "REFUSED: cannot read #$N"; exit 4; }
  IFS=$'\t' read -r fork bot who ref <<<"$pv"
  if [ -n "$ACT" ]; then   # act checked the shape when it armed; a fork reaches only the trunk, and only on an OK
    [ "$fork" = false ] || { [ "$BASE" = "$TRUNK" ] && [ "$AUTH" = ok ]; } || { echo "REFUSED: #$N comes from a fork"; exit 4; }
    [ "$AUTH" != go ] || go_shape "$ref" "$bot" "$who" "$BASE" "$LANE" || { echo "REFUSED: #$N is none of the shapes a go merges"; exit 4; }
    authorized "$AUTH" "$AASK" "$ACT" "$LANE" || { echo "REFUSED: no live $AUTH on $AASK for $ACT"; exit 4; }
  else
    [ "$fork" = false ] || { echo "REFUSED: #$N comes from a fork"; exit 4; }
    [ "$bot" = false ] || { echo "REFUSED: #$N was opened by $who, not a lead"; exit 4; }
    [ "$ref" = "worktree-$LANE" ] || [[ "$ref" == "$LANE"-* ]] || { echo "REFUSED: #$N head $ref is not lane $LANE's branch"; exit 4; }
  fi
  # the pin binds the head, not the base: the merge must land on this base or a descendant of it
  B0=$(gh api "repos/$REPO/commits/$BASE" --jq .sha 2>/dev/null) && sha_ok "$B0" || { echo "REFUSED: cannot read $BASE's head"; exit 4; }
  HS=all; [ "$BASE" = "$TRUNK" ] && HS=trunk   # a trunk hold stops only merges into the trunk
  i=0; said_held=""; merged=0; claimed=0; updated=0
  while :; do   # polling, then the merge step, which comes back here when a hold landed in between
    wm_poll
    echo "$(date -u +%H:%MZ) required ok=$ok/${#REQ[@]} report_done=$(report_done && echo yes || echo no) state: $m"
    [ "$m" = "MERGEABLE CLEAN" ] || { echo "TIMEOUT; not merged"; exit 3; }
    wm_merge || continue   # a hold landed after the last poll: back to polling, which says HELD
    break
  done
  [ "$merged" = 1 ] || { echo "NOT MERGED; check #$N by hand"; exit 6; }
  [ -z "$ACT" ] || exit 0
  [ "$ARCH" = - ] && { echo "--- no plan to archive: the orchestrator tears $LANE down"; exit 0; }
  echo "--- teardown $LANE once the archived plan is on $TRUNK"
  on_trunk=0; for _ in 1 2 3 4 5 6; do git -C "$ROOT" fetch -q origin "$TRUNK"; git -C "$ROOT" cat-file -e "FETCH_HEAD:$ARCHIVE/$ARCH/plan.md" 2>/dev/null && { on_trunk=1; break; }; sleep $((WS/4)); done
  if [ $on_trunk = 1 ]; then "$0" teardown "$LANE" 2>&1 | tail -3; else echo "archived plan not on $TRUNK yet; teardown skipped"; fi
}
pr_state() { gh pr view "$N" --repo "$REPO" --json state,isDraft,baseRefName,headRefOid,mergeable,mergeStateStatus --jq '"\(.state) \(.isDraft) \(.baseRefName) \(.headRefOid) \(.mergeable) \(.mergeStateStatus)"' 2>/dev/null; }
report_done() { # the LAST marker line of the report decides; it must be exactly LEAD_DONE, with a PR line for this PR and a full-sha HEAD line equal to the scanned pin
  [ -z "$ACT" ] || return 0
  local r="$H/reports/$REPORT" own="" rx='LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*' last; [ -f "$r" ] || return 1
  # or LEAD_DONE <lane> <arc>, the tokens of this report's own key <lane>-<arc>.md: both are this watcher's arguments, so the
  # line carries no free text, names no other report, and reads as no other marker (each needs its own word first)
  [[ "$REPORT" == "$LANE"-?*.md ]] && own="LEAD_DONE $LANE ${REPORT:${#LANE}+1:-3}" && rx="$rx|${own//./\\.}"
  last=$(grep -xE "$rx" "$r" | tail -1); [ "$last" = LEAD_DONE ] || { [ -n "$own" ] && [ "$last" = "$own" ]; } || return 1
  grep -qE "^PR #$N( |$)" "$r" || return 1
  [ "$(grep -oE '^HEAD [0-9a-f]{40}$' "$r" | tail -1 | cut -d' ' -f2)" = "$SCANNED" ]
}
# An observed red trunk blocks, except for a PR that contains the red commit and passed the failed checks itself: a fix lane
# can land, an unrelated PR cannot. Pending does not block, and nothing here proves the trunk healthy; it is re-read every round.
trunk_ok() {
  local out tsha failed n all=1
  out=$(base_state "$BASE" "${BCHK[@]}") || { [ "$trunk_said" = unreadable ] || echo "$(date -u +%H:%MZ) TRUNK UNREADABLE; waiting"; trunk_said=unreadable; return 1; }
  tsha=${out%%$'\n'*}; failed=$(tail -n +2 <<<"$out"); [ -n "$failed" ] || { trunk_said=""; return 0; }
  if [ "$(gh api "repos/$REPO/compare/$tsha...$PIN" --jq .behind_by 2>/dev/null)" = 0 ]; then
    while IFS= read -r n; do awk -F'\t' -v n="$n" '$1==n' <<<"$runs" | tail -1 | grep -qE $'\tcompleted\tsuccess$' || all=0; done <<<"$failed"
    [ "$all" = 1 ] && return 0
  fi
  [ "$trunk_said" = "$tsha" ] || echo "$(date -u +%H:%MZ) TRUNK RED at ${tsha:0:8}: $(paste -sd, <<<"$failed"); waiting"; trunk_said=$tsha; return 1
}
wm_poll() { # polls until the PR may merge or the rounds run out, m holding its last merge state; every other hand-back exits
  m=""; ok=0; api_fail=0; quiet=""; said_wait=""; said_missing=""
  while [ "$i" -lt "$rounds" ]; do i=$((i+1))
    st=$(pr_state) || { api_fail=$((api_fail+1)); [ "$api_fail" = 10 ] && echo "$(date -u +%H:%MZ) API FAILURE: gh pr view failed 10 rounds running"; sleep "$WS"; continue; }; read -r state draft base head _ <<<"$st"
    [ "$state" = OPEN ] || { echo "#$N is $state; watcher stopped"; exit 4; }
    [ "$head" = "$PIN" ] || repin "$head" || { echo "HEAD MOVED to $head (scanned $SCANNED); rescan before merging"; exit 2; }
    runs=$(checks "$head") || { api_fail=$((api_fail+1)); [ "$api_fail" = 10 ] && echo "$(date -u +%H:%MZ) API FAILURE: check-runs unreadable 10 rounds running"; sleep "$WS"; continue; }; api_fail=0; ok=0; bad=""; absent=""; cx=""
    for name in "${REQ[@]}"; do
      line=$(awk -F'\t' -v n="$name" '$1==n' <<<"$runs" | tail -1)
      case "$line" in "") absent="$absent $name";; *$'\t'completed$'\t'success) ok=$((ok+1));; *$'\t'completed$'\t'cancelled) cx="$cx $name";; *$'\t'completed$'\t'failure|*$'\t'completed$'\t'timed_out) bad="$bad $name";; esac
    done
    [ -n "$absent" ] || said_missing=""
    if [ -z "$absent$cx" ]; then quiet=""; said_wait=""
    elif [ -z "$bad" ] && ! not_started; then bad=$cx   # past the grace: absent is missing, cancelled is failed
      [ -z "$absent" ] || [ -n "$said_missing" ] || { echo "$(date -u +%H:%MZ) MISSING REQUIRED CHECK (no run or status, nothing else running on the head for ${grace}s):$absent; a renamed check waits here until the timeout"; said_missing=1; }
    fi
    # the table is indented: a check name is untrusted and may carry a newline, and no line of it may start a marker
    [ -n "$bad" ] && { echo "$(date -u +%H:%MZ) REQUIRED FAILED:$bad"; printf '  %s\n' "${runs//$'\n'/$'\n  '}"; exit 1; }
    # a hold waits and never ends the watcher; an unreadable holds.json holds too
    hr=$(held "$HS") || hr="holds.json, unreadable"
    if [ -n "$hr" ]; then [ "$hr" = "$said_held" ] || echo "$(date -u +%H:%MZ) HELD: $hr; waiting"; said_held=$hr; sleep "$WS"; continue; fi
    said_held=""
    if [ "$ok" = "${#REQ[@]}" ] && report_done && trunk_ok; then
      read -r state draft base head mergeable mstate <<<"$(pr_state)"; m="$mergeable $mstate"
      [ "$m" = "MERGEABLE CLEAN" ] && break
      # BEHIND (a strict base) never clears while the head is pinned: one update per arm, then the base has to be merged in
      [ "$m $head" = "MERGEABLE BEHIND $PIN" ] && update_branch && { sleep "$WS"; continue; }
      case "$m" in CONFLICTING*|*DIRTY) echo "$(date -u +%H:%MZ) DIRTY: $m"; exit 5;; *BEHIND) echo "$(date -u +%H:%MZ) DIRTY: $m; bring the base in first"; exit 5;; esac
    fi
    sleep "$WS"
  done
}
not_started() { # 0 while a required check may still start: anything else on the head queued or running, or within the grace after
  local now why; now=$(date +%s)
  # a suite with no runs is an app that may never report, so it holds nothing; the grace covers a real suite's first run
  if awk -F'\t' 'NF && $2 != "completed"' <<<"$runs" | grep -q . || [ -n "$(gh api "repos/$REPO/commits/$head/check-suites" --paginate \
      --jq '.check_suites[] | select(.status != "completed" and .latest_check_runs_count > 0) | .id' 2>/dev/null)" ]; then
    quiet=""; why="other checks on the head still run"
  else
    quiet=${quiet:-$now}; [ $((now - quiet)) -lt "$grace" ] || return 1; why="until $(date -u -d "@$((quiet + grace))" +%H:%MZ)"
  fi
  [ "$absent$cx|$why" = "$said_wait" ] || echo "$(date -u +%H:%MZ) waiting on required checks${absent:+ not started yet:$absent;}${cx:+ cancelled, for a newer run:$cx;} $why"
  said_wait="$absent$cx|$why"
}
update_branch() { # once per arm, a lane PR only (a fork's or an app's is refused at arming): GitHub merges the base in, pinned to the head
  local p hit=0; [ -z "$ACT" ] && [ "$updated" = 0 ] || return 1; updated=1
  # shellcheck disable=SC2053  # the protected entries are globs
  while IFS= read -r p; do [[ "$ref" == $p ]] && hit=1; done < <(cfg '(.protected // [])[]')
  [ "$hit" = 0 ] && ref_ok "$ref" && [ "$ref" != "$TRUNK" ] && [ "$(gh api "repos/$REPO/branches/$ref" --jq .protected 2>/dev/null)" = false ] \
    || { echo "$(date -u +%H:%MZ) not updating $ref: protected, or its protection unreadable"; return 1; }
  gh api "repos/$REPO/pulls/$N/update-branch" -X PUT -f expected_head_sha="$PIN" >/dev/null 2>&1 || { echo "$(date -u +%H:%MZ) update-branch refused"; return 1; }
  echo "$(date -u +%H:%MZ) BEHIND: GitHub merges $BASE into $ref (once per arm); the watcher re-pins that merge"
}
repin() { # the one move a watcher follows, after its own update: a merge of the scanned head and a base commit, its tree their clean merge
  local h=$1 p x more t
  [ "$updated" = 1 ] && [ "$PIN" = "$SCANNED" ] && sha_ok "$h" && timeout 120 git -C "$ROOT" fetch -q origin "$h" 2>/dev/null || return 1
  read -r p x more <<<"$(git -C "$ROOT" log -1 --format=%P "$h")"; [ "$p" = "$PIN" ] && sha_ok "$x" && [ -z "$more" ] || return 1
  case $(gh api "repos/$REPO/compare/$x...$BASE" --jq .status 2>/dev/null) in ahead|identical) ;; *) return 1;; esac
  t=$(git -C "$ROOT" merge-tree --write-tree "$PIN" "$x" 2>/dev/null) && [ "$t" = "$(git -C "$ROOT" rev-parse "$h^{tree}")" ] || return 1
  echo "$(date -u +%H:%MZ) re-pinned to $h: $BASE at ${x:0:8} merged into ${PIN:0:8}"; PIN=$h
}
wm_merge() { # up to three merge calls; 1 when a hold landed after the last poll, so polling resumes
  for try in 1 2 3; do
    [ "$(cfg '.mode // empty')" = triage ] && { echo "REFUSED: orchy.json mode is triage; not merged"; exit 4; }
    # every try: gh merges into whatever base the PR names then, and a PR can be retargeted during a retry's wait
    read -r state draft base head _ <<<"$(pr_state)"
    [ "$state" = OPEN ] && [ "$draft" = false ] && [ "$base" = "$BASE" ] && [ "$head" = "$PIN" ] || { echo "REFUSED at merge time: state=$state draft=$draft base=$base head=$head"; exit 4; }
    [ "$try" = 1 ] || trunk_ok || { echo "TRUNK RED at merge time; not merged"; exit 7; }
    case $(gh api "repos/$REPO/compare/$B0...$BASE" --jq .status 2>/dev/null) in
      ahead|identical) ;;
      "") echo "REFUSED at merge time: cannot read $BASE's history"; exit 4;;
      *) echo "HEAD MOVED: $BASE history was rewritten since arming"; exit 2;;
    esac
    margs=("--$method"); [ -n "$ACT" ] || margs+=(--delete-branch)   # an act's head may be the trunk itself
    if [ -n "$ACT" ] && [ "$claimed" = 0 ] && [ "$AUTH" = grant ]; then grant_pr_ok "$N" || { echo "REFUSED at merge time: #$N is no longer Dependabot's own"; exit 4; }; fi
    # holds.lock, shared, spans the hold check, the claim, the call and its outcome line; each call is bounded and runs without the descriptor
    ( flock -s -w 300 7 || { echo "REFUSED at merge time: holds.lock is busy for 300 s"; exit 4; }
      hr=$(held "$HS") || hr="holds.json, unreadable"; [ -z "$hr" ] || exit 10
      # an act spends its authority once, before its first call: a retry, on a moved base or after a hold, is the same attempt
      if [ -n "$ACT" ] && [ "$claimed" = 0 ]; then
        claim "$AUTH" "$AASK" "$ACT" "$LANE" 2>/dev/null || { echo "REFUSED at merge time: $ACT is no longer authorized"; exit 4; }
      elif [ -n "$ACT" ]; then
        unrevoked "$AUTH" "$AASK" "$ACT" "$LANE" || { echo "REFUSED at merge time: $ACT was revoked before its retry"; exit 4; }
      fi
      out=$(exec 7>&-; timeout 120 gh pr merge "$N" --repo "$REPO" "${margs[@]}" --match-head-commit "$PIN" 2>&1 | tail -1); echo "$out"
      for _ in 1 2 3; do sleep $((WS/10)); s=$(exec 7>&-; timeout 30 gh pr view "$N" --repo "$REPO" --json state --jq .state 2>/dev/null) && break; done
      [ -n "$s" ] || { echo "#$N state unreadable after the merge call; check it by hand"; exit 6; }
      if [ "$s" = MERGED ]; then
        (exec 7>&-; timeout 30 gh pr view "$N" --repo "$REPO" --json state,mergeCommit --jq '"#'"$N"' \(.state) \(.mergeCommit.oid)"' 2>/dev/null) || echo "#$N MERGED"; exit 0
      fi
      grep -q "Base branch was modified" <<<"$out" && exit 11; exit 12 ) 7>>"$HOLDS_LOCK"
    rc=$?; case $rc in
      0) merged=1; break;;
      10) return 1;;
      11) claimed=1; sleep $((WS/2));;
      12) break;;
      *) exit "$rc";;
    esac
  done
  return 0
}
orchy_arm_merge() {
  N=${1:-}; delay=${6:-0}
  e=$(merge_arg_err "$N" "${2:-}" "${3:-}" "${4:-}" "${5:-${3:-}}"); [ -z "$e" ] || { echo "refused: $e"; exit 4; }
  [[ "$delay" =~ ^[0-9]{1,5}$ ]] || { echo "refused: the delay is whole seconds"; exit 4; }
  # the watcher reads reports/<name> and waits silently for its LEAD_DONE, so a report it cannot find would idle for hours
  [ -f "$H/reports/$4" ] || { echo "refused: no report $H/reports/$4; pass its file name under reports/"; exit 4; }
  args=("$1" "$2" "$3" "$4"); [ -n "${5:-}" ] && args+=("$5")
  arm_watch "$delay" "${args[@]}" || exit 1
  echo "armed merge-$N pid $(cut -d' ' -f1 "$H/watch/merge-$N.pid") (delay ${delay}s) -> $H/watch/merge-$N.out"
}
orchy_disarm() {
  # through a symlinked watch dir, a pid file and a log would be another home's
  [ -L "$H/watch" ] && { echo "refused: $H/watch must not be a symlink" >&2; exit 1; }
  for f in "$H"/watch/merge-${1:-*}.pid; do [ -f "$f" ] || continue; n=$(basename "$f" .pid); num=${n#merge-}; stopped=0
    if watcher_alive "$f"; then p=$(cut -d' ' -f1 "$f"); kill -- "-$p" 2>/dev/null; kill "$p" 2>/dev/null; sleep 1; echo "stopped $n"; stopped=1
      if [[ "$num" =~ ^[0-9]+$ ]]; then ev merge.disarmed pr:="$num"; fi
    else echo "$n not running"; fi
    # a wrapper that had not exec'd yet, or a child gh call, may outlive the group kill: finish by command line, never by a bare name
    for q in $(pgrep -f "orchy.sh watch-merge $num " 2>/dev/null); do tr '\0' '\n' < "/proc/$q/environ" 2>/dev/null | grep -qxF "ORCHY_HOME=$H" || continue; kill "$q" 2>/dev/null && echo "stopped stray $q of $n"; done
    # after every stray, so nothing writes below it: the stopped watcher's hand-back no longer stands
    o="$H/watch/$n.out"; if [ "$stopped" = 1 ] && [ -f "$o" ] && [ ! -L "$o" ]; then echo "$(date -u +%H:%MZ) DISARMED" >> "$o"; fi
  done
}
