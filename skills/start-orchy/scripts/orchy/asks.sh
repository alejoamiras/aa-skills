# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# The ask subcommands that capture, restate, route, file and close an ask; go, ok, grant and revoke are the authority's,
# goal is the goals'.
orchy_ask() {
  sub=${1:-}; shift || true
  case "$sub" in list|show) ledger_ro || exit 1;; *) need flock; ledger_ok || exit 1;; esac
  case "$sub" in add|list|close-lane) ;; public|said|note|done|drop|reopen|show|lane|file|go|ok|grant|revoke|goal)
    [[ "${1:-}" =~ ^ask[0-9]+$ ]] || { echo "usage: ask $sub <askN> ..." >&2; exit 1; }; id=$1; shift;;
    *) echo "usage: ask add|public|said|note|lane|done|drop|reopen|list|show|file|go|ok|grant|revoke|goal ... (orchy.sh help)" >&2; exit 1;; esac
  case "$sub" in
  add) ask_cmd_add "$@";;
  public) ask_cmd_public "$@";;
  said|note) ask_cmd_text "$@";;
  done|drop|reopen) ask_cmd_move "$@";;
  lane) ask_cmd_lane "$@";;
  list) ask_cmd_list "$@";;
  show) ask_cmd_show;;
  file) ask_cmd_file "$@";;
  go|ok|grant) ask_cmd_auth "$sub" "$id" "$@";;
  goal) ask_cmd_goal "$id" "$@";;
  revoke) ask_cmd_revoke "$id" "$@";;
  close-lane) ask_cmd_close_lane "$@";;
  esac
}
ask_row() { jq -nc --arg id "$id" --arg at "$(utc_now)" "$@"; }
ask_cmd_add() {
  t="$*"; [ -n "$t" ] || { echo "usage: ask add <text>" >&2; exit 1; }
  ask_add() { local n; n=$(fold | jq -r '[keys[] | select(test("^ask[0-9]+$")) | ltrimstr("ask") | tonumber] | max // 0')
    id="ask$((n + 1))"; ledger_append "$(ask_row --arg t "$t" '{id: $id, at: $at, state: "open", text: $t}')" && echo "$id"; }
  with_ledger ask_add
}
ask_cmd_public() {
  t="$*"; [ -n "$t" ] || { echo "usage: ask public <askN> <text>" >&2; exit 1; }
  tf=$(mktemp "$H/scratch/public.XXXXXX"); printf '%s\n' "$t" > "$tf"; "$0" check-public "$tf"; rc=$?; rm -f "$tf"; [ "$rc" = 0 ] || exit 1
  ask_public() { local a st; a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; return 1; }
    st=$(jq -r .state <<<"$a"); case "$st" in open|lane) ;; *) echo "refused: $id is $st" >&2; return 1;; esac
    read -ra ds <<<"$(jq -r "$GOAL_DATES" <<<"$a")"
    [ ${#ds[@]} = 0 ] || ! date_in "$t" "${ds[@]}" || { echo "refused: $id is a goal, and its public text never carries the goal's date" >&2; return 1; }
    # the owner's OK covered the wording they saw, never its replacement; one row, so no reader sees it unheld
    if jq -e 'any(.notes[]; startswith("waiting: wording"))' <<<"$a" >/dev/null; then
      ledger_append "$(ask_row --arg t "$t" '{id: $id, at: $at, public: $t, note: "waiting: wording (changed)"}')" || return 1; echo "$id public wording stored; it needs the owner's OK again"
    else ledger_append "$(ask_row --arg t "$t" '{id: $id, at: $at, public: $t}')" || return 1; echo "$id public wording stored"; fi; }
  with_ledger ask_public
}
ask_cmd_text() {
  t="$*"; [ -n "$t" ] || { echo "usage: ask $sub <askN> <text>" >&2; exit 1; }
  [ "$sub" = said ] || note_ok "$t" || exit 1
  ask_text() { [ -n "$(ask_get "$id")" ] || { echo "refused: no $id" >&2; return 1; }
    ledger_append "$(ask_row --arg k "$sub" --arg t "$t" '{id: $id, at: $at} + {($k): $t}')" && echo "$id $sub recorded"; }
  with_ledger ask_text
}
ask_cmd_move() {
  t="$*"; [ -n "$t" ] || { echo "usage: ask $sub <askN> <note>" >&2; exit 1; }
  note_ok "$t" || exit 1
  to=$sub; [ "$sub" = drop ] && to=dropped; [ "$sub" = reopen ] && to=open
  ask_move() { local a st; a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; return 1; }
    st=$(jq -r .state <<<"$a"); ask_moves "$st" "$to" || { echo "refused: $id is $st; $sub does not apply" >&2; return 1; }
    ledger_append "$(ask_row --arg s "$to" --arg t "$t" '{id: $id, at: $at, state: $s, note: $t}')" && echo "$id $to"; }
  with_ledger ask_move
}
ask_cmd_lane() {
  s=${1:-}; shift || true; t="$*"
  [[ "$s" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] && [ -n "$t" ] || { echo "usage: ask lane <askN> <slug> <route>" >&2; exit 1; }
  note_ok "$t" || exit 1
  ask_lane() { local a st; a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; return 1; }
    st=$(jq -r .state <<<"$a"); ask_moves "$st" lane || { echo "refused: $id is $st; lane does not apply" >&2; return 1; }
    ask_ready "$a" "$id" || return 1
    # a goal leaves on the orchestrator's 'answered: ready' alone, never on the answer to a question that replaced its hold
    if jq -e 'any(.notes[]; startswith("goal: "))' <<<"$a" >/dev/null && [ "$(jq -r "$ASK_CTL" <<<"$a")" != "answered: ready" ]; then
      echo "refused: $id is a goal; it takes a lane only after 'answered: ready'" >&2; return 1; fi
    if lane_reported "$s" && [ ! -d "$WT_ROOT/$s" ]; then echo "refused: lane $s is closed (its reports remain); name a new lane" >&2; return 1; fi
    ledger_append "$(ask_row --arg s "$s" --arg t "$t" '{id: $id, at: $at, state: "lane", lane: $s, note: $t}')" && echo "$id lane $s"; }
  with_ledger ask_lane
}
ask_cmd_list() {
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
        + ((.text // "") | gsub("\\s+"; " ") | .[0:80]))] | join("  ")'
}
ask_cmd_show() {
  a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; exit 1; }
  jq . <<<"$a"; echo "-- history"; jq -Rc --arg id "$id" 'fromjson? | select(type == "object" and .id == $id)' "$LEDGER"
}
ask_cmd_file() {
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
    ledger_append "$(ask_row --argjson n "$n" '{id: $id, at: $at, state: "filed", issue: $n}')" && echo "$id filed as #$n"; }
  with_ledger ask_file
}
ask_cmd_close_lane() {
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
      D) t="delivered in $s"; p=""; [ "$x" = "?" ] || { t+=" PR #$x"; p=" (PR #$x)"; }   # a dispatch-only release delivers with no PR
         ledger_append "$(ask_row --arg t "$t" '{id: $id, at: $at, state: "done", note: $t}')" && echo "$id done$p";;
      *) case "$kd" in L|C) ;; *) x="not reported";; esac
         ledger_append "$(ask_row --arg t "lane $s closed without delivering it: $x" '{id: $id, at: $at, state: "open", note: $t}')" && echo "$id reopened: $x";;
      esac
    done; }
  with_ledger ask_close
}
