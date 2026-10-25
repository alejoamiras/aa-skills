#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
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
#   render [--keep K,...] <template> K=V ...   substitute <K> tokens to stdout; exit 1 on a token left over that --keep does not name
#   check-text <file>...         refuse a file carrying a banned string (local.json prompt_ban: roster names, page ids)
#   check-private <file>...      refuse a file that copies six consecutive words of the owner's verbatim words in the ask ledger
#   check-public [--no-sensitive] <file>   check-private, then the leak and sensitive patterns and gitleaks; any check error refuses
#   ask add <text>               capture the owner's words verbatim; prints the new id (askN)
#   ask public <id> <text>       the restatement every handoff carries; ask said <id> <text>: the owner's later words, verbatim
#   ask lane <id> <slug> <route> | done|drop|reopen <id> <note> | note <id> <text>   route or move an ask
#   ask list [--all] [--json] | show <id>   one line per open or laned ask (every ask with --all; orchy.asks/1 with --json); one ask's fold and history
#   ask file <id> <title> <body-file>   file an ask as a GitHub issue: check, dedupe, create and record under one lock
#   ask close-lane <slug>        after teardown: each ask laned there is done (delivered, with its PR) or reopened, from the reports' ASKS: lines
#   waiting add <ref> <text> | done <ref> | list [--json]   what waits on the owner, one item per ref (pr:N issue:N page:N
#                                ask:askN lane:<slug> other:<slug>); add replaces the text and keeps since; orchy.waiting/1 with --json
#   wt-new <slug>...             create worktrees from origin/<trunk> and install deps; sequential; refuses an existing slug
#   launch [--light] <key> <slug> <account>            start a headless lead on prompts/<key>.md inside the lane worktree
#   resume [--light] <key> <slug> <account> <session>  resume a lead's session with prompts/<key>.md
#   stop <key>                   end a live lead and every process it started
#   say <key> <text>             queue a steering note; a live lead gets it after its next tool call (inbox-hook.sh)
#   session-id <key>             the session id of a lead's latest run
#   snapshot                     the tick's facts: reports, leads, watchers, PRs, worktrees, load, headroom
#   state [--json]               a poller's view as orchy.state/1 JSON: local facts only, no gh, usage or network call, nothing written
#   wait [seconds]               block until a report, lead or watcher changes, or (every wait.poll_sec, default 120) open PRs, open issues or the trunk head (default 1500)
#   scan <pr>                    gate-weakening and leak scan of a PR's diff, title, body and commit messages (plus the local ban)
#   watch-merge <pr> <full-sha> <lane> <report> [archive-name]   merge on the standing policy, then tear the lane down
#   arm-merge  <pr> <full-sha> <lane> <report-name> [archive-name] [delay-s]   watch-merge detached (nohup, .out + .pid)
#   disarm [<pr>]                stop one merge watcher, or every one
#   receipt [--json] [--offline] [<lane>]   per lane: API-equivalent dollars, tokens, wall-clock, PRs merged, issues closed, failed arcs,
#                                Codex rounds; --json prints orchy.receipt/1 with per-run costs, --offline skips the gh joins
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
# The owner's verbatim words live outside $H, where leads write their reports and would find them.
ASKS_DIR=$(realpath -sm "${ORCHY_ASKS_DIR:-$HOME/.agents/orchy/asks}"); LEDGER="$ASKS_DIR/$slug.jsonl"
OVERLAP="$(dirname "$(realpath "$0")")/overlap.sh"
cmd=${1:-help}; shift || true
case "$cmd" in help|-h|--help) usage 0;; home) echo "$H"; exit 0;; esac
[ -f "$CFG" ] || { echo "orchy: no $CFG (run /start-orchy in the repo first)" >&2; exit 1; }
cfg() { jq -r "$1" "$CFG"; }
lcl() { [ -f "$LOCAL" ] && jq -r "$1" "$LOCAL" || echo ""; }
TRUNK=$(cfg '.trunk // "main"')
case "$cmd" in wt-new|launch|resume|arm-merge|watch-merge)
  [ "$(cfg '.mode // empty')" = triage ] && { echo "refused: orchy.json mode is triage (labels, comments and pages only; no worktree, lead or merge)" >&2; exit 1; };; esac
# A lead runs the hook its settings file names, so nobody but the owner may write here. chmod tightens a fresh or loose
# home (a umask would also reach wt-new's product checkout), but cannot undo what another user planted while it was loose.
under=0; ds=("$H"); [ "$(dirname "$H")" = "$CAP" ] && under=1 && ds+=("$CAP")
for d in "${ds[@]}"; do [ ! -L "$d" ] && [ -O "$d" ] || { echo "orchy: $d must be a directory owned by $(id -un), not a symlink" >&2; exit 1; }; done
f=$({ find "$H" -maxdepth 2 ! -user "$EUID"; [ $under = 0 ] || find "$CAP" -maxdepth 1 ! -user "$EUID"; } 2>/dev/null | head -1)
[ -z "$f" ] || { echo "orchy: $f belongs to another user; refusing a home someone else could write" >&2; exit 1; }
# Readers keep the ownership checks but create nothing, so a poller never changes the home it reads.
ro=0; case "$cmd" in state|config|local|session-id|receipt) ro=1;; ask) case "${1:-}" in list|show) ro=1;; esac;; waiting) case "${1:-}" in list) ro=1;; esac;; esac
if [ $ro = 0 ]; then
  mkdir -p "$H"/{briefs,prompts,reports,leads,watch,wt,scratch,inbox,page/shots,page/build}
  chmod 700 "$H"; [ $under = 1 ] && chmod 700 "$CAP"
