# shellcheck shell=bash
# The summary: the one or two plain lines a viewer shows for this program (summary.ts holds the format and the line rules).
orchy_summary() {
  case "${1:-} $#" in
  "show 1") ts_run summary show "$H/summary.json" "$(utc_now)";;
  "set 2"|"set 3") shift; public_text "the summary" "$(printf '%s\n' "$@")" && ts_run summary set "$H/summary.json" "$(utc_now)" "$@";;
  *) echo "usage: summary set <line> [<line>] | show" >&2; exit 1;;
  esac
}
