# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Schedules: recurring harden runs in orchy.json, each due slot started as a heavy lead through wt-new and launch, or
# recorded as skipped (rules and records: schedules.ts). fd 3 holds runs.lock and fd 4 schedules.lock; both are
# closed for every child that may outlive the call, so no lead ever holds either.
RUNS="$H/runs"
sc_list() { jq -c '.schedules // []' "$CFG"; }
sc_facts() { # what the view needs from outside TS: the mode, an all hold, the standing harden-* worktrees, the live lead keys
  local h o=() x
  h=$(held all 2>/dev/null) || h="holds.json, which cannot be read"
  for x in "$WT_ROOT"/harden-*; do [ -d "$x" ] && o+=("${x##*/}"); done
  jq -nc --arg m "$(cfg '.mode // empty')" --arg h "$h" --arg o "${o[*]}" --arg a "$(lead_rows | cut -d' ' -f1)" \
    'def opt: if . == "" then null else . end; def words($s): $s | split("\\s+"; null) | map(select(. != ""));
     {mode: ($m | opt), hold: ($h | opt), open: words($o), alive: words($a)}'
}
sc_view() { ts_run schedules view "$RUNS" "$(sc_list)" "$(sc_facts)" "$(utc_now)" "$1"; }
sc_config() { # <op> <arg>...: the TS op on the stored list, renamed over orchy.json only while the file still equals the copy it read
  local c o t
  need flock; exec 4>>"$H/schedules.lock"; flock -w 30 4 || { echo "refused: schedules.lock is busy for 30 s" >&2; exit 1; }
  c=$(cat "$CFG") && o=$(ts_run schedules "$1" "$(jq -c '.schedules // []' <<<"$c")" "${@:2}" "$(utc_now)") || exit 1
  if [ "$(jq -r .changed <<<"$o")" = true ]; then
    { t=$(mktemp "$H/.orchy.XXXXXX") && jq --argjson s "$(jq -c .schedules <<<"$o")" '.schedules = $s' <<<"$c" > "$t"; } \
      || { rm -f "${t:-}"; echo "refused: cannot write orchy.json" >&2; exit 1; }
    # the orchestrator's hand edits take no lock: one landing between this compare and the rename is lost
    [ "$(cat "$CFG")" = "$c" ] || { rm -f "$t"; echo "refused: orchy.json changed meanwhile; run it again" >&2; exit 1; }
    mv -f "$t" "$CFG" || { rm -f "$t"; echo "refused: cannot write orchy.json" >&2; exit 1; }
  fi
  jq -r .message <<<"$o"
}
sc_heavy() { # why launch would refuse every heavy lead now, in its own words, or nothing
  local j; j=$("$0" accounts --json 2>&1 3>&-) || { j=$(tail -n 1 <<<"$j"); echo "${j#refused: }"; return; }
  jq -r '.policy.heavy_per_account as $c
    | if any(.accounts[]; .verdict == "heavy" and .heavy_leads < $c) then empty
      elif any(.accounts[]; .verdict == "heavy") then "every account that may take a heavy lead already runs \($c) (the cap)"
      else "no account may take a heavy lead now: " + ([.accounts[] | "\(.label) \(.verdict) (\(.why))"] | join("; ")) end' <<<"$j"
}
sc_reading() { # <roster key>: its cached headroom reading as JSON, or null
  local l r; l=$(roster_rows 2>/dev/null | awk -v k="$1" '$1 == k { print $2; exit }')
  r=$(claude-usage --json --cached 2>/dev/null | jq -c --arg a "${l:-$1}" 'first(.[] | objects | select(.account == $a)
    | {week_left_pct, week_resets_at, session_left_pct, session_resets_at, session_window, observed_at}) // null' 2>/dev/null)
  echo "${r:-null}"
}
sc_prompt() { # <entry> <lane> <key>: prompts/<key>.md from templates/harden-spawn.md, or nothing
  local f b sk no t
  f=$(jq -r .focus <<<"$1")
  case $f in security) b="critical high medium low";; bugs) b="blocker critical major minor";; *) b="architectural structural local cosmetic";; esac
  if [ "$(jq -r .skip_filed <<<"$1")" = true ]; then sk="Findings already filed: run Phase 6's match step, which writes nothing; a verified finding that an open issue or a draft or triage advisory already tracks goes under \`## Already tracked\` with that number, and stays out of the findings and the counts."
  else sk="Findings already filed: count every verified finding; where Phase 6's match step finds an open issue or advisory that tracks one, name its number beside it."; fi
  no=$(jq -r '.never_open // [] | map(strings) | if length == 0 then "" else "- Never open, read or search \(join(", ")): they hold secrets, and the audit leaves them out. Every reviewer prompt you write carries this same line." end' "$CFG")
  # the key is predictable, so the prompt lands by rename onto the name itself (-T): a planted link is replaced, never followed
  [ ! -L "$H/prompts" ] && t=$(mktemp "$H/prompts/.$3.XXXXXX") || { echo "refused: prompts/ must be a directory, not a symlink" >&2; return 1; }
  # the template by its absolute path: render tries a bare name in the working directory first
  if "$0" render "$SCRIPTS/../templates/harden-spawn.md" LANE="$2" KEY="$3" WORKTREE="$WT_ROOT/$2" BRANCH="$(cfg '.worktrees.branch_prefix // "worktree-"')$2" \
    TRUNK="$TRUNK" ORCHY_HOME="$H" FOCUS="$f" EFFORT="$(jq -r .effort <<<"$1")" CLAUDE_MODEL="$(cfg '.leads.model // "opus"')" \
    CODEX_MODEL="$(cfg '.leads.codex_model // "gpt-6.1-sol"')" SKIP_FILED="$sk" BUCKETS="${b// /=<n> }=<n>" DATE="$(date -u +%F)" NEVER_OPEN="$no" \
    > "$t" 3>&- 4>&- && mv -fT "$t" "$H/prompts/$3.md"; then return 0; fi
  rm -f "$t"; echo "refused: templates/harden-spawn.md did not render into prompts/$3.md" >&2; return 1
}
sc_skip() { # <why>: the slot spent as skipped, through this start's record once it has one; a skip is an answer, so exit 0
  ts_run schedules skip "$RUNS" "$id" "$slot" "$lane" "$(utc_now)" "$1" ${f:+"$f"} >/dev/null || exit 1
  echo "skipped $id: $1"; exit 0
}
sc_drop() { local o; o=$("$0" teardown "$lane" 2>&1 3>&-) || why="$why; its fresh worktree stays: $(tail -n 1 <<<"$o")"; }
sc_start() { # <id>: a DUE slot's harden run as a heavy lead in a worktree of its own, or its skip; one attempt per slot
  local id=$1 v e slot lane key why out acct f=
  [ "$(cfg '.mode // empty')" != triage ] || { echo "refused: orchy.json mode is triage; no scheduled run starts" >&2; exit 1; }
  need claude-usage; need agent-worktree; need flock
  exec 3>>"$H/runs.lock"; flock -w 30 3 || { echo "refused: runs.lock is busy for 30 s" >&2; exit 1; }
  # schedules.lock from the read until the slot is spent: a pause or resume that returned first is what this start reads
  exec 4>>"$H/schedules.lock"; flock -w 30 4 || { echo "refused: schedules.lock is busy for 30 s" >&2; exit 1; }
  v=$(sc_view 1) && e=$(jq -c --arg i "$id" 'first(.schedules[] | select(.id == $i)) // empty' <<<"$v") || exit 1
  [ -n "$e" ] || { echo "refused: no schedule $id" >&2; exit 1; }
  slot=$(jq -r '.due // empty' <<<"$e")
  [ -n "$slot" ] || { echo "refused: $id is not due; its next slot is $(jq -r '.next // "none: it is paused"' <<<"$e")" >&2; exit 1; }
  lane=$(jq -r .lane <<<"$e"); key="$lane-$(date -u +%Y%m%d%H%M)"
  why=$(jq -r '.why // empty' <<<"$e"); [ -n "$why" ] || why=$(sc_heavy 4>&-)
  [ -z "$why" ] || sc_skip "$why"
  sc_prompt "$e" "$lane" "$key" || exit 2
  # the slot is spent from here on, so a start killed midway can neither vanish nor run twice
  f=$(ts_run schedules begin "$RUNS" "$id" "$slot" "$(utc_now)" "$key" "$lane") || exit 1
  exec 4>&-
  # torn down only on proof this start made it: wt-new prints "install exit 1" only past its own creation
  if ! out=$("$0" wt-new "$lane" 2>&1 3>&-); then why=$(tail -n 1 <<<"$out"); [ "$why" != "$lane: install exit 1" ] || sc_drop; sc_skip "$why"; fi
  if ! out=$("$0" launch "$key" "$lane" auto 2>&1 3>&-); then why=$(tail -n 1 <<<"$out"); why=${why#refused: }; sc_drop; sc_skip "$why"; fi
  read -r _ _ acct _ < "$H/leads/$key.started" && ts_run schedules launched "$RUNS" "$id" "$f" "$acct" "$(sc_reading "$acct")" >/dev/null || exit 1
  echo "started $id: $key on $acct"
}
sc_settle() { # each dead lead's record, recomputed from its files while it reads started or once they moved past it
  local f live k st lane a rp off rx mk fl rj
  live=$(lead_rows | cut -d' ' -f1)
  for f in "$RUNS"/*/*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    # schedules.ts validates the record again: this only picks the ones worth its look
    read -r st k lane a < <(jq -r '"\(.status) \(.key) \(.lane) \(.account // "-")"' "$f" 2>/dev/null) || continue
    [ "$st" != skipped ] && name_ok "$k" && [[ $lane =~ ^harden-(security|quality|bugs)-[0-9]{8}$ ]] && ! grep -qxF -- "$k" <<<"$live" || continue
    [ "$a" != - ] || a=""
    rp="$H/reports/$k.md"; [ -f "$H/leads/$k.started" ] || continue
    [ "$st" = started ] || [ "$H/leads/$k.started" -nt "$f" ] || [ "$rp" -nt "$f" ] || continue
    # an unreadable receipt waits for the next snapshot, so a settled run never keeps a cost it could not read; a lane
    # with no lead logs exits 1 and still prints the model
    rj=$("$0" receipt --json --offline "$lane" 2>/dev/null); jq -e '.schema == "orchy.receipt/1"' <<<"$rj" >/dev/null 2>&1 || continue
    # only what the latest invocation appended ends the run: launch logs the report's size as each one starts
    off=$(grep '^{"type":"orchy_invocation"' "$H/leads/$k.log" 2>/dev/null | tail -n 1 | jq -r '.report_bytes // 0' 2>/dev/null)
    [[ $off =~ ^[0-9]{1,12}$ ]] || off=0
    mk=; fl=; if [ -f "$rp" ] && [ ! -L "$rp" ]; then rx=$(marker_rx "$k.md" 'LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*')
      mk=$(tail -c +$((off + 1)) "$rp" | grep -xE "$rx" | tail -1); fl=$(tail -c +$((off + 1)) "$rp" | grep '^FINDINGS: ' | tail -1); fi
    [ -n "$a" ] || read -r _ _ a _ < "$H/leads/$k.started"
    ts_run schedules settle "$RUNS" "$(basename "$(dirname "$f")")" "$(basename "$f")" "$mk" "$fl" "$rj" "$a" "$(sc_reading "$a")" "$(utc_now)" >/dev/null || true
  done
}
orchy_schedule() {
  local sub=${1:-} l x s=0 a=(); shift || true
  case "$sub" in
  list) case "${1:-}" in --json) sc_view 1;; "") sc_view 0;; *) echo "usage: schedule list [--json]" >&2; exit 1;; esac; exit;;
  add|remove|pause|resume|start) ;;
  *) echo "usage: schedule add <id> <security|quality|bugs> <effort> <mon..sun> <HH:MM> <zone> [--skip-filed] | remove|pause|resume|start <id> | list [--json]" >&2; exit 1;;
  esac
  l=$(lead_below) && { echo "refused: this process runs under lead pid $l; only the orchestrator and the viewer change schedules" >&2; exit 1; }
  case "$sub" in add|remove|start) seat_held || exit 1;; esac
  case "$sub" in
  add) for x in "$@"; do if [ "$x" = --skip-filed ]; then s=1; else a+=("$x"); fi; done
    [ ${#a[@]} = 6 ] || { echo "usage: schedule add <id> <security|quality|bugs> <effort> <mon..sun> <HH:MM> <zone> [--skip-filed]" >&2; exit 1; }
    sc_config add "${a[@]}" "$s";;
  start) [ $# = 1 ] || { echo "usage: schedule start <id>" >&2; exit 1; }; sc_start "$1";;
  *) [ $# = 1 ] || { echo "usage: schedule $sub <id>" >&2; exit 1; }; sc_config set "$1" "$sub";;
  esac
}
