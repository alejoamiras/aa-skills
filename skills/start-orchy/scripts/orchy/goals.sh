# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Goals: an ask whose answer is a body of work, its milestone, its runbook and its date, which never leaves the ledger.
date_in() { python3 -I "$SCRIPTS/orchy/dates.py" "$@"; }
GOAL_DATES='[.notes[] | select(startswith("goal: ")) | capture(" (by|on) (?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})").d] | unique | join(" ")'
GOAL_LINE='"goal \(.name) " + (.milestone | if . == null then "milestones unread" elif . == "missing" then "milestone missing"
  else "\(.closed)/\(.open + .closed)" end) + (.runbook | if . == null then "" elif type == "object" then " runbook \(.done)/\(.steps)" else " runbook unreadable" end)'
ask_cmd_goal() { # ask_cmd_goal <askN> <name> [by|on <YYYY-MM-DD>] [then release]
  local id=$1; shift
  nm=${1:-}; shift || true; dk=; dt=; th=
  [[ "$nm" =~ ^[a-z0-9][a-z0-9-]{0,26}$ ]] || { echo "usage: ask goal <askN> <name> [by|on <YYYY-MM-DD>] [then release]; a name is [a-z0-9-], at most 27, so runbook goal-<name> is a slug" >&2; exit 1; }
  while [ $# -gt 0 ]; do case "$1" in
    by|on) [ -z "$dk" ] && [ $# -ge 2 ] || { echo "refused: a goal has at most one date, by or on <YYYY-MM-DD>" >&2; exit 1; }; dk=$1; dt=$2; shift 2;;
    then) [ -z "$th" ] && [ "${2:-}" = release ] || { echo "refused: the only end action is 'then release'" >&2; exit 1; }; th=release; shift 2;;
    *) echo "refused: ask goal takes [by|on <YYYY-MM-DD>] [then release], not '$1'" >&2; exit 1;; esac; done
  [ -z "$dk" ] || { [[ "$dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && ts_run calendar "$dt" 2>/dev/null; } \
    || { echo "refused: $dt is not a calendar date (YYYY-MM-DD)" >&2; exit 1; }
  tf=$(mktemp "$H/scratch/goal.XXXXXX"); printf '%s\n' "$nm" > "$tf"; "$0" check-public "$tf" >/dev/null; rc=$?; rm -f "$tf"
  [ "$rc" = 0 ] || { echo "refused: the goal's name fails check-public" >&2; exit 1; }
  need gh; need timeout; gn="goal: $nm${dk:+ $dk $dt}${th:+ then $th}"
  ask_goal() { local a st w p ms nh ds; a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; return 1; }
    st=$(jq -r .state <<<"$a"); [ "$st" = open ] || { echo "refused: $id is $st; a goal is an open ask" >&2; return 1; }
    # a goal's hold would replace another, which answers nothing
    w=$(jq -r "$ASK_HOLD" <<<"$a"); case "$w" in "" | "waiting: goal "*) ;; *) echo "refused: $id is $w; settle that first" >&2; return 1;; esac
    # every date this ask's goals have named, so a goal set again cannot publish an earlier one
    read -ra ds <<<"$(jq -r "$GOAL_DATES" <<<"$a")"; [ -z "$dt" ] || ds+=("$dt"); p=$(jq -r '.public // empty' <<<"$a")
    if [ ${#ds[@]} -gt 0 ]; then
      ! date_in "$nm" "${ds[@]}" || { echo "refused: the goal's name carries its date, and the name is public" >&2; return 1; }
      [ -z "$p" ] || ! date_in "$p" "${ds[@]}" || { echo "refused: $id's public text carries the goal's date; restate it first" >&2; return 1; }
    fi
    ms=$(timeout 30 gh api "repos/$REPO/milestones?state=all&per_page=100") \
      && jq -e 'type == "array" and all(.[]; type == "object" and (.title | type) == "string")' <<<"$ms" >/dev/null \
      || { echo "refused: the milestones could not be read; nothing recorded" >&2; return 1; }
    [ "$(jq length <<<"$ms")" -lt 100 ] || { echo "refused: 100 milestones or more, past one page; nothing recorded" >&2; return 1; }
    nh=$(jq --arg t "$nm" 'map(select(.title == $t)) | length' <<<"$ms") || { echo "refused: the milestones could not be read; nothing recorded" >&2; return 1; }
    case $nh in
      # the title only: a due date would publish the goal's date
      0) jq -n --arg t "$nm" '{title: $t}' | timeout 30 gh api "repos/$REPO/milestones" -X POST --input - >/dev/null \
           || { echo "refused: creating milestone $nm failed; nothing recorded, and a rerun finds it if GitHub made it" >&2; return 1; };;
      1) ;;
      *) echo "refused: $nh milestones are titled $nm; nothing recorded" >&2; return 1;; esac
    # the hold first: a reader never sees the goal unheld
    ledger_append "$(ask_row --arg t "waiting: goal $nm" '{id: $id, at: $at, note: $t}')" && ledger_append "$(ask_row --arg t "$gn" '{id: $id, at: $at, note: $t}')" \
      && echo "$id $gn recorded; milestone $nm"; }
  with_ledger ask_goal
}
orchy_goals() {
  ledger_ro || exit 1
  gs=$(ledger_rows | jq -c 'group_by(.id) | map(([.[] | select((.note // "") | startswith("goal: "))] | last) as $g | select($g != null)
    | ($g.note | capture("^goal: (?<name>[a-z0-9-]+)(?: (?<kind>by|on) (?<date>[0-9]{4}-[0-9]{2}-[0-9]{2}))?(?: then (?<then>release))?$"))
      + {ask: $g.id, state: ([.[] | select((.state | type) == "string")] | last | .state), hold: ({notes: [.[].note | strings]} | ['"$ASK_HOLD"'] | first // "")})') || exit 1
  ms='[]'; [ "$gs" = '[]' ] || { need gh; need timeout
    ms=$(timeout 30 gh api "repos/$REPO/milestones?state=all&per_page=100" 2>/dev/null) && jq -e 'type == "array" and length < 100 and all(.[]; type == "object" and (.title | type) == "string")' <<<"$ms" >/dev/null || ms=null; }
  rb=$(for n in $(jq -r '.[].name' <<<"$gs"); do f="$RUNBOOKS/goal-$n.md"; [ -L "$RUNBOOKS" ] || [ -e "$f" ] || [ -L "$f" ] || continue
      if [ ! -L "$RUNBOOKS" ] && [ -f "$f" ] && [ ! -L "$f" ] && j=$(rb_parse "$f" 2>/dev/null); then jq -c --arg n "$n" '{($n): {done: (map(select(.[0])) | length), steps: length}}' <<<"$j"
      else jq -nc --arg n "$n" '{($n): "unreadable"}'; fi; done | jq -sc 'add // {}')
  # a goal another question holds is never ready, or the tick's 'answered: ready' would answer that question for the owner
  g=$(jq -c --argjson ms "$ms" --argjson rb "$rb" --arg today "$(date -u +%F)" '{schema: "orchy.goals/1", goals: map(. as $x
    | ($ms | if . == null then null else map(select(.title == $x.name)) | if length == 0 then "missing" elif length > 1 then null
        else .[0] | if [.open_issues, .closed_issues] | all(type == "number" and . >= 0 and . == floor) then {open: .open_issues, closed: .closed_issues}
        else null end end end) as $m | ($rb[$x.name] // null) as $b
    | $x + {milestone: $m, runbook: $b,
       days: (if $x.date then ((($x.date + "T00:00:00Z" | fromdateiso8601) - ($today + "T00:00:00Z" | fromdateiso8601)) / 86400 | floor) else null end),
       ready: ($x.state == "open" and ($x.hold | IN("", "waiting: goal \($x.name)")) and ($m | type) == "object" and $m.open == 0
         and ($b == null or (($b | type) == "object" and $b.done == $b.steps)) and ($x.kind != "on" or $x.date <= $today))} | del(.hold))}' <<<"$gs") || exit 1
  if [ "${1:-}" = --json ]; then echo "$g"
  else jq -r 'if .goals == [] then "no goals" else .goals[] | '"$GOAL_LINE"' + (if .days != null then ", \(.days) days" else "" end) + (if .ready then ", ready" else "" end) end' <<<"$g"; fi
}
