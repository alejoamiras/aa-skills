# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Runbooks: the owner's own steps for a release or a goal, kept as one waiting record that names the next step.
RUNBOOKS="$H/runbooks"; RB_LOCK="$H/runbooks.lock"
rb_parse() { ts_run runbook "$(abs_path "$1")" "${@:2}"; }   # rb_parse <file> [--new]: the steps as JSON [[done, text, proof kind, proof arg], ...]; refuses a line outside the format
rb_line() { jq -r '.[] | "- [\(if .[0] then "x" else " " end)] \(.[1])\(if .[2] != "" then " (proof: \(.[2]) \(.[3]))" else "" end)"'; }
orchy_runbook() {
  sub=${1:-}; s=${2:-}; f="$RUNBOOKS/$s.md"
  case "$sub $#" in "add 3"|"tick 3"|"check 2"|"show 2") ;; *) echo "usage: runbook add <slug> <file> | tick <slug> <n> | check <slug> | show <slug>" >&2; exit 1;; esac
  [[ "$s" =~ ^[a-z0-9-]{1,32}$ ]] || { echo "refused: a runbook's slug is its waiting ref other:<slug>: [a-z0-9-], at most 32" >&2; exit 1; }
  rb_read() { # the stored steps; a missing, symlinked or malformed runbook refuses
    if [ -L "$RUNBOOKS" ] || [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then echo "refused: $f must be a regular file, not a symlink" >&2; return 1; fi
    [ -f "$f" ] || { echo "refused: no runbook $s" >&2; return 1; }
    rb_parse "$f"; }
  if [ "$sub" = show ]; then j=$(rb_read) || exit 1; rb_line <<<"$j" | nl -w1 -s'. ' | sed -E 's/^([0-9]+)\. - /\1. /'; exit 0; fi
  need flock
  if [ "$sub" = add ]; then new=$(rb_parse "$3" --new) || exit 1
    o=$("$0" check-public "$3" 2>&1); case $? in 0) ;; 1) echo "refused: the runbook fails check-public ($(grep -oE '^(LEAK|SENSITIVE|SECRET)|copies the owner' <<<"$o" | sort -u | paste -sd, -))" >&2; exit 1;;
      *) echo "refused: check-public could not run" >&2; exit 1;; esac; fi
  [ "$sub" != tick ] || [[ "$3" =~ ^[1-9][0-9]?$ ]] || { echo "refused: a step is numbered 1 to 20" >&2; exit 1; }
  [ "$sub" != check ] || { need gh; need timeout; }
  [ ! -L "$RUNBOOKS" ] && mkdir -p "$RUNBOOKS" || { echo "refused: $RUNBOOKS must be a directory, not a symlink" >&2; exit 1; }
  ( flock -w 30 6 || { echo "refused: the runbooks lock is busy for 30 s" >&2; exit 1; }
    case $sub in
    add) if [ -e "$f" ] || [ -L "$f" ]; then j=$(rb_read) || exit 1; else j='[]'; fi
      j=$(jq -c --argjson n "$new" '. + $n' <<<"$j"); n=$(jq length <<<"$j")
      [ "$n" -le 20 ] || { echo "refused: runbook $s would hold $n steps; at most 20" >&2; exit 1; };;
    tick) j=$(rb_read) || exit 1; i=$(( $3 - 1 ))
      case $(jq -r --argjson i "$i" 'if .[$i] == null then "none" else .[$i][0] end' <<<"$j") in none) echo "refused: runbook $s has no step $3" >&2; exit 1;;
        true) echo "refused: step $3 of runbook $s is already done" >&2; exit 1;; esac
      j=$(jq -c --argjson i "$i" '.[$i][0] = true' <<<"$j");;
    check) j=$(rb_read) || exit 1; moved=0; ef=$(mktemp "$H/scratch/runbook.XXXXXX") || exit 1
      while IFS=$'\t' read -r i k a; do
        if [ "$k" = run ]; then r=$(timeout 30 gh api "repos/$REPO/actions/runs/$a" --jq '"\(.status) \(.conclusion)"' 2>"$ef") || r=unreadable
          [ "$r" = "completed success" ] && ok=1 || ok=0
        else r=$(timeout 30 gh api "repos/$REPO/releases/tags/$(jq -rn --arg t "$a" '$t | @uri')" --jq 'if type != "object" or (.draft | type) != "boolean" then "unreadable" elif .draft then "a draft"
            elif .published_at == null then "not published" elif (.published_at | try fromdateiso8601 catch null) != null then "published" else "unreadable" end' 2>"$ef") \
            || { grep -q 'HTTP 404' "$ef" && r="not published" || r=unreadable; }
          [ "$r" = published ] && ok=1 || ok=0
        fi
        echo "step $((i + 1)): $k $a: $r"; [ $ok = 0 ] || { j=$(jq -c --argjson i "$i" '.[$i][0] = true' <<<"$j"); moved=1; }
      done < <(jq -r 'to_entries[] | select((.value[0] | not) and .value[2] != "") | "\(.key)\t\(.value[2])\t\(.value[3])"' <<<"$j")
      rm -f "$ef"; [ $moved = 1 ] || { echo "runbook $s: nothing proven since the last check"; exit 0; };;
    esac
    # the record before the file: a failed update leaves the runbook as it was, so a rerun retries both
    t=$(jq -r '(map(select(.[0])) | length) as $k | (map(select(.[0] | not)) | first) as $x
      | if $x == null then "" else "\($k) of \(length) done; next: \($x[1])" | if length > 160 then .[0:157] + "..." else . end end' <<<"$j")
    if [ -n "$t" ]; then "$0" waiting add "other:$s" "$t" >/dev/null || exit 1
    else o=$("$0" waiting "done" "other:$s" 2>&1) || grep -q 'nothing waits' <<<"$o" || { echo "$o" >&2; exit 1; }; fi
    tmp=$(mktemp "$RUNBOOKS/.$s.XXXXXX") && rb_line <<<"$j" > "$tmp" && mv -f "$tmp" "$f" || { rm -f "${tmp:-}"; echo "refused: cannot write $f" >&2; exit 1; }
    echo "runbook $s: ${t:-every step done}"
  ) 6>>"$RB_LOCK"
}
