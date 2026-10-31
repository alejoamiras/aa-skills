# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Holds: a peer's quiet or a release freeze pauses new work and merges; it never ends anything.
HOLDS="$H/holds.json"; HOLDS_LOCK="$H/holds.lock"
holds_read() { # orchy.holds/1 on stdout, a missing file as empty; a symlinked, non-regular or malformed one refuses
  if [ -L "$HOLDS" ] || { [ -e "$HOLDS" ] && [ ! -f "$HOLDS" ]; }; then echo "refused: $HOLDS must be a regular file, not a symlink" >&2; return 1; fi
  [ -e "$HOLDS" ] || { echo '{"schema":"orchy.holds/1","holds":[]}'; return 0; }
  # jq parses, so a file reads as it always has (nan, a BOM, its depth limit); holds.ts checks the shape
  local j; j=$(jq -sc . "$HOLDS" 2>/dev/null) && ts_run holds "$WREF" <<<"$j" 2>/dev/null || { echo "refused: $HOLDS is not orchy.holds/1" >&2; return 1; }
}
held() { # held all|trunk: the ref of the oldest hold that stops this scope (an all hold stops both), else nothing; exit 1 when unreadable
  local h; h=$(holds_read) || return 1
  jq -r --arg s "$1" '[.holds[] | select(.scope == "all" or .scope == $s)] | first | .ref // empty' <<<"$h"; }
hold_guard() { local r; r=$(held all) || exit 1; [ -z "$r" ] || { echo "refused: $r holds the program (ORCHY hold list)" >&2; exit 1; }; }
orchy_hold() {
  sub=${1:-}; shift || true
  case "$sub" in
  list)
    h=$(holds_read) || exit 1
    if [ "${1:-}" = --json ]; then printf '%s\n' "$h"; else jq -r 'if .holds == [] then "no holds" else .holds[] | "\(.ref)  \(.scope)  since \(.since)" end' <<<"$h"; fi;;
  add|done)
    need flock; r=${1:-}; sc=${2:-}
    [[ "$r" =~ $WREF ]] || { echo "refused: a ref is pr:<n>, issue:<n>, page:<n>, ask:<askN>, lane:<slug> or other:<slug>" >&2; exit 1; }
    case "$sub $#" in "add 2") [[ "$sc" =~ ^(all|trunk)$ ]] || { echo "refused: a hold's scope is all or trunk" >&2; exit 1; };; "done 1") ;;
      *) echo "usage: hold add <ref> <all|trunk> | done <ref>" >&2; exit 1;; esac
    # exclusive against the shared span of every merge and act call: add returns only after the calls already past their check
    ( flock -w 300 7 || { echo "refused: holds.lock is busy for 300 s" >&2; exit 1; }
      h=$(holds_read) || exit 1
      if [ "$sub" = add ]; then
        h=$(jq -c --arg r "$r" --arg s "$sc" --arg at "$(utc_now)" '.holds |= if any(.[]; .ref == $r) then map(if .ref == $r then .scope = $s else . end) else . + [{ref: $r, scope: $s, since: $at}] end' <<<"$h") || exit 1
      else
        jq -e --arg r "$r" 'any(.holds[]; .ref == $r)' <<<"$h" >/dev/null || { echo "refused: no hold on $r" >&2; exit 1; }
        h=$(jq -c --arg r "$r" '.holds |= map(select(.ref != $r))' <<<"$h") || exit 1
      fi
      if ! tmp=$(mktemp "$H/.holds.XXXXXX") || ! printf '%s\n' "$h" > "$tmp" || ! mv -f "$tmp" "$HOLDS"; then rm -f "${tmp:-}"; echo "refused: cannot write $HOLDS" >&2; exit 1; fi
      echo "hold $sub $r${sc:+ $sc}" ) 7>>"$HOLDS_LOCK";;
  *) echo "usage: hold add <ref> <all|trunk> | done <ref> | list [--json]" >&2; exit 1;;
  esac
}
