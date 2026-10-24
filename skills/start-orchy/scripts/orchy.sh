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
#   stop <key>                   end a live lead and every process it started
#   say <key> <text>             queue a steering note; a live lead gets it after its next tool call (inbox-hook.sh)
#   session-id <key>             the session id of a lead's latest run
#   snapshot                     the tick's facts: reports, leads, watchers, PRs, worktrees, load, headroom
#   wait [seconds]               block until a report, lead, watcher or open-PR state changes (default 1500)
#   scan <pr>                    gate-weakening and leak scan of a PR's diff, title, body and commit messages (plus the local ban)
#   watch-merge <pr> <full-sha> <lane> <report> [archive-name]   merge on the standing policy, then tear the lane down
#   arm-merge  <pr> <full-sha> <lane> <report> [archive-name] [delay-s]   watch-merge detached (nohup, .out + .pid)
#   disarm [<pr>]                stop one merge watcher, or every one
#   receipt [<lane>]             per lane: API-equivalent dollars, tokens, wall-clock, PRs merged, issues closed, failed arcs, Codex rounds
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
# Every program's home sits under one capacity root, so a launch can count all programs' leads under one lock.
# Lexical normalization only: with a trailing slash, -L would look through a symlinked home to its target.
CAP=$(realpath -sm "${ORCHY_CAPACITY_ROOT:-$HOME/.cache/orchy}")
ORCHY_HOME=$(realpath -sm "${ORCHY_HOME:-$CAP/$slug}")
H="$ORCHY_HOME"; CFG="$H/orchy.json"; LOCAL="$H/local.json"
cmd=${1:-help}; shift || true
case "$cmd" in help|-h|--help) usage 0;; home) echo "$H"; exit 0;; esac
[ -f "$CFG" ] || { echo "orchy: no $CFG (run /start-orchy in the repo first)" >&2; exit 1; }
cfg() { jq -r "$1" "$CFG"; }
lcl() { [ -f "$LOCAL" ] && jq -r "$1" "$LOCAL" || echo ""; }
TRUNK=$(cfg '.trunk // "main"')
case "$cmd" in wt-new|launch|resume|arm-merge)
  [ "$(cfg '.mode // empty')" = triage ] && { echo "refused: orchy.json mode is triage (labels, comments and pages only; no worktree, lead or merge)" >&2; exit 1; };; esac
