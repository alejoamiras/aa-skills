#!/usr/bin/env bash
# Smoke for skills/start-orchy: orchy.sh against a throwaway repo and home with mocked gh / agent-worktree / claude-usage, the templates, the page toolchain's own smoke.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); K="$HERE/skills/start-orchy"; ORCHY="$K/scripts/orchy.sh"
T=$(mktemp -d -t orchy-smoke-XXXX); pgp=; trap '[ -z "$pgp" ] || kill "$pgp" 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PATH="$HERE/tests/mocks/orchy:$PATH" MOCK_DIR="$T/mock" ORCHY_CAPACITY_ROOT="$T/cap" ORCHY_HOME="$T/cap/home" ORCHY_REPO=example/app ORCHY_WATCH_SLEEP=1 ORCHY_PROFILE_DIR="$T/profile" ORCHY_ASKS_DIR="$T/asks" ORCHY_GITLEAKS=fake-gitleaks; mkdir -p "$MOCK_DIR"
# the page toolchain's own smoke shares nothing with this one, so it runs alongside
[ -x "$K/page/smoke.sh" ] || fail "page/smoke.sh missing"; bash "$K/page/smoke.sh" > "$T/page.log" 2>&1 & pgp=$!
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
"$ORCHY" render --keep LANE,KEY,WORKTREE,BRANCH common-brief.md REPO=example/app PRODUCT=x TRUNK=dev PLANS_DIR=plans ARCHIVE_DIR=plans/archive ORCHY_HOME="$ORCHY_HOME" CODEX_EFFORT=high CODEX_MODEL=m CODEX_MODEL_SHORT=s LEAD_MODEL=opus LEAD_MODEL_NAME=x QUALITY_BAR=p GATES=g PROTECTED=main KNOWN_LIMIT_LABEL=k DELEGATIONS= NEVER_OPEN= | grep -q '<WORKTREE>' || fail "render --keep did not keep the lead-bound tokens"
if "$ORCHY" render common-brief.md REPO=x >/dev/null 2>&1; then fail "render must fail on a leftover token"; fi
for t in planner-brief implementer-brief lane-brief plan-spawn arc-spawn closeout-spawn shots-spawn goal tick; do [ -f "$K/templates/$t.md" ] || fail "template $t missing"; done
for t in goal tick; do "$ORCHY" render "$t.md" REPO=example/app ORCHY_HOME="$ORCHY_HOME" ORCHY_SH="$ORCHY" MERGE_METHOD=squash PROTECTED=main TRUNK=dev CAPS="2 heavy, 3 light" LOAD_MAX=6 BLOCKED_LABEL=blocked:external > "$T/$t.txt" || fail "render $t left a token"; "$ORCHY" check-text "$T/$t.txt" >/dev/null || fail "check-text $t"; done
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
read -r lp _ _ _ _ _ lg _ < "$ORCHY_HOME/leads/x-plan.started"; [ "$lp" = "$lg" ] || fail "lead pid $lp is not its own group leader ($lg)"
[ "$(stat -c %a "$ORCHY_HOME")" = 700 ] || fail "home is not mode 700"
grep -q -- '--permission-mode auto --permission-prompts none' "$MOCK_DIR/cu.log" || fail "auto mode flags missing: $(head -1 "$MOCK_DIR/cu.log")"
grep -q -- "--settings $ORCHY_HOME/leads/x-plan.settings.json --add-dir $ORCHY_HOME/reports --add-dir $ORCHY_HOME/scratch/x" "$MOCK_DIR/cu.log" || fail "settings or add-dir flags missing"
jq -e '.hooks.PostToolUse[0].hooks[0].command | test("inbox-hook.sh .*/inbox/x-plan.jsonl$")' "$ORCHY_HOME/leads/x-plan.settings.json" >/dev/null || fail "hook settings"
grep -q '"type":"orchy_invocation","key":"x-plan","lane":"x"' "$ORCHY_HOME/leads/x-plan.log" || fail "no invocation marker"
if grep -q '^claude-usage:' "$ORCHY_HOME/leads/x-plan.log" || ! grep -q '^claude-usage:' "$ORCHY_HOME/leads/x-plan.err"; then fail "the banner is not in .err alone"; fi
for f in "$ORCHY_HOME"/leads/*.started; do read -r p _ < "$f"; for fd in /proc/"$p"/fd/*; do case "$(readlink "$fd")" in *spawn.lock) fail "lead $p holds the spawn lock";; esac; done; done
tmp=$(mktemp); jq '.accounts.use += ["acct-d","acct-e","acct-f"]' "$ORCHY_HOME/local.json" > "$tmp" && mv "$tmp" "$ORCHY_HOME/local.json"
jq '.leads.permission_mode="bypass"' "$ORCHY_HOME/orchy.json" > "$tmp" && cp "$ORCHY_HOME/orchy.json" "$T/orchy.bak" && mv "$tmp" "$ORCHY_HOME/orchy.json"
cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/x-b1.md"; mkdir -p "$ORCHY_HOME/page/shots-plan"; echo '[]' > "$ORCHY_HOME/page/shots-plan/x-b1.json"
"$ORCHY" launch x-b1 x acct-b >/dev/null || fail "bypass launch"
tail -1 "$MOCK_DIR/cu.log" | grep -q -- '--dangerously-skip-permissions' || fail "bypass mode flag missing"; cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"
tail -1 "$MOCK_DIR/cu.log" | grep -q -- "--add-dir $ORCHY_HOME/page/shots " || fail "a shots lead cannot write the page's shots"
if head -1 "$MOCK_DIR/cu.log" | grep -q -- 'page/shots'; then fail "a lead with no shots plan got the shots dir"; fi
if "$ORCHY" launch .x-hidden x acct-b >/dev/null 2>&1; then fail "launch accepted a dot-led key"; fi
# the cap holds across every program under the capacity root, at the strictest cap among them
# the second home's name carries a space, which must not shift the fields its rows are counted by
H2="$T/cap/home 2"; mkdir -p "$H2/prompts"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$H2/"; cp "$ORCHY_HOME/prompts/x-plan.md" "$H2/prompts/y-a1.md"
o=$(ORCHY_HOME="$H2" "$ORCHY" launch y-a1 x acct-a 2>&1 || true); grep -q 'across programs (cap 2)' <<<"$o" || fail "a second program exceeded the account cap: $o"
jq '.accounts.heavy_per_account=1' "$H2/local.json" > "$tmp" && mv "$tmp" "$H2/local.json"
ORCHY_HOME="$H2" "$ORCHY" launch y-a1 x acct-d >/dev/null || fail "second program launch"
for k in x-d1 x-c1 x-c2 x-c3; do cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/$k.md"; done
o=$("$ORCHY" launch x-d1 x acct-d 2>&1 || true); grep -q 'cap 1' <<<"$o" || fail "the strictest cap among running programs was not applied: $o"
# concurrent launches never pass the cap together
ps=(); for k in x-c1 x-c2 x-c3; do ( "$ORCHY" launch "$k" x acct-c > "$T/$k.out" 2>&1 ) & ps+=($!); done; wait "${ps[@]}" || true
[ "$(cat "$T"/x-c?.out | grep -c ' on acct-c pid ')" = 2 ] || fail "concurrent launches broke the cap: $(cat "$T"/x-c?.out)"
# a home outside the capacity root, a dot-named or symlinked home, or a writable root, is refused
mkdir -p "$T/cap/.hid/prompts"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$T/cap/.hid/"; cp "$ORCHY_HOME/prompts/x-plan.md" "$T/cap/.hid/prompts/z.md"
o=$(ORCHY_HOME="$T/cap/.hid" "$ORCHY" launch z x acct-e 2>&1 || true); grep -q 'invisible to the capacity count' <<<"$o" || fail "a dot-named home launched: $o"
ln -s "$T/cap/.hid" "$T/cap/lnk"; for l in "$T/cap/lnk" "$T/cap/lnk/"; do
  o=$(ORCHY_HOME="$l" "$ORCHY" snapshot 2>&1 || true); grep -q 'not a symlink' <<<"$o" || fail "a symlinked home was used as $l: $o"; done
mkdir -p "$T/elsewhere/h/prompts"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$T/elsewhere/h/"; cp "$ORCHY_HOME/prompts/x-plan.md" "$T/elsewhere/h/prompts/z.md"
o=$(ORCHY_HOME="$T/elsewhere/h" "$ORCHY" launch z x acct-e 2>&1 || true); grep -q 'not directly under the capacity root' <<<"$o" || fail "a home outside the root launched: $o"
chmod 775 "$T"; o=$("$ORCHY" launch z x acct-e 2>&1 || true); chmod 700 "$T"; grep -q 'group- or world-writable' <<<"$o" || fail "a writable root parent was accepted: $o"
# stop ends the lead and the session-leader grandchild a group kill would miss
read -r sp _ < "$ORCHY_HOME/leads/x-b1.started"; gc=$(cat "$MOCK_DIR/gc.$sp"); [ -d "/proc/$gc" ] || fail "mock grandchild $gc not running"
"$ORCHY" stop x-b1 | grep -q 'stopped' || fail "stop"; sleep 0.5; [ ! -d "/proc/$sp" ] && [ ! -d "/proc/$gc" ] || fail "stop left $sp or grandchild $gc alive"
MOCK_LEAD_SECS=120 MOCK_SESSION=00000000-0000-4000-8000-000000000002 "$ORCHY" launch x-b1 x acct-b >/dev/null || fail "relaunch after stop"
[ "$("$ORCHY" session-id x-b1)" = 00000000-0000-4000-8000-000000000002 ] || fail "session-id is not the latest run's"
[ "$(grep -c orchy_invocation "$ORCHY_HOME/leads/x-b1.log")" = 2 ] || fail "the relaunch did not append to the log"
# say + inbox-hook: one delivery per note, to the lead's thread only, whole lines, cursor moved only after the write
IB="$ORCHY_HOME/inbox/x-b1.jsonl"; hook() { bash "$K/scripts/inbox-hook.sh" "$IB"; }; ctx() { jq -r '.hookSpecificOutput.additionalContext'; }
printf '{"a":1}\n{"at":"x","text":"eighth byte"}\n' > "$T/ib.jsonl"; printf '08\n' > "$T/ib.cursor"
[ "$(bash "$K/scripts/inbox-hook.sh" "$T/ib.jsonl" <<<'{}' 2>&1 | ctx)" = "ORCHY-STEER: eighth byte" ] || fail "a zero-padded cursor was not read as decimal"
"$ORCHY" say x-b1 "$(printf 'café\nsecond line')" | grep -q 'queued' || fail "say"
[ -z "$(hook <<<'{"agent_id":"a1"}')" ] || fail "a subagent's tool call consumed a note"
o=$("$ORCHY" snapshot 2>&1); grep -q "^x-b1: 1 undelivered" <<<"$o" || fail "snapshot does not count the undelivered note: $o"
hook <<<'{}' >&- 2>/dev/null; [ ! -f "${IB%.jsonl}.cursor" ] || fail "a failed write advanced the cursor"
[ "$(hook <<<'{}' | ctx)" = "$(printf 'ORCHY-STEER: café\nsecond line')" ] || fail "the note did not survive the round trip"
[ -z "$(hook <<<'{}')" ] || fail "a note was delivered twice"
printf '{"at":"x","text":"partial"}' >> "$IB"; [ -z "$(hook <<<'{}')" ] || fail "a line without its newline was delivered"
echo >> "$IB"; [ "$(hook <<<'{}' | ctx)" = "ORCHY-STEER: partial" ] || fail "the completed line was not delivered"
pad=$(head -c 1000 /dev/zero | tr '\0' x); for i in 1 2 3 4 5; do "$ORCHY" say x-b1 "n$i $pad" >/dev/null || fail "say n$i"; done
ps=(); for i in 1 2 3 4 5 6 7 8; do ( hook <<<'{}' > "$T/hook.$i" ) & ps+=($!); done; wait "${ps[@]}" || true
cat "$T"/hook.? | jq -r '.hookSpecificOutput.additionalContext' | grep -o '^ORCHY-STEER: n[0-9]' | sort | uniq -c > "$T/hook.count"
[ "$(wc -l < "$T/hook.count")" = 5 ] && ! grep -qv '^ *1 ' "$T/hook.count" || fail "parallel hooks did not deliver each note once: $(cat "$T/hook.count")"
[ "$(cat "$T"/hook.? | grep -c additionalContext)" -lt 5 ] || fail "notes that fit in 4 KiB were not delivered together"
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
jq -n '{title:"fix: retry on acct-b", body:"body", commits:[]}' > "$MOCK_DIR/pr-8.json"; cp "$MOCK_DIR/diff-7.txt" "$MOCK_DIR/diff-8.txt"; cp "$MOCK_DIR/files-7.txt" "$MOCK_DIR/files-8.txt"
o=$("$ORCHY" scan 8); grep -q 'leaks=1' <<<"$o" || fail "scan missed a locally banned name in a PR title: $o"
# watch-merge: pin validation, strict report parsing, pinned merge, head-moved exit
SHA=1111111111111111111111111111111111111111; TS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; jq -n --arg s "$TS" '{sha:$s}' > "$MOCK_DIR/trunk.json"
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
# trunk guard: a failed trunk check blocks, unless the PR contains that trunk commit and passed the failed check itself; pending never blocks
jq -n '{check_runs:[{id:9,name:"quality-status",status:"completed",conclusion:"failure"}]}' > "$MOCK_DIR/checks-$TS.json"; mkpr "$SHA"
o=$("$ORCHY" snapshot 2>&1); grep -qx 'dev aaaaaaaa: RED quality-status' <<<"$o" || fail "snapshot does not show the red trunk exactly once: $o"
grep -q -- '/status --paginate' "$MOCK_DIR/gh.log" || fail "the combined status is read without --paginate"
o=$("$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); grep -q 'TIMEOUT; not merged' <<<"$o" || fail "a red trunk did not block: $o"
[ "$(grep -c 'TRUNK RED at aaaaaaaa: quality-status' <<<"$o")" = 1 ] || fail "TRUNK RED not printed exactly once: $o"
jq -n '{behind_by:0}' > "$MOCK_DIR/compare.json"
o=$("$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); grep -q '#9 MERGED' <<<"$o" || fail "a PR containing the red commit, green on the failed check, did not merge: $o"
cp "$ORCHY_HOME/orchy.json" "$T/orchy.bak"; jq '.merge.trunk_checks=["quality-status","nightly"]' "$T/orchy.bak" > "$ORCHY_HOME/orchy.json"
jq -n '{check_runs:[{id:9,name:"nightly",status:"completed",conclusion:"failure"}]}' > "$MOCK_DIR/checks-$TS.json"; mkpr "$SHA"
o=$("$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); grep -q 'TRUNK RED at aaaaaaaa: nightly' <<<"$o" || fail "a failed trunk check the PR never ran did not block: $o"
jq -n '{check_runs:[{id:9,name:"nightly",status:"in_progress",conclusion:null}]}' > "$MOCK_DIR/checks-$TS.json"; mkpr "$SHA"
o=$("$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); grep -q '#9 MERGED' <<<"$o" || fail "a pending trunk check blocked: $o"
cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"; rm -f "$MOCK_DIR/checks-$TS.json" "$MOCK_DIR/compare.json"
# arm-merge: the detached watcher finds the repo and the home (no cd into the cache), and a second arm refuses
if "$ORCHY" arm-merge 9 "$SHA" lane-9 "$ORCHY_HOME/reports/r9.md" >/dev/null 2>&1; then fail "arm-merge accepted a report path the watcher cannot find"; fi
mkpr "$SHA"; "$ORCHY" arm-merge 9 "$SHA" lane-9 r9.md "" 4 >/dev/null || fail "arm-merge"
o=$("$ORCHY" arm-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); grep -q 'already armed' <<<"$o" || fail "arm-merge armed twice: $o"
for i in $(seq 1 30); do grep -q 'MERGED deadbeef\|archived plan' "$ORCHY_HOME/watch/merge-9.out" 2>/dev/null && break; sleep 1; done
grep -q '#9 MERGED deadbeef' "$ORCHY_HOME/watch/merge-9.out" || fail "the armed watcher did not merge: $(cat "$ORCHY_HOME/watch/merge-9.out")"
# teardown: refuses a lane with a live lead, then (hand removal off) relays the refusal, then (on) removes only a HEAD that is a merged PR's head
o=$("$ORCHY" teardown x 2>&1 || true); grep -q 'lead of this lane is alive' <<<"$o" || fail "teardown ignored a live lead: $o"
"$ORCHY" wt-new y >/dev/null || fail "wt-new"
if "$ORCHY" wt-new y >/dev/null 2>&1; then fail "wt-new accepted an existing slug"; fi
HY=$(git -C .claude/worktrees/y rev-parse HEAD)
# a lead running in the lane's worktree blocks teardown whatever its key; lane x's live leads do not
# the stand-in is a script named claude, blocked on a fifo so it has no child to outlive it
mkdir -p "$T/fake"; mkfifo "$T/fake/fifo"; printf '#!/usr/bin/env bash\nread -rt 60 <> "%s/fake/fifo"\n' "$T" > "$T/fake/claude"; chmod +x "$T/fake/claude"
(cd .claude/worktrees/y && exec "$T/fake/claude") & zp=$!
echo "$zp $(awk '{print $22}' /proc/$zp/stat) acct-z 2026-01-01T00:00:00Z light" > "$ORCHY_HOME/leads/y-shots-p1.started"
o=$("$ORCHY" snapshot 2>&1); grep -q '^alive y-shots-p1 ' <<<"$o" || fail "the stand-in lead is not live: $o"
o=$(MOCK_AW_REFUSE=1 "$ORCHY" teardown y 2>&1 || true); grep -q 'lead of this lane is alive' <<<"$o" || fail "teardown ignored a live lead in the lane's worktree: $o"
kill "$zp"; wait "$zp" 2>/dev/null || true; rm "$ORCHY_HOME/leads/y-shots-p1.started"
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
H2="$T/cap/home2"; mkdir -p "$H2/reports"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$H2/"; cp "$ORCHY_HOME/reports/r9.md" "$H2/reports/"
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
# triage mode refuses worktrees, leads and merges in one guard
cp "$ORCHY_HOME/orchy.json" "$T/orchy.bak"; jq '.mode="triage"' "$T/orchy.bak" > "$ORCHY_HOME/orchy.json"
for c in "wt-new z" "launch x-plan x acct-e" "arm-merge 9 $SHA lane-9 r9.md" "watch-merge 9 $SHA lane-9 r9.md"; do
  o=$("$ORCHY" $c 2>&1 || true); grep -q 'mode is triage' <<<"$o" || fail "triage mode allowed $c: $o"; done
cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"
# intake and page age: untriaged open issues, unsigned pages with how long they have waited
o=$("$ORCHY" snapshot 2>&1); grep -q '^(no triaged.txt' <<<"$o" || fail "snapshot without triaged.txt: $o"
jq -n '[{number:1,title:"old"},{number:2,title:"new one"}]' > "$MOCK_DIR/issues.json"; printf '1\n2junk\n' > "$ORCHY_HOME/triaged.txt"
jq -n --arg t "$(date -u -d '50 hours ago' +%FT%TZ)" '{pages:[{no:3,name:"Copy",added_at:$t},{no:4,name:"Old"},{no:5,name:"Signed",added_at:$t}]}' > "$ORCHY_HOME/page/decisions.json"; echo '[3,4]' > "$ORCHY_HOME/page/unsigned.json"
o=$("$ORCHY" snapshot 2>&1); grep -q '^#2 new one$' <<<"$o" && ! grep -q '^#1 ' <<<"$o" || fail "untriaged issues: $o"
grep -q '^page 3 Copy: waiting 2d2h$' <<<"$o" && grep -q '^page 4 Old: age unknown$' <<<"$o" && ! grep -q '^page 5 ' <<<"$o" || fail "unsigned page ages: $o"
# close-outs run one at a time: an open close-out PR of another lane, or a live close-out lead, refuses the next
for k in x-closeout x2-closeout; do cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/$k.md"; done
jq -n '[{headRefName:"q-closeout"},{headRefName:"x-closeout"}]' > "$MOCK_DIR/open.json"
o=$("$ORCHY" launch x-closeout x acct-e 2>&1 || true); grep -q 'close-out PR q-closeout is still open' <<<"$o" || fail "a second close-out launched beside an open one: $o"
jq -n '[{headRefName:"x-closeout"}]' > "$MOCK_DIR/open.json"; "$ORCHY" launch x-closeout x acct-e >/dev/null || fail "a lane's own open close-out PR blocked its close-out lead"
o=$("$ORCHY" launch x2-closeout x acct-f 2>&1 || true); grep -q 'close-out lead x-closeout is alive' <<<"$o" || fail "two close-out leads ran at once: $o"
grep -q -- '--state open --limit 1000' "$MOCK_DIR/gh.log" || fail "the close-out PR check reads gh's default 30 PRs"
rm -f "$MOCK_DIR/open.json"
# receipt: a session counts its last (running-total) result once; a killed run adds deduped, unpriced usage; only closed issues count
HR="$T/cap/rcpt"; mkdir -p "$HR"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$HR/"; cp -r "$HERE/tests/mocks/orchy/receipt/." "$HR/"
jq -n '{closingIssuesReferences:[{number:3},{number:4}]}' > "$MOCK_DIR/pr-21.json"; jq -n '{state:"CLOSED"}' > "$MOCK_DIR/issue-3.json"; jq -n '{state:"OPEN"}' > "$MOCK_DIR/issue-4.json"
o=$(ORCHY_HOME="$HR" "$ORCHY" receipt) || fail "receipt: $o"
grep -qF 'r: $1.50 API-equivalent + 37 unpriced tokens from killed runs; 2 session(s); tokens in 150 out 20 cache-read 1500 cache-write 60;' <<<"$o" || fail "receipt cost or tokens: $o"
grep -qF 'PRs #21 #22 #23 (merged #21); issues closed 1 (#3); failed arcs 1; Codex rounds 3' <<<"$o" || fail "receipt joins, with the auto-continued arc1 report: $o"
grep -qF 'q: $0.25 API-equivalent; 1 session(s); tokens in 1 out 2 cache-read 3 cache-write 4; wall ?;' <<<"$o" || fail "receipt of a log without markers: $o"
grep -qF 'total: $1.75 API-equivalent + 37 unpriced tokens' <<<"$o" || fail "receipt total: $o"
[ "$(ORCHY_HOME="$HR" "$ORCHY" receipt q | wc -l)" = 1 ] || fail "receipt <lane> printed other lanes"
if ORCHY_HOME="$HR" "$ORCHY" receipt nope >/dev/null 2>&1; then fail "receipt of an unknown lane succeeded"; fi
# the owner-record footer: last row per record, take-all picks and delegations never scored
mkdir -p "$T/profile"; { jq -nc '{record:"a",category:"copy",agreed:false}'; jq -nc '{record:"a",category:"copy",agreed:true}'; jq -nc '{record:"b",category:"copy",agreed:false}'
  jq -nc '{record:"c",category:"layout",agreed:true,via_recommend_all:true}'; jq -nc '{record:"d",category:"layout",agreed:null}'; } > "$T/profile/example-app.jsonl"
o=$(ORCHY_HOME="$HR" "$ORCHY" receipt q | tail -1); [ "$o" = "owner took the recommendation: copy 1/2; 1 taken all at once (not scored), 1 left to the orchestrator" ] || fail "owner-record footer: $o"
# ask ledger: distinct ids under contention, transitions, a torn tail, the size cap
LG="$T/asks/example-app.jsonl"; A() { "$ORCHY" ask "$@"; }
ps=(); for i in 1 2 3 4; do ( A add "parallel ask $i" > "$T/add.$i" ) & ps+=($!); done; wait "${ps[@]}" || true
[ "$(cat "$T"/add.* | sort -u | grep -c '^ask[1-4]$')" = 4 ] || fail "parallel ask add reused an id: $(cat "$T"/add.*)"
[ "$(stat -c %a "$T/asks") $(stat -c %a "$LG")" = "700 600" ] || fail "ledger modes: $(stat -c %a "$T/asks") $(stat -c %a "$LG")"
o=$(A lane ask1 greet-1 "a repo change" 2>&1 || true); grep -q 'no public wording' <<<"$o" || fail "lane without a public wording: $o"
A public ask1 "Add a greeting helper with a unit test" >/dev/null || fail "ask public"
A lane ask1 greet-1 "a repo change" >/dev/null || fail "ask lane"
A "done" ask1 "delivered in greet-1 PR #5" >/dev/null || fail "ask done"
o=$(A "done" ask1 again 2>&1 || true); grep -q 'ask1 is done' <<<"$o" || fail "a refused transition does not name the state: $o"
o=$(A note ask99 x 2>&1 || true); grep -q 'no ask99' <<<"$o" || fail "unknown id: $o"
A public ask2 "Rename the config loader" >/dev/null || fail "public ask2"
A lane ask2 cfg-1 "a repo change" >/dev/null || fail "lane ask2"
A reopen ask2 "lane closed" >/dev/null || fail "reopen ask2"
[ "$(A show ask2 | sed '/^-- history/,$d' | jq -r '.lane')" = null ] || fail "reopen kept the lane"
A note ask3 "waiting: wording" >/dev/null; A public ask3 "Tidy the README" >/dev/null
o=$(A lane ask3 docs-1 "a repo change" 2>&1 || true); grep -q 'waiting: wording' <<<"$o" || fail "lane ignored the wording gate: $o"
A note ask3 "wording ok" >/dev/null; A public ask3 "Tidy the README intro" | grep -q "OK again" || fail "a new wording kept the old OK"
A note ask3 "wording okay? queued behind the docs lane" >/dev/null; A list | grep -q '^ask3 .*\[waiting\]' || fail "an ordinary note cleared the hold in list: $(A list)"
o=$(A lane ask3 docs-1 "a repo change" 2>&1 || true); grep -q 'waiting: wording (changed)' <<<"$o" || fail "a replaced wording skipped the gate: $o"
A note ask3 "wording ok" >/dev/null; A lane ask3 docs-1 "a repo change" >/dev/null || fail "lane after the OK"
printf '{"id":"ask4","at":"2026-01-01T00:00:00Z","no' >> "$LG"
[ "$(A add "after a torn tail")" = ask5 ] || fail "add after a torn tail"
tail -n 1 "$LG" | jq -e '.id == "ask5"' >/dev/null || fail "the row after a torn tail does not start its own line"
o=$(A add "$(head -c 17000 /dev/zero | tr '\0' a)" 2>&1 || true); grep -q '16 KiB' <<<"$o" || fail "16 KiB cap: $o"
A list | grep -q '^ask2  open' || fail "list: $(A list)"; A list | grep -q '^ask1 ' && fail "list shows a done ask without --all"
# the copy check: six words of the owner's text or later words, accents and curly quotes aside; template boilerplate exempt
p=$(A add "Please add a greet function, my sister Ana asked for it last Tuesday")
o=$(A public "$p" "Context: my sister Ana asked for it last Tuesday" 2>&1 || true); grep -q 'copies the owner' <<<"$o" || fail "public copied six words: $o"
A public "$p" "Add greet(name); my sister Ana asked for help" >/dev/null || fail "a five-word overlap was refused"
A said "$p" "Sí, añadí la función greet para mi hermana" >/dev/null
o=$(A public "$p" 'Añadí la función “greet” para mi hermana' 2>&1 || true); grep -q 'copies the owner' <<<"$o" || fail "copied Spanish from a said row passed: $o"
A add "You are a subagent. Don't run memo. Summarize this email for me" >/dev/null
printf 'You are a subagent. Don'"'"'t run memo.\nRead your brief.\n' > "$T/boiler.md"; "$ORCHY" check-private "$T/boiler.md" >/dev/null || fail "template boilerplate counted as a copy"
# check-public: leak, sensitive word, a planted secret (assembled here, so this file carries none), and failing closed
printf 'see %s/someone/x\n' "/ho""me" > "$T/p1"; printf 'a vulnerability in login\n' > "$T/p2"; printf 'clean text\n' > "$T/p0"
printf 'aws_access_key_id = %s\naws_secret_access_key = %s\n' "AKIA""QYLPMN5HHHFPZAM2" "wJalrXUtnFEMI/K7MDENG/bPxRfiCY""EXAMPLEKEYzz" > "$T/p3"
ORCHY_GITLEAKS=gitleaks "$ORCHY" check-public "$T/p0" >/dev/null || fail "check-public refused clean text"
for n in 1 2; do if "$ORCHY" check-public "$T/p$n" >/dev/null 2>&1; then fail "check-public accepted p$n: $(cat "$T/p$n")"; fi; done
o=$(ORCHY_GITLEAKS=gitleaks "$ORCHY" check-public "$T/p3" 2>&1 || true); grep -q 'SECRET' <<<"$o" || fail "the real gitleaks missed the planted secret: $o"
"$ORCHY" check-public --no-sensitive "$T/p2" >/dev/null || fail "--no-sensitive still applied the sensitive pattern"
o=$(ORCHY_GITLEAKS=no-such-gitleaks "$ORCHY" check-public "$T/p0" 2>&1; echo "rc=$?"); grep -q 'rc=2' <<<"$o" || fail "check-public without gitleaks did not refuse: $o"
cp "$ORCHY_HOME/local.json" "$T/local.bak"; echo '{' > "$ORCHY_HOME/local.json"
o=$("$ORCHY" check-public "$T/p0" 2>&1; echo "rc=$?"); grep -q 'rc=2' <<<"$o" || fail "check-public with a broken local.json did not refuse: $o"; cp "$T/local.bak" "$ORCHY_HOME/local.json"
mkdir "$T/lk"; cp "$LG" "$T/lk/l.jsonl"; chmod 000 "$T/lk"; o=$(bash "$K/scripts/overlap.sh" "$T/lk/l.jsonl" "$T/p0" 2>&1; echo "rc=$?"); chmod 700 "$T/lk"
grep -q 'rc=2' <<<"$o" || fail "the copy check read a ledger behind a locked dir as absent: $o"
# ask file: every refusal leaves no create call; an exact title, a failed search and a failed create file nothing; one lock spans it all
f=$(A add "File the flaky login test"); A public "$f" "The login test fails intermittently" >/dev/null
printf '## Problem\nThe login test fails about one run in ten.\n' > "$T/body.md"; jq -n '[{number:9,title:"Flaky login test"}]' > "$MOCK_DIR/issues.json"; : > "$MOCK_DIR/created.log"
for b in p1 p2 p3; do if A file "$f" "Login test is flaky" "$T/$b" >/dev/null 2>&1; then fail "file accepted body $b"; fi; done
o=$(A file "$f" "flaky LOGIN test" "$T/body.md" 2>&1 || true); grep -q 'issue #9 already has this exact title' <<<"$o" || fail "exact title: $o"
o=$(MOCK_GH_FAIL=search A file "$f" "Login test is flaky" "$T/body.md" 2>&1 || true); grep -q 'duplicate search failed' <<<"$o" || fail "search error: $o"
[ ! -s "$MOCK_DIR/created.log" ] || fail "a refused file still called gh issue create"
n0=$(wc -l < "$LG"); o=$(MOCK_GH_FAIL=create A file "$f" "Login test is flaky" "$T/body.md" 2>&1 || true)
grep -q 'ledger is unchanged' <<<"$o" && [ "$(wc -l < "$LG")" = "$n0" ] || fail "a failed create changed the ledger: $o"
( MOCK_GH_DELAY=2 A file "$f" "Login test is flaky" "$T/body.md" > "$T/file.out" 2>&1 ) & fp=$!; sleep 0.5
o=$(A drop "$f" "never mind" 2>&1 || true); wait "$fp"
grep -q "$f filed as #77" "$T/file.out" || fail "file: $(cat "$T/file.out")"; grep -q "$f is filed" <<<"$o" || fail "a drop during the create was not refused after it: $o"
[ "$(A show "$f" | sed '/^-- history/,$d' | jq -r '"\(.state) \(.issue)"')" = "filed 77" ] || fail "filed state"
rm -f "$MOCK_DIR/issues.json"
# asks in lanes: the lane brief carries them; close-lane reads each report's last ASKS: line in lane order
"$ORCHY" render lane-brief.md LANE=cl ISSUES=none ASKS="ask9: Add a greeting helper" TIER=light SCOPE=s DECISIONS=none OUT=none VERIFY=none ARCS=a1 OTHER_LEADS=none | grep -qx 'ask9: Add a greeting helper' || fail "lane brief does not render ASKS"
c=(); for i in 1 2 3 4 5; do c[i]=$(A add "close-lane case $i"); A public "${c[i]}" "Close-lane requirement number $i" >/dev/null; A lane "${c[i]}" cl "a repo change" >/dev/null || fail "lane ${c[i]}"; done
A drop "${c[4]}" "withdrawn" >/dev/null
RP="$ORCHY_HOME/reports"; mkdir -p "$RP"
printf 'LEAD_DONE\nASKS: delivered %s %s %s\n' "${c[1]}" "${c[2]}" "${c[3]}" > "$RP/cl-plan.md"   # a plan delivers nothing
printf 'LEAD_DONE\nPR #31 add it ready checks: green\nASKS: delivered %s %s; left out %s the API it needs is missing\n' "${c[1]}" "${c[5]}" "${c[2]}" > "$RP/cl-a1.md"
printf 'LEAD_DONE\nPR #32 retry ready checks: green\nASKS: left out %s not needed\n' "${c[5]}" > "$RP/cl-arc1.md"
printf 'LEAD_DONE\nPR #40 other ready checks: green\nASKS: delivered %s\n' "${c[3]}" > "$RP/cl-a11y-a1.md"
mkdir -p .claude/worktrees/cl; o=$(A close-lane cl 2>&1 || true); grep -q 'still has its worktree' <<<"$o" || fail "close-lane with the worktree present: $o"; rmdir .claude/worktrees/cl
A close-lane cl > "$T/cl.out" || fail "close-lane: $(cat "$T/cl.out")"
st() { A show "$1" | sed '/^-- history/,$d' | jq -r '"\(.state) \(.notes[-1])"'; }
[ "$(st "${c[1]}")" = "done delivered in cl PR #31" ] || fail "delivered ask: $(st "${c[1]}")"
[ "$(st "${c[2]}")" = "open lane cl closed without delivering it: the API it needs is missing" ] || fail "a later left-out did not win: $(st "${c[2]}")"
[ "$(st "${c[3]}")" = "open lane cl closed without delivering it: not reported" ] || fail "an unreported ask (the plan's claim and another lane's report ignored): $(st "${c[3]}")"
[ "$(st "${c[4]}")" = "dropped withdrawn" ] || fail "a dropped ask was touched: $(st "${c[4]}")"
[ "$(st "${c[5]}")" = "open lane cl closed without delivering it: conflicting reports a1/arc1" ] || fail "a1/arc1 conflict: $(st "${c[5]}")"
o=$(A lane "${c[3]}" cl "again" 2>&1 || true); grep -q 'lane cl is closed' <<<"$o" || fail "ask lane reused a closed slug: $o"
o=$("$ORCHY" wt-new cl 2>&1 || true); grep -q 'never reused' <<<"$o" || fail "wt-new recreated a closed lane: $o"
# snapshot names asks by id and state only, flags an ask whose lane is gone, and lists no untriaged issue for an empty backlog
g=$(A add "my sister Ana wants the gone lane"); A public "$g" "Gone-lane requirement" >/dev/null; A lane "$g" gone-1 "a repo change" >/dev/null
echo '[]' > "$MOCK_DIR/issues.json"; : > "$ORCHY_HOME/triaged.txt"; "$ORCHY" snapshot > "$T/snap.out" 2>&1
sed -n '/^-- asks/,/^--/p' "$T/snap.out" | grep -q "^$g lane gone-1 .*lane closed: run ask close-lane gone-1" || fail "snapshot asks: $(sed -n '/^-- asks/,/^--/p' "$T/snap.out")"
grep -q 'Ana\|close-lane case' "$T/snap.out" && fail "snapshot printed an ask's text"
if sed -n '/^-- untriaged/,/^--/p' "$T/snap.out" | grep -q '^#'; then fail "untriaged issues listed for an empty backlog"; fi
r=$(A add "receipt case"); A public "$r" "Receipt requirement" >/dev/null; A lane "$r" r "a repo change" >/dev/null; A "done" "$r" "delivered" >/dev/null
o=$(ORCHY_HOME="$HR" "$ORCHY" receipt r); grep -qF "asks done 1 ($r)" <<<"$o" || fail "receipt asks: $o"
# launch and say: an ask reaches a lead only as its stored wording, laned there, not held, never copied from the owner
l=$(A add "Please add the greeting on the home page because my landlord asked twice"); A public "$l" "Show a greeting on the home page" >/dev/null; A lane "$l" x "a repo change" >/dev/null
lt() { printf 'You are a subagent.\n%s\n' "$1" > "$ORCHY_HOME/prompts/x-lt.md"; "$ORCHY" launch x-lt x acct-a 2>&1 || true; }
o=$(lt "$l: Show a greeting"); grep -q 'not its stored public wording' <<<"$o" || fail "launch with a reworded ask line: $o"
o=$(lt "$l: Show a greeting on the home page, a vulnerability fix"); grep -q 'SENSITIVE' <<<"$o" || fail "launch with a sensitive ask line: $o"
o=$(lt "$r: Receipt requirement"); grep -q "$r is not laned to x" <<<"$o" || fail "launch with another lane's ask: $o"
o=$(lt "Context: on the home page because my landlord asked twice"); grep -q 'copies the owner' <<<"$o" || fail "launch with a copied sentence: $o"
printf 'Lane x for acct-a\n' > "$ORCHY_HOME/briefs/x.md"; o=$(lt "$l: Show a greeting on the home page"); grep -q 'banned text' <<<"$o" || fail "launch with a banned lane brief: $o"; rm "$ORCHY_HOME/briefs/x.md"
o=$(lt "$l: Show a greeting on the home page"); grep -qE 'refused: (the|.* is not laned|.*copies)|SENSITIVE|LEAK' <<<"$o" && fail "launch refused a clean ask line: $o"
printf 'You are a subagent.\n' > "$ORCHY_HOME/prompts/x-say.md"; MOCK_LEAD_SECS=30 "$ORCHY" launch --force-cap x-say x acct-b >/dev/null || fail "launch x-say"
o=$("$ORCHY" say x-say "remember: home page because my landlord asked twice" 2>&1 || true); grep -q 'copies the owner' <<<"$o" || fail "say queued a copied sentence: $o"
o=$("$ORCHY" say x-say "$(cat "$T/p3")" 2>&1 || true); grep -q 'SECRET' <<<"$o" || fail "say queued a secret: $o"
o=$("$ORCHY" say x-say "$l: Show a greeting" 2>&1 || true); grep -q 'not its stored public wording' <<<"$o" || fail "say queued a reworded ask: $o"
o=$("$ORCHY" say x-say "$g: Gone-lane requirement" 2>&1 || true); grep -q "$g is not laned to x" <<<"$o" || fail "say queued another lane's ask: $o"
"$ORCHY" say x-say "fix the review finding in $l first" | grep -q queued || fail "say refused an ordinary note naming a finding"
"$ORCHY" stop x-say >/dev/null
# the seat: session id and messaging address recorded, the token never; pid and start time alone decide ownership
L="$ORCHY_HOME/orchestrator.lock"; TOK="tok-$RANDOM$RANDOM"
CLAUDE_CODE_SESSION_ID=sess-0001 CLAUDE_CODE_MESSAGING_SOCKET="$T/m.sock" CLAUDE_CODE_MESSAGING_TOKEN="$TOK" "$ORCHY" lock >/dev/null || fail "lock with the session env"
read -r _ _ _ s4 s5 < "$L"; [ "$s4 $s5" = "sess-0001 uds:$T/m.sock" ] || fail "seat fields: $(cat "$L")"
grep -rqF -- "$TOK" "$ORCHY_HOME" && fail "the messaging token reached the home"
"$ORCHY" unlock | grep -qx unlocked || fail "the holder could not unlock its seat"
seat() { printf '%s %s 2026-01-01T00:00:00Z %s uds:%s\n' "$1" "$(awk '{print $22}' "/proc/$1/stat")" "$2" "$T/o.sock" > "$L"; }
sleep 60 & sa=$!; seat "$sa" sess-other
o=$("$ORCHY" lock 2>&1 || true); grep -q 'session sess-other' <<<"$o" || fail "a refused lock does not name the holder's session: $o"
o=$("$ORCHY" unlock 2>&1; echo "rc=$?"); grep -q 'rc=2' <<<"$o" || fail "unlock removed a live other session's seat: $o"
kill "$sa"; wait "$sa" 2>/dev/null || true; sleep 60 & sb=$!; seat "$sb" sess-contender
o=$("$ORCHY" unlock 2>&1; echo "rc=$?"); grep -q 'rc=2' <<<"$o" || fail "unlock removed a contender's fresh seat: $o"
seat "$sb" sess-0001; o=$(CLAUDE_CODE_SESSION_ID=sess-0001 "$ORCHY" unlock 2>&1; echo "rc=$?"); grep -q 'rc=2' <<<"$o" || fail "a matching session string unlocked another process's seat: $o"
kill "$sb"; wait "$sb" 2>/dev/null || true; "$ORCHY" unlock | grep -qx unlocked || fail "a dead holder's seat was not released"
# wait, in fast motion (1 s ticks and polls), in a home of its own so no lead or report moves under it
HW="$T/cap/hw"; mkdir -p "$HW"; jq '.wait.poll_sec=1' "$ORCHY_HOME/orchy.json" > "$HW/orchy.json"; cp "$ORCHY_HOME/local.json" "$HW/"
jq -n '[{number:1,updatedAt:"2026-01-01T00:00:00Z"}]' > "$MOCK_DIR/issues.json"; jq -n '{sha:"1111111111111111111111111111111111111111"}' > "$MOCK_DIR/trunk.json"; rm -f "$MOCK_DIR/open.json"
w() { ORCHY_HOME="$HW" ORCHY_WAIT_TICK=1 "$ORCHY" wait "$1" > "$T/w.out" 2>&1; }
w 5; [ "$(grep -cE '^CHANGED \((issues|trunk|prs|reports/leads/watchers)\)' "$T/w.out")" = 4 ] || fail "sources with no seen file did not fire on their first read: $(cat "$T/w.out")"
# between two waits nobody watches: the next wait compares against what the last one reported, so the gap is seen
jq '. + [{number:2,updatedAt:"2026-01-02T00:00:00Z"}]' "$MOCK_DIR/issues.json" > "$T/i.json" && mv "$T/i.json" "$MOCK_DIR/issues.json"
w 5; [ "$(grep '^CHANGED' "$T/w.out")" = 'CHANGED (issues):' ] || fail "an issue added between two waits was absorbed: $(cat "$T/w.out")"
jq -n '{sha:"2222222222222222222222222222222222222222"}' > "$MOCK_DIR/trunk.json"; jq '.[0].updatedAt="2026-01-03T00:00:00Z"' "$MOCK_DIR/issues.json" > "$T/i.json" && mv "$T/i.json" "$MOCK_DIR/issues.json"
w 5; [ "$(grep -cE '^CHANGED \((trunk|issues)\)' "$T/w.out")" = 2 ] || fail "wait did not report both sources that moved in one poll: $(cat "$T/w.out")"
w 2; [ "$(cat "$T/w.out")" = "TIMEOUT after 2s, no change" ] || fail "reported changes fired again, or a quiet wait did not time out cleanly: $(cat "$T/w.out")"
touch "$MOCK_DIR/fail-issues"; jq -n '{sha:"3333333333333333333333333333333333333333"}' > "$MOCK_DIR/trunk.json"
w 5; grep -q 'CHANGED (trunk)' "$T/w.out" || fail "a failing issue read hid a trunk move: $(cat "$T/w.out")"
w 2; rm "$MOCK_DIR/fail-issues"; grep -q 'TIMEOUT after 2s, no change; unreadable: issues' "$T/w.out" || fail "a timeout did not name the unreadable source: $(cat "$T/w.out")"
# local events re-arm the wait long before poll_sec, so the first tick must read GitHub too
jq '.wait.poll_sec=120' "$HW/orchy.json" > "$T/o.json" && mv "$T/o.json" "$HW/orchy.json"; jq -n '{sha:"4444444444444444444444444444444444444444"}' > "$MOCK_DIR/trunk.json"
w 3; grep -q 'CHANGED (trunk)' "$T/w.out" || fail "the first tick of a wait did not read GitHub: $(cat "$T/w.out")"
rm -f "$MOCK_DIR/issues.json" "$MOCK_DIR/trunk.json"
wait "$pgp" || { tail -n 20 "$T/page.log"; fail "page smoke"; }; pgp=
# no project names, home paths or roster names anywhere in the skill
if grep -rnE 'nulo|Nulo|program-2|program2|/mnt/user-data|/Users/|martu|proton|icloud|GzKw77' "$K" --include='*.md' --include='*.sh' --include='*.py' --include='*.js' --include='*.ts' --include='*.json' --include='*.cjs' | grep -v 'page/fixtures' ; then fail "project-specific text in the skill"; fi
echo "smoke-orchy: ok"
