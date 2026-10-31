# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Requests: what waits on the owner as a typed question (requests.ts holds the format). They sit beside the ask ledger,
# not in $H: a lead writes anywhere in $H, and a request planted there could be shown, answered and acted on.
# Lock order: requests.lock (fd 5), then the seat's takeover lock (fd 4), then the waiting lock (fd 8).
RQ="${LEDGER%.jsonl}.requests"
rq_dirs_ro() { # the readers' check: creates nothing; a missing folder holds no requests
  local p; for p in "$ASKS_DIR" "$RQ" "$RQ/closed"; do
    if [ -L "$p" ] || { [ -e "$p" ] && { [ ! -d "$p" ] || [ ! -O "$p" ]; }; }; then echo "refused: $p must be a directory owned by $(id -un), not a symlink" >&2; return 1; fi; done
}
rq_dirs_ok() {
  rq_dirs_ro && mkdir -p "$RQ/closed" && chmod 700 "$ASKS_DIR" "$RQ" "$RQ/closed" && rq_dirs_ro || { echo "refused: cannot create $RQ" >&2; return 1; }
}
lead_below() { # the pid of the lead this process runs under: an ancestor whose pid and start time a leads/*.started records
  local f p st k=" " q=$$
  for f in "$CAP"/*/leads/*.started; do [ -f "$f" ] && read -r p st _ < "$f" 2>/dev/null && k+="$p:$st "; done
  while [ "$q" -gt 1 ] 2>/dev/null; do
    [[ $k == *" $q:$(pid_start "$q") "* ]] && { echo "$q"; return 0; }
    q=$(ps -o ppid= -p "$q" 2>/dev/null | tr -d ' '); [ -n "$q" ] || q=1
  done; return 1
}
# One request file, slurped so it must hold exactly one value, as its waiting row: empty when closed, an error when it
# is not a request the waiting grammar can show. Refs and times are held to printable ASCII and a fixed length first,
# since jq's $ also matches before a final newline and fromdateiso8601 ignores what follows a blank.
RQ_ROW='if length != 1 then error("x") else .[0] end
  | if type != "object" or .schema != "orchy.request/1" or .id != $id then error("x")
  elif .status == "done" or .status == "withdrawn" then empty
  elif (.status == "open" or .status == "stale" or .status == "taken")
    and (.ref | type) == "string" and (.ref | explode | all(. > 32 and . < 127)) and (.ref | test($wref))
    and (.title | type) == "string" and (.title | length) >= 1 and (.title | length) <= 160
    and (.title | explode | all(. >= 32 and (. < 127 or . >= 160) and . != 1564 and . != 8206 and . != 8207
      and (. < 8232 or . > 8238) and (. < 8294 or . > 8297)))
    and (.since | type) == "string" and (.since | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and length == 20)
    and (.since | try fromdateiso8601 catch null) != null
  then {id, ref, text: .title, since} else error("x") end'
rq_rows() { # {rows: [{id, ref, text, since}], errors: [{file, error}]} of the requests not closed; jq alone, so a viewer without bun reads it
  rq_dirs_ro || return 1
  local f b e r rows=() errs=()
  for f in "$RQ"/rq*.json; do b=${f##*/}
    [[ $b =~ ^rq[1-9][0-9]{0,8}\.json$ ]] || continue
    if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -O "$f" ]; then e="not a regular file owned by $(id -un)"
    elif [ "$(stat -c %s -- "$f" 2>/dev/null || echo 0)" -gt 65536 ]; then e="over 65536 bytes"
    elif r=$(jq -sc --arg id "${b%.json}" --arg wref "$WREF" "$RQ_ROW" "$f" 2>/dev/null); then [ -z "$r" ] || rows+=("$r"); continue
    else e="not an orchy.request/1 the waiting list can show"; fi
    [ -e "$f" ] || [ -L "$f" ] || continue   # renamed away since the listing: closed, not broken
    errs+=("$(jq -nc --arg f "$b" --arg e "$e" '{file: $f, error: $e}')")
  done
  # a ref held twice (only by hand) shows its lowest id
  jq -nc --slurpfile r <(printf '%s\n' "${rows[@]}") --slurpfile e <(printf '%s\n' "${errs[@]}") \
    '{rows: ($r | sort_by(.id | ltrimstr("rq") | tonumber) | unique_by(.ref) | sort_by(.id | ltrimstr("rq") | tonumber)), errors: $e}'
}
rq_holder() { local q; q=$(rq_rows 2>/dev/null) || return 1; jq -r --arg r "$1" 'first(.rows[] | select(.ref == $r) | .id) // empty' <<<"$q"; }
rq_ref() { local q; q=$(rq_rows 2>/dev/null) || return 1; jq -r --arg i "$1" 'first(.rows[] | select(.id == $i) | .ref) // empty' <<<"$q"; }
rq_locked() { # rq_locked <fn> <arg>...: the seat is rechecked under the takeover lock that lock and unlock take to remove a seat, so it holds until the write commits
  ( flock -w 30 5 || { echo "refused: requests.lock is busy for 30 s" >&2; exit 1; }
    ( flock -w 5 4 || { echo "refused: the seat's takeover lock is busy" >&2; exit 1; }
      seat_held || exit 1; "$@" ) 4>>"$H/orchestrator.lock.takeover" ) 5>>"$RQ/requests.lock"
}
rq_op() { ts_run requests "$1" "$WREF" "$RQ" "${@:2}" "$(utc_now)"; }
rq_drop_bare() { # the bare row of a ref a request holds, dropped with no event: the item never stopped waiting
  ( flock -w 30 8 && w=$(waiting_read) || exit 1
    jq -e --arg r "$1" 'any(.waiting[]; .ref == $r)' <<<"$w" >/dev/null || exit 0
    w=$(jq -c --arg r "$1" '.waiting |= map(select(.ref != $r))' <<<"$w") && waiting_write "$w" ) 8>>"$H/waiting.lock" 2>/dev/null \
    || { echo "warning: the bare waiting row of $1 stays beside its request" >&2; return 1; }
}
rq_add() { # under rq_locked: a bare record of the ref gives its since, and its row goes once the request holds the ref
  local w since o
  w=$(waiting_read) || return 1
  since=$(jq -r --arg r "$1" 'first(.waiting[] | select(.ref == $r) | .since) // empty' <<<"$w")
  o=$(rq_op add "$1" "$2" "$3" "$since") || return 1
  # always, so a waiting add that checked before the file existed leaves no row; one left by a failure here shows as the
  # request until the close drops it
  rq_drop_bare "$1"
  [ -n "$since" ] || [ "${o##* }" != created ] || ev waiting.add ref="$1"
  echo "$o"
}
rq_close() { # under rq_locked: rq_close <done|withdrawn> <rid> <outcome>. A leftover bare row goes before the status
  # commits: once the request is closed nothing would drop it, and it would show again.
  local o id st r; r=$(rq_ref "$2") || return 1
  [ -z "$r" ] || rq_drop_bare "$r" || { echo "refused: $2 stays open until its bare waiting row can go" >&2; return 1; }
  o=$(rq_op close "$2" "$1" "$3") || return 1; read -r id st r <<<"$o"
  ev waiting.done ref="$r"; echo "$id $st"
}
public_text() { # public_text <what> <text>: the text as a file through check-public
  local tf rc; tf=$(mktemp "$H/scratch/request.XXXXXX") || return 1
  printf '%s\n' "$2" > "$tf"; public_ok "$tf" "$1"; rc=$?; rm -f "$tf"; return $rc
}
orchy_request() {
  sub=${1:-}; shift || true
  case "$sub" in
  list|show)
    rq_dirs_ro || exit 1
    if [ "$sub" = show ]; then [ $# = 1 ] || { echo "usage: request show <rid>" >&2; exit 1; }; rq_op show "$1"; exit; fi
    all=0; js=0; for o in "$@"; do case "$o" in --all) all=1;; --json) js=1;; *) echo "usage: request list [--json] [--all]" >&2; exit 1;; esac; done
    rq_op list "$all" "$js"; exit;;
  add|note|stale|done|withdraw) need flock
    l=$(lead_below) && { echo "refused: this process runs under lead pid $l; only the orchestrator writes requests" >&2; exit 1; }
    seat_held && rq_dirs_ok || exit 1;;
  *) echo "usage: request add <ref> <spec-file> [--again] | note <rid> [--re <aid>] <text> | stale <rid> <reason> | done <rid> <outcome> | withdraw <rid> <reason> | list [--json] [--all] | show <rid>" >&2; exit 1;;
  esac
  case "$sub" in
  add) r=${1:-}; sp=${2:-}; again=0; [ "${3:-}" = --again ] && again=1
    [ $# = $((2 + again)) ] || { echo "usage: request add <ref> <spec-file> [--again]" >&2; exit 1; }
    [[ "$r" =~ $WREF ]] || { echo "refused: a ref is pr:<n>, issue:<n>, page:<n>, ask:<askN>, lane:<slug> or other:<slug>" >&2; exit 1; }
    case "$r" in other:peer-*) echo "refused: $r is a peer's hold; only the peer's DONE or the owner's words lift it" >&2; exit 1;; esac
    if [[ $r == other:* ]] && { [ -e "$RUNBOOKS/${r#other:}.md" ] || [ -L "$RUNBOOKS/${r#other:}.md" ]; }; then
      echo "refused: runbook ${r#other:} keeps $r; it rewrites that record on every check" >&2; exit 1; fi
    abs_path sp; j=$(ts_run requests spec "$WREF" "$r" "$sp" "$H/page/shots") || exit 1
    public_text "the request" "$(jq -r .text <<<"$j")" || exit 1
    rq_locked rq_add "$r" "$(jq -c .content <<<"$j")" "$again";;
  note) id=${1:-}; re=; shift || true
    if [ "${1:-}" = --re ] && [ $# -ge 2 ]; then re=$2; shift 2; [[ "$re" =~ ^rq[1-9][0-9]{0,8}\.[1-9][0-9]?$ ]] || re=-; fi
    [[ "$id" =~ ^rq[1-9][0-9]{0,8}$ ]] && [ $# -gt 0 ] && [ "$re" != - ] || { echo "usage: request note <rid> [--re <aid>] <text>" >&2; exit 1; }
    public_text "the note" "$*" || exit 1; rq_locked rq_op note "$id" "$re" "$*";;
  stale|done|withdraw) id=${1:-}; shift || true
    [[ "$id" =~ ^rq[1-9][0-9]{0,8}$ ]] && [ $# -gt 0 ] || { echo "usage: request $sub <rid> <$([ "$sub" = "done" ] && echo outcome || echo reason)>" >&2; exit 1; }
    # the ref too: the close's event carries it, and a name banned since the add must not reach events.jsonl
    r=$(rq_ref "$id") || r=
    public_text "the $([ "$sub" = stale ] && echo reason || echo outcome)" "${r:+$r$'\n'}$*" || exit 1
    case "$sub" in stale) rq_locked rq_op stale "$id" "$*";; done) rq_locked rq_close "done" "$id" "$*";; *) rq_locked rq_close withdrawn "$id" "$*";; esac;;
  esac
}