# A lead runs the hook its settings file names, so nobody but the owner may write here. chmod tightens a fresh or loose
# home (a umask would also reach wt-new's product checkout), but cannot undo what another user planted while it was loose.
under=0; ds=("$H"); [ "$(dirname "$H")" = "$CAP" ] && under=1 && ds+=("$CAP")
for d in "${ds[@]}"; do [ ! -L "$d" ] && [ -O "$d" ] || { echo "orchy: $d must be a directory owned by $(id -un), not a symlink" >&2; exit 1; }; done
f=$({ find "$H" -maxdepth 2 ! -user "$EUID"; [ $under = 0 ] || find "$CAP" -maxdepth 1 ! -user "$EUID"; } 2>/dev/null | head -1)
[ -z "$f" ] || { echo "orchy: $f belongs to another user; refusing a home someone else could write" >&2; exit 1; }
mkdir -p "$H"/{briefs,prompts,reports,leads,watch,wt,scratch,inbox,page/shots,page/build}
chmod 700 "$H"; [ $under = 1 ] && chmod 700 "$CAP"
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
all_rows() { # <acct> <weight> <home>: every live lead of every program under the capacity root
  local f pid st acct t weight
  for f in "$CAP"/*/leads/*.started; do [ -f "$f" ] || continue; read -r pid st acct t weight _ < "$f"; alive "$pid" "$st" && echo "$acct ${weight:-heavy} ${f%/leads/*}"; done
}
cap_root_ok() { # the root holds every home and the spawn lock: whoever can rename or replace it can swap a lead's hook settings
  local p
  [ -d "$CAP" ] && [ ! -L "$CAP" ] && [ -O "$CAP" ] || { echo "refused: capacity root $CAP must be a directory owned by $(id -un), not a symlink" >&2; return 1; }
  for p in "$CAP" "$(dirname "$CAP")"; do case "$(stat -c %a "$p")" in *[2367]?|*[2367]) echo "refused: $p is group- or world-writable" >&2; return 1;; esac; done
  case "$(basename "$H")" in .*) echo "refused: a home named $(basename "$H") is invisible to the capacity count" >&2; return 1;; esac
  [ "$(cd "$(dirname "$H")" && pwd -P)" = "$(cd "$CAP" && pwd -P)" ] || { echo "refused: $H is not directly under the capacity root $CAP (ORCHY_CAPACITY_ROOT); its leads would escape the shared cap" >&2; return 1; }
}
refuse_cap() { # refuse_cap <account> <heavy|light>: the strictest cap among this program and the programs already running on the account
  local a=$1 w=$2 cap c n rows home
  cap=$(lcl ".accounts.${w}_per_account // empty")
  rows=$(all_rows | awk -v a="$a" -v w="$w" '$1==a && $2==w')
  while IFS= read -r home; do
    c=$(jq -r ".accounts.${w}_per_account // empty" "$home/local.json" 2>/dev/null); [ -n "$c" ] || continue
    { [ -z "$cap" ] || [ "$c" -lt "$cap" ]; } && cap=$c
  done < <([ -n "$rows" ] && cut -d' ' -f3- <<<"$rows" | sort -u)
  [ -n "$cap" ] || return 0
  n=$(grep -c . <<<"$rows")
  [ "$n" -lt "$cap" ] || { echo "refused: $a already runs $n $w lead(s) across programs (cap $cap); --force-cap only on the owner's word" >&2; return 1; }
}
sha_ok() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
checks() { # name<TAB>status<TAB>conclusion: the newest check-run per name, then a commit status only for a name no check-run carries; exit 1 on an API failure
  local cr st
  cr=$(gh api "repos/$REPO/commits/$1/check-runs" --paginate --jq '.check_runs[] | {id, name, status, conclusion}' 2>/dev/null) || return 1
  st=$(gh api "repos/$REPO/commits/$1/status" --jq '.statuses[] | "\(.context)\tcompleted\t\(.state)"' 2>/dev/null) || return 1
  cr=$(jq -rs 'group_by(.name) | map(max_by(.id)) | .[] | "\(.name)\t\(.status)\t\(.conclusion)"' <<<"$cr")
  printf '%s\n' "$cr"
  [ -z "$st" ] || awk -F'\t' 'NR==FNR{seen[$1]=1; next} !($1 in seen)' <(printf '%s\n' "$cr") <(printf '%s\n' "$st" | sed 's/\terror$/\tfailure/')
}
trunk_state() { # the trunk head's sha, then one line per trunk check that concluded failure or timed_out there; exit 1 when unreadable
  local sha runs n; sha=$(gh api "repos/$REPO/commits/$TRUNK" --jq .sha 2>/dev/null) && sha_ok "$sha" || return 1
  runs=$(checks "$sha") || return 1; echo "$sha"
  while IFS= read -r n; do awk -F'\t' -v n="$n" '$1==n' <<<"$runs" | tail -1 | grep -qE $'\tcompleted\t(failure|timed_out)$' && echo "$n"; done < <(cfg '(.merge.trunk_checks // .merge.required_checks)[]')
  return 0
}
session_pid() { # the nearest `claude` ancestor is the orchestrator session; without one (a test, a plain shell) the caller's parent
  local p=$PPID c; while [ "$p" -gt 1 ] 2>/dev/null; do c=$(ps -o comm= -p "$p" 2>/dev/null); [ "$c" = claude ] && { echo "$p"; return; }; p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 1); done; echo "$PPID"
}
case "$cmd" in
config) cfg "$1";;
local) lcl "$1";;
lock)
  f="$H/orchestrator.lock"; me=$(session_pid)
  for try in 1 2 3; do
    if ( set -o noclobber; echo "$me $(pstart "$me") $(now) ${ORCHY_SESSION:-}" > "$f" ) 2>/dev/null; then echo "locked $REPO for session pid $me"; exit 0; fi
    read -r p st t _ < "$f" 2>/dev/null || { sleep 1; continue; }
    [ "$p" = "$me" ] && { echo "already locked by this session (pid $me)"; exit 0; }
    if [ -d "/proc/$p" ] && [ "$(pstart "$p")" = "$st" ]; then echo "refused: another orchestrator holds $REPO (pid $p since $t)"; exit 2; fi
    # a stale holder: one contender at a time replaces it (the flock dies with its holder), so two contenders cannot unlink each other's fresh lock
    ( flock -w 5 9 || exit 1; read -r p2 _ < "$f" 2>/dev/null; [ "$p2" = "$p" ] && rm -f "$f"; exit 0 ) 9>"$f.takeover" || sleep 1
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
  need claude-usage; need flock; weight=heavy; force=0
  while [ "${1:-}" = --light ] || [ "${1:-}" = --force-cap ]; do [ "$1" = --light ] && weight=light; [ "$1" = --force-cap ] && force=1; shift; done
  k=$1; w=$2; a=$3; sid=${4:-}
  [[ "$k" =~ ^[A-Za-z0-9._-]+$ && "$w" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "refused: key and slug are [A-Za-z0-9._-]" >&2; exit 1; }
  refuse_account "$a" || exit 1; cap_root_ok || exit 1
  # Close-outs run one at a time: each merges the trunk's plan index and lessons, and two in flight would each miss the other's.
  if [[ "$k" == *-closeout ]]; then
    open=$(gh pr list --repo "$REPO" --state open --json headRefName --jq '.[].headRefName' 2>/dev/null) || { echo "refused: cannot list open PRs to serialize close-outs" >&2; exit 1; }
    other=$(grep -E -- '-closeout$' <<<"$open" | grep -vxF -- "$w-closeout" | head -1)
    [ -z "$other" ] || { echo "refused: close-out PR $other is still open; close-outs run one at a time" >&2; exit 1; }
  fi
  [ "$cmd" = resume ] && [ -z "$sid" ] && { echo "usage: resume <key> <slug> <account> <session-id>" >&2; exit 1; }
  p="$H/prompts/$k.md"; [ -f "$p" ] || { echo "orchy: no prompt $p" >&2; exit 1; }
  "$0" check-text "$p" || exit 1
  d="$WT_ROOT/$w"; [ -d "$d" ] || { echo "orchy: no worktree $d" >&2; exit 3; }
  model=$(cfg '.leads.model // "opus"'); l1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")
  case "$(cfg '.leads.permission_mode // "auto"')" in
    auto) perm=(--permission-mode auto --permission-prompts none);;
    bypass) perm=(--dangerously-skip-permissions);;
    *) echo "orchy: leads.permission_mode must be auto or bypass" >&2; exit 1;;
  esac
  extra=(); [ "$cmd" = resume ] && extra=(--resume "$sid")
  mkdir -p "$H/scratch/$w"; S="$H/leads/$k.settings.json"; L="$H/leads/$k.log"
  hook=$(printf '%q ' bash "$(realpath "$(dirname "$0")")/inbox-hook.sh" "$H/inbox/$k.jsonl"); hook=${hook% }
  jq -n --arg c "$hook" '{hooks: {PostToolUse: [{matcher: "*", hooks: [{type: "command", command: $c}]}]}}' > "$S"
  # Key check, count, spawn and the .started write are one step, so two programs cannot both take an account's last slot.
  # Nothing in here touches the network; the lead starts with fd 9 closed, so no descendant ever holds the lock.
  exec 9>"$CAP/.spawn.lock"; flock -w 30 9 || { echo "refused: spawn lock busy for 30 s" >&2; exit 1; }
  if [ -f "$H/leads/$k.started" ]; then read -r pid st _ < "$H/leads/$k.started"; alive "$pid" "$st" && { echo "refused: lead $k is alive (pid $pid)" >&2; exit 1; }; fi
  if [[ "$k" == *-closeout ]]; then other=$(lead_rows | awk -v k="$k" '$1 ~ /-closeout$/ && $1 != k {print $1; exit}')
    [ -z "$other" ] || { echo "refused: close-out lead $other is alive; close-outs run one at a time" >&2; exit 1; }; fi
  [ "$force" = 1 ] || refuse_cap "$a" "$weight" || exit 1
  # a killed run may end mid-line: the newline keeps the marker a line of its own
  printf '\n%s\n' "$(jq -nc --arg k "$k" --arg l "$w" --arg c "$cmd" --arg t "$(now)" '{type: "orchy_invocation", key: $k, lane: $l, cmd: $c, at: $t}')" >> "$L"
  # PRINT_BG_WAIT_CEILING=0: a headless turn that yields to a background task ends the session; the brief tells leads to poll inside one tool call instead.
  # setsid: the lead leads its own process group (a background subshell is not a group leader, so setsid does not fork and $! stays the lead).
  ( cd "$d" && exec 9>&- env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 setsid nohup claude-usage run "=$a" "${extra[@]}" -p "$(cat "$p")" --model "$model" "${perm[@]}" \
      --settings "$S" --add-dir "$H/reports" --add-dir "$H/scratch/$w" --verbose --output-format stream-json >> "$L" 2>> "$H/leads/$k.err" ) &
  pid=$!; for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$pid" && break; sleep 0.2; done
  pg=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  printf '%s %s %s %s %s %s %s\n' "$pid" "$(pstart "$pid")" "$a" "$(now)" "$weight" "prompts/$k.md" "${pg:-?}" > "$H/leads/$k.started.tmp" && mv "$H/leads/$k.started.tmp" "$H/leads/$k.started"
  exec 9>&-
  echo "$k ${cmd}d on $a pid $pid pgid ${pg:-?} ($weight, $(cfg '.leads.permission_mode // "auto"'), load1 $l1)";;
stop)
  k=$1; f="$H/leads/$k.started"; [ -f "$f" ] || { echo "$k: no lead record"; exit 1; }
  read -r pid st _ _ _ _ pg < "$f"; alive "$pid" "$st" || { echo "$k: not alive"; exit 0; }
  # Claude Code starts each Bash-tool shell as its own session leader, so a group kill alone misses a hung tool process:
  # collect the whole tree first, while every child still points at its parent.
  mapfile -t tree < <(ps -eo pid=,ppid= | awk -v r="$pid" '{p[$1]=$2} END {s[r]=1; c=1; while (c) {c=0; for (x in p) if (!(x in s) && (p[x] in s)) {s[x]=1; c=1}}; for (x in s) print x}')
  ids=(); for q in "${tree[@]}"; do if [ "$q" = "$pid" ]; then ids+=("$q:$st"); else ids+=("$q:$(pstart "$q")"); fi; done
  # A lead that exited before the walk may have handed its pid, group id and so the walked tree to a stranger: then signal
  # nothing. A lead that is simply gone leaves its orphans in the tree, and those are still ended.
  cur=$(pstart "$pid"); [ -n "$cur" ] && [ "$cur" != "$st" ] && { echo "$k: pid $pid now belongs to another process; nothing signalled"; exit 0; }
  [ "${pg:-?}" = "$pid" ] && [ "$cur" = "$st" ] && kill -TERM -- "-$pg" 2>/dev/null
  for e in "${ids[@]}"; do [ -n "${e#*:}" ] && [ "$(pstart "${e%%:*}")" = "${e#*:}" ] && kill -TERM "${e%%:*}" 2>/dev/null; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do left=0; for e in "${ids[@]}"; do [ "$(pstart "${e%%:*}")" = "${e#*:}" ] && left=1; done; [ "$left" = 0 ] && break; sleep 0.5; done
  for e in "${ids[@]}"; do [ -n "${e#*:}" ] && [ "$(pstart "${e%%:*}")" = "${e#*:}" ] && kill -KILL "${e%%:*}" 2>/dev/null; done
  echo "$k: stopped pid $pid and ${#ids[@]} process(es) in its tree";;
say)
  need flock; k=$1; shift; t="$*"
  [[ "$k" =~ ^[A-Za-z0-9._-]+$ ]] && [ -n "$t" ] || { echo "usage: say <key> <text>" >&2; exit 1; }
  [ -f "$H/leads/$k.started" ] && read -r pid st _ < "$H/leads/$k.started" && alive "$pid" "$st" || { echo "refused: no live lead $k; fold the note into its next prompt" >&2; exit 1; }
  # leads quote their instructions into committed plans, so a note passes the same ban as a prompt
  tf="$H/scratch/say.$$"; printf '%s\n' "$t" > "$tf"; "$0" check-text "$tf"; rc=$?; rm -f "$tf"; [ "$rc" = 0 ] || exit 1
  line=$(jq -nc --arg t "$(now)" --arg x "$t" '{at: $t, text: $x}')
  [ "$(printf '%s' "$line" | wc -c)" -le 3072 ] || { echo "refused: a note is at most 3 KiB once serialized; put the detail in a file under the lane's scratch dir and name it" >&2; exit 1; }
  ( flock -w 5 8 || exit 1; printf '%s\n' "$line" >&8 ) 8>>"$H/inbox/$k.jsonl" || { echo "refused: inbox lock busy" >&2; exit 1; }
  echo "queued for $k";;
session-id) grep -oE '"session_id":"[0-9a-f-]{36}"' "$H/leads/$1.log" 2>/dev/null | tail -1 | cut -d'"' -f4;;
snapshot)
  need gh
  echo "== $(now) load1 $(cut -d' ' -f1 /proc/loadavg 2>/dev/null) nproc $(nproc 2>/dev/null)"
  echo "-- reports (newest first)"; ls -t "$H"/reports/*.md 2>/dev/null | head -12 | while read -r f; do printf '%s %s %s\n' "$(date -u -r "$f" +%m-%dT%H:%MZ)" "$(basename "$f")" "$(grep -xE 'LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*|SHOTS_READY.*|SHOTS_BLOCKED:.*' "$f" | tail -1 | cut -c1-80)"; done
  echo "-- progress"; for f in "$H"/reports/*.progress; do [ -f "$f" ] && printf '%s: %s\n' "$(basename "$f" .progress)" "$(tail -c 200 "$f" | tr '\n' ' ')"; done
  echo "-- leads"
  # Health without sampling: how long the log has been silent, the progress file's age, and what the newest process in the
  # lead's tree is doing. STALLED? is advisory; the command and its age are the evidence.
  stall=$(( $(cfg '.leads.stall_after_min // 20') * 60 )); tnow=$(date +%s); ps_rows=$(ps -eo pid=,ppid=,etimes=,args=)
  lead_rows | while read -r k a w p; do
    q=$(( tnow - $(stat -c %Y "$H/leads/$k.log" 2>/dev/null || echo "$tnow") ))
    pf="$H/reports/$k.progress"; pa=$([ -f "$pf" ] && echo "$(( (tnow - $(stat -c %Y "$pf")) / 60 ))m" || echo "-")
    newest=$(awk -v r="$p" '
      { pid=$1; par[pid]=$2; et[pid]=$3; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+/, ""); cmd[pid]=$0 }
      END { s[r]=1; c=1; while (c) { c=0; for (x in par) if (!(x in s) && (par[x] in s)) { s[x]=1; c=1 } }
            best=""; for (x in s) if (x != r && (best == "" || et[x] < et[best])) best=x
            if (best != "") printf "%s (%dm)", substr(cmd[best], 1, 80), et[best] / 60 }' <<<"$ps_rows")
    flag=""; [ "$q" -gt "$stall" ] && flag="STALLED? "
    echo "alive $k $a $w pid $p ${flag}quiet $((q / 60))m progress $pa ${newest:+$newest}"
  done
  echo "-- inbox"; for f in "$H"/inbox/*.jsonl; do [ -f "$f" ] || continue
    c=$(cat "${f%.jsonl}.cursor" 2>/dev/null); [[ "$c" =~ ^[0-9]{1,15}$ ]] && c=$((10#$c)) || c=0
    n=$(tail -c +"$((c + 1))" "$f" | grep -c ''); [ "$n" -gt 0 ] && echo "$(basename "$f" .jsonl): $n undelivered"; done
  echo "-- watchers"; for f in "$H"/watch/*.pid; do [ -f "$f" ] || continue; n=$(basename "$f" .pid); if watcher_alive "$f"; then echo "alive $n pid $(cut -d' ' -f1 "$f")"; else echo "ended $n: $(tail -n 1 "$H/watch/$n.out" 2>/dev/null | cut -c1-120)"; fi; done
  echo "-- trunk"; if t=$(trunk_state); then f=$(tail -n +2 <<<"$t" | paste -sd, -); echo "$TRUNK ${t:0:8}: ${f:+RED $f}${f:-no failed trunk check}"; else echo "(trunk checks unreadable)"; fi
  echo "-- open PRs"; gh pr list --repo "$REPO" --state open --json number,title,headRefOid,mergeable,mergeStateStatus,isDraft,baseRefName --jq '.[]|"#\(.number) \(.headRefOid[0:8]) \(.mergeable) \(.mergeStateStatus) draft=\(.isDraft) -> \(.baseRefName) \(.title)"' 2>/dev/null || echo "(gh pr list failed)"
  echo "-- worktrees"; git -C "$ROOT" worktree list | tail -n +2
  echo "-- untriaged issues"
  if [ ! -f "$H/triaged.txt" ]; then echo "(no triaged.txt: write every triaged issue number into it, one per line)"
  elif iss=$(gh issue list --repo "$REPO" --state open --limit 1000 --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null); then
    awk -F'\t' 'FILENAME == ARGV[1] {t[$1]=1; next} $1 != "" && !($1 in t) {print "#" $1 " " substr($2, 1, 100)}' <(grep -oE '^[0-9]+' "$H/triaged.txt") <(printf '%s\n' "$iss")
  else echo "(gh issue list failed)"; fi
  echo "-- unsigned pages"; [ -f "$H/page/unsigned.json" ] && jq -r --argjson now "$(date +%s)" --slurpfile u "$H/page/unsigned.json" '.pages[] | select(.no as $n | $u[0] | index($n)) |
    "page \(.no) \(.name): " + (if .added_at then (($now - (.added_at | fromdateiso8601)) | "waiting \(. / 86400 | floor)d\(. % 86400 / 3600 | floor)h") else "age unknown" end)' "$H/page/decisions.json" 2>/dev/null
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
  meta=$(gh pr view "$n" --repo "$REPO" --json title,body,commits --jq '.title, .body, (.commits[].messageHeadline), (.commits[].messageBody)') || { echo "SCAN FAILED: gh pr view #$n"; exit 2; }
  # the local ban (roster names, page ids) never sits in the committed config, so it joins the leak pattern here
  leakre=$(cfg '.scan.leak'); ban=$(lcl '.prompt_ban // empty'); [ -n "$ban" ] && leakre="($leakre)|($ban)"
  gf=$(echo "$files" | grep -E "$(cfg '.scan.gate_files')" || true)
  add=$(echo "$d" | grep -E '^\+' | grep -v '^+++' | grep -E "$(cfg '.scan.weakening')" || true)
  leak=$( (echo "$d" | grep -E '^\+'; echo "$meta") | grep -E "$leakre" || true)
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
  echo "$$ $(pstart $$)" > "$H/watch/merge-$N.pid"   # the watcher's own identity, whatever wrapper started it
  pr_state() { gh pr view "$N" --repo "$REPO" --json state,isDraft,baseRefName,headRefOid,mergeable,mergeStateStatus --jq '"\(.state) \(.isDraft) \(.baseRefName) \(.headRefOid) \(.mergeable) \(.mergeStateStatus)"' 2>/dev/null; }
  report_done() { # the LAST marker line of the report decides; it must be exactly LEAD_DONE, with a PR line for this PR and a full-sha HEAD line equal to the pin
    local r="$H/reports/$REPORT"; [ -f "$r" ] || return 1
    [ "$(grep -xE 'LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*' "$r" | tail -1)" = "LEAD_DONE" ] || return 1
    grep -qE "^PR #$N( |$)" "$r" || return 1
    [ "$(grep -oE '^HEAD [0-9a-f]{40}$' "$r" | tail -1 | cut -d' ' -f2)" = "$PIN" ]
  }
  # An observed red trunk blocks, except for a PR that contains the red commit and passed the failed checks itself: a fix lane
  # can land, an unrelated PR cannot. Pending does not block, and nothing here proves the trunk healthy; it is re-read every round.
  trunk_said=""
  trunk_ok() {
    local out tsha failed n all=1
    out=$(trunk_state) || { [ "$trunk_said" = unreadable ] || echo "$(date -u +%H:%MZ) TRUNK UNREADABLE; waiting"; trunk_said=unreadable; return 1; }
    tsha=${out%%$'\n'*}; failed=$(tail -n +2 <<<"$out"); [ -n "$failed" ] || { trunk_said=""; return 0; }
    if [ "$(gh api "repos/$REPO/compare/$tsha...$PIN" --jq .behind_by 2>/dev/null)" = 0 ]; then
      while IFS= read -r n; do awk -F'\t' -v n="$n" '$1==n' <<<"$runs" | tail -1 | grep -qE $'\tcompleted\tsuccess$' || all=0; done <<<"$failed"
      [ "$all" = 1 ] && return 0
    fi
    [ "$trunk_said" = "$tsha" ] || echo "$(date -u +%H:%MZ) TRUNK RED at ${tsha:0:8}: $(paste -sd, <<<"$failed"); waiting"; trunk_said=$tsha; return 1
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
    if [ "$ok" = "${#REQ[@]}" ] && report_done && trunk_ok; then
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
    [ "$try" = 1 ] || trunk_ok || { echo "TRUNK RED at merge time; not merged"; exit 7; }
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
  ( cd "$ROOT" && exec env ORCHY_ROOT="$ROOT" ORCHY_HOME="$H" setsid nohup bash -c "sleep $delay; exec bash '$(realpath "$0")' watch-merge $(printf '%q ' "${args[@]}")" ) > "$H/watch/merge-$N.out" 2>&1 &
  p=$!; echo "$p $(pstart "$p")" > "$H/watch/merge-$N.pid"; sleep 1   # the watcher overwrites this with its own identity once it runs
  echo "armed merge-$N pid $(cut -d' ' -f1 "$H/watch/merge-$N.pid") (delay ${delay}s) -> $H/watch/merge-$N.out";;
disarm)
  for f in "$H"/watch/merge-${1:-*}.pid; do [ -f "$f" ] || continue; n=$(basename "$f" .pid); num=${n#merge-}
    if watcher_alive "$f"; then p=$(cut -d' ' -f1 "$f"); kill -- "-$p" 2>/dev/null; kill "$p" 2>/dev/null; sleep 1; echo "stopped $n"; else echo "$n not running"; fi
    # a wrapper that had not exec'd yet, or a child gh call, may outlive the group kill: finish by command line, never by a bare name
    for q in $(pgrep -f "orchy.sh watch-merge $num " 2>/dev/null); do tr '\0' '\n' < "/proc/$q/environ" 2>/dev/null | grep -qxF "ORCHY_HOME=$H" || continue; kill "$q" 2>/dev/null && echo "stopped stray $q of $n"; done
  done;;
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
receipt)
  need gh; python3 -I - "$H" "$REPO" "${1:-}" <<'PY'
import sys, os, re, json, glob, subprocess, datetime
H, repo, want = sys.argv[1:4]
# keys are <lane>-plan, <lane>-a<n>, <lane>-closeout; only logs written before invocation markers need the name
legacy_lane = lambda k: re.sub(r"-(plan|a\d+|closeout|shots[\w-]*)$", "", k)
KINDS = (("in", "input_tokens", "inputTokens"), ("out", "output_tokens", "outputTokens"),
         ("cache-read", "cache_read_input_tokens", "cacheReadInputTokens"), ("cache-write", "cache_creation_input_tokens", "cacheCreationInputTokens"))
segs = []
for path in sorted(glob.glob(f"{H}/leads/*.log")):
    key = os.path.basename(path)[:-4]; seg = None
    def new(lane, k, at): s = {"lane": lane, "key": k, "at": at, "sid": None, "result": None, "after": {}, "mtime": os.path.getmtime(path)}; segs.append(s); return s
    for line in open(path, errors="replace"):
        try: e = json.loads(line)
        except ValueError: continue
        if not isinstance(e, dict): continue
        t = e.get("type")
        if t == "orchy_invocation": seg = new(e.get("lane") or legacy_lane(key), e.get("key") or key, e.get("at") or ""); continue
        if t == "system" and e.get("subtype") == "init":
            if seg is None or (seg["sid"] and not seg["at"]): seg = new(legacy_lane(key), key, "")
            seg["sid"] = seg["sid"] or e.get("session_id"); continue
        if seg is None: seg = new(legacy_lane(key), key, "")
        if t == "result": seg["result"] = e; seg["after"] = {}
        elif t == "assistant" and isinstance(e.get("message"), dict) and e["message"].get("usage"):
            seg["after"][e["message"].get("id") or id(e)] = e["message"]["usage"]   # a message repeats per content block: keep the last
# On --resume, total_cost_usd and modelUsage are the session's running totals: each session counts its last result once,
# plus the unpriced usage of runs killed after it.
lanes, by_sid = {}, {}
for i, s in enumerate(segs): s["sid"] = s["sid"] or f"unknown-{i}"
for s in sorted(segs, key=lambda s: s["at"]): by_sid.setdefault(s["sid"], []).append(s)
for sid, ss in by_sid.items():
    L = lanes.setdefault(ss[0]["lane"], {"cost": 0.0, "tok": {k[0]: 0 for k in KINDS}, "partial": 0, "sessions": 0, "keys": set(), "start": None, "end": 0})
    L["sessions"] += 1
    done = [j for j, s in enumerate(ss) if s["result"]]
    if done:
        r = ss[done[-1]]["result"]; L["cost"] += float(r.get("total_cost_usd") or 0)
        for mu in (r.get("modelUsage") or {}).values():
            for name, _, camel in KINDS: L["tok"][name] += int(mu.get(camel) or 0)
    for s in ss[done[-1] if done else 0:]:
        L["partial"] += sum(int(u.get(snake) or 0) for u in s["after"].values() for _, snake, _ in KINDS)
    for s in ss:
        L["keys"].add(s["key"]); L["end"] = max(L["end"], s["mtime"])
        if s["at"] and (L["start"] is None or s["at"] < L["start"]): L["start"] = s["at"]
def gh(*a):
    p = subprocess.run(["gh", *a, "--repo", repo], capture_output=True, text=True)
    if p.returncode: raise RuntimeError(p.stderr.strip()[:120])
    return p.stdout.split()
tot = {"cost": 0.0, "partial": 0}
for lane in sorted(lanes):
    if want and lane != want: continue
    L = lanes[lane]; prs, failed, rounds = [], 0, 0
    for k in sorted(L["keys"]):
        try: rep = open(f"{H}/reports/{k}.md", errors="replace").read()
        except OSError: continue
        prs += [int(n) for n in re.findall(r"^PR #(\d+) ", rep, re.M)]
        failed += len(re.findall(r"^ARC_FAILED:", rep, re.M)); rounds += sum(int(n) for n in re.findall(r"^CODEX: converged in (\d+) round", rep, re.M))
    prs = sorted(set(prs)); merged = []
    for n in prs:
        try: out = open(f"{H}/watch/merge-{n}.out", errors="replace").read()
        except OSError: continue
        if re.search(rf"^#{n} MERGED [0-9a-f]+", out, re.M): merged.append(n)
    try:
        refs = sorted({int(i) for n in merged for i in gh("pr", "view", str(n), "--json", "closingIssuesReferences", "--jq", ".closingIssuesReferences[].number")})
        closed = [i for i in refs if gh("issue", "view", str(i), "--json", "state", "--jq", ".state") == ["CLOSED"]]
        issues = f"{len(closed)}" + (f" ({' '.join(f'#{i}' for i in closed)})" if closed else "")
    except RuntimeError as err: issues = f"? (gh: {err})"
    wall = "?"
    if L["start"]:
        secs = L["end"] - datetime.datetime.strptime(L["start"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
        wall = f"{int(secs // 3600)}h{int(secs % 3600 // 60):02d}m"
    tok = " ".join(f"{k} {v}" for k, v in L["tok"].items())
    part = f" + {L['partial']} unpriced tokens from killed runs" if L["partial"] else ""
    print(f"{lane}: ${L['cost']:.2f} API-equivalent{part}; {L['sessions']} session(s); tokens {tok}; wall {wall}; "
          f"PRs {' '.join(f'#{n}' for n in prs) or '-'} (merged {' '.join(f'#{n}' for n in merged) or '-'}); issues closed {issues}; "
          f"failed arcs {failed}; Codex rounds {rounds}")
    tot["cost"] += L["cost"]; tot["partial"] += L["partial"]
if not want and len(lanes) > 1: print(f"total: ${tot['cost']:.2f} API-equivalent" + (f" + {tot['partial']} unpriced tokens" if tot["partial"] else ""))
rec_file = os.path.join(os.environ.get("ORCHY_PROFILE_DIR") or os.path.expanduser("~/.agents/orchy/profile"), repo.replace("/", "-") + ".jsonl")
if os.path.exists(rec_file):
    last = {}
    for line in open(rec_file, errors="replace"):
        try: o = json.loads(line); last[o["record"]] = o
        except (ValueError, KeyError, TypeError): continue
    cats, take_all, neither = {}, 0, 0
    for o in last.values():
        if o.get("via_recommend_all"): take_all += 1
        elif o.get("agreed") is None: neither += 1
        else: c = cats.setdefault(o.get("category") or "other", [0, 0]); c[0] += bool(o["agreed"]); c[1] += 1
    print("owner took the recommendation: " + (", ".join(f"{k} {a}/{n}" for k, (a, n) in sorted(cats.items())) or "nothing scored yet")
          + f"; {take_all} taken all at once (not scored), {neither} left to the orchestrator")
if want and want not in lanes: print(f"no lead logs for lane {want}", file=sys.stderr); sys.exit(1)
PY
  ;;
*) echo "orchy: unknown subcommand $cmd" >&2; usage 1;;
esac