fi
WT_ROOT="$ROOT/$(cfg '.worktrees.root // ".claude/worktrees"')"
ARCHIVE=$(cfg '.plans.archive // "implementations-plan/archive"')
now() { date -u +%FT%TZ; }
ev() { # ev <kind> [k=v | k:=<json>]...: one orchy.event/1 line in $H/events.jsonl; ids only, never text, account names or paths
  local kind=$1 a args=(); shift
  for a in "$@"; do case "$a" in *:=*) args+=(--argjson "${a%%:=*}" "${a#*:=}");; *) args+=(--arg "${a%%=*}" "${a#*=}");; esac; done
  # one write under 1 KiB, so atomic under O_APPEND; a failed write never changes the caller's output or exit code
  local f="$H/events.jsonl"; if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then return 0; fi
  { jq -nc --arg kind "$kind" --arg at "$(now)" "${args[@]}" '{schema: "orchy.event/1"} + $ARGS.named' >> "$f"; } 2>/dev/null || true
}
pstart() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null || echo ""; }   # a pid is reused; its start time is not
alive() { # alive <pid> [<start>]: the process exists, is a claude or claude-usage run, and has the recorded start time
  local p=$1 s=${2:-}; [ -n "$p" ] || return 1
  ps -o args= -p "$p" 2>/dev/null | grep -qE '(^|/)(claude|claude-usage)( |$)' || return 1
  [ -z "$s" ] || [ "$(pstart "$p")" = "$s" ]
}
watcher_alive() { local f=$1; [ -f "$f" ] || return 1; read -r p s < "$f"; [ -n "$p" ] && [ -d "/proc/$p" ] && { [ -z "${s:-}" ] || [ "$(pstart "$p")" = "$s" ]; }; }
lead_rows() { for f in "$H"/leads/*.started; do [ -f "$f" ] || continue; read -r pid st acct t weight _ < "$f"; alive "$pid" "$st" && echo "$(basename "$f" .started) $acct ${weight:-heavy} $pid"; done; }
newest_proc() { # newest_proc <pid> <ps -eo pid=,ppid=,etimes=,args= rows>: "<age_s><TAB><cmd ≤80>" of the youngest process below pid, or nothing
  awk -v r="$1" '
    { pid=$1; par[pid]=$2; et[pid]=$3; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+/, ""); cmd[pid]=$0 }
    END { s[r]=1; c=1; while (c) { c=0; for (x in par) if (!(x in s) && (par[x] in s)) { s[x]=1; c=1 } }
          best=""; for (x in s) if (x != r && (best == "" || et[x] < et[best])) best=x
          if (best != "") printf "%d\t%s", et[best], substr(cmd[best], 1, 80) }' <<<"$2"
}
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
  st=$(gh api "repos/$REPO/commits/$1/status" --paginate --jq '.statuses[] | "\(.context)\tcompleted\t\(.state)"' 2>/dev/null) || return 1
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
session_pid() { # the orchestrator session: $CLAUDE_PID while it is a live claude, else the nearest `claude` ancestor, else (a test, a plain shell) the caller's parent
  local p=${CLAUDE_PID:-} c
  if [[ "$p" =~ ^[0-9]+$ ]] && [ "$(ps -o comm= -p "$p" 2>/dev/null)" = claude ]; then echo "$p"; return; fi
  p=$PPID; while [ "$p" -gt 1 ] 2>/dev/null; do c=$(ps -o comm= -p "$p" 2>/dev/null); [ "$c" = claude ] && { echo "$p"; return; }; p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 1); done; echo "$PPID"
}
ledger_ok() { # owner-only and never a symlink: it holds the owner's verbatim words
  mkdir -p "$ASKS_DIR" && chmod 700 "$ASKS_DIR" || return 1
  [ ! -L "$ASKS_DIR" ] && [ -O "$ASKS_DIR" ] && [ ! -L "$LEDGER" ] || { echo "refused: $ASKS_DIR and $LEDGER must be owned by $(id -un), not symlinks" >&2; return 1; }
  ( umask 077; : >> "$LEDGER" ) && chmod 600 "$LEDGER"
}
ledger_ro() { # the readers' check: creates nothing, refuses a symlink or another owner; a missing ledger folds to {}
  local p; for p in "$ASKS_DIR" "$LEDGER"; do
    if [ -L "$p" ] || { [ -e "$p" ] && [ ! -O "$p" ]; }; then echo "refused: $p must be owned by $(id -un), not a symlink" >&2; return 1; fi; done
}
# One fold for every reader: a line that is not a JSON object with a string id (a torn tail) is skipped.
FOLD='reduce (inputs | fromjson? | select(type == "object" and (.id | type) == "string")) as $r ({};
  .[$r.id] |= ((. // {id: $r.id, at: $r.at, said: [], notes: []})
    | .updated = $r.at
    | if .text == null and ($r.text | type) == "string" then .text = $r.text else . end
    | if ($r.said | type) == "string" then .said += [$r.said] else . end
    | if ($r.public | type) == "string" then .public = $r.public else . end
    | if ($r.note | type) == "string" then .notes += [$r.note] else . end
    | if ($r.state | type) == "string" then .state = $r.state
        | if $r.state == "lane" then .lane = $r.lane elif $r.state == "open" or $r.state == "dropped" then .lane = null else . end
        | if $r.state == "filed" then .issue = $r.issue else . end
      else . end))'
fold() { if [ -f "$LEDGER" ]; then jq -Rn "$FOLD" "$LEDGER"; else echo '{}'; fi; }
ask_get() { fold | jq -c --arg id "$1" '.[$id] // empty'; }
ask_moves() { case "$1>$2" in open\>lane|open\>done|open\>dropped|open\>filed|lane\>done|lane\>open|lane\>dropped|lane\>filed|done\>open|dropped\>open) return 0;; esac; return 1; }
ASK_HOLD='[.notes[] | select(test("^(waiting:|answered:)") or . == "wording ok")][-1] // "" | select(startswith("waiting:"))'
ask_ready() { # ask_ready <fold-json> <id>: a handoff needs the stored restatement and no open owner question
  local w; [ -n "$(jq -r '.public // empty' <<<"$1")" ] || { echo "refused: $2 has no public wording; ask public $2 first" >&2; return 1; }
  # only control notes decide a hold, so an ordinary note never clears one
  w=$(jq -r "$ASK_HOLD" <<<"$1"); [ -z "$w" ] || { echo "refused: $2 is $w; record 'answered: …' or 'wording ok' with ask note first" >&2; return 1; }
}
ask_lines() { # ask_lines <slug> [--no-sensitive] <file>...: each `askN: ` line is that ask's stored wording, laned to <slug>, not held
  local s=$1 m id t a rc=0 tf lines nosens=(); shift; [ "${1:-}" = --no-sensitive ] && { nosens=(--no-sensitive); shift; }
  tf=$(mktemp "$H/scratch/asklines.XXXXXX"); grep -hE '\bask[0-9]+\b' "$@" > "$tf"
  [ $? -le 1 ] || { echo "refused: cannot read the ask lines of $*" >&2; rm -f "$tf"; return 1; }
  if [ -s "$tf" ]; then "$0" check-public "${nosens[@]}" "$tf" || { echo "refused: a line that names an ask is checked as public text; keep paths and other local detail off it" >&2; rc=1; }; fi
  lines=$(grep -ohE '\bask[0-9]+: .*' "$tf"); [ $? -le 1 ] || { echo "refused: cannot read the ask lines of $*" >&2; rm -f "$tf"; return 1; }
  while IFS= read -r m; do   # one ask per line: the wording runs to the end of it
    [ -n "$m" ] || continue; id=${m%%: *}; t=${m#*: }; t=${t%"${t##*[![:space:]]}"}; a=$(ask_get "$id")
    [ -n "$a" ] || { echo "refused: $id is not in the ask ledger" >&2; rc=1; continue; }
    [ "$(jq -r '.public // empty' <<<"$a")" = "$t" ] || { echo "refused: the $id line is not its stored public wording (ask show $id)" >&2; rc=1; }
    jq -e --arg s "$s" '.state == "lane" and .lane == $s' <<<"$a" >/dev/null || { echo "refused: $id is not laned to $s" >&2; rc=1; }
    ask_ready "$a" "$id" || rc=1
  done <<<"$lines"
  rm -f "$tf"; return $rc
}
lane_reported() { # a lane's reports outlive its worktree: their slug never names a new lane
  local f b; for f in "$H/reports/$1"-*.md; do [ -f "$f" ] || continue; b=$(basename "$f" .md); [[ "${b#"$1"-}" =~ ^(plan|a[0-9]+|arc[0-9]+|closeout)$ ]] && return 0; done; return 1
}
append_row() { # inside the ledger lock (fd 9); a torn last line is ended first so the new row parses
  [ "$(printf '%s' "$1" | wc -c)" -le 16384 ] || { echo "refused: a ledger row is at most 16 KiB; restate or split the ask" >&2; return 1; }
  [ -z "$(tail -c 1 "$LEDGER")" ] || printf '\n' >&9
  printf '%s\n' "$1" >&9 || return 1
  local e; mapfile -t e < <(jq -r '"ask=\(.id)", "state:=\(.state // null | tojson)", "lane:=\(.lane // null | tojson)"' <<<"$1" 2>/dev/null)
  if [ ${#e[@]} = 3 ]; then ev ask.row "${e[@]}"; fi
}
with_ledger() { ( flock -w 60 9 || { echo "refused: ask ledger lock busy for 60 s" >&2; exit 1; }; "$@" ) 9>>"$LEDGER"; }
WAITING="$H/waiting.json"
WREF='^(pr|issue):[1-9][0-9]{0,8}$|^page:(0|[1-9][0-9]{0,8})$|^ask:ask[0-9]{1,9}$|^lane:[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$|^other:[a-z0-9-]{1,32}$'
waiting_read() { # orchy.waiting/1 on stdout, a missing file as empty; a symlinked or non-regular one refuses, as does a malformed one (shape, a repeated ref, a since jq cannot parse)
  if [ -L "$WAITING" ] || { [ -e "$WAITING" ] && [ ! -f "$WAITING" ]; }; then echo "refused: $WAITING must be a regular file, not a symlink" >&2; return 1; fi
  [ -e "$WAITING" ] || { echo '{"schema":"orchy.waiting/1","waiting":[]}'; return 0; }
  jq -sce 'select(length == 1) | .[0] | select(.schema == "orchy.waiting/1" and (.waiting | type) == "array"
      and all(.waiting[]; type == "object" and ([.ref, .text, .since] | map(type)) == ["string", "string", "string"] and (.since | try fromdateiso8601 catch null) != null)
      and ([.waiting[].ref] | length == (unique | length)))
    | {schema, waiting: [.waiting[] | {ref, text, since}]}' "$WAITING" 2>/dev/null || { echo "refused: $WAITING is not orchy.waiting/1" >&2; return 1; }
}
waiting_text_ok() { # one line of 1-160 code points; Python, since jq silently replaces invalid UTF-8
  printf '%s' "$1" | python3 -I -c '
import sys
try: t = sys.stdin.buffer.read().decode("utf-8")
except UnicodeDecodeError: sys.exit("refused: the text is not UTF-8")
if not 1 <= len(t) <= 160: sys.exit(f"refused: the text is {len(t)} characters; 1 to 160")
# C0, DEL and C1 controls, the line and paragraph separators, and every Bidi_Control character
bad = {*range(0x20), *range(0x7f, 0xa0), 0x2028, 0x2029, 0x61c, 0x200e, 0x200f, *range(0x202a, 0x202f), *range(0x2066, 0x206a)}
if any(ord(c) in bad for c in t): sys.exit("refused: the text carries a control, line separator or bidi character")'
}
case "$cmd" in
config) cfg "$1";;
local) lcl "$1";;
lock)
  f="$H/orchestrator.lock"; me=$(session_pid)
  # The seat names the session and its messaging address so a coordinator can find it; pid and start time stay the only
  # ownership test, and the messaging token is never read.
  sess=${CLAUDE_CODE_SESSION_ID:-${ORCHY_SESSION:--}}; addr=-; [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] && addr="uds:$CLAUDE_CODE_MESSAGING_SOCKET"
  for try in 1 2 3; do
    if ( set -o noclobber; echo "$me $(pstart "$me") $(now) $sess $addr" > "$f" ) 2>/dev/null; then echo "locked $REPO for session pid $me ($sess)"; ev seat.lock session="$sess"; exit 0; fi
    read -r p st t hs _ < "$f" 2>/dev/null || { sleep 1; continue; }
    [ "$p" = "$me" ] && [ "$st" = "$(pstart "$me")" ] && { echo "already locked by this session (pid $me)"; exit 0; }
    if [ -d "/proc/$p" ] && [ "$(pstart "$p")" = "$st" ]; then echo "refused: another orchestrator holds $REPO (pid $p, session ${hs:--}, since $t)"; exit 2; fi
    # a stale holder: one contender at a time replaces it (the flock dies with its holder), so two contenders cannot unlink each other's fresh lock
    ( flock -w 5 9 || exit 1; read -r p2 st2 _ < "$f" 2>/dev/null; [ "$p2" = "$p" ] && [ "$st2" = "$st" ] && rm -f "$f"; exit 0 ) 9>"$f.takeover" || sleep 1
  done; echo "lock: could not claim $f"; exit 2;;
unlock)
  # Under the takeover lock, so the seat read is the seat removed: never a live other session's, never a contender's fresh one.
  need flock; f="$H/orchestrator.lock"; me=$(session_pid)
  ( flock -w 5 9 || { echo "refused: the seat's takeover lock is busy"; exit 2; }
    [ -f "$f" ] || { echo "unlocked (no seat was held)"; exit 0; }
    read -r p st _ hs _ < "$f" 2>/dev/null; mine=0; gone=1
    [ "$p" = "$me" ] && [ "$st" = "$(pstart "$me")" ] && mine=1
    [ -n "$p" ] && [ -d "/proc/$p" ] && [ "$(pstart "$p")" = "$st" ] && gone=0
    if [ $mine = 1 ] || [ $gone = 1 ]; then rm -f "$f"; echo "unlocked"; ev seat.unlock session="${hs:--}"; exit 0; fi
    echo "refused: pid $p holds the seat and is alive; it is not this session"; exit 2 ) 9>"$f.takeover";;
render)
  # the shared briefs keep <LANE>, <KEY>, <WORKTREE> and <BRANCH>: each spawn prompt binds them for its lead
  keep=; [ "${1:-}" = --keep ] && { keep=${2:-}; shift 2; }
  name=${1:-}; t=$name; shift; [ -f "$t" ] || t="$(dirname "$0")/../templates/$t"
  [ -f "$t" ] || { echo "orchy: no template $name" >&2; exit 1; }
  # values may carry newlines, '|', '&' or '/': a plain string replace, never sed
  python3 -I - "$t" "$keep" "$@" <<'PY'
import sys, re
t = open(sys.argv[1]).read()
for kv in sys.argv[3:]:
    k, _, v = kv.partition("="); t = t.replace(f"<{k}>", v)
sys.stdout.write(t)
left = sorted(set(re.findall(r"<[A-Z_]{3,}>", t)) - {f"<{k}>" for k in sys.argv[2].split(",") if k})
if left: print("orchy: unrendered tokens: " + " ".join(left), file=sys.stderr); sys.exit(1)
PY
  ;;
check-text)
  ban=$(lcl '.prompt_ban // empty'); [ -n "$ban" ] || { echo "orchy: local.json has no prompt_ban" >&2; exit 2; }
  grep -qE "$ban" /dev/null 2>/dev/null; [ $? -le 1 ] || { echo "orchy: prompt_ban is not a valid regex" >&2; exit 2; }
  rc=0; for f in "$@"; do [ -r "$f" ] || { echo "orchy: cannot read $f" >&2; rc=2; continue; }
    hits=$(grep -nE "$ban" "$f"); [ $? -le 1 ] || { echo "orchy: cannot scan $f" >&2; rc=2; continue; }
    [ -z "$hits" ] || { echo "orchy: $f carries banned text:"; head -5 <<<"$hits" | cut -c1-160; rc=1; }; done; exit $rc;;
check-private) [ $# -gt 0 ] || { echo "usage: check-private <file>..." >&2; exit 2; }; bash "$OVERLAP" "$LEDGER" "$@";;
check-public)
  # Fails closed: a check that cannot run refuses (exit 2), unlike scan, which reports what it could read.
  sens=1; [ "${1:-}" = --no-sensitive ] && { sens=0; shift; }
  f=${1:-}; [ -r "$f" ] || { echo "usage: check-public [--no-sensitive] <file>" >&2; exit 2; }
  bash "$OVERLAP" "$LEDGER" "$f"; rc=$?; [ "$rc" -le 1 ] || { echo "refused: the copy check could not run" >&2; exit 2; }
  # a policy file that cannot be parsed refuses: an empty pattern would pass everything
  if ! leakre=$(cfg '.scan.leak // empty') || ! ban=$(jq -r '.prompt_ban // empty' "$LOCAL"); then echo "refused: orchy.json or local.json cannot be read" >&2; exit 2; fi
  [ -n "$ban" ] && leakre="${leakre:+($leakre)|}($ban)"
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
  gl=${ORCHY_GITLEAKS:-gitleaks}; command -v "$gl" >/dev/null || { echo "refused: $gl not found, so the secret check cannot run" >&2; exit 2; }
  "$gl" stdin --no-banner --redact --exit-code 3 -l error < "$f" >/dev/null 2>&1; r=$?
  case $r in 0) ;; 3) echo "SECRET: gitleaks found a secret"; rc=1;; *) echo "refused: gitleaks failed (exit $r)" >&2; exit 2;; esac
  exit $rc;;
ask)
  sub=${1:-}; shift || true
  case "$sub" in list|show) ledger_ro || exit 1;; *) need flock; ledger_ok || exit 1;; esac
  case "$sub" in add|list|close-lane) ;; public|said|note|done|drop|reopen|show|lane|file)
    [[ "${1:-}" =~ ^ask[0-9]+$ ]] || { echo "usage: ask $sub <askN> ..." >&2; exit 1; }; id=$1; shift;;
    *) echo "usage: ask add|public|said|note|lane|done|drop|reopen|list|show|file ... (orchy.sh help)" >&2; exit 1;; esac
  row() { jq -nc --arg id "$id" --arg at "$(now)" "$@"; }
  case "$sub" in
  add)
    t="$*"; [ -n "$t" ] || { echo "usage: ask add <text>" >&2; exit 1; }
    ask_add() { local n; n=$(fold | jq -r '[keys[] | select(test("^ask[0-9]+$")) | ltrimstr("ask") | tonumber] | max // 0')
      id="ask$((n + 1))"; append_row "$(row --arg t "$t" '{id: $id, at: $at, state: "open", text: $t}')" && echo "$id"; }
    with_ledger ask_add;;
  public)
    t="$*"; [ -n "$t" ] || { echo "usage: ask public <askN> <text>" >&2; exit 1; }
    tf=$(mktemp "$H/scratch/public.XXXXXX"); printf '%s\n' "$t" > "$tf"; "$0" check-public "$tf"; rc=$?; rm -f "$tf"; [ "$rc" = 0 ] || exit 1
    ask_public() { local a st; a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; return 1; }
      st=$(jq -r .state <<<"$a"); case "$st" in open|lane) ;; *) echo "refused: $id is $st" >&2; return 1;; esac
      # the owner's OK covered the wording they saw, never its replacement; one row, so no reader sees it unheld
      if jq -e 'any(.notes[]; startswith("waiting: wording"))' <<<"$a" >/dev/null; then
        append_row "$(row --arg t "$t" '{id: $id, at: $at, public: $t, note: "waiting: wording (changed)"}')" || return 1; echo "$id public wording stored; it needs the owner's OK again"
      else append_row "$(row --arg t "$t" '{id: $id, at: $at, public: $t}')" || return 1; echo "$id public wording stored"; fi; }
    with_ledger ask_public;;
  said|note)
    t="$*"; [ -n "$t" ] || { echo "usage: ask $sub <askN> <text>" >&2; exit 1; }
    ask_text() { [ -n "$(ask_get "$id")" ] || { echo "refused: no $id" >&2; return 1; }
      append_row "$(row --arg k "$sub" --arg t "$t" '{id: $id, at: $at} + {($k): $t}')" && echo "$id $sub recorded"; }
    with_ledger ask_text;;
  done|drop|reopen)
    t="$*"; [ -n "$t" ] || { echo "usage: ask $sub <askN> <note>" >&2; exit 1; }
    to=$sub; [ "$sub" = drop ] && to=dropped; [ "$sub" = reopen ] && to=open
    ask_move() { local a st; a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; return 1; }
      st=$(jq -r .state <<<"$a"); ask_moves "$st" "$to" || { echo "refused: $id is $st; $sub does not apply" >&2; return 1; }
      append_row "$(row --arg s "$to" --arg t "$t" '{id: $id, at: $at, state: $s, note: $t}')" && echo "$id $to"; }
    with_ledger ask_move;;
  lane)
    s=${1:-}; shift || true; t="$*"
    [[ "$s" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] && [ -n "$t" ] || { echo "usage: ask lane <askN> <slug> <route>" >&2; exit 1; }
    ask_lane() { local a st; a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; return 1; }
      st=$(jq -r .state <<<"$a"); ask_moves "$st" lane || { echo "refused: $id is $st; lane does not apply" >&2; return 1; }
      ask_ready "$a" "$id" || return 1
      if lane_reported "$s" && [ ! -d "$WT_ROOT/$s" ]; then echo "refused: lane $s is closed (its reports remain); name a new lane" >&2; return 1; fi
      append_row "$(row --arg s "$s" --arg t "$t" '{id: $id, at: $at, state: "lane", lane: $s, note: $t}')" && echo "$id lane $s"; }
    with_ledger ask_lane;;
  list)
    all=0; js=0; for o in "$@"; do case "$o" in --all) all=1;; --json) js=1;; esac; done
    if [ $js = 1 ]; then   # the owner's text is in here: a local reader may show it, nothing may publish it
      fold | jq -c --argjson all "$all" --argjson now "$(date +%s)" '{schema: "orchy.asks/1", asks: [map(.) | sort_by(.id | ltrimstr("ask") | tonumber? // 0) | .[]
        | select($all == 1 or .state == "open" or .state == "lane")
        | . + {age_s: ($now - (.at | fromdateiso8601? // $now)), held: ([ '"$ASK_HOLD"' ] | first // null)} | . + {waiting: (.held != null)}]}'
      exit 0
    fi
    fold | jq -r --argjson all "$all" --argjson now "$(date +%s)" 'map(.) | sort_by(.id | ltrimstr("ask") | tonumber? // 0) | .[]
      | select($all == 1 or .state == "open" or .state == "lane")
      | ($now - (.at | fromdateiso8601? // $now)) as $s
      | [.id, .state, (.lane // (if .issue then "#\(.issue)" else "-" end)), (if $s < 3600 then "\($s / 60 | floor)m" else "\($s / 3600 | floor)h" end),
         ((if .public then "" else "[no public] " end) + (if ([ '"$ASK_HOLD"' ] | length) > 0 then "[waiting] " else "" end)
          + ((.text // "") | gsub("\\s+"; " ") | .[0:80]))] | join("  ")';;
  show)
    a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; exit 1; }
    jq . <<<"$a"; echo "-- history"; jq -Rc --arg id "$id" 'fromjson? | select(type == "object" and .id == $id)' "$LEDGER";;
  file)
    need gh; need timeout; title=${1:-}; bf=${2:-}
    [ -n "$title" ] && [ -r "$bf" ] || { echo "usage: ask file <askN> <title> <body-file>" >&2; exit 1; }
    # One critical section from the state check to the filed row: a concurrent drop waits, then finds the ask filed.
    ask_file() { local a st tf rc found ex url n; a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; return 1; }
      st=$(jq -r .state <<<"$a"); ask_moves "$st" filed || { echo "refused: $id is $st; file does not apply" >&2; return 1; }
      ask_ready "$a" "$id" || return 1
      # the body that is checked is the body that is filed: a snapshot, never the caller's file
      bs=$(mktemp "$H/scratch/file-body.XXXXXX") || return 1
      trap 'rm -f "$bs"' EXIT   # bs is not local: the trap runs as the subshell exits
      cat "$bf" > "$bs" || { echo "refused: cannot snapshot $bf; nothing filed" >&2; return 1; }
      tf=$(mktemp "$H/scratch/file.XXXXXX"); { printf '%s\n\n' "$title"; cat "$bs"; } > "$tf"; "$0" check-public "$tf"; rc=$?; rm -f "$tf"
      [ "$rc" = 0 ] || { echo "refused: the title or body failed check-public; nothing filed" >&2; return 1; }
      found=$(timeout 30 gh issue list --repo "$REPO" --state all --limit 50 --search "$title in:title" --json number,title --jq '.[] | "\(.number)\t\(.title)"') \
        || { echo "refused: the duplicate search failed; nothing filed" >&2; return 1; }
      ex=$(awk -F'\t' -v t="$title" 'tolower($2) == tolower(t) {print "#" $1; exit}' <<<"$found")
      [ -z "$ex" ] || { echo "refused: issue $ex already has this exact title" >&2; return 1; }
      [ -z "$found" ] || { echo "similar titles:"; head -5 <<<"$found" | sed 's/^/  #/'; }
      url=$(timeout 30 gh issue create --repo "$REPO" --title "$title" --body-file "$bs"); rc=$?
      [ "$rc" != 124 ] || { echo "AMBIGUOUS: gh issue create timed out; GitHub may have filed it. Reconcile $id by hand; never retry" >&2; return 1; }
      [ "$rc" = 0 ] || { echo "refused: gh issue create failed; the ledger is unchanged" >&2; return 1; }
      n=$(grep -oE '/issues/[0-9]+' <<<"$url" | tail -1 | cut -d/ -f3)
      [ -n "$n" ] || { echo "AMBIGUOUS: gh issue create printed no issue number ($url). Reconcile $id by hand; never retry" >&2; return 1; }
      append_row "$(row --argjson n "$n" '{id: $id, at: $at, state: "filed", issue: $n}')" && echo "$id filed as #$n"; }
    with_ledger ask_file;;
  close-lane)
    s=${1:-}; [[ "$s" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || { echo "usage: ask close-lane <slug>" >&2; exit 1; }
    [ ! -d "$WT_ROOT/$s" ] || { echo "refused: lane $s still has its worktree; close-lane runs after teardown" >&2; exit 1; }
    k=$(lead_rows | awk -v s="$s" '{x = substr($1, length(s) + 2)} index($1, s "-") == 1 && x ~ /^(plan|a[0-9]+|arc[0-9]+|closeout)$/ {print $1; exit}')
    [ -z "$k" ] || { echo "refused: lead $k of lane $s is alive" >&2; exit 1; }
    # Each report's last ASKS: line, in lane order (plan, then a<n>/arc<n> by n, then closeout); the latest mention wins.
    # a<n> and arc<n> (a fresh retry beside an auto-continued arc) that disagree on an ask leave it unresolved.
    rd="$H/reports"; ns=$(for f in "$rd/$s"-a*.md; do [ -f "$f" ] && basename "$f" .md; done | sed -nE "s/^$(printf '%s' "$s" | sed 's/[.]/\\./g')-(a|arc)([0-9]+)$/\2/p" | sort -nu)
    mentions() { [ -f "$rd/$1.md" ] || return 0
      { grep -E '^ASKS:' "$rd/$1.md" | tail -n 1; grep -oE '^PR #[0-9]+' "$rd/$1.md" | tail -n 1; } | awk '
        /^PR #/ { pr = substr($2, 2); next }
        { sub(/^ASKS:[ \t]*/, ""); n = split($0, seg, /;[ \t]*/)
          for (i = 1; i <= n; i++) { k = split(seg[i], w, /[ \t]+/)
            if (w[1] == "delivered") { for (j = 2; j <= k; j++) if (w[j] ~ /^ask[0-9]+$/) out[++m] = w[j] "\tD" }
            else if (w[1] == "left" && w[2] == "out" && w[3] ~ /^ask[0-9]+$/) { r = seg[i]; sub(/^left[ \t]+out[ \t]+ask[0-9]+[ \t]*/, "", r); out[++m] = w[3] "\tL\t" (r == "" ? "no reason given" : r) } } }
        END { for (i = 1; i <= m; i++) { split(out[i], f, "\t"); print out[i] (f[2] == "D" ? "\t" (pr == "" ? "?" : pr) : "") } }'; }
    declare -A res=()
    while IFS=$'\t' read -r i kd x; do [ "$kd" = D ] || res[$i]="$kd"$'\t'"$x"; done < <(mentions "$s-plan")   # a plan delivers nothing
    for n in $ns; do
      declare -A a1=() a2=()
      while IFS=$'\t' read -r i kd x; do a1[$i]="$kd"$'\t'"$x"; done < <(mentions "$s-a$n")
      while IFS=$'\t' read -r i kd x; do a2[$i]="$kd"$'\t'"$x"; done < <(mentions "$s-arc$n")
      for i in "${!a1[@]}" "${!a2[@]}"; do
        if [ -n "${a1[$i]:-}" ] && [ -n "${a2[$i]:-}" ] && [ "${a1[$i]%%$'\t'*}" != "${a2[$i]%%$'\t'*}" ]; then res[$i]="C"$'\t'"conflicting reports a$n/arc$n"
        else res[$i]=${a2[$i]:-${a1[$i]}}; fi
      done; unset a1 a2
    done
    while IFS=$'\t' read -r i kd x; do res[$i]="$kd"$'\t'"$x"; done < <(mentions "$s-closeout")
    ask_close() { local id kd x; for id in $(fold | jq -r --arg s "$s" 'map(select(.state == "lane" and .lane == $s)) | .[].id'); do
        kd=${res[$id]:-}; x=${kd#*$'\t'}; kd=${kd%%$'\t'*}
        case "$kd" in
        D) append_row "$(row --arg t "delivered in $s PR #$x" '{id: $id, at: $at, state: "done", note: $t}')" && echo "$id done (PR #$x)";;
        *) case "$kd" in L|C) ;; *) x="not reported";; esac
           append_row "$(row --arg t "lane $s closed without delivering it: $x" '{id: $id, at: $at, state: "open", note: $t}')" && echo "$id reopened: $x";;
        esac
      done; }
    with_ledger ask_close;;
  esac;;
