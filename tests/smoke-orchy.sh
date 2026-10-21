#!/usr/bin/env bash
# Smoke for skills/start-orchy: orchy.sh against a throwaway repo and home with mocked gh / agent-worktree / claude-usage, the templates, the page toolchain's own smoke.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); K="$HERE/skills/start-orchy"; ORCHY="$K/scripts/orchy.sh"
T=$(mktemp -d -t orchy-smoke-XXXX); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PATH="$HERE/tests/mocks/orchy:$PATH" MOCK_DIR="$T/mock" ORCHY_HOME="$T/home" ORCHY_REPO=example/app ORCHY_WATCH_SLEEP=1; mkdir -p "$MOCK_DIR"
# a real local origin with a dev branch, so wt-new's fetch and reset work
git init -q --bare "$T/origin.git"; git init -q -b dev "$T/repo"; git -C "$T/repo" remote add origin "$T/origin.git"
(cd "$T/repo" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init && git push -q origin dev)
cd "$T/repo"
[ "$("$ORCHY" home)" = "$T/home" ] || fail "home"
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
H2="$T/home2"; mkdir -p "$H2"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$H2/"
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
for f in "$ORCHY_HOME"/leads/*.started; do read -r p _ < "$f"; kill "$p" 2>/dev/null || true; done
# the page toolchain's own smoke
[ -x "$K/page/smoke.sh" ] || fail "page/smoke.sh missing"; bash "$K/page/smoke.sh" > "$T/page.log" 2>&1 || { tail -n 20 "$T/page.log"; fail "page smoke"; }
# no project names, home paths or roster names anywhere in the skill
if grep -rnE 'nulo|Nulo|program-2|program2|/mnt/user-data|/Users/|martu|proton|icloud|GzKw77' "$K" --include='*.md' --include='*.sh' --include='*.py' --include='*.js' --include='*.ts' --include='*.json' --include='*.cjs' | grep -v 'page/fixtures' ; then fail "project-specific text in the skill"; fi
echo "smoke-orchy: ok"
