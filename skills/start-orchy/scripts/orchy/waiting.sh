# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# What waits on the owner: one record per ref, replaced by rename under its own lock.
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
waiting_write() { local tmp; if ! tmp=$(mktemp "$H/.waiting.XXXXXX") || ! printf '%s\n' "$1" > "$tmp" || ! mv -f "$tmp" "$WAITING"; then rm -f "${tmp:-}"; echo "refused: cannot write $WAITING" >&2; return 1; fi; }
waiting_view() { # the bare records merged with the open requests, for views only: a writer that read it would persist
  # every request as a ghost row. A request owns its ref's row and keeps the earlier since; an unreadable one is named in errors.
  local w q; w=$(waiting_read) || return 1
  q=$(rq_rows 2>/dev/null) || q=$(jq -nc --arg f "${RQ##*/}" '{rows: [], errors: [{file: $f, error: "not a directory owned by this user"}]}')
  jq -c --argjson q "$q" '.waiting as $b | ($q.rows | map({(.ref): .}) | add // {}) as $by
    | {schema, waiting: ([$b[] | if $by[.ref] then {ref, text: $by[.ref].text, since: ([.since, $by[.ref].since] | min_by(fromdateiso8601))} else . end]
        + [$q.rows[] | select(.ref as $x | all($b[]; .ref != $x)) | {ref, text, since}])}
    + (if $q.errors == [] then {} else {errors: $q.errors} end)' <<<"$w"
}
waiting_text_ok() { ts_run text "$1"; }   # one line of 1-160 code points; TypeScript, since jq silently replaces invalid UTF-8
orchy_waiting() {
  sub=${1:-}; shift || true
  case "$sub" in
  list)
    w=$(waiting_view) || exit 1
    if [ "${1:-}" = --json ]; then printf '%s\n' "$w"; exit 0; fi
    jq -r --argjson now "$(date +%s)" '.waiting[] | ($now - (.since | fromdateiso8601? // $now)) as $s
      | "\(.ref)  \(if $s < 3600 then "\($s / 60 | floor)m" else "\($s / 3600 | floor)h" end)  \(.text)"' <<<"$w"
    jq -r '.errors[]? | "error: \(.file): \(.error)"' <<<"$w" >&2;;
  add|done)
    need flock; r=${1:-}; shift || true; t="$*"
    [[ "$r" =~ $WREF ]] || { echo "refused: a ref is pr:<n>, issue:<n>, page:<n>, ask:<askN>, lane:<slug> or other:<slug>" >&2; exit 1; }
    [ "$sub" = "done" ] || waiting_text_ok "$t" || exit 1
    # done checks the ref too: a name banned after its add must not reach events.jsonl
    tf=$(mktemp "$H/scratch/waiting.XXXXXX") || exit 1; { printf '%s\n' "$r"; [ "$sub" = "done" ] || printf '%s\n' "$t"; } > "$tf"
    public_ok "$tf" "the ref or text"; rc=$?; rm -f "$tf"; [ $rc = 0 ] || exit 1
    # the lock file is never replaced, so one writer at a time spans the read, the rename and the event
    ( flock -w 30 8 || { echo "refused: the waiting lock is busy for 30 s" >&2; exit 1; }
      w=$(waiting_read) || exit 1
      # under this lock, which a request add or close holds from reading the ref's bare row to its own write
      q=$(rq_holder "$r") || { echo "refused: the requests cannot be read, so $r may belong to one" >&2; exit 1; }
      [ -z "$q" ] || { echo "refused: request $q holds $r; ORCHY request note, done or withdraw changes it" >&2; exit 1; }
      if [ "$sub" = add ]; then
        w=$(jq -c --arg r "$r" --arg t "$t" --arg at "$(utc_now)" '.waiting |= if any(.[]; .ref == $r) then map(if .ref == $r then .text = $t else . end) else . + [{ref: $r, text: $t, since: $at}] end' <<<"$w") || exit 1
      else
        jq -e --arg r "$r" 'any(.waiting[]; .ref == $r)' <<<"$w" >/dev/null || { echo "refused: nothing waits on $r" >&2; exit 1; }
        w=$(jq -c --arg r "$r" '.waiting |= map(select(.ref != $r))' <<<"$w") || exit 1
      fi
      waiting_write "$w" || exit 1
      ev "waiting.$sub" ref="$r"; echo "waiting $sub $r" ) 8>>"$H/waiting.lock";;
  *) echo "usage: waiting add <ref> <text> | done <ref> | list [--json]" >&2; exit 1;;
  esac
}