waiting)
  sub=${1:-}; shift || true
  case "$sub" in
  list)
    w=$(waiting_read) || exit 1
    if [ "${1:-}" = --json ]; then printf '%s\n' "$w"; exit 0; fi
    jq -r --argjson now "$(date +%s)" '.waiting[] | ($now - (.since | fromdateiso8601? // $now)) as $s
      | "\(.ref)  \(if $s < 3600 then "\($s / 60 | floor)m" else "\($s / 3600 | floor)h" end)  \(.text)"' <<<"$w";;
  add|done)
    need flock; r=${1:-}; shift || true; t="$*"
    [[ "$r" =~ $WREF ]] || { echo "refused: a ref is pr:<n>, issue:<n>, page:<n>, ask:<askN>, lane:<slug> or other:<slug>" >&2; exit 1; }
    [ "$sub" = "done" ] || waiting_text_ok "$t" || exit 1
    # done checks the ref too: a name banned after its add must not reach events.jsonl
    tf=$(mktemp "$H/scratch/waiting.XXXXXX") || exit 1; { printf '%s\n' "$r"; [ "$sub" = "done" ] || printf '%s\n' "$t"; } > "$tf"
    o=$("$0" check-public "$tf" 2>&1); rc=$?; rm -f "$tf"
    case $rc in 0) ;; 1) echo "refused: the ref or text fails check-public ($(grep -oE '^(LEAK|SENSITIVE|SECRET)|copies the owner' <<<"$o" | sort -u | paste -sd, -))" >&2; exit 1;;
      *) echo "refused: check-public could not run" >&2; exit 1;; esac
    # the lock file is never replaced, so one writer at a time spans the read, the rename and the event
    ( flock -w 30 8 || { echo "refused: the waiting lock is busy for 30 s" >&2; exit 1; }
      w=$(waiting_read) || exit 1
      if [ "$sub" = add ]; then
        w=$(jq -c --arg r "$r" --arg t "$t" --arg at "$(now)" '.waiting |= if any(.[]; .ref == $r) then map(if .ref == $r then .text = $t else . end) else . + [{ref: $r, text: $t, since: $at}] end' <<<"$w") || exit 1
      else
        jq -e --arg r "$r" 'any(.waiting[]; .ref == $r)' <<<"$w" >/dev/null || { echo "refused: nothing waits on $r" >&2; exit 1; }
        w=$(jq -c --arg r "$r" '.waiting |= map(select(.ref != $r))' <<<"$w") || exit 1
      fi
      if ! tmp=$(mktemp "$H/.waiting.XXXXXX") || ! printf '%s\n' "$w" > "$tmp" || ! mv -f "$tmp" "$WAITING"; then rm -f "${tmp:-}"; echo "refused: cannot write $WAITING" >&2; exit 1; fi
      ev "waiting.$sub" ref="$r"; echo "waiting $sub $r" ) 8>>"$H/waiting.lock";;
  *) echo "usage: waiting add <ref> <text> | done <ref> | list [--json]" >&2; exit 1;;
  esac;;
