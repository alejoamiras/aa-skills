#!/usr/bin/env bash
# Smoke for skills/start-orchy: orchy.sh against a throwaway repo and home with mocked gh / agent-worktree / claude-usage, the templates, the page toolchain's own smoke.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); K="$HERE/skills/start-orchy"; ORCHY="$K/scripts/orchy.sh"
T=$(mktemp -d -t orchy-smoke-XXXX); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PATH="$HERE/tests/mocks/orchy:$PATH" MOCK_DIR="$T/mock" ORCHY_CAPACITY_ROOT="$T/cap" ORCHY_HOME="$T/cap/home" ORCHY_REPO=example/app ORCHY_WATCH_SLEEP=1; mkdir -p "$MOCK_DIR"
# a real local origin with a dev branch, so wt-new's fetch and reset work
git init -q --bare "$T/origin.git"; git init -q -b dev "$T/repo"; git -C "$T/repo" remote add origin "$T/origin.git"
(cd "$T/repo" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init && git push -q origin dev)
cd "$T/repo"
[ "$("$ORCHY" home)" = "$T/cap/home" ] || fail "home"
if "$ORCHY" config .trunk >/dev/null 2>&1; then fail "config before bootstrap must refuse"; fi
mkdir -p "$ORCHY_HOME"; jq '.install="true"' "$K/examples/orchy.example.json" > "$ORCHY_HOME/orchy.json"; cp "$K/examples/local.example.json" "$ORCHY_HOME/local.json"
[ "$("$ORCHY" config .trunk)" = dev ] || fail "config .trunk"
# render: every token substituted; a token left over is exit 1
out=$("$ORCHY" render common-brief.md REPO=example/app PRODUCT="the app" TRUNK=dev WORKTREE=/w/x BRANCH=worktree-x LANE=x KEY=x-plan PLANS_DIR=plans ARCHIVE_DIR=plans/archive ORCHY_HOME="$ORCHY_HOME" CODEX_EFFORT=high CODEX_MODEL=gpt-6.1-sol CODEX_MODEL_SHORT=sol LEAD_MODEL=opus LEAD_MODEL_NAME="Claude Opus 5.5" QUALITY_BAR=production GATES="lint, test" PROTECTED=main KNOWN_LIMIT_LABEL=known-limit DELEGATIONS="" NEVER_OPEN="")
grep -q 'example/app backlog program (the app)' <<<"$out" || fail "render substitution"
if "$ORCHY" render common-brief.md REPO=x >/dev/null 2>&1; then fail "render must fail on a leftover token"; fi
for t in planner-brief implementer-brief lane-brief plan-spawn arc-spawn closeout-spawn shots-spawn goal tick; do [ -f "$K/templates/$t.md" ] || fail "template $t missing"; done
# every rendered brief passes check-text (no roster name, no account-variable assignment)
printf '%s\n' "$out" > "$T/brief.md"; "$ORCHY" check-text "$T/brief.md" || fail "rendered common brief fails check-text"
printf 'run it on acct-a\n' > "$T/bad.md"; if "$ORCHY" check-text "$T/bad.md" >/dev/null 2>&1; then fail "check-text accepted a roster name"; fi
tmp=$(mktemp); jq '.prompt_ban="("' "$ORCHY_HOME/local.json" > "$tmp"; cp "$ORCHY_HOME/local.json" "$T/local.bak"; mv "$tmp" "$ORCHY_HOME/local.json"
if "$ORCHY" check-text "$T/brief.md" >/dev/null 2>&1; then fail "check-text accepted an invalid regex"; fi; cp "$T/local.bak" "$ORCHY_HOME/local.json"
# launch: never-list, allowlist, duplicate and cap refusals; a launched lead is alive with its start-time identity
mkdir -p "$ORCHY_HOME/prompts" ".claude/worktrees/x"; printf 'You are a subagent.\n' > "$ORCHY_HOME/prompts/x-plan.md"; cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/x-a1.md"; cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/x-a2.md"
o=$("$ORCHY" launch x-plan x acct-main 2>&1 || true); grep -q 'accounts.never' <<<"$o" || fail "launch did not refuse accounts.never: $o"
o=$("$ORCHY" launch x-plan x acct-z 2>&1 || true); grep -q 'accounts.use' <<<"$o" || fail "launch did not refuse an account off the allowlist: $o"
"$ORCHY" launch x-plan x acct-a >/dev/null || fail "launch"
o=$("$ORCHY" launch x-plan x acct-a 2>&1 || true); grep -q 'is alive' <<<"$o" || fail "launch did not refuse a duplicate key: $o"
"$ORCHY" launch x-a1 x acct-a >/dev/null || fail "second heavy launch"
o=$("$ORCHY" launch x-a2 x acct-a 2>&1 || true); grep -q 'cap 2' <<<"$o" || fail "launch did not enforce heavy_per_account: $o"
"$ORCHY" launch --light x-a2 x acct-a >/dev/null || fail "light launch under its own cap"
[ "$("$ORCHY" snapshot 2>/dev/null | grep -c '^alive x-')" = 3 ] || fail "snapshot does not list the three live leads"
[ "$("$ORCHY" session-id x-plan)" = 00000000-0000-4000-8000-000000000001 ] || fail "session-id"
# launch: its own process group, auto mode by default, the hook settings and the two writable dirs, banner kept out of the JSON log
read -r lp _ _ _ _ _ lg < "$ORCHY_HOME/leads/x-plan.started"; [ "$lp" = "$lg" ] || fail "lead pid $lp is not its own group leader ($lg)"
[ "$(stat -c %a "$ORCHY_HOME")" = 700 ] || fail "home is not mode 700"
grep -q -- '--permission-mode auto --permission-prompts none' "$MOCK_DIR/cu.log" || fail "auto mode flags missing: $(head -1 "$MOCK_DIR/cu.log")"
grep -q -- "--settings $ORCHY_HOME/leads/x-plan.settings.json --add-dir $ORCHY_HOME/reports --add-dir $ORCHY_HOME/scratch/x" "$MOCK_DIR/cu.log" || fail "settings or add-dir flags missing"
jq -e '.hooks.PostToolUse[0].hooks[0].command | test("inbox-hook.sh .*/inbox/x-plan.jsonl$")' "$ORCHY_HOME/leads/x-plan.settings.json" >/dev/null || fail "hook settings"
grep -q '"type":"orchy_invocation","key":"x-plan","lane":"x"' "$ORCHY_HOME/leads/x-plan.log" || fail "no invocation marker"
if grep -q '^claude-usage:' "$ORCHY_HOME/leads/x-plan.log" || ! grep -q '^claude-usage:' "$ORCHY_HOME/leads/x-plan.err"; then fail "the banner is not in .err alone"; fi
for f in "$ORCHY_HOME"/leads/*.started; do read -r p _ < "$f"; for fd in /proc/"$p"/fd/*; do case "$(readlink "$fd")" in *spawn.lock) fail "lead $p holds the spawn lock";; esac; done; done
tmp=$(mktemp); jq '.accounts.use += ["acct-d","acct-e","acct-f"]' "$ORCHY_HOME/local.json" > "$tmp" && mv "$tmp" "$ORCHY_HOME/local.json"
jq '.leads.permission_mode="bypass"' "$ORCHY_HOME/orchy.json" > "$tmp" && cp "$ORCHY_HOME/orchy.json" "$T/orchy.bak" && mv "$tmp" "$ORCHY_HOME/orchy.json"
cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/x-b1.md"; "$ORCHY" launch x-b1 x acct-b >/dev/null || fail "bypass launch"
tail -1 "$MOCK_DIR/cu.log" | grep -q -- '--dangerously-skip-permissions' || fail "bypass mode flag missing"; cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"
# the cap holds across every program under the capacity root, at the strictest cap among them
H2="$T/cap/home2"; mkdir -p "$H2/prompts"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$H2/"; cp "$ORCHY_HOME/prompts/x-plan.md" "$H2/prompts/y-a1.md"
o=$(ORCHY_HOME="$H2" "$ORCHY" launch y-a1 x acct-a 2>&1 || true); grep -q 'across programs (cap 2)' <<<"$o" || fail "a second program exceeded the account cap: $o"
jq '.accounts.heavy_per_account=1' "$H2/local.json" > "$tmp" && mv "$tmp" "$H2/local.json"
ORCHY_HOME="$H2" "$ORCHY" launch y-a1 x acct-d >/dev/null || fail "second program launch"
for k in x-d1 x-c1 x-c2 x-c3; do cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/$k.md"; done
o=$("$ORCHY" launch x-d1 x acct-d 2>&1 || true); grep -q 'cap 1' <<<"$o" || fail "the strictest cap among running programs was not applied: $o"
# concurrent launches never pass the cap together
for k in x-c1 x-c2 x-c3; do ( "$ORCHY" launch "$k" x acct-c > "$T/$k.out" 2>&1 ) & done; wait
[ "$(cat "$T"/x-c?.out | grep -c ' on acct-c pid ')" = 2 ] || fail "concurrent launches broke the cap: $(cat "$T"/x-c?.out)"
# a home outside the capacity root, or a writable root, is refused
mkdir -p "$T/elsewhere/h/prompts"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$T/elsewhere/h/"; cp "$ORCHY_HOME/prompts/x-plan.md" "$T/elsewhere/h/prompts/z.md"
o=$(ORCHY_HOME="$T/elsewhere/h" "$ORCHY" launch z x acct-e 2>&1 || true); grep -q 'not directly under the capacity root' <<<"$o" || fail "a home outside the root launched: $o"
chmod 775 "$T"; o=$("$ORCHY" launch z x acct-e 2>&1 || true); chmod 700 "$T"; grep -q 'group- or world-writable' <<<"$o" || fail "a writable root parent was accepted: $o"
# stop ends the lead and the session-leader grandchild a group kill would miss
read -r sp _ < "$ORCHY_HOME/leads/x-b1.started"; gc=$(cat "$MOCK_DIR/gc.$sp"); [ -d "/proc/$gc" ] || fail "mock grandchild $gc not running"
"$ORCHY" stop x-b1 | grep -q 'stopped' || fail "stop"; sleep 0.5; [ ! -d "/proc/$sp" ] && [ ! -d "/proc/$gc" ] || fail "stop left $sp or grandchild $gc alive"
MOCK_SESSION=00000000-0000-4000-8000-000000000002 "$ORCHY" launch x-b1 x acct-b >/dev/null || fail "relaunch after stop"
[ "$("$ORCHY" session-id x-b1)" = 00000000-0000-4000-8000-000000000002 ] || fail "session-id is not the latest run's"
[ "$(grep -c orchy_invocation "$ORCHY_HOME/leads/x-b1.log")" = 2 ] || fail "the relaunch did not append to the log"
# say + inbox-hook: one delivery per note, to the lead's thread only, whole lines, cursor moved only after the write
IB="$ORCHY_HOME/inbox/x-b1.jsonl"; hook() { bash "$K/scripts/inbox-hook.sh" "$IB"; }; ctx() { jq -r '.hookSpecificOutput.additionalContext'; }
"$ORCHY" say x-b1 "$(printf 'café\nsecond line')" | grep -q 'queued' || fail "say"
[ -z "$(hook <<<'{"agent_id":"a1"}')" ] || fail "a subagent's tool call consumed a note"
o=$("$ORCHY" snapshot 2>&1); grep -q "^x-b1: 1 undelivered" <<<"$o" || fail "snapshot does not count the undelivered note: $o"
hook <<<'{}' >&- 2>/dev/null; [ ! -f "${IB%.jsonl}.cursor" ] || fail "a failed write advanced the cursor"
[ "$(hook <<<'{}' | ctx)" = "$(printf 'ORCHY-STEER: café\nsecond line')" ] || fail "the note did not survive the round trip"
[ -z "$(hook <<<'{}')" ] || fail "a note was delivered twice"
printf '{"at":"x","text":"partial"}' >> "$IB"; [ -z "$(hook <<<'{}')" ] || fail "a line without its newline was delivered"
echo >> "$IB"; [ "$(hook <<<'{}' | ctx)" = "ORCHY-STEER: partial" ] || fail "the completed line was not delivered"
pad=$(head -c 1000 /dev/zero | tr '\0' x); for i in 1 2 3 4 5 6 7 8; do "$ORCHY" say x-b1 "n$i $pad" >/dev/null || fail "say n$i"; done
for i in 1 2 3 4 5 6 7 8; do ( hook <<<'{}' > "$T/hook.$i" ) & done; wait
cat "$T"/hook.? | jq -r '.hookSpecificOutput.additionalContext' | grep -o '^ORCHY-STEER: n[0-9]' | sort | uniq -c > "$T/hook.count"
[ "$(wc -l < "$T/hook.count")" = 8 ] && ! grep -qv '^ *1 ' "$T/hook.count" || fail "parallel hooks did not deliver each note once: $(cat "$T/hook.count")"
[ "$(cat "$T"/hook.? | grep -c 'additionalContext')" -lt 8 ] || fail "notes that fit in 4 KiB were not delivered together"
o=$("$ORCHY" say x-zz hi 2>&1 || true); grep -q 'no live lead' <<<"$o" || fail "say queued for a dead key: $o"
o=$("$ORCHY" say x-b1 "use acct-a" 2>&1 || true); grep -q 'banned text' <<<"$o" || fail "say queued banned text: $o"
o=$("$ORCHY" say x-b1 "$(head -c 3100 /dev/zero | tr '\0' x)" 2>&1 || true); grep -q 'at most 3 KiB' <<<"$o" || fail "say queued an oversized note: $o"
# health: quiet time from the log, progress age, the newest process in the tree, STALLED? past leads.stall_after_min
touch -d '30 minutes ago' "$ORCHY_HOME/leads/x-b1.log"; touch "$ORCHY_HOME/reports/x-b1.progress"
o=$("$ORCHY" snapshot 2>/dev/null | grep '^alive x-b1 '); grep -qE 'STALLED\? quiet 30m progress 0m sleep' <<<"$o" || fail "lead health line: $o"
o=$("$ORCHY" snapshot 2>/dev/null | grep '^alive x-c1 \|^alive x-c2 \|^alive x-c3 ' | head -1); grep -q 'STALLED' <<<"$o" && fail "a fresh lead was flagged: $o"
# scan: a gh failure is loud, never a clean report
jq -n '{body:"body", commits:[{messageHeadline:"feat: x", messageBody:"ran with CLAUDE_ACCOUNT=acct-a"}]}' > "$MOCK_DIR/pr-7.json"
printf 'diff --git a/x b/x\n+++ b/x\n+ok\n' > "$MOCK_DIR/diff-7.txt"; printf 'x\n' > "$MOCK_DIR/files-7.txt"
o=$("$ORCHY" scan 7); grep -q 'leaks=1' <<<"$o" || fail "scan missed an account assignment in a commit message: $o"
if MOCK_GH_FAIL=diff "$ORCHY" scan 7 >/dev/null 2>&1; then fail "scan reported success on a gh failure"; fi
# watch-merge: pin validation, strict report parsing, pinned merge, head-moved exit
SHA=1111111111111111111111111111111111111111
mkpr() { jq -n --arg s "$1" --arg st "${2:-OPEN}" '{state:$st,isDraft:false,baseRefName:"dev",headRefOid:$s,mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",body:"",commits:[]}' > "$MOCK_DIR/pr-9.json"; }
mkpr "$SHA"; jq -n '{check_runs:[{id:1,name:"quality-status",status:"completed",conclusion:"failure"},{id:2,name:"quality-status",status:"completed",conclusion:"success"},{id:3,name:"e2e-status",status:"completed",conclusion:"success"}]}' > "$MOCK_DIR/checks.json"; jq -n '{statuses:[]}' > "$MOCK_DIR/status.json"
if "$ORCHY" watch-merge 9 1111111 lane-9 r9.md >/dev/null 2>&1; then fail "watch-merge accepted a short pin"; fi
tmp=$(mktemp); jq '.merge.watch_rounds=2' "$ORCHY_HOME/orchy.json" > "$tmp" && mv "$tmp" "$ORCHY_HOME/orchy.json"
printf 'notes\nARC_FAILED: gate red\n' > "$ORCHY_HOME/reports/r9.md"
o=$("$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); grep -q 'TIMEOUT; not merged' <<<"$o" || fail "ARC_FAILED report merged: $o"
printf 'Never print LEAD_DONE early.\nLEAD_DONE\nPR #9 title ready checks: green\nHEAD 2222222222222222222222222222222222222222\n' > "$ORCHY_HOME/reports/r9.md"
o=$("$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); grep -q 'TIMEOUT; not merged' <<<"$o" || fail "a HEAD line that differs from the pin merged: $o"
printf 'LEAD_DONE\nPR #9 title ready checks: green\nHEAD %s\nCODEX: converged in 2 rounds\n' "$SHA" > "$ORCHY_HOME/reports/r9.md"
o=$("$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); grep -q '#9 MERGED deadbeef' <<<"$o" || fail "watch-merge did not merge a converged PR: $o"
grep -q -- "--match-head-commit $SHA" "$MOCK_DIR/gh.log" || fail "merge was not pinned with --match-head-commit"
mkpr "$SHA"; jq --arg s 3333333333333333333333333333333333333333 '.headRefOid=$s' "$MOCK_DIR/pr-9.json" > "$tmp" && mv "$tmp" "$MOCK_DIR/pr-9.json"
o=$("$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); grep -q 'HEAD MOVED' <<<"$o" || fail "a moved head did not exit: $o"
# arm-merge: the detached watcher finds the repo and the home (no cd into the cache), and a second arm refuses
mkpr "$SHA"; "$ORCHY" arm-merge 9 "$SHA" lane-9 r9.md "" 4 >/dev/null || fail "arm-merge"
o=$("$ORCHY" arm-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); grep -q 'already armed' <<<"$o" || fail "arm-merge armed twice: $o"
for i in $(seq 1 30); do grep -q 'MERGED deadbeef\|archived plan' "$ORCHY_HOME/watch/merge-9.out" 2>/dev/null && break; sleep 1; done
grep -q '#9 MERGED deadbeef' "$ORCHY_HOME/watch/merge-9.out" || fail "the armed watcher did not merge: $(cat "$ORCHY_HOME/watch/merge-9.out")"
# teardown: refuses a lane with a live lead, then (hand removal off) relays the refusal, then (on) removes only a HEAD that is a merged PR's head
o=$("$ORCHY" teardown x 2>&1 || true); grep -q 'lead of this lane is alive' <<<"$o" || fail "teardown ignored a live lead: $o"
"$ORCHY" wt-new y >/dev/null || fail "wt-new"
if "$ORCHY" wt-new y >/dev/null 2>&1; then fail "wt-new accepted an existing slug"; fi
HY=$(git -C .claude/worktrees/y rev-parse HEAD)
o=$(MOCK_AW_REFUSE=1 "$ORCHY" teardown y 2>&1 || true); grep -q 'hand removal is off' <<<"$o" || fail "teardown hand-removed with the switch off: $o"
jq '.teardown.hand_remove=true' "$ORCHY_HOME/orchy.json" > "$tmp" && mv "$tmp" "$ORCHY_HOME/orchy.json"
jq -n --arg h 4444444444444444444444444444444444444444 '[{number:5,headRefOid:$h,baseRefName:"dev"}]' > "$MOCK_DIR/merged.json"
o=$(MOCK_AW_REFUSE=1 "$ORCHY" teardown y 2>&1 || true); grep -q 'not the head of a PR merged' <<<"$o" || fail "teardown removed a worktree whose HEAD is not a merged PR head: $o"
[ -d .claude/worktrees/y ] || fail "worktree y was removed"
jq -n --arg h "$HY" '[{number:5,headRefOid:$h,baseRefName:"dev"}]' > "$MOCK_DIR/merged.json"
o=$(MOCK_AW_REFUSE=1 "$ORCHY" teardown y 2>&1); grep -q 'hand-removed' <<<"$o" || fail "teardown did not remove an exact merged head: $o"
[ ! -d .claude/worktrees/y ] || fail "worktree y still there"
# disarm stops a live watcher (its whole process group); lock refuses while another live holder has it and replaces a stale one
mkpr "$SHA"; "$ORCHY" arm-merge 9 "$SHA" lane-9 r9.md "" 30 >/dev/null || fail "arm-merge for disarm"
# another home's watcher on the same PR number is never this home's stray
H2="$T/cap/home2"; mkdir -p "$H2"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$H2/"
ORCHY_HOME="$H2" "$ORCHY" arm-merge 9 "$SHA" lane-9 r9.md "" 30 >/dev/null || fail "arm-merge in a second home"
wp2=$(cut -d' ' -f1 "$H2/watch/merge-9.pid")
wp=$(cut -d' ' -f1 "$ORCHY_HOME/watch/merge-9.pid"); "$ORCHY" disarm 9 | grep -q 'stopped merge-9' || fail "disarm did not stop the watcher"
sleep 1; [ ! -d "/proc/$wp" ] || fail "watcher $wp still alive after disarm"
[ -d "/proc/$wp2" ] || fail "disarm in one home killed another home's watcher on the same PR number"
[ "$(ps -eo pid,args | grep "[w]atch-merge 9 " | grep -vc "^ *$wp2 ")" = 0 ] || fail "a watch-merge 9 process of this home survived disarm: $(ps -eo pid,args | grep "[w]atch-merge 9 ")"
ORCHY_HOME="$H2" "$ORCHY" disarm 9 | grep -q 'stopped merge-9' || fail "disarm in the second home"
sleep 1; [ ! -d "/proc/$wp2" ] || fail "the second home's watcher survived its own disarm"
sleep 60 & hp=$!; echo "$hp $(awk '{print $22}' /proc/$hp/stat) 2026-01-01T00:00:00Z other" > "$ORCHY_HOME/orchestrator.lock"
if "$ORCHY" lock >/dev/null 2>&1; then fail "lock did not refuse a live holder"; fi
# a takeover file left by a killed contender never blocks the next one
touch "$ORCHY_HOME/orchestrator.lock.takeover"
kill $hp; wait $hp 2>/dev/null || true; "$ORCHY" lock | grep -q '^locked' || fail "lock did not replace a stale holder"; "$ORCHY" unlock >/dev/null
for f in "$T"/cap/*/leads/*.started; do read -r p _ < "$f"; kill "$p" 2>/dev/null || true; done; for f in "$MOCK_DIR"/gc.*; do kill "$(cat "$f")" 2>/dev/null || true; done
# receipt: a session counts its last (running-total) result once; a killed run adds deduped, unpriced usage; only closed issues count
HR="$T/cap/rcpt"; mkdir -p "$HR"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$HR/"; cp -r "$HERE/tests/mocks/orchy/receipt/." "$HR/"
jq -n '{closingIssuesReferences:[{number:3},{number:4}]}' > "$MOCK_DIR/pr-21.json"; jq -n '{state:"CLOSED"}' > "$MOCK_DIR/issue-3.json"; jq -n '{state:"OPEN"}' > "$MOCK_DIR/issue-4.json"
o=$(ORCHY_HOME="$HR" "$ORCHY" receipt) || fail "receipt: $o"
grep -qF 'r: $1.50 API-equivalent + 27 unpriced tokens from killed runs; 2 session(s); tokens in 150 out 20 cache-read 1500 cache-write 60;' <<<"$o" || fail "receipt cost or tokens: $o"
grep -qF 'PRs #21 #22 (merged #21); issues closed 1 (#3); failed arcs 1; Codex rounds 2' <<<"$o" || fail "receipt joins: $o"
grep -qF 'q: $0.25 API-equivalent; 1 session(s); tokens in 1 out 2 cache-read 3 cache-write 4; wall ?;' <<<"$o" || fail "receipt of a log without markers: $o"
grep -qF 'total: $1.75 API-equivalent + 27 unpriced tokens' <<<"$o" || fail "receipt total: $o"
[ "$(ORCHY_HOME="$HR" "$ORCHY" receipt q | wc -l)" = 1 ] || fail "receipt <lane> printed other lanes"
if ORCHY_HOME="$HR" "$ORCHY" receipt nope >/dev/null 2>&1; then fail "receipt of an unknown lane succeeded"; fi
# the page toolchain's own smoke
[ -x "$K/page/smoke.sh" ] || fail "page/smoke.sh missing"; bash "$K/page/smoke.sh" > "$T/page.log" 2>&1 || { tail -n 20 "$T/page.log"; fail "page smoke"; }
# no project names, home paths or roster names anywhere in the skill
if grep -rnE 'nulo|Nulo|program-2|program2|/mnt/user-data|/Users/|martu|proton|icloud|GzKw77' "$K" --include='*.md' --include='*.sh' --include='*.py' --include='*.js' --include='*.ts' --include='*.json' --include='*.cjs' | grep -v 'page/fixtures' ; then fail "project-specific text in the skill"; fi
echo "smoke-orchy: ok"
