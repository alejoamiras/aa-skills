#!/usr/bin/env bash
# Smoke for start-orchy's schedules: schedule add|remove|pause|resume|list, the DUE line, the wait source and its rollover,
# and start, skip and settle, against a throwaway repo and home; gh, agent-worktree and claude-usage are mocks.
set -eEuo pipefail
trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2' ERR
HERE=$(cd "$(dirname "$0")/.." && pwd); K="$HERE/skills/start-orchy"; ORCHY="$K/scripts/orchy.sh"; G="$HERE/tests/mocks/orchy"
T=$(mktemp -d -t orchy-schedules-XXXX); ps=()
ss_cleanup() { # the sessions, then every lead's process group (.started's seventh field)
  local f g; kill "${ps[@]}" 2>/dev/null || true
  for f in "${H:-$T}"/leads/*.started; do [ -f "$f" ] || continue; read -r _ _ _ _ _ _ g _ < "$f"; [[ ${g:-} =~ ^[0-9]+$ ]] && kill -- "-$g" 2>/dev/null || true; done
  rm -rf "$T"; }
trap ss_cleanup EXIT
ss_fail() { echo "FAIL: $*" >&2; exit 1; }
ss_nope() { local o; o=$("$@" 2>&1) && ss_fail "accepted: $*"; grep -qF -- "$want" <<<"$o" || ss_fail "$*: $o"; }
export PATH="$G:$PATH" MOCK_DIR="$T/mock" ORCHY_CAPACITY_ROOT="$T/cap" ORCHY_HOME="$T/cap/home" ORCHY_REPO=example/app ORCHY_ASKS_DIR="$T/asks" \
  ORCHY_GITLEAKS=fake-gitleaks ORCHY_ACCOUNTS="$T/accounts.json" ORCHY_WAIT_TICK=1 MOCK_LEAD_SECS=2
H=$ORCHY_HOME; C="$H/orchy.json"; mkdir -p "$MOCK_DIR/cu" "$H"
# atlas takes heavy leads, beacon (under the week floor) light ones only, and the orchestrator runs on cedar; one heavy lead per account
ss_row() { jq -nc --arg a "$1" --argjson w "$2" --arg sw "${3:-}" --argjson now "$(date +%s)" '{account: $a, active: false, week_left_pct: $w,
  week_resets_at: ($now + 72 * 3600), session_left_pct: (if $sw == "none" then null else 80 end), session_resets_at: (if $sw == "none" then null else $now + 3600 end),
  session_window: (if $sw == "" then null else $sw end), observed_at: ($now - 60), note: ""}'; }
printf '%-8s %s\n' main "$T/slot" atlas "$T/acct/atlas" beacon "$T/acct/beacon" cedar "$T/acct/cedar" > "$MOCK_DIR/cu/list.txt"; echo cedar > "$MOCK_DIR/cu/current.txt"
{ ss_row atlas 90; ss_row beacon 10; ss_row cedar 90; } | jq -s . > "$MOCK_DIR/cu/rows.json"
echo '{"schema": "orchy.accounts/1", "never": [], "heavy_per_account": 1}' > "$ORCHY_ACCOUNTS"
# two sessions named claude (python via a symlink): the seat's, and one that never holds it
mkdir -p "$T/sess"; ln -s "$(command -v python3)" "$T/sess/claude"
for _ in 1 2; do "$T/sess/claude" -c 'import time; time.sleep(3600)' & ps+=($!); done; export CLAUDE_PID=${ps[0]}
# a real local origin, so wt-new's fetch and reset work
git init -q --bare "$T/origin.git"; git init -q -b dev "$T/repo"; git -C "$T/repo" remote add origin "$T/origin.git"
git -C "$T/repo" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init; git -C "$T/repo" push -q origin dev
cd "$T/repo"
jq '.install = "true"' "$K/examples/orchy.example.json" > "$C"; cp "$K/examples/local.example.json" "$H/local.json"
"$ORCHY" lock >/dev/null
SCH() { "$ORCHY" schedule "$@"; }
ss_sum() { md5sum < "$C"; }

# --- add: normalized and stamped, the other keys kept, no temp file left; each refusal changes nothing
o=$(SCH add sec security high Mon 9:00 utc); grep -qE '^schedule sec added: harden security high, mon 09:00 UTC; next 20[0-9-]{8}T09:00:00Z$' <<<"$o" || ss_fail "add: $o"
jq -e '.trunk == "dev" and .merge.method == "squash" and (.schedules | length == 1) and (.schedules[0] | .when == "mon 09:00 UTC"
  and .paused == false and .skip_filed == false and (.since | test("^20[0-9-]{8}T[0-9:]{8}Z$")))' "$C" >/dev/null || ss_fail "the stored entry: $(jq -c .schedules "$C")"
[ -z "$(find "$H" -maxdepth 1 -name '.orchy.*')" ] || ss_fail "a write left its temp file"
b=$(ss_sum)
want='+03:00 is not an IANA time zone'; ss_nope SCH add dup security high mon 09:00 +03:00
want='focus is security, quality, bugs'; ss_nope SCH add dup speed high mon 09:00 UTC
want='a schedule sec exists'; ss_nope SCH add sec quality low tue 10:00 UTC
want='does not hold the seat'; CLAUDE_PID=${ps[1]} ss_nope SCH add dup quality low tue 10:00 UTC
want='runs under lead pid'; ss_nope "$T/sess/claude" -c 'import os, subprocess, sys
st = open("/proc/self/stat").read().rsplit(")", 1)[1].split()[19]
open(sys.argv[1], "w").write(f"{os.getpid()} {st} atlas 2031-01-15T00:00:00Z heavy prompts/x.md {os.getpid()} x\n")
sys.exit(subprocess.call(sys.argv[2:]))' "$H/leads/sc-lead.started" "$ORCHY" schedule pause sec; rm -f "$H/leads/sc-lead.started"
[ "$(ss_sum)" = "$b" ] || ss_fail "a refused call changed orchy.json"

# --- pause and resume need no seat, so the viewer may call them; a second pause writes nothing
[ "$(CLAUDE_PID=${ps[1]} SCH pause sec)" = "schedule sec paused" ] || ss_fail "pause without the seat"
b=$(ss_sum); [ "$(SCH pause sec)" = "schedule sec is already paused" ] && [ "$(ss_sum)" = "$b" ] || ss_fail "a second pause wrote orchy.json"
SCH list | grep -qxF 'sec: harden security high, mon 09:00 UTC; paused' || ss_fail "list of a paused schedule: $(SCH list)"
o=$(CLAUDE_PID=${ps[1]} SCH resume sec); grep -qE '^schedule sec resumed; next 20[0-9-]{8}T09:00:00Z$' <<<"$o" || ss_fail "resume: $o"

# --- DUE: a schedule older than its last slot (since moved back, as a long-standing schedule's is) shows in the snapshot
jq '.schedules[0].since = "2026-01-05T00:00:00Z"' "$C" > "$T/c.json" && mv "$T/c.json" "$C"
due=$(SCH list --json | jq -r '.schedules[0].due'); [[ $due =~ ^20[0-9-]{8}T09:00:00Z$ ]] || ss_fail "list --json shows no due slot: $(SCH list --json)"
"$ORCHY" snapshot 2>&1 | sed -n '/^-- schedules$/,$p' | grep -qxF "DUE sec: harden security high, slot $due; ORCHY schedule start sec" \
  || ss_fail "the snapshot's DUE line: $("$ORCHY" snapshot 2>&1 | sed -n '/^-- schedules$/,$p')"

# --- wait: a due slot wakes it once; a slot that passes mid-wait, with orchy.json unchanged, wakes it too. A date on PATH
# shifts that wait's clock to 3 s before the slot, so the slot need not be minutes away
o=$("$ORCHY" wait 10); grep -qx 'CHANGED (schedules):' <<<"$o" && grep -qxF "> sec $due" <<<"$o" || ss_fail "wait did not report the due slot: $o"
o=$("$ORCHY" wait 2); grep -q '^TIMEOUT after 2s' <<<"$o" || ss_fail "a reported slot woke the wait again: $o"
at=$(( ($(date +%s) / 60 + 2) * 60 ))
SCH add roll bugs low "$(LC_ALL=C date -u -d "@$at" +%a)" "$(date -u -d "@$at" +%H:%M)" UTC >/dev/null
real=$(command -v date); mkdir -p "$T/clock"
printf '#!/usr/bin/env bash\nexec %q -d "@$(( $(%q +%%s) + %d ))" "$@"\n' "$real" "$real" "$(( at - $(date +%s) - 3 ))" > "$T/clock/date"; chmod +x "$T/clock/date"
o=$(PATH="$T/clock:$PATH" "$ORCHY" wait 20)
grep -qxF "> roll $(date -u -d "@$at" +%FT%TZ)" <<<"$o" && ! grep -q '^TIMEOUT' <<<"$o" || ss_fail "the slot passing mid-wait did not wake it: $o"
[ "$(SCH remove roll)" = "schedule roll removed; its run records stay" ] || ss_fail "remove"

# --- a pause that lands while a start waits on schedules.lock is what that start reads
flock "$H/schedules.lock" bash -c 'touch "$2"; sleep 2; jq ".schedules[0].paused = true" "$1" > "$1.p" && mv "$1.p" "$1"' _ "$C" "$T/held" & w=$!
timeout 5 bash -c 'until [ -e "$1" ]; do sleep 0.05; done' _ "$T/held" || ss_fail "the lock holder never took schedules.lock"
want='sec is not due; its next slot is none: it is paused'; ss_nope SCH start sec; wait "$w"
jq '.schedules[0].paused = false' "$C" > "$T/c.json" && mv "$T/c.json" "$C"

# --- start: the due slot runs as a heavy lead on atlas, its record written before anything ran; no lock reaches a child.
# The agent-worktree first on PATH logs the lane's started records as each worktree is asked for
mkdir -p "$T/aw"; cat > "$T/aw/agent-worktree" <<EOF; chmod +x "$T/aw/agent-worktree"
#!/usr/bin/env bash
[ "\$1" != new ] || jq -r --arg l "\$2" 'select(.status == "started" and .lane == \$l) | .key' "\$ORCHY_HOME"/runs/*/*.json >> "\$MOCK_DIR/begun.log"
exec "$G/agent-worktree" "\$@"
EOF
ss_rec() { jq -c . "$(find "$H/runs/$1" -name '*.json' | sort | tail -n 1)"; }   # a schedule's newest record
ss_dead() { local i; for ((i = 0; i < 100; i++)); do [ -d "/proc/$1" ] || return 0; sleep 0.1; done; ss_fail "lead pid $1 still runs"; }
ss_back() { jq --arg i "$1" '(.schedules[] | select(.id == $i)).since = "2026-01-05T00:00:00Z"' "$C" > "$T/c.json" && mv "$T/c.json" "$C"; }
o=$(PATH="$T/aw:$PATH" SCH start sec); [[ $o =~ ^started\ sec:\ (harden-security-[0-9]{12})\ on\ atlas$ ]] || ss_fail "start: $o"; k=${BASH_REMATCH[1]}
grep -qxF "$k" "$MOCK_DIR/begun.log" || ss_fail "no started record when its worktree was asked for: $(cat "$MOCK_DIR/begun.log" 2>&1)"
grep -qF "the harden skill's \`security\` focus at effort \`high\`" "$H/prompts/$k.md" && grep -qxF 'FINDINGS: critical=<n> high=<n> medium=<n> low=<n>' "$H/prompts/$k.md" \
  || ss_fail "the rendered prompt: $(cat "$H/prompts/$k.md")"
jq -e --arg k "$k" --arg d "$due" '.status == "started" and .key == $k and .account == "atlas" and .slot == $d and .window.start.week_left_pct == 90' <<<"$(ss_rec sec)" >/dev/null \
  || ss_fail "the started record: $(ss_rec sec)"
read -r pid _ < "$H/leads/$k.started"
for x in /proc/"$pid"/fd/*; do case $(readlink "$x") in *runs.lock|*schedules.lock) ss_fail "the lead holds $(readlink "$x")";; esac; done
want='sec is not due'; ss_nope SCH start sec

# --- settle: a dead lead with no report keeps started and gains its cost; its report (its block written twice) ends it;
# a resume that dies having added prose but no block of its own reads started again, with both runs' cost, until its block lands
ss_dead "$pid"; "$ORCHY" snapshot >/dev/null 2>&1
jq -e '.status == "started" and .cost_usd == 0.5 and .end == null' <<<"$(ss_rec sec)" >/dev/null || ss_fail "a dead lead's record with no report: $(ss_rec sec)"
SCH list | grep -qF "$k has no live lead and no final marker" || ss_fail "list of a dead unreported run: $(SCH list)"
{ ss_row atlas 85; ss_row beacon 10; ss_row cedar 90; } | jq -s . > "$MOCK_DIR/cu/rows.json"
{ echo 'Audit done.'; for _ in 1 2; do printf '%s\n' LEAD_DONE 'REPORT audit/security/r1/report.md' 'COMMIT none' 'FINDINGS: critical=0 high=2 medium=1 low=0'; done; } > "$H/reports/$k.md"
"$ORCHY" snapshot >/dev/null 2>&1
jq -e '.status == "done" and .marker == "LEAD_DONE" and .counts == {critical: 0, high: 2, medium: 1, low: 0} and .cost_usd == 0.5
  and (.end | test("Z$")) and .window.week_used_pct == 5 and .window.session_used_pct == 0' <<<"$(ss_rec sec)" >/dev/null || ss_fail "the settled record: $(ss_rec sec)"
MOCK_RESULT='{"type":"result","subtype":"success","total_cost_usd":1.25,"num_turns":3,"duration_ms":1000}' "$ORCHY" resume "$k" harden-security atlas "$("$ORCHY" session-id "$k")" >/dev/null
read -r pid _ < "$H/leads/$k.started"; ss_dead "$pid"; echo 'Resumed: rerunning the fix loop.' >> "$H/reports/$k.md"; "$ORCHY" snapshot >/dev/null 2>&1
jq -e '.status == "started" and .marker == null and .counts == null and .cost_usd == 1.25' <<<"$(ss_rec sec)" >/dev/null || ss_fail "a resume that died unreported: $(ss_rec sec)"
printf '%s\n' LEAD_DONE 'REPORT audit/security/r1/report.md' 'COMMIT none' 'FINDINGS: critical=0 high=1 medium=1 low=0' >> "$H/reports/$k.md"
"$ORCHY" snapshot >/dev/null 2>&1
jq -e '.status == "done" and .counts.high == 1 and .cost_usd == 1.25' <<<"$(ss_rec sec)" >/dev/null || ss_fail "the resumed run's settle: $(ss_rec sec)"

# --- two due at once with one heavy slot left: one starts, the other skips with launch's own reason and makes no worktree
SCH add q quality medium Tue 10:00 Europe/London >/dev/null; SCH add b bugs low Wed 11:00 America/New_York --skip-filed >/dev/null; ss_back q; ss_back b
# a link to a directory, planted at each name q's prompt may take, is replaced by the prompt and receives nothing
mkdir -p "$T/trap"; m=$(date +%s); for d in 0 60; do ln -s "$T/trap" "$H/prompts/harden-quality-$(date -u -d "@$((m + d))" +%Y%m%d%H%M).md"; done
o=$(MOCK_LEAD_SECS=60 SCH start q); [[ $o =~ ^started\ q:\ (harden-quality-[0-9]{12})\ on\ atlas$ ]] || ss_fail "start q: $o"; kq=${BASH_REMATCH[1]}
[ -z "$(find "$T/trap" -mindepth 1)" ] && [ -f "$H/prompts/$kq.md" ] && [ ! -L "$H/prompts/$kq.md" ] || ss_fail "the planted prompt link was followed"
[ "$(SCH start b)" = "skipped b: every account that may take a heavy lead already runs 1 (the cap)" ] || ss_fail "the second due run: $(ss_rec b)"
[ ! -d .claude/worktrees/harden-bugs ] && jq -e '.status == "skipped" and .key == null' <<<"$(ss_rec b)" >/dev/null || ss_fail "the skip made a worktree, or no record"
"$ORCHY" stop "$kq" >/dev/null

# --- an open worktree skips its focus; six records stay
SCH add q2 quality low Thu 12:00 UTC >/dev/null; ss_back q2; mkdir -p "$H/runs/q2"
for d in 01 02 03 04 05 06; do jq -nc --arg t "2026-10-${d}T12:00:00Z" '{schema: "orchy.schedule-run/1", schedule: "q2", slot: $t, start: $t, end: $t, status: "skipped",
  reason: "planted", lane: "harden-quality", key: null, account: null, cost_usd: null, marker: null, detail: null, counts: null, window: null}' > "$H/runs/q2/202610${d}T120000Z.json"; done
[ "$(SCH start q2)" = "skipped q2: the worktree harden-quality is still open" ] || ss_fail "a run whose worktree stands: $(ss_rec q2)"
[ "$(find "$H/runs/q2" -name '*.json' | wc -l)" = 6 ] && [ ! -e "$H/runs/q2/20261001T120000Z.json" ] || ss_fail "prune kept $(ls "$H/runs/q2")"

# --- a launch refusal after the pre-check passed: the fresh worktree goes through teardown with the trunk, the record is a skip
SCH add b2 bugs high Fri 13:00 UTC >/dev/null; ss_back b2; echo stranger > "$MOCK_DIR/cu/current.txt"
o=$(MOCK_AW_ANCESTRY=1 SCH start b2); echo cedar > "$MOCK_DIR/cu/current.txt"
[ "$o" = "skipped b2: this session runs on stranger, which is not on the claude-usage roster, so no lead can be kept off it" ] || ss_fail "a launch refusal: $o"
grep -qxF "done repo/harden-bugs --merged --trunk dev" "$MOCK_DIR/aw.log" || ss_fail "no teardown with the trunk: $(cat "$MOCK_DIR/aw.log")"
jq -e '.status == "skipped" and .key == null and (.reason | startswith("this session runs on stranger"))' <<<"$(ss_rec b2)" >/dev/null || ss_fail "the refused start's record: $(ss_rec b2)"
[ ! -e "$MOCK_DIR/locked.log" ] || ss_fail "an agent-worktree call held a lock: $(cat "$MOCK_DIR/locked.log")"
git worktree remove --force .claude/worktrees/harden-bugs && git branch -q -D worktree-harden-bugs   # the mock's done removes nothing

# --- a FIFO planted at each name the run's report may take refuses the launch at once, nothing read from it
SCH add f bugs low Sun 15:00 UTC >/dev/null; ss_back f; m=$(date +%s); for d in 0 60; do mkfifo "$H/reports/harden-bugs-$(date -u -d "@$((m + d))" +%Y%m%d%H%M).md"; done
o=$(timeout 20 "$ORCHY" schedule start f) && [[ $o =~ ^skipped\ f:\ reports/harden-bugs-[0-9]{12}\.md\ is\ not\ a\ regular\ file$ ]] || ss_fail "a FIFO report: $o"
rm -f "$H"/reports/harden-bugs-*.md; git worktree remove --force .claude/worktrees/harden-bugs && git branch -q -D worktree-harden-bugs

# --- the only heavy account has no 5-hour window: judged on its week; skip_filed reaches the prompt
{ ss_row atlas 85 none; ss_row beacon 10; ss_row cedar 90; } | jq -s . > "$MOCK_DIR/cu/rows.json"
SCH add b3 bugs max Sat 14:00 Asia/Tokyo --skip-filed >/dev/null; ss_back b3
o=$(SCH start b3); [[ $o =~ ^started\ b3:\ (harden-bugs-[0-9]{12})\ on\ atlas$ ]] || ss_fail "the account with no 5-hour window: $o"; kb=${BASH_REMATCH[1]}
grep -qF '## Already tracked' "$H/prompts/$kb.md" && grep -qxF 'FINDINGS: blocker=<n> critical=<n> major=<n> minor=<n>' "$H/prompts/$kb.md" || ss_fail "the skip_filed prompt"
jq -e '.window.start.session_window == "none"' <<<"$(ss_rec b3)" >/dev/null || ss_fail "the start reading: $(ss_rec b3)"

# --- a resume landing while a settle reads the run's files waits for it, so the resumed run never keeps what that settle read
read -r pid _ < "$H/leads/$kb.started"; ss_dead "$pid"; printf '%s\n' LEAD_DONE 'REPORT audit/bugs/r1/report.md' 'COMMIT none' 'FINDINGS: none' > "$H/reports/$kb.md"
mkdir -p "$T/slow"; printf '#!/usr/bin/env bash\n[ "${@: -1}" != %q ] || [ -e %q ] || { touch %q; sleep 2; }\nexec %q "$@"\n' "$H/reports/$kb.md" "$T/in" "$T/in" "$(command -v tail)" > "$T/slow/tail"
chmod +x "$T/slow/tail"; PATH="$T/slow:$PATH" "$ORCHY" snapshot >/dev/null 2>&1 & s=$!
timeout 60 bash -c 'until [ -e "$1" ]; do sleep 0.05; done' _ "$T/in" || ss_fail "the settle never read the report"
"$ORCHY" resume "$kb" harden-bugs atlas "$("$ORCHY" session-id "$kb")" >/dev/null; wait "$s"
read -r pid _ < "$H/leads/$kb.started"; ss_dead "$pid"; "$ORCHY" snapshot >/dev/null 2>&1
jq -e '.status == "started" and .marker == null' <<<"$(ss_rec b3)" >/dev/null || ss_fail "a resume during a settle kept that settle's result: $(ss_rec b3)"

# --- the reader's shape, pinned: times, epochs and key stamps vary per run
SCH list --json | jq -S '.schedules |= map(select(.id == "sec" or .id == "b"))
  | walk(if type == "string" and test("^20[0-9-]{8}T[0-9:]{8}Z$") then "T" elif type == "number" and . > 1e9 then 0 else . end)
  | .schedules[].runs[] |= (.key |= (if . == null then null else sub("[0-9]{12}$"; "N") end))' > "$T/sl.json"
diff <(jq -S . "$G/schedules.v1.json") "$T/sl.json" || ss_fail "schedule list --json drifted from tests/mocks/orchy/schedules.v1.json"

echo "smoke-orchy-schedules: ok"
