# shellcheck shell=bash
# Process identity, the event log and the name checks every part shares.
utc_now() { date -u +%FT%TZ; }
ev() { # ev <kind> [k=v | k:=<json>]...: one orchy.event/1 line in $H/events.jsonl; ids only, never text, account names or paths
  local kind=$1 a args=(); shift
  for a in "$@"; do case "$a" in *:=*) args+=(--argjson "${a%%:=*}" "${a#*:=}");; *) args+=(--arg "${a%%=*}" "${a#*=}");; esac; done
  # one write under 1 KiB, so atomic under O_APPEND; a failed write never changes the caller's output or exit code
  local f="$H/events.jsonl"; if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then return 0; fi
  { jq -nc --arg kind "$kind" --arg at "$(utc_now)" "${args[@]}" '{schema: "orchy.event/1"} + $ARGS.named' >> "$f"; } 2>/dev/null || true
}
pid_start() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null || echo ""; }   # a pid is reused; its start time is not
alive() { # alive <pid> [<start>]: the process exists, is a claude or claude-usage run, and has the recorded start time
  local p=$1 s=${2:-}; [ -n "$p" ] || return 1
  ps -o args= -p "$p" 2>/dev/null | grep -qE '(^|/)(claude|claude-usage)( |$)' || return 1
  [ -z "$s" ] || [ "$(pid_start "$p")" = "$s" ]
}
watcher_alive() { local f=$1; [ -f "$f" ] || return 1; read -r p s < "$f"; [ -n "$p" ] && [ -d "/proc/$p" ] && { [ -z "${s:-}" ] || [ "$(pid_start "$p")" = "$s" ]; }; }
lead_rows() { for f in "$H"/leads/*.started; do [ -f "$f" ] || continue; read -r pid st acct _ weight _ < "$f"; alive "$pid" "$st" && echo "$(basename "$f" .started) $acct ${weight:-heavy} $pid"; done; }
newest_proc() { # newest_proc <pid> <ps -eo pid=,ppid=,etimes=,args= rows>: "<age_s><TAB><cmd ≤80>" of the youngest process below pid, or nothing
  awk -v r="$1" '
    { pid=$1; par[pid]=$2; et[pid]=$3; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+/, ""); cmd[pid]=$0 }
    END { s[r]=1; c=1; while (c) { c=0; for (x in par) if (!(x in s) && (par[x] in s)) { s[x]=1; c=1 } }
          best=""; for (x in s) if (x != r && (best == "" || et[x] < et[best])) best=x
          if (best != "") printf "%d\t%s", et[best], substr(cmd[best], 1, 80) }' <<<"$2"
}
sha_ok() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
name_ok() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; }   # a slug or a file name: no path, nothing dot- or dash-led
ref_ok() { [[ "$1" =~ ^[A-Za-z0-9._/-]{1,100}$ && "$1" != *..* && "$1" != [-/]* ]]; }   # branch, ref and tag names, safe in an API path as written
session_pid() { # the orchestrator session: $CLAUDE_PID while it is a live claude, else the nearest `claude` ancestor, else (a test, a plain shell) the caller's parent
  local p=${CLAUDE_PID:-} c
  if [[ "$p" =~ ^[0-9]+$ ]] && [ "$(ps -o comm= -p "$p" 2>/dev/null)" = claude ]; then echo "$p"; return; fi
  p=$PPID; while [ "$p" -gt 1 ] 2>/dev/null; do c=$(ps -o comm= -p "$p" 2>/dev/null); [ "$c" = claude ] && { echo "$p"; return; }; p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 1); done; echo "$PPID"
}
# ts_run <module> <arg>...: orchy/<module>.ts under bun, from its own directory, so no bunfig.toml or .env of the caller's
# repo reaches it. Never on the path of state, ask list or receipt: those viewers run where bun is not installed.
ts_run() {
  (cd "$SCRIPTS/orchy" && exec bun "./$1.ts" "${@:2}")
}
abs_path() { case $1 in /* | "") printf '%s' "$1";; *) printf '%s/%s' "$(pwd -P)" "$1";; esac; }   # ts_run changes directory
