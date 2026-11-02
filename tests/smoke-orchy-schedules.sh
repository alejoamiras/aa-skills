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
o=$("$ORCHY" wait 3); grep -q '^TIMEOUT after 3s' <<<"$o" || ss_fail "a reported slot woke the wait again: $o"
at=$(( ($(date +%s) / 60 + 2) * 60 ))
SCH add roll bugs low "$(LC_ALL=C date -u -d "@$at" +%a)" "$(date -u -d "@$at" +%H:%M)" UTC >/dev/null
real=$(command -v date); mkdir -p "$T/clock"
printf '#!/usr/bin/env bash\nexec %q -d "@$(( $(%q +%%s) + %d ))" "$@"\n' "$real" "$real" "$(( at - $(date +%s) - 3 ))" > "$T/clock/date"; chmod +x "$T/clock/date"
o=$(PATH="$T/clock:$PATH" "$ORCHY" wait 20)
grep -qxF "> roll $(date -u -d "@$at" +%FT%TZ)" <<<"$o" && ! grep -q '^TIMEOUT' <<<"$o" || ss_fail "the slot passing mid-wait did not wake it: $o"
[ "$(SCH remove roll)" = "schedule roll removed; its run records stay" ] || ss_fail "remove"

echo "smoke-orchy-schedules: ok"