wt-new)
  need agent-worktree; install=$(cfg '.install // empty'); rc=0
  git -C "$ROOT" fetch -q origin "$TRUNK" || { echo "fetch failed"; exit 1; }
  for s in "$@"; do
    out="$H/wt/$s.out"; w="$WT_ROOT/$s"
    [ -d "$w" ] && { echo "$s: worktree exists at $w; refusing"; rc=1; continue; }
    lane_reported "$s" && { echo "$s: lane $s has reports from an earlier run; a closed lane's slug is never reused"; rc=1; continue; }
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
  # a dot-led key's .started file would be invisible to every *.started glob, so to the cap and to liveness
  [[ "$k" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && "$w" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || { echo "refused: key and slug are [A-Za-z0-9._-], not starting with a dot or a dash" >&2; exit 1; }
  refuse_account "$a" || exit 1; cap_root_ok || exit 1
  # Close-outs run one at a time: each merges the trunk's plan index and lessons, and two in flight would each miss the other's.
  if [[ "$k" == *-closeout ]]; then
    open=$(gh pr list --repo "$REPO" --state open --limit 1000 --json headRefName --jq '.[].headRefName' 2>/dev/null) || { echo "refused: cannot list open PRs to serialize close-outs" >&2; exit 1; }
    other=$(grep -E -- '-closeout$' <<<"$open" | grep -vxF -- "$w-closeout" | head -1)
    [ -z "$other" ] || { echo "refused: close-out PR $other is still open; close-outs run one at a time" >&2; exit 1; }
  fi
  [ "$cmd" = resume ] && [ -z "$sid" ] && { echo "usage: resume <key> <slug> <account> <session-id>" >&2; exit 1; }
  p="$H/prompts/$k.md"; [ -f "$p" ] || { echo "orchy: no prompt $p" >&2; exit 1; }
  # What the earlier run left, read before this one can rewrite it: a retry's event keeps a first failure countable.
  rp="$H/reports/$k.md"; prior=null; pfl=null; pfs=null
  if [ -f "$rp" ]; then
    m=$(grep -xE 'LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*|SHOTS_READY.*|SHOTS_BLOCKED:.*' "$rp" | tail -1 | grep -oE '^(LEAD_DONE|LEAD_BLOCKED|ARC_FAILED|SHOTS_READY|SHOTS_BLOCKED)')
    [ -n "$m" ] && prior="\"$m\""
    pfl=$(grep -c '^ARC_FAILED:' "$rp"); [[ "$pfl" =~ ^[0-9]+$ ]] || pfl=null
    [ "$pfl" != null ] && [ "$pfl" -gt 0 ] && pfs="\"$(grep '^ARC_FAILED:' "$rp" | tail -1 | tr -d '\n' | sha256sum | cut -d' ' -f1)\""
  fi
  # Everything the lead reads passes the ban and the copy check; the owner's words reach it only as stored askN lines.
  reads=("$p"); for b in _common _planner _implementer "$w"; do [ -f "$H/briefs/$b.md" ] && reads+=("$H/briefs/$b.md"); done
  "$0" check-text "${reads[@]}" || exit 1
  "$0" check-private "${reads[@]}" || exit 1
  lb=(); [ -f "$H/briefs/$w.md" ] && lb=("$H/briefs/$w.md")
  ask_lines "$w" "$p" "${lb[@]}" || exit 1
  d="$WT_ROOT/$w"; [ -d "$d" ] || { echo "orchy: no worktree $d" >&2; exit 3; }
  model=$(cfg '.leads.model // "opus"'); l1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")
  case "$(cfg '.leads.permission_mode // "auto"')" in
    auto) perm=(--permission-mode auto --permission-prompts none);;
    bypass) perm=(--dangerously-skip-permissions);;
    *) echo "orchy: leads.permission_mode must be auto or bypass" >&2; exit 1;;
  esac
  extra=(); [ "$cmd" = resume ] && extra=(--resume "$sid")
  mkdir -p "$H/scratch/$w"; S="$H/leads/$k.settings.json"; L="$H/leads/$k.log"
  dirs=(--add-dir "$H/reports" --add-dir "$H/scratch/$w")
  [ -f "$H/page/shots-plan/$k.json" ] && { mkdir -p "$H/page/shots"; dirs+=(--add-dir "$H/page/shots"); }
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
      --settings "$S" "${dirs[@]}" --verbose --output-format stream-json >> "$L" 2>> "$H/leads/$k.err" ) &
  pid=$!
  record() { printf '%s %s %s %s %s %s %s %s\n' "$pid" "$(pstart "$pid")" "$a" "$(now)" "$weight" "prompts/$k.md" "$1" "$w" > "$H/leads/$k.started.tmp" && mv "$H/leads/$k.started.tmp" "$H/leads/$k.started"; }
  # recorded at once (exec keeps the pid and its start time), so a launcher killed during the wait still leaves the lead counted and stoppable
  record "?"
  for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$pid" && break; sleep 0.2; done
  pg=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' '); record "${pg:-?}"
  exec 9>&-
  echo "$k ${cmd%e}ed on $a pid $pid pgid ${pg:-?} ($weight, $(cfg '.leads.permission_mode // "auto"'), load1 $l1)"
  ev "lead.$cmd" key="$k" lane="$w" weight="$weight" prior:="$prior" prior_failed_lines:="$pfl" prior_failed_sha:="$pfs";;
