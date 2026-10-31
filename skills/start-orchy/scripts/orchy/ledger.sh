# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# The ask ledger: its owner-only file and lock, the one fold every reader shares, and the gates a handoff passes.
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
ASK_CTL='[.notes[] | select(test("^(waiting:|answered:)") or . == "wording ok")][-1] // ""'   # the latest control note
ASK_HOLD="$ASK_CTL"' | select(startswith("waiting:"))'
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
ledger_append() { # inside the ledger lock (fd 9); a torn last line is ended first so the new row parses
  [ "$(printf '%s' "$1" | wc -c)" -le 16384 ] || { echo "refused: a ledger row is at most 16 KiB; restate or split the ask" >&2; return 1; }
  [ -z "$(tail -c 1 "$LEDGER")" ] || printf '\n' >&9
  printf '%s\n' "$1" >&9 || return 1
  local e; mapfile -t e < <(jq -r '"ask=\(.id)", "state:=\(.state // null | tojson)", "lane:=\(.lane // null | tojson)"' <<<"$1" 2>/dev/null)
  if [ ${#e[@]} = 3 ]; then ev ask.row "${e[@]}"; fi
}
with_ledger() { ( flock -w 60 9 || { echo "refused: ask ledger lock busy for 60 s" >&2; exit 1; }; "$@" ) 9>>"$LEDGER"; }
ledger_rows() { if [ -f "$LEDGER" ]; then jq -Rsc '[split("\n")[] | fromjson? | select(type == "object" and (.id | type) == "string")]' "$LEDGER"; else echo '[]'; fi; }
note_ok() { case "$1" in go | ok:* | grant:* | revoke:* | used:* | goal:*) echo "refused: a note \"${1%%:*}\" is written only by ask go, ok, grant, revoke, goal and act" >&2; return 1;; esac; }