stop)
  k=$1; f="$H/leads/$k.started"; [ -f "$f" ] || { echo "$k: no lead record"; exit 1; }
  read -r pid st _ _ _ _ pg _ < "$f"; alive "$pid" "$st" || { echo "$k: not alive"; exit 0; }
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
  echo "$k: stopped pid $pid and ${#ids[@]} process(es) in its tree"; ev lead.stop key="$k";;
say)
  need flock; k=$1; shift; t="$*"
  [[ "$k" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] && [ -n "$t" ] || { echo "usage: say <key> <text>" >&2; exit 1; }
  [ -f "$H/leads/$k.started" ] && read -r pid st _ _ _ _ _ lane _ < "$H/leads/$k.started" && alive "$pid" "$st" || { echo "refused: no live lead $k; fold the note into its next prompt" >&2; exit 1; }
  # leads quote their instructions into committed plans, so a note passes the same ban as a prompt
  # the sensitive pattern stays off: notes routinely name review findings
  tf="$H/scratch/say.$$"; printf '%s\n' "$t" > "$tf"
  { "$0" check-text "$tf" && "$0" check-public --no-sensitive "$tf" && ask_lines "${lane:-?}" --no-sensitive "$tf"; }; rc=$?; rm -f "$tf"; [ "$rc" = 0 ] || exit 1
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
    newest=$(newest_proc "$p" "$ps_rows"); [ -z "$newest" ] || newest="${newest#*$'\t'} ($(( ${newest%%$'\t'*} / 60 ))m)"
    flag=""; [ "$q" -gt "$stall" ] && flag="STALLED? "
    echo "alive $k $a $w pid $p ${flag}quiet $((q / 60))m progress $pa ${newest:+$newest}"
  done
  echo "-- inbox"; for f in "$H"/inbox/*.jsonl; do [ -f "$f" ] || continue
    c=$(cat "${f%.jsonl}.cursor" 2>/dev/null); [[ "$c" =~ ^[0-9]{1,15}$ ]] && c=$((10#$c)) || c=0
    n=$(tail -c +"$((c + 1))" "$f" | grep -c ''); [ "$n" -gt 0 ] && echo "$(basename "$f" .jsonl): $n undelivered"; done
  # ids and states only: the owner's words stay in the ledger (ask show)
  echo "-- asks"; live=$(lead_rows | cut -d' ' -f1)
  fold | jq -r --argjson now "$(date +%s)" 'map(select(.state == "open" or .state == "lane")) | sort_by(.id | ltrimstr("ask") | tonumber? // 0) | .[]
    | ($now - (.at | fromdateiso8601? // $now)) as $s
    | "\(.id) \(.state) \(.lane // "-") \(if $s < 3600 then "\($s / 60 | floor)m" else "\($s / 3600 | floor)h" end)"
      + (if .public then "" else " no-public-wording" end) + (if ([ '"$ASK_HOLD"' ] | length) > 0 then " waiting" else "" end)' |
  while read -r i st l rest; do
    if [ "$st" = lane ] && [ ! -d "$WT_ROOT/$l" ] && ! grep -qE "^$l-(plan|a[0-9]+|arc[0-9]+|closeout)$" <<<"$live"; then rest="$rest lane closed: run ask close-lane $l"; fi
    echo "$i $st $l $rest"
  done
  echo "-- watchers"; for f in "$H"/watch/*.pid; do [ -f "$f" ] || continue; n=$(basename "$f" .pid); if watcher_alive "$f"; then echo "alive $n pid $(cut -d' ' -f1 "$f")"; else echo "ended $n: $(tail -n 1 "$H/watch/$n.out" 2>/dev/null | cut -c1-120)"; fi; done
  echo "-- trunk"; if t=$(trunk_state); then f=$(tail -n +2 <<<"$t" | paste -sd, -); echo "$TRUNK ${t:0:8}: ${f:+RED }${f:-no failed trunk check}"; else echo "(trunk checks unreadable)"; fi
  echo "-- open PRs"; gh pr list --repo "$REPO" --state open --json number,title,headRefOid,mergeable,mergeStateStatus,isDraft,baseRefName --jq '.[]|"#\(.number) \(.headRefOid[0:8]) \(.mergeable) \(.mergeStateStatus) draft=\(.isDraft) -> \(.baseRefName) \(.title)"' 2>/dev/null || echo "(gh pr list failed)"
  echo "-- worktrees"; git -C "$ROOT" worktree list | tail -n +2
  echo "-- untriaged issues"
  if [ ! -f "$H/triaged.txt" ]; then echo "(no triaged.txt: write every triaged issue number into it, one per line)"
  elif iss=$(gh issue list --repo "$REPO" --state open --limit 1000 --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null); then
    awk -F'\t' 'FILENAME == ARGV[1] {t[$1]=1; next} $1 != "" && !($1 in t) {print "#" $1 " " substr($2, 1, 100)}' <(grep -xE '[0-9]+' "$H/triaged.txt") <(printf '%s\n' "$iss")
  else echo "(gh issue list failed)"; fi
  echo "-- unsigned pages"; [ -f "$H/page/unsigned.json" ] && jq -r --argjson now "$(date +%s)" --slurpfile u "$H/page/unsigned.json" '.pages[] | select(.no as $n | $u[0] | index($n)) |
    "page \(.no) \(.name): " + (if .added_at then (($now - (.added_at | fromdateiso8601)) | "waiting \(. / 86400 | floor)d\(. % 86400 / 3600 | floor)h") else "age unknown" end)' "$H/page/decisions.json" 2>/dev/null
  echo "-- waiting"; "$0" waiting list 2>&1
  echo "-- headroom"; claude-usage 2>/dev/null | head -12;;
state)
  # orchy.state/1 for a poller: local facts only (no gh, usage or network call) and nothing written. The seat and the
  # pages are left to the reader, who parses those files directly. An unreadable source is null and named in errors.
  errs=(); tnow=$(date +%s); sm=$(cfg '.leads.stall_after_min // 20' 2>/dev/null); [[ "$sm" =~ ^[0-9]{1,6}$ ]] || sm=20; stall=$(( 10#$sm * 60 )); ps_rows=$(ps -eo pid=,ppid=,etimes=,args=)
  leads=$(for f in "$H"/leads/*.started; do [ -f "$f" ] && [ ! -L "$f" ] || continue; k=$(basename "$f" .started)
      read -r pid st acct t weight _ pg lane _ < "$f" || continue
      a=false; alive "$pid" "$st" && a=true; nw=""; [ $a = true ] && nw=$(newest_proc "$pid" "$ps_rows")
      q=$(( tnow - $(stat -c %Y "$H/leads/$k.log" 2>/dev/null || echo "$tnow") ))
      pa=null; [ -f "$H/reports/$k.progress" ] && pa=$(( tnow - $(stat -c %Y "$H/reports/$k.progress") ))
      jq -nc --arg key "$k" --arg lane "${lane:-}" --arg account "${acct:-}" --arg weight "${weight:-heavy}" --argjson alive "$a" \
        --arg pid "$pid" --arg pgid "${pg:-}" --arg started "${t:-}" --argjson q "$q" --argjson pa "$pa" --arg nw "$nw" --argjson stall "$stall" \
        '{key: $key, lane: (if $lane == "" then null else $lane end), account: $account, weight: $weight, alive: $alive,
          pid: ($pid | tonumber? // null), pgid: ($pgid | tonumber? // null), started: $started, quiet_s: $q, progress_age_s: $pa,
          newest: (if $nw == "" then null else ($nw | split("\t") | {cmd: (.[1:] | join("\t")), age_s: (.[0] | tonumber)}) end),
          stalled: ($alive and $q > $stall)}'
    done | jq -sc .) || { leads=null; errs+=(leads); }
  rep=$(python3 -I - "$H/reports" <<'PY'
import sys, os, re, json, glob, hashlib
d = sys.argv[1]; out = {"reports": [], "progress": {}}
MARK = re.compile(rb"(LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*|SHOTS_READY.*|SHOTS_BLOCKED:.*)")
def text(b, n): return b.decode("utf-8", "replace")[:n]
def regular(p): return os.path.isfile(p) and not os.path.islink(p)
for p in sorted(glob.glob(os.path.join(d, "*.md"))):
    key = os.path.basename(p)[:-3]
    if not regular(p): out["reports"].append({"key": key, "error": "not a regular file"}); continue
    try:
        if os.path.getsize(p) > 4 << 20: out["reports"].append({"key": key, "error": "larger than 4 MiB"}); continue
        with open(p, "rb") as fh: data = fh.read()
        mtime = int(os.path.getmtime(p))
    except OSError: out["reports"].append({"key": key, "error": "unreadable"}); continue
    lines = data.split(b"\n"); marks = [l for l in lines if MARK.fullmatch(l)]
    failed = [l for l in lines if l.startswith(b"ARC_FAILED:")]
    last = marks[-1] if marks else None; marker = detail = None
    if last is not None:
        marker = re.match(rb"[A-Z_]+", last).group(0).decode()
        rest = last[len(marker):].lstrip(b":").strip(); detail = text(rest, 80) if rest else None
    def lastm(rx, conv):
        m = [re.match(rx, l) for l in lines]; m = [x for x in m if x]
        return conv(m[-1].group(1)) if m else None
    out["reports"].append({"key": key, "mtime": mtime, "marker": marker, "detail": detail,
        "pr": lastm(rb"PR #(\d+)(?: |$)", int), "head": lastm(rb"HEAD ([0-9a-f]{40})$", bytes.decode),
        "codex_rounds": lastm(rb"CODEX: converged in (\d+) round", int), "arc_failed_lines": len(failed),
        "last_failed_sha": hashlib.sha256(failed[-1]).hexdigest() if failed else None})
for p in sorted(glob.glob(os.path.join(d, "*.progress"))):
    if not regular(p): continue
    try:
        with open(p, "rb") as fh: fh.seek(max(0, os.path.getsize(p) - 200)); out["progress"][os.path.basename(p)[:-9]] = text(fh.read().replace(b"\n", b" "), 200)
    except OSError: pass
print(json.dumps(out))
PY
  ) || { rep='{"reports": null, "progress": null}'; errs+=(reports); }
  watchers=$(for f in "$H"/watch/*.pid; do [ -f "$f" ] || continue; n=$(basename "$f" .pid); a=false; watcher_alive "$f" && a=true
      # the last line is often a runs table or a status line, so the newest watcher marker is read separately
      mk=$(grep -oE '#[0-9]+ MERGED|HEAD MOVED|DIRTY|TRUNK RED|TRUNK UNREADABLE|REQUIRED FAILED|MISSING REQUIRED CHECK|NOT MERGED|TIMEOUT|REFUSED|state unreadable after the merge call' "$H/watch/$n.out" 2>/dev/null | tail -n 1)
      jq -nc --arg n "$n" --argjson a "$a" --arg last "$(tail -n 1 "$H/watch/$n.out" 2>/dev/null | cut -c1-120)" --arg mk "$mk" \
        '{name: $n, alive: $a, pr: (($n | capture("^merge-(?<n>[0-9]+)$").n | tonumber) // null), last: (if $last == "" then null else $last end),
          marker: (if $mk == "" then null elif ($mk | test("^#[0-9]+ MERGED$")) then "MERGED" elif ($mk | startswith("state unreadable")) then "AMBIGUOUS" else $mk end)}'
    done | jq -sc .) || { watchers=null; errs+=(watchers); }
  inbox=$(for f in "$H"/inbox/*.jsonl; do [ -f "$f" ] || continue
      c=$(cat "${f%.jsonl}.cursor" 2>/dev/null); [[ "$c" =~ ^[0-9]{1,15}$ ]] && c=$((10#$c)) || c=0
      jq -nc --arg k "$(basename "$f" .jsonl)" --argjson n "$(tail -c +"$((c + 1))" "$f" | grep -c '')" '{key: $k, undelivered: $n}'
    done | jq -sc .) || { inbox=null; errs+=(inbox); }
  # ids, states and flags only: the owner's words stay behind ask list --json
  asks=null; if ledger_ro 2>/dev/null; then
    asks=$(fold | jq -c --argjson now "$tnow" '[map(select(.state == "open" or .state == "lane")) | sort_by(.id | ltrimstr("ask") | tonumber? // 0) | .[]
      | {id, state, lane: (.lane // null), age_s: ($now - (.at | fromdateiso8601? // $now)), has_public: (.public != null),
         waiting: (([ '"$ASK_HOLD"' ] | length) > 0)}]') || { asks=null; errs+=(asks); }
  else errs+=(asks); fi
  waiting=null; if w=$(waiting_read 2>/dev/null); then waiting=$(jq -c .waiting <<<"$w"); else errs+=(waiting); fi
  triaged=null; if [ -e "$H/triaged.txt" ]; then
    if [ -f "$H/triaged.txt" ] && [ -r "$H/triaged.txt" ]; then triaged=$(grep -xE '[0-9]+' "$H/triaged.txt" | jq -Rsc 'split("\n") | map(select(. != "") | tonumber)')
    else errs+=(triaged); fi
  fi
  wts=null; if wl=$(git -C "$ROOT" worktree list --porcelain 2>/dev/null); then
    wts=$(awk -v r="$WT_ROOT/" '
      function out() { s = substr(p, length(r) + 1); if (index(p, r) == 1 && s != "" && index(s, "/") == 0) print s "\t" b "\t" h }
      /^worktree / { if (p != "") out(); p = substr($0, 10); b = ""; h = "" } /^HEAD / { h = $2 } /^branch / { b = substr($2, 12) } END { if (p != "") out() }' <<<"$wl" |
      jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {slug: .[0], branch: (if .[1] == "" then null else .[1] end), head: .[2]})')
  else errs+=(worktrees); fi
  caps=null; [ -f "$LOCAL" ] && { caps=$(jq -c '{week_floor_pct: .accounts.min_week_left_pct, heavy: .accounts.heavy_per_account, light: .accounts.light_per_account, load_max}
      | map_values(if type == "number" then . else null end)' "$LOCAL" 2>/dev/null) || { caps=null; errs+=(caps); }; }
  j() { printf '%s' "${1:-null}"; }   # each source travels as a file: a large array would overflow one argv string
  jq -nc --arg repo "$REPO" --arg at "$(now)" --slurpfile leads <(j "$leads") --slurpfile rep <(j "$rep") --slurpfile watchers <(j "$watchers") \
    --slurpfile inbox <(j "$inbox") --slurpfile asks <(j "$asks") --slurpfile waiting <(j "$waiting") --slurpfile triaged <(j "$triaged") --slurpfile wts <(j "$wts") --argjson caps "${caps:-null}" \
    --arg mode "$(cfg '.mode // empty')" --arg boot "$(cfg '.bootstrap // empty')" --arg trunk "$TRUNK" \
    --arg load1 "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)" --arg nproc "$(nproc 2>/dev/null)" --arg errs "${errs[*]}" \
    '{schema: "orchy.state/1", repo: $repo, at: $at, leads: $leads[0], reports: $rep[0].reports, progress: $rep[0].progress, watchers: $watchers[0],
      inbox: $inbox[0], asks: $asks[0], waiting: $waiting[0], triaged: $triaged[0], worktrees: $wts[0], caps: $caps,
      mode: (if $mode == "" then null else $mode end), bootstrap: (if $boot == "" then null else $boot end), trunk: $trunk,
      load1: ($load1 | tonumber? // null), nproc: ($nproc | tonumber? // null), errors: ($errs | split(" ") | map(select(. != "")))}';;
wait)
  LIMIT=${1:-1500}
  snap() {
    ls -l --time-style=+%s "$H"/reports/*.md 2>/dev/null | awk '{print $6, $7}'
    lead_rows | awk '{print "alive", $1}'
    for f in "$H"/watch/*.pid; do watcher_alive "$f" && echo "watcher $(basename "$f" .pid)"; done
  }
  # GitHub every poll_sec, in three independent reads: one that fails keeps its baseline and never hides another's change.
  read_src() { local o; case $1 in
    prs) o=$(timeout 30 gh pr list --repo "$REPO" --state open --limit 1000 --json number,headRefOid,mergeable,isDraft --jq '.[]|"\(.number) \(.headRefOid[0:8]) \(.mergeable) \(.isDraft)"' 2>/dev/null) || return 1;;
    issues) o=$(timeout 30 gh issue list --repo "$REPO" --state open --limit 1000 --json number,updatedAt --jq '.[]|"\(.number) \(.updatedAt)"' 2>/dev/null) || return 1;;
    trunk) o=$(timeout 30 gh api "repos/$REPO/commits/$TRUNK" --jq .sha 2>/dev/null) && sha_ok "$o" || return 1;;
    esac; sort <<<"$o"; }
  tick=${ORCHY_WAIT_TICK:-20}; every=$(( $(cfg '.wait.poll_sec // 120') / tick )); [ "$every" -ge 1 ] || every=1
  # Baselines persist in seen/, so what moved while nobody waited (the orchestrator handling the last event) fires at the
  # first look. A source with no seen file is unknown: its first successful read fires. An exit advances only what it printed,
  # so seen/ only ever holds reported values: a second concurrent wait can report a change twice, never lose one.
  SEEN="$H/seen"; mkdir -p "$SEEN"
  declare -A last=() new=() unread=(); srcs=(prs issues trunk)
  for s in local "${srcs[@]}"; do [ -f "$SEEN/$s" ] && last[$s]=$(cat "$SEEN/$s"); done
  report() { local s l
    for s in "$@"; do l=$s; [ "$s" = local ] && l="reports/leads/watchers"
      echo "CHANGED ($l):" || return 1; diff <(echo "${last[$s]:-}") <(echo "${new[$s]}") | grep '^[<>]' | head -20; done
    for s in "$@"; do printf '%s\n' "${new[$s]}" > "$SEEN/.$s.$$" && mv "$SEEN/.$s.$$" "$SEEN/$s" || return 1; done; }
  t0=$(date +%s); n=0
  while :; do
    sleep "$tick"; n=$((n+1)); changed=()
    new[local]=$(snap); { [ -n "${last[local]+x}" ] && [ "${new[local]}" = "${last[local]}" ]; } || changed+=(local)
    # the first tick polls too: local events re-arm the wait, and a burst of them must not starve GitHub
    if [ "$n" = 1 ] || [ $((n % every)) -eq 0 ]; then
      for s in "${srcs[@]}"; do
        v=$(read_src "$s") || { unread[$s]=1; continue; }; unset "unread[$s]"
        # GitHub answers UNKNOWN while it recomputes mergeability; that is not a change
        [ "$s" = prs ] && [ -n "${last[$s]+x}" ] && v=$(awk 'NR==FNR{m[$1]=$3; next} ($1 in m) && $3=="UNKNOWN"{$3=m[$1]} {print}' <(echo "${last[$s]}") <(echo "$v"))
        if [ -z "${last[$s]+x}" ] || [ "$v" != "${last[$s]}" ]; then changed+=("$s"); new[$s]=$v; fi
      done
    fi
    if [ ${#changed[@]} -gt 0 ]; then report "${changed[@]}"; exit $?; fi
    if [ $(( $(date +%s) - t0 )) -ge "$LIMIT" ]; then u="${!unread[*]}"; echo "TIMEOUT after ${LIMIT}s, no change${u:+; unreadable: $u}"; exit 0; fi
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
    [ "$state" = OPEN ] || { echo "#$N is $state; watcher stopped"; exit 4; }
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
    [ "$(cfg '.mode // empty')" = triage ] && { echo "REFUSED: orchy.json mode is triage; not merged"; exit 4; }
    [ "$try" = 1 ] || trunk_ok || { echo "TRUNK RED at merge time; not merged"; exit 7; }
    out=$(gh pr merge "$N" --repo "$REPO" "--$method" --delete-branch --match-head-commit "$PIN" 2>&1 | tail -1); echo "$out"
    for _ in 1 2 3; do sleep $((WS/10)); s=$(gh pr view "$N" --repo "$REPO" --json state --jq .state 2>/dev/null) && break; done
    [ -n "$s" ] || { echo "#$N state unreadable after the merge call; check it by hand"; exit 6; }
    [ "$s" = MERGED ] && { merged=1; break; }
    echo "$out" | grep -q "Base branch was modified" || break; sleep $((WS/2))
  done
  [ "$merged" = 1 ] || { echo "NOT MERGED; check #$N by hand"; exit 6; }
  gh pr view "$N" --repo "$REPO" --json state,mergeCommit --jq '"#'"$N"' \(.state) \(.mergeCommit.oid)"'
  echo "--- teardown $LANE once the archived plan is on $TRUNK"
  on_trunk=0; for t in 1 2 3 4 5 6; do git -C "$ROOT" fetch -q origin "$TRUNK"; git -C "$ROOT" cat-file -e "FETCH_HEAD:$ARCHIVE/$ARCH/plan.md" 2>/dev/null && { on_trunk=1; break; }; sleep $((WS/4)); done
  if [ $on_trunk = 1 ]; then "$0" teardown "$LANE" 2>&1 | tail -3; else echo "archived plan not on $TRUNK yet; teardown skipped"; fi;;
arm-merge)
  N=$1; sha_ok "$2" || { echo "refused: pin must be the full 40-hex head sha"; exit 4; }
  # the watcher reads reports/<name> and waits silently for its LEAD_DONE, so a report it cannot find would idle for hours
  [ -f "$H/reports/${4:-}" ] || { echo "refused: no report $H/reports/${4:-}; pass its file name under reports/"; exit 4; }
  delay=${6:-0}; args=("$1" "$2" "$3" "$4"); [ -n "${5:-}" ] && args+=("$5")
  watcher_alive "$H/watch/merge-$N.pid" && { echo "refused: merge-$N is already armed (pid $(cut -d' ' -f1 "$H/watch/merge-$N.pid"))"; exit 1; }
  ( cd "$ROOT" && exec env ORCHY_ROOT="$ROOT" ORCHY_HOME="$H" setsid nohup bash -c "sleep $delay; exec bash '$(realpath "$0")' watch-merge $(printf '%q ' "${args[@]}")" ) > "$H/watch/merge-$N.out" 2>&1 &
  p=$!; echo "$p $(pstart "$p")" > "$H/watch/merge-$N.pid"; sleep 1   # the watcher overwrites this with its own identity once it runs
  echo "armed merge-$N pid $(cut -d' ' -f1 "$H/watch/merge-$N.pid") (delay ${delay}s) -> $H/watch/merge-$N.out";;
disarm)
  for f in "$H"/watch/merge-${1:-*}.pid; do [ -f "$f" ] || continue; n=$(basename "$f" .pid); num=${n#merge-}
    if watcher_alive "$f"; then p=$(cut -d' ' -f1 "$f"); kill -- "-$p" 2>/dev/null; kill "$p" 2>/dev/null; sleep 1; echo "stopped $n"
      if [[ "$num" =~ ^[0-9]+$ ]]; then ev merge.disarmed pr:="$num"; fi
    else echo "$n not running"; fi
    # a wrapper that had not exec'd yet, or a child gh call, may outlive the group kill: finish by command line, never by a bare name
    for q in $(pgrep -f "orchy.sh watch-merge $num " 2>/dev/null); do tr '\0' '\n' < "/proc/$q/environ" 2>/dev/null | grep -qxF "ORCHY_HOME=$H" || continue; kill "$q" 2>/dev/null && echo "stopped stray $q of $n"; done
  done;;
teardown)
  need gh; need agent-worktree; s=$1; W="$WT_ROOT/$s"; q="$(basename "$ROOT")/$s"
  [ -d "$W" ] || { echo "$s: no worktree dir"; (cd "$ROOT" && agent-worktree done "$q" --forget 2>&1 | tail -1); exit 0; }
  # a lead belongs to the lane whose worktree it runs in (launch starts it there), whatever its key
  wr=$(realpath -m "$W")
  lead_rows | while read -r k _ _ p; do c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue; { [ "$c" = "$wr" ] || [ "${c#"$wr"/}" != "$c" ]; } && echo "$k"; done | grep -q . && { echo "$s: a lead of this lane is alive; refusing"; exit 4; }
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
  js=0; off=0; want=""; for o in "$@"; do case "$o" in --json) js=1;; --offline) off=1;; *) want=$o;; esac; done
  [ $off = 1 ] || need gh
  asks='{}'; if ledger_ro 2>/dev/null; then asks=$(fold | jq -c 'map_values({state, lane})'); fi
  python3 -I - "$H" "$REPO" "$want" "$asks" "$js" "$off" <<'PY'
import sys, os, re, json, glob, subprocess, datetime
H, repo, want = sys.argv[1:4]
asks = json.loads(sys.argv[4] or "{}")   # ask id -> {state, lane}; never the owner's words
as_json, offline = sys.argv[5] == "1", sys.argv[6] == "1"
# keys are <lane>-plan, <lane>-a<n>, <lane>-closeout; only logs written before invocation markers need the name
legacy_lane = lambda k: re.sub(r"-(plan|a\d+|closeout|shots[\w-]*)$", "", k)
KINDS = (("in", "input_tokens", "inputTokens"), ("out", "output_tokens", "outputTokens"),
         ("cache-read", "cache_read_input_tokens", "cacheReadInputTokens"), ("cache-write", "cache_creation_input_tokens", "cacheCreationInputTokens"))
UTC = datetime.timezone.utc
def epoch(at):
    try: return datetime.datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC).timestamp()
    except (TypeError, ValueError): return None
iso = lambda t: datetime.datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
segs = []
for path in sorted(glob.glob(f"{H}/leads/*.log")):
    key = os.path.basename(path)[:-4]; seg = None; mine = []
    def new(lane, k, at, cmd=None):
        s = {"lane": lane, "key": k, "at": at, "cmd": cmd, "sid": None, "result": None, "after": {}, "mtime": os.path.getmtime(path), "file": mine}
        segs.append(s); mine.append(s); return s
    for line in open(path, errors="replace"):
        try: e = json.loads(line)
        except ValueError: continue
        if not isinstance(e, dict): continue
        t = e.get("type")
        if t == "orchy_invocation": seg = new(e.get("lane") or legacy_lane(key), e.get("key") or key, e.get("at") or "", e.get("cmd")); continue
        if t == "system" and e.get("subtype") == "init":
            if seg is None or (seg["sid"] and not seg["at"]): seg = new(legacy_lane(key), key, "")
            seg["sid"] = seg["sid"] or e.get("session_id"); continue
        if seg is None: seg = new(legacy_lane(key), key, "")
        if t == "result": seg["result"] = e; seg["after"] = {}
        elif t == "assistant" and isinstance(e.get("message"), dict) and e["message"].get("usage"):
            seg["after"][e["message"].get("id") or id(e)] = e["message"]["usage"]   # a message repeats per content block: keep the last
# On --resume, total_cost_usd and modelUsage are the session's running totals: each session counts its last result once,
# plus the unpriced usage of runs killed after it. A run's own cost is its total minus the session's previous total.
lanes, by_sid = {}, {}
for i, s in enumerate(segs): s["sid"] = s["sid"] or f"unknown-{i}"
def order(s):  # an unmarked segment sits just before the next marked one in its log, else at the log's mtime;
    # only order within a session matters: ties go by the session's running total so far in this log (a killed run has
    # none of its own), then by position in the log
    i = s["file"].index(s); later = [x["at"] for x in s["file"][i + 1:] if x["at"]]
    total = max([float(x["result"].get("total_cost_usd") or 0) for x in s["file"][:i + 1] if x["result"] and x["sid"] == s["sid"]] or [0.0])
    return (s["at"] or (later[0] if later else iso(s["mtime"])), 1 if s["at"] else 0, total, i)
for s in sorted(segs, key=order): by_sid.setdefault(s["sid"], []).append(s)
for sid, ss in by_sid.items():
    L = lanes.setdefault(ss[0]["lane"], {"cost": 0.0, "tok": {k[0]: 0 for k in KINDS}, "partial": 0, "sessions": 0, "keys": set(), "start": None, "end": 0, "runs": []})
    L["sessions"] += 1
    done = [j for j, s in enumerate(ss) if s["result"]]
    if done:
        r = ss[done[-1]]["result"]; L["cost"] += float(r.get("total_cost_usd") or 0)
        for mu in (r.get("modelUsage") or {}).values():
            for name, _, camel in KINDS: L["tok"][name] += int(mu.get(camel) or 0)
    for s in ss[done[-1] if done else 0:]:
        L["partial"] += sum(int(u.get(snake) or 0) for u in s["after"].values() for _, snake, _ in KINDS)
    prev = 0.0
    for s in ss:
        L["keys"].add(s["key"]); L["end"] = max(L["end"], s["mtime"])
        if s["at"] and (L["start"] is None or s["at"] < L["start"]): L["start"] = s["at"]
        r, cost = s["result"], None
        if r:
            total = float(r.get("total_cost_usd") or 0); cost = round(total - prev if total >= prev else total, 6); prev = total
        # the log's mtime is the file's, not the run's: it is the last resort, flagged approx
        t0, dur, ended, approx = epoch(s["at"]), (r or {}).get("duration_ms"), None, True
        if t0 is not None and isinstance(dur, (int, float)): ended, approx = iso(t0 + dur / 1000), False
        else:
            later = [x for x in s["file"][s["file"].index(s) + 1:] if x["at"]]
            ended = later[0]["at"] if later else iso(s["mtime"])
        L["runs"].append({"key": s["key"], "session": s["sid"], "cmd": s["cmd"], "at": s["at"] or None, "ended": ended, "approx": approx, "cost_usd": cost})
def gh(*a):
    p = subprocess.run(["gh", *a, "--repo", repo], capture_output=True, text=True)
    if p.returncode: raise RuntimeError(p.stderr.strip()[:120])
    return p.stdout.split()
model = {"schema": "orchy.receipt/1", "offline": offline, "lanes": [], "total": None}
for lane in sorted(lanes):
    if want and lane != want: continue
    L = lanes[lane]; prs, failed, rounds = [], 0, 0
    try: named = [f[:-3] for f in os.listdir(f"{H}/reports") if re.fullmatch(rf"{re.escape(lane)}-(plan|closeout|a\d+|arc\d+)\.md", f)]
    except OSError: named = []
    for k in sorted(L["keys"] | set(named)):
        try: rep = open(f"{H}/reports/{k}.md", errors="replace").read()
        except OSError: continue
        prs += [int(n) for n in re.findall(r"^PR #(\d+) ", rep, re.M)]
        failed += len(re.findall(r"^ARC_FAILED:", rep, re.M)); rounds += sum(int(n) for n in re.findall(r"^CODEX: converged in (\d+) round", rep, re.M))
    prs = sorted(set(prs)); merged = []
    for n in prs:
        try: out = open(f"{H}/watch/merge-{n}.out", errors="replace").read()
        except OSError: continue
        if re.search(rf"^#{n} MERGED [0-9a-f]+", out, re.M): merged.append(n)
    closed, gh_error = None, None
    if not offline:
        try:
            refs = sorted({int(i) for n in merged for i in gh("pr", "view", str(n), "--json", "closingIssuesReferences", "--jq", ".closingIssuesReferences[].number")})
            closed = [i for i in refs if gh("issue", "view", str(i), "--json", "state", "--jq", ".state") == ["CLOSED"]]
        except RuntimeError as err: gh_error = str(err)
    t0 = epoch(L["start"]); wall = None if t0 is None else int(L["end"] - t0)
    done_asks = sorted((i for i, a in asks.items() if a.get("state") == "done" and a.get("lane") == lane), key=lambda i: int(i[3:]) if i[3:].isdigit() else 0)
    model["lanes"].append({"lane": lane, "cost_usd": L["cost"], "unpriced_tokens": L["partial"], "sessions": L["sessions"],
        "tokens": {k.replace("-", "_"): v for k, v in L["tok"].items()}, "wall_s": wall, "start": L["start"], "prs": prs, "merged": merged,
        "issues_closed": closed, "gh_error": gh_error, "failed_arcs": failed, "codex_rounds": rounds, "asks_done": done_asks, "runs": L["runs"]})
if not want: model["total"] = {"cost_usd": sum(l["cost_usd"] for l in model["lanes"]), "unpriced_tokens": sum(l["unpriced_tokens"] for l in model["lanes"])}
missing = bool(want) and want not in lanes
if as_json:
    print(json.dumps(model)); sys.exit(1 if missing else 0)
for l in model["lanes"]:
    wall = "?" if l["wall_s"] is None else f"{int(l['wall_s'] // 3600)}h{int(l['wall_s'] % 3600 // 60):02d}m"
    if offline: issues = "? (offline)"
    elif l["gh_error"] is not None: issues = f"? (gh: {l['gh_error']})"
    else: issues = f"{len(l['issues_closed'])}" + (f" ({' '.join(f'#{i}' for i in l['issues_closed'])})" if l["issues_closed"] else "")
    tok = " ".join(f"{k.replace('_', '-')} {v}" for k, v in l["tokens"].items())
    part = f" + {l['unpriced_tokens']} unpriced tokens from killed runs" if l["unpriced_tokens"] else ""
    print(f"{l['lane']}: ${l['cost_usd']:.2f} API-equivalent{part}; {l['sessions']} session(s); tokens {tok}; wall {wall}; "
          f"PRs {' '.join(f'#{n}' for n in l['prs']) or '-'} (merged {' '.join(f'#{n}' for n in l['merged']) or '-'}); issues closed {issues}; "
          f"failed arcs {l['failed_arcs']}; Codex rounds {l['codex_rounds']}; asks done {len(l['asks_done'])}" + (f" ({' '.join(l['asks_done'])})" if l["asks_done"] else ""))
if not want and len(lanes) > 1:
    t = model["total"]; print(f"total: ${t['cost_usd']:.2f} API-equivalent" + (f" + {t['unpriced_tokens']} unpriced tokens" if t["unpriced_tokens"] else ""))
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
if missing: print(f"no lead logs for lane {want}", file=sys.stderr); sys.exit(1)
PY
  ;;
*) echo "orchy: unknown subcommand $cmd" >&2; usage 1;;
esac
