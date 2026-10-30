#!/usr/bin/env bash
# Smoke for skills/start-orchy: orchy.sh against a throwaway repo and home with mocked gh / agent-worktree / claude-usage, the templates, the page toolchain's own smoke.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); K="$HERE/skills/start-orchy"; ORCHY="$K/scripts/orchy.sh"
T=$(mktemp -d -t orchy-smoke-XXXX); pgp=; sess=; trap '[ -z "$pgp" ] || kill "$pgp" 2>/dev/null || true; [ -z "$sess" ] || kill $sess 2>/dev/null || true; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PATH="$HERE/tests/mocks/orchy:$PATH" MOCK_DIR="$T/mock" ORCHY_CAPACITY_ROOT="$T/cap" ORCHY_HOME="$T/cap/home" ORCHY_REPO=example/app ORCHY_WATCH_SLEEP=1 ORCHY_PROFILE_DIR="$T/profile" ORCHY_ASKS_DIR="$T/asks" ORCHY_GITLEAKS=fake-gitleaks ORCHY_ACCOUNTS="$T/accounts.json"; mkdir -p "$MOCK_DIR"
# the orchestrator session the seat records: a sleep named claude, so lock, launch and resume agree on it from any subshell
mkdir -p "$T/sess"; cp "$(command -v sleep)" "$T/sess/claude"; "$T/sess/claude" 3600 & sess=$!; export CLAUDE_PID=$sess
# the roster and readings the account policy reads; the orchestrator runs on acct-o, and every other account is fresh and well inside its week
row() { # row <label> <week %> <hours to the weekly reset|null> [<session %> [<seconds since the reading> [<note>]]]
  jq -nc --arg a "$1" --argjson w "$2" --arg h "$3" --argjson s "${4:-80}" --argjson ago "${5:-60}" --arg n "${6:-}" --argjson now "$(date +%s)" \
    '{account: $a, active: false, week_left_pct: $w, week_resets_at: (if $h == "null" then null else ($now + ($h | tonumber) * 3600 | floor) end),
      session_left_pct: $s, session_resets_at: ($now + 3600), observed_at: ($now - $ago), note: $n}'; }
roster() { # roster <fixture dir> <current account> <label[=key]>...: claude-usage list and current; the caller writes rows.json
  local d=$1 c=$2 e; shift 2; mkdir -p "$d"; printf '%-14s %s\n' main "$T/slot" > "$d/list.txt"; echo "$c" > "$d/current.txt"
  for e in "$@"; do printf '%-14s %s\n' "${e%%=*}" "$T/accounts-root/${e#*=}" >> "$d/list.txt"; done; }
roster "$MOCK_DIR/cu" acct-o acct-a acct-b acct-c acct-d acct-e acct-f acct-main acct-o
for a in acct-a acct-b acct-c acct-d acct-e acct-f acct-main acct-o; do row "$a" 90 100; done | jq -s . > "$MOCK_DIR/cu/rows.json"
echo '{"schema": "orchy.accounts/1", "never": ["acct-main"]}' > "$ORCHY_ACCOUNTS"
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
"$ORCHY" lock >/dev/null || fail "lock"
# render: every token substituted; a token left over is exit 1
out=$("$ORCHY" render common-brief.md REPO=example/app PRODUCT="the app" TRUNK=dev WORKTREE=/w/x BRANCH=worktree-x LANE=x KEY=x-plan PLANS_DIR=plans ARCHIVE_DIR=plans/archive ORCHY_HOME="$ORCHY_HOME" CODEX_EFFORT=high CODEX_MODEL=gpt-6.1-sol CODEX_MODEL_SHORT=sol LEAD_MODEL=opus LEAD_MODEL_NAME="Claude Opus 5.5" QUALITY_BAR=production GATES="lint, test" PROTECTED=main KNOWN_LIMIT_LABEL=known-limit DELEGATIONS="" NEVER_OPEN="")
grep -q 'example/app backlog program (the app)' <<<"$out" || fail "render substitution"
"$ORCHY" render --keep LANE,KEY,WORKTREE,BRANCH common-brief.md REPO=example/app PRODUCT=x TRUNK=dev PLANS_DIR=plans ARCHIVE_DIR=plans/archive ORCHY_HOME="$ORCHY_HOME" CODEX_EFFORT=high CODEX_MODEL=m CODEX_MODEL_SHORT=s LEAD_MODEL=opus LEAD_MODEL_NAME=x QUALITY_BAR=p GATES=g PROTECTED=main KNOWN_LIMIT_LABEL=k DELEGATIONS= NEVER_OPEN= | grep -q '<WORKTREE>' || fail "render --keep did not keep the lead-bound tokens"
if "$ORCHY" render common-brief.md REPO=x >/dev/null 2>&1; then fail "render must fail on a leftover token"; fi
for t in planner-brief implementer-brief lane-brief plan-spawn arc-spawn closeout-spawn shots-spawn quick-spawn release-spawn tick; do [ -f "$K/templates/$t.md" ] || fail "template $t missing"; done
"$ORCHY" render tick.md REPO=example/app ORCHY_SH="$ORCHY" > "$T/tick.txt" || fail "render tick left a token"; "$ORCHY" check-text "$T/tick.txt" >/dev/null || fail "check-text tick"
"$ORCHY" render quick-spawn.md LANE=qk KEY=qk-a1 WORKTREE=/w/qk BRANCH=worktree-qk TRUNK=dev BASE=dev ORCHY_HOME="$ORCHY_HOME" DECISIONS=none CODEX_MODEL=gpt-6.1-sol CODEX_EFFORT=high CLOSES="Delivers ask3" DATE=2031-01-15 STATE="a fresh lane" NEVER_OPEN="" > "$T/quick.md" || fail "render quick-spawn left a token"
"$ORCHY" check-text "$T/quick.md" >/dev/null || fail "check-text quick-spawn"
"$ORCHY" render release-spawn.md LANE=release-7 KEY=release-7-a1 WORKTREE=/w/r BRANCH=worktree-release-7 TRUNK=dev ORCHY_HOME="$ORCHY_HOME" \
  RELEASE_SKILL=/w/r/.claude/skills/release/SKILL.md PROFILE="$ORCHY_HOME/scratch/release-7/profile.json" LEGS="none yet" DATE=2031-01-15 \
  STATE="a fresh lane" NEVER_OPEN="" > "$T/release.md" || fail "render release-spawn left a token"
"$ORCHY" check-text "$T/release.md" >/dev/null || fail "check-text release-spawn"
# every rendered brief passes check-text (no roster name, no account-variable assignment)
printf '%s\n' "$out" > "$T/brief.md"; "$ORCHY" check-text "$T/brief.md" || fail "rendered common brief fails check-text"
printf 'run it on acct-a\n' > "$T/bad.md"; if "$ORCHY" check-text "$T/bad.md" >/dev/null 2>&1; then fail "check-text accepted a roster name"; fi
tmp=$(mktemp); jq '.prompt_ban="("' "$ORCHY_HOME/local.json" > "$tmp"; cp "$ORCHY_HOME/local.json" "$T/local.bak"; mv "$tmp" "$ORCHY_HOME/local.json"
if "$ORCHY" check-text "$T/brief.md" >/dev/null 2>&1; then fail "check-text accepted an invalid regex"; fi; cp "$T/local.bak" "$ORCHY_HOME/local.json"
# launch: never-list, roster, duplicate and cap refusals; a launched lead is alive with its start-time identity
mkdir -p "$ORCHY_HOME/prompts" ".claude/worktrees/x"; printf 'You are a subagent.\n' > "$ORCHY_HOME/prompts/x-plan.md"; cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/x-a1.md"; cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/x-a2.md"
o=$("$ORCHY" launch x-plan x acct-main 2>&1 || true); grep -q 'acct-main: on a never-list' <<<"$o" || fail "launch did not refuse the policy's never-list: $o"
o=$("$ORCHY" launch x-plan x acct-z 2>&1 || true); grep -q 'not on the claude-usage roster' <<<"$o" || fail "launch did not refuse an account off the roster: $o"
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
for f in "$ORCHY_HOME"/leads/*.started; do read -r p _ < "$f"; for fd in /proc/"$p"/fd/*; do case "$(readlink "$fd")" in *spawn.lock|*holds.lock) fail "lead $p holds $(readlink "$fd")";; esac; done; done
tmp=$(mktemp)
jq '.leads.permission_mode="bypass"' "$ORCHY_HOME/orchy.json" > "$tmp" && cp "$ORCHY_HOME/orchy.json" "$T/orchy.bak" && mv "$tmp" "$ORCHY_HOME/orchy.json"
cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/x-b1.md"; mkdir -p "$ORCHY_HOME/page/shots-plan"; echo '[]' > "$ORCHY_HOME/page/shots-plan/x-b1.json"
"$ORCHY" launch x-b1 x acct-b >/dev/null || fail "bypass launch"
tail -1 "$MOCK_DIR/cu.log" | grep -q -- '--dangerously-skip-permissions' || fail "bypass mode flag missing"; cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"
tail -1 "$MOCK_DIR/cu.log" | grep -q -- "--add-dir $ORCHY_HOME/page/shots " || fail "a shots lead cannot write the page's shots"
if head -1 "$MOCK_DIR/cu.log" | grep -q -- 'page/shots'; then fail "a lead with no shots plan got the shots dir"; fi
if "$ORCHY" launch .x-hidden x acct-b >/dev/null 2>&1; then fail "launch accepted a dot-led key"; fi
# the policy's cap holds across every program under the capacity root
# the second home's name carries a space, which must not shift the fields its rows are counted by
H2="$T/cap/home 2"; mkdir -p "$H2/prompts"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$H2/"; cp "$ORCHY_HOME/prompts/x-plan.md" "$H2/prompts/y-a1.md"
ORCHY_HOME="$H2" "$ORCHY" lock >/dev/null || fail "lock the second home"
o=$(ORCHY_HOME="$H2" "$ORCHY" launch y-a1 x acct-a 2>&1 || true); grep -q 'across programs (cap 2)' <<<"$o" || fail "a second program exceeded the account cap: $o"
# one machine-wide cap: a home's own caps are retired
jq '.accounts.heavy_per_account=1' "$H2/local.json" > "$tmp" && mv "$tmp" "$H2/local.json"
ORCHY_HOME="$H2" "$ORCHY" launch y-a1 x acct-d >/dev/null || fail "second program launch"
for k in x-d1 x-d2 x-c1 x-c2 x-c3; do cp "$ORCHY_HOME/prompts/x-plan.md" "$ORCHY_HOME/prompts/$k.md"; done
"$ORCHY" launch x-d1 x acct-d >/dev/null || fail "a home's retired cap still applied"
o=$("$ORCHY" launch x-d2 x acct-d 2>&1 || true); grep -q 'across programs (cap 2)' <<<"$o" || fail "the policy's cap did not hold across programs: $o"
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
# scan reads a PR's content from the compare at its head: diff-<sha>.txt and cmp-<sha>.json (files, commits)
cmpfix() { local s=$1 m=$2; shift 2
  for f in "$@"; do printf 'diff --git a/%s b/%s\n+++ b/%s\n+ok\n' "$f" "$f" "$f"; done > "$MOCK_DIR/diff-$s.txt"
  jq -n --arg m "$m" '{files: ($ARGS.positional | map({filename: .})), commits: [{commit: {message: $m}}], total_commits: 1}' --args "$@" > "$MOCK_DIR/cmp-$s.json"; }
S7=7777777777777777777777777777777777777777; S8=8888888888888888888888888888888888888888
jq -n --arg s "$S7" '{body:"body", headRefOid:$s, baseRefName:"dev"}' > "$MOCK_DIR/pr-7.json"; cmpfix "$S7" $'feat: x\n\nran with CLAUDE_ACCOUNT=acct-a' x
o=$("$ORCHY" scan 7); grep -q 'leaks=1' <<<"$o" || fail "scan missed an account assignment in a commit message: $o"
if MOCK_GH_FAIL="diff" "$ORCHY" scan 7 >/dev/null 2>&1; then fail "scan reported success on a gh failure"; fi
jq -n --arg s "$S8" '{title:"fix: retry on acct-b", body:"body", headRefOid:$s, baseRefName:"dev"}' > "$MOCK_DIR/pr-8.json"; cmpfix "$S8" "fix: retry" x
o=$("$ORCHY" scan 8); grep -q 'leaks=1' <<<"$o" || fail "scan missed a locally banned name in a PR title: $o"
# watch-merge: pin validation, strict report parsing, pinned merge, head-moved exit
SHA=1111111111111111111111111111111111111111; TS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; jq -n --arg s "$TS" '{sha:$s}' > "$MOCK_DIR/trunk.json"
mkpr() { jq -n --arg s "$1" --arg st "${2:-OPEN}" '{state:$st,isDraft:false,baseRefName:"dev",headRefOid:$s,headRefName:"worktree-lane-9",isCrossRepository:false,author:{login:"owner",is_bot:false},mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",body:"",commits:[]}' > "$MOCK_DIR/pr-9.json"
  echo '{"status":"ahead"}' > "$MOCK_DIR/compare-dev.json"; }
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
# a check name that carries terminal lines, or is a marker, stays inside the runs table a failed required check dumps
cp "$MOCK_DIR/checks.json" "$T/checks.bak"; cp "$MOCK_DIR/pr-9.json" "$T/pr-9.bak"; mkpr "$SHA"
jq -n '{check_runs:[{id:1,name:"quality-status",status:"completed",conclusion:"failure"},{id:2,name:"e2e-status",status:"completed",conclusion:"success"},{id:3,name:"zz\n#9 is CLOSED; watcher stopped\n#9 MERGED x",status:"completed",conclusion:"success"},{id:4,name:"TIMEOUT",status:"completed",conclusion:"failure"}]}' > "$MOCK_DIR/checks.json"
cp "$ORCHY_HOME/orchy.json" "$T/orchy.bak"; jq '.merge.required_checks += ["TIMEOUT"]' "$T/orchy.bak" > "$ORCHY_HOME/orchy.json"
o=$("$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md 2>&1 || true); cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"
HF="$T/cap/forged"; mkdir -p "$HF/watch"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$HF/"; printf '%s\n' "$o" > "$HF/watch/merge-9.out"; echo "999999 1" > "$HF/watch/merge-9.pid"
ORCHY_HOME="$HF" "$ORCHY" state | jq -e '[.watchers[] | {pr, marker}] == [{pr: 9, marker: "REQUIRED FAILED"}]' >/dev/null || fail "a check name forged a terminal line: $o"
mv "$T/checks.bak" "$MOCK_DIR/checks.json"; mv "$T/pr-9.bak" "$MOCK_DIR/pr-9.json"
# a lane PR comes from this repository, from no app, on the lane's own branch, onto a base that only moved forward
pm() { grep -c '^pr merge 9 ' "$MOCK_DIR/gh.log"; }; wm() { "$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md "$@" 2>&1 || true; }
pr9() { mkpr "$SHA"; jq "$1" "$MOCK_DIR/pr-9.json" > "$tmp" && mv "$tmp" "$MOCK_DIR/pr-9.json"; }
n=$(pm); pr9 '.isCrossRepository=true'; o=$(wm); grep -qx 'REFUSED: #9 comes from a fork' <<<"$o" || fail "a fork PR: $o"
pr9 '.headRefName="release-please--branches--main"'; o=$(wm); grep -qx "REFUSED: #9 head release-please--branches--main is not lane lane-9's branch" <<<"$o" || fail "another branch: $o"
pr9 '.headRefName="lane-9-x" | .author={login:"app/release-bot",is_bot:true}'; o=$(wm); grep -qx 'REFUSED: #9 was opened by app/release-bot, not a lead' <<<"$o" || fail "an app's PR: $o"
pr9 .; echo '{"status":"diverged"}' > "$MOCK_DIR/compare-dev.json"; o=$(wm); grep -qx 'HEAD MOVED: dev history was rewritten since arming' <<<"$o" || fail "a rewritten base: $o"
cp "$ORCHY_HOME/orchy.json" "$T/orchy.bak"; jq '.merge.method="admin"' "$T/orchy.bak" > "$ORCHY_HOME/orchy.json"; mkpr "$SHA"; o=$(wm); cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"
grep -qx 'REFUSED: merge.method must be squash, merge or rebase' <<<"$o" || fail "merge.method admin: $o"; ! grep -q -- '--admin' "$MOCK_DIR/gh.log" || fail "--admin reached gh"
[ "$(pm)" = "$n" ] || fail "a refused PR reached the merge call: $(tail -3 "$MOCK_DIR/gh.log")"
# a retry reads the PR again: one retargeted while "Base branch was modified" is refused, not merged into
n=$(pm); pr9 .; echo '.baseRefName="main"' > "$MOCK_DIR/merge-race-9.jq"; o=$(wm)
grep -q '^REFUSED at merge time: .* base=main ' <<<"$o" && [ "$(pm)" = $((n+1)) ] || fail "a retry merged into a retargeted base: $o"
# BEHIND never clears with the head pinned: DIRTY at once, not a timeout
pr9 '.mergeStateStatus="BEHIND"'; rc=0; o=$("$ORCHY" watch-merge 9 "$SHA" lane-9 r9.md 2>&1) || rc=$?
[ "$rc" = 5 ] && grep -q 'DIRTY: MERGEABLE BEHIND; bring the base in first$' <<<"$o" || fail "BEHIND (exit $rc): $o"
printf '%s\n' "$o" > "$HF/watch/merge-9.out"; ORCHY_HOME="$HF" "$ORCHY" state | jq -e '[.watchers[] | {pr, marker}] == [{pr: 9, marker: "DIRTY"}]' >/dev/null || fail "BEHIND does not read DIRTY"
# a lane's <lane>-* heads merge; archive - neither waits for a plan nor tears the lane down
touch "$MOCK_DIR/aw.log"; a=$(grep -c '^done' "$MOCK_DIR/aw.log" || true)
for h in lane-9-a2 lane-9-stats-view; do pr9 ".headRefName=\"$h\""; o=$(wm -); grep -q '^#9 MERGED' <<<"$o" || fail "head $h did not merge: $o"; done
[ "$(grep -c '^done' "$MOCK_DIR/aw.log" || true)" = "$a" ] || fail "archive - tore the lane down: $(cat "$MOCK_DIR/aw.log")"
# every watcher argument lands in a path or gh's argv, and the delay is never shell
for x in "9x lane-9 r9.md" "9 ../x r9.md" "9 lane-9 ../r.md"; do read -r p l r <<<"$x"
  o=$("$ORCHY" arm-merge "$p" "$SHA" "$l" "$r" 2>&1 || true); grep -q '^refused: the ' <<<"$o" || fail "arm-merge took $x: $o"
  o=$("$ORCHY" watch-merge "$p" "$SHA" "$l" "$r" 2>&1 || true); grep -q '^REFUSED: the ' <<<"$o" || fail "watch-merge took $x: $o"; done
o=$("$ORCHY" arm-merge 9 "$SHA" lane-9 r9.md "" "1;touch $T/pwn" 2>&1 || true); grep -qx 'refused: the delay is whole seconds' <<<"$o" || fail "a delay that is not seconds: $o"
[ ! -e "$T/pwn" ] || fail "a delay ran as shell"
# a pinned scan reads the content at that sha, and fails when the head is elsewhere before or after the reads
cmpfix "$SHA" "feat: y" x; mkpr "$SHA"; dr() { grep -c "^api repos/example/app/compare/dev...$SHA -H" "$MOCK_DIR/gh.log"; }
o=$("$ORCHY" scan 9 "$SHA"); grep -q '^#9 files=1 ' <<<"$o" && [ "$(dr)" = 1 ] || fail "a pinned scan at its head: $o"
! grep -q '^pr diff' "$MOCK_DIR/gh.log" || fail "a scan read the diff through the PR"
pr9 '.headRefOid="3333333333333333333333333333333333333333"'; o=$("$ORCHY" scan 9 "$SHA" || true); grep -qx 'SCAN FAILED: head moved' <<<"$o" || fail "a scan whose head moved: $o"
mkpr "$SHA"; printf '%s\n' "$SHA" 3333333333333333333333333333333333333333 > "$MOCK_DIR/heads-9.txt"; rc=0; o=$("$ORCHY" scan 9 "$SHA") || rc=$?; rm -f "$MOCK_DIR/heads-9.txt"
[ "$rc" = 2 ] && [ "$o" = 'SCAN FAILED: head moved' ] && [ "$(dr)" = 2 ] || fail "a head that moved during the reads (exit $rc): $o"
jq '.files = [{filename: "docs/ci.yml", previous_filename: ".github/workflows/ci.yml"}]' "$MOCK_DIR/cmp-$SHA.json" > "$tmp" && mv "$tmp" "$MOCK_DIR/cmp-$SHA.json"
o=$("$ORCHY" scan 9 "$SHA"); grep -qx '  GATE FILE: .github/workflows/ci.yml' <<<"$o" || fail "a workflow renamed away is not a gate file: $o"
jq '.total_commits = 251' "$MOCK_DIR/cmp-$SHA.json" > "$tmp" && mv "$tmp" "$MOCK_DIR/cmp-$SHA.json"
o=$("$ORCHY" scan 9 "$SHA" || true); grep -q '^SCAN FAILED: #9 is more than one compare lists' <<<"$o" || fail "a compare cut short: $o"
# scan --quick: past a quick lane's bounds is exit 3; a two-file change is within them
qs() { cmpfix "$SHA" "fix: q" "$@"; mkpr "$SHA"; rc=0; o=$("$ORCHY" scan 9 "$SHA" --quick) || rc=$?; }
qs src/a.ts src/a.test.ts; [ "$rc" = 0 ] && [ "$(tail -n 1 <<<"$o")" = 'QUICK: within bounds' ] || fail "a two-file change (exit $rc): $o"
for c in "biome.json|a gate file" "bun.lock|a lockfile" "Pipfile.lock|a lockfile" "package.json|a manifest" "src/1.ts src/2.ts src/3.ts src/4.ts src/5.ts src/6.ts|6 files"; do
  read -ra fs <<<"${c%%|*}"; qs "${fs[@]}"; [ "$rc" = 3 ] && [ "$(tail -n 1 <<<"$o")" = "QUICK: past the bounds: ${c#*|}" ] || fail "scan --quick on ${c%%|*} (exit $rc): $o"; done
qs src/a.ts src/b.ts src/c.ts src/d.ts src/e.ts $'src/a.ts\nsrc/b.ts'; [ "$rc" = 3 ] && [ "$(tail -n 1 <<<"$o")" = 'QUICK: past the bounds: 6 files' ] && grep -q '^#9 files=6 ' <<<"$o" || fail "a name with a newline hid a file (exit $rc): $o"
cp "$ORCHY_HOME/orchy.json" "$T/orchy.bak"; jq '.scan.gate_files = "biome\\.json"' "$T/orchy.bak" > "$ORCHY_HOME/orchy.json"
qs .github/workflows/ci.yml; cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"
[ "$rc" = 3 ] && [ "$(tail -n 1 <<<"$o")" = 'QUICK: past the bounds: a workflow' ] || fail "a workflow outside gate_files (exit $rc): $o"
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
# a removal that fails keeps the lane's hold; each success path ends it, and no other hold
"$ORCHY" hold add lane:y trunk >/dev/null || fail "hold add lane:y"; "$ORCHY" hold add lane:z trunk >/dev/null || fail "hold add lane:z"
git worktree lock .claude/worktrees/y; o=$(MOCK_AW_REFUSE=1 "$ORCHY" teardown y 2>&1 || true); git worktree unlock .claude/worktrees/y
grep -q 'hand removal failed' <<<"$o" && [ -d .claude/worktrees/y ] && "$ORCHY" hold list | grep -q '^lane:y ' || fail "a failed hand removal: $o"
o=$(MOCK_AW_REFUSE=1 "$ORCHY" teardown y 2>&1); grep -q 'hand-removed' <<<"$o" || fail "teardown did not remove an exact merged head: $o"
[ ! -d .claude/worktrees/y ] || fail "worktree y still there"
"$ORCHY" hold list --json | jq -e '[.holds[].ref] == ["lane:z"]' >/dev/null || fail "the hand removal's holds: $("$ORCHY" hold list)"
"$ORCHY" hold add lane:y trunk >/dev/null; "$ORCHY" teardown y >/dev/null || fail "teardown of a lane with no worktree"
"$ORCHY" wt-new y2 >/dev/null || fail "wt-new y2"; "$ORCHY" hold add lane:y2 trunk >/dev/null; "$ORCHY" teardown y2 >/dev/null || fail "teardown y2"
"$ORCHY" hold list --json | jq -e '[.holds[].ref] == ["lane:z"]' >/dev/null || fail "teardown's holds: $("$ORCHY" hold list)"
"$ORCHY" hold "done" lane:z >/dev/null; git worktree remove --force .claude/worktrees/y2; git branch -q -D worktree-y2
# a hotfix worktree starts from the release branch; bounced and clean, it tears down against that branch, though main holds a
# release commit dev lacks; a second hotfix lane starts from main too
m=$(git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit-tree -p origin/dev -m "release 1.4" "origin/dev^{tree}"); git push -q origin "$m:refs/heads/main"
cp "$ORCHY_HOME/orchy.json" "$T/cfg.bak"; jq '.merge.branches = {main: {method: "merge", required_checks: ["release-gate"]}}' "$T/cfg.bak" > "$ORCHY_HOME/orchy.json"
o=$("$ORCHY" wt-new hx --base feature-x 2>&1 || true); grep -q 'neither the trunk nor a merge.branches base' <<<"$o" && [ ! -d .claude/worktrees/hx ] || fail "wt-new on another base: $o"
"$ORCHY" wt-new hf --base main >/dev/null || fail "wt-new --base main"
[ "$(git -C .claude/worktrees/hf rev-parse HEAD)" = "$m" ] && [ "$(cat "$ORCHY_HOME/wt/hf.base")" = main ] || fail "wt-new --base main is at $(git -C .claude/worktrees/hf rev-parse --short HEAD)"
o=$(MOCK_AW_ANCESTRY=1 "$ORCHY" teardown hf 2>&1) && grep -qx 'done [^ ]*/hf --merged --trunk main' "$MOCK_DIR/aw.log" || fail "teardown of a hotfix lane against main: $o"
"$ORCHY" wt-new hf2 --base main >/dev/null && [ "$(git -C .claude/worktrees/hf2 rev-parse HEAD)" = "$m" ] || fail "a second hotfix lane's base"
echo keep > "$T/target"; ln -s "$T/target" "$ORCHY_HOME/wt/hx.base"; o=$("$ORCHY" wt-new hx --base main 2>&1 || true)
grep -q 'must be a regular file, not a link' <<<"$o" && [ "$(cat "$T/target")" = keep ] && [ ! -d .claude/worktrees/hx ] || fail "wt-new wrote through a planted base link: $o"
rm -f "$ORCHY_HOME/wt/hx.base"
echo feature-x > "$ORCHY_HOME/wt/hf2.base"; o=$("$ORCHY" teardown hf2 2>&1 || true); grep -q 'names neither the trunk nor a merge.branches base' <<<"$o" || fail "teardown on a planted base: $o"
for w in hf hf2; do git worktree remove --force ".claude/worktrees/$w"; git branch -q -D "worktree-$w"; done; cp "$T/cfg.bak" "$ORCHY_HOME/orchy.json"
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
[ "$(grep -c '' "$H2/events.jsonl")" = 1 ] && jq -e '.kind == "merge.disarmed" and .pr == 9' "$H2/events.jsonl" >/dev/null || fail "disarm event: $(cat "$H2/events.jsonl")"
[ "$(grep -cxE '[0-9]{2}:[0-9]{2}Z DISARMED' "$H2/watch/merge-9.out")" = 1 ] || fail "disarm did not write one DISARMED line: $(cat "$H2/watch/merge-9.out")"
sleep 1; [ ! -d "/proc/$wp2" ] || fail "the second home's watcher survived its own disarm"
c=$(cksum < "$H2/watch/merge-9.out"); ORCHY_HOME="$H2" "$ORCHY" disarm 9 | grep -q 'merge-9 not running' || fail "disarm of a dead watcher"
# a symlinked watch dir is refused before any pid file behind it is read
HS="$T/cap/hs"; mkdir -p "$HS" "$T/other-watch"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$HS/"; ln -s "$T/other-watch" "$HS/watch"
sleep 60 & so=$!; echo "$so $(awk '{print $22}' /proc/$so/stat)" > "$T/other-watch/merge-4.pid"; : > "$T/other-watch/merge-4.out"
if ORCHY_HOME="$HS" "$ORCHY" disarm 4 >/dev/null 2>&1; then fail "disarm followed a symlinked watch dir"; fi
[ -d "/proc/$so" ] && [ ! -s "$T/other-watch/merge-4.out" ] || fail "a refused disarm touched the watcher behind a symlinked watch dir"
kill "$so"; wait "$so" 2>/dev/null || true
[ "$(cksum < "$H2/watch/merge-9.out")" = "$c" ] && [ "$(grep -c '' "$H2/events.jsonl")" = 1 ] || fail "a dead watcher's disarm wrote its log or an event"
# snapshot shows a live watcher's newest marker after its pid, and nothing of a log without one
sleep 60 & sp=$!; echo "$sp $(awk '{print $22}' /proc/$sp/stat)" > "$ORCHY_HOME/watch/merge-31.pid"
printf '10:00Z MISSING REQUIRED CHECK (no run or status after 10 rounds): e2e\n10:02Z required ok=1/2\n' > "$ORCHY_HOME/watch/merge-31.out"
sleep 60 & sq=$!; echo "$sq $(awk '{print $22}' /proc/$sq/stat)" > "$ORCHY_HOME/watch/merge-32.pid"; printf '10:00Z required ok=1/2\n' > "$ORCHY_HOME/watch/merge-32.out"
o=$("$ORCHY" snapshot 2>&1)
if ! grep -qx "alive merge-31 pid $sp MISSING REQUIRED CHECK" <<<"$o" || ! grep -qx "alive merge-32 pid $sq" <<<"$o"; then fail "live watcher lines: $(grep '^alive merge-' <<<"$o")"; fi
kill "$sp" "$sq"; wait "$sp" "$sq" 2>/dev/null || true; rm -f "$ORCHY_HOME"/watch/merge-3[12].*
sleep 60 & hp=$!; echo "$hp $(awk '{print $22}' /proc/$hp/stat) 2026-01-01T00:00:00Z other" > "$ORCHY_HOME/orchestrator.lock"
if "$ORCHY" lock >/dev/null 2>&1; then fail "lock did not refuse a live holder"; fi
# a takeover file left by a killed contender never blocks the next one
touch "$ORCHY_HOME/orchestrator.lock.takeover"
kill $hp; wait $hp 2>/dev/null || true; "$ORCHY" lock | grep -q '^locked' || fail "lock did not replace a stale holder"; "$ORCHY" unlock >/dev/null
"$ORCHY" lock >/dev/null || fail "relock"
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
find "$HR/leads" "$HR/reports" "$HR/watch" -type f -exec touch -d 2026-10-24T03:00:00Z {} +
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
# the JSON views: one object each with its schema, the text's numbers, and a stable shape for pollers (goldens; volatile fields dropped)
G="$HERE/tests/mocks/orchy"
ORCHY_HOME="$HR" "$ORCHY" receipt --json --offline > "$T/r.json" || fail "receipt --json --offline"
diff <(jq -S . "$G/receipt.v1.json") <(jq -S . "$T/r.json") || fail "receipt JSON drifted from tests/mocks/orchy/receipt.v1.json"
ORCHY_HOME="$HR" "$ORCHY" state > "$T/s.json" || fail "state"
diff <(jq -S . "$G/state.v1.json") <(jq -S 'del(.at, .load1, .nproc)' "$T/s.json") || fail "state JSON drifted from tests/mocks/orchy/state.v1.json"
o=$(ORCHY_HOME="$HR" "$ORCHY" receipt --offline r); grep -qF 'issues closed ? (offline);' <<<"$o" || fail "offline receipt text: $o"
grep -q 'owner took' <"$T/r.json" && fail "receipt JSON carries the owner record"
HD="$T/cap/rcpt-d"; cp -r "$HR" "$HD"; echo "10:09Z DISARMED" >> "$HD/watch/merge-21.out"
ORCHY_HOME="$HD" "$ORCHY" receipt --offline r | grep -qF '(merged #21)' || fail "a DISARMED line after a merge hid it from the receipt"
# a fresh home stays empty under every reader, and a missing ledger is not created
HF="$T/cap/fresh"; mkdir -m 700 "$HF"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$HF/"
ORCHY_HOME="$HF" ORCHY_ASKS_DIR="$T/asks-none" "$ORCHY" state | jq -e '.schema == "orchy.state/1" and .leads == [] and .asks == [] and .waiting == []' >/dev/null || fail "state on a fresh home"
ORCHY_HOME="$HF" ORCHY_ASKS_DIR="$T/asks-none" "$ORCHY" receipt --offline >/dev/null || fail "receipt on a fresh home"
ORCHY_HOME="$HF" ORCHY_ASKS_DIR="$T/asks-none" "$ORCHY" ask list --json | jq -e '. == {schema: "orchy.asks/1", asks: []}' >/dev/null || fail "ask list on a missing ledger"
ORCHY_HOME="$HF" "$ORCHY" waiting list --json | jq -e '. == {schema: "orchy.waiting/1", waiting: []}' >/dev/null && [ -z "$(ORCHY_HOME="$HF" "$ORCHY" waiting list)" ] || fail "waiting list on a fresh home"
[ -z "$(find "$HF" -mindepth 1 ! -name orchy.json ! -name local.json)" ] && [ ! -e "$T/asks-none" ] || fail "a reader created $(find "$HF" -mindepth 1 ! -name orchy.json ! -name local.json) $(ls -d "$T/asks-none" 2>/dev/null)"
# one bad source never blanks the state: a huge triage list travels as a file, a junk stall setting takes the default
seq 0 29999 > "$HF/triaged.txt"; jq '.leads.stall_after_min = "oops"' "$HF/orchy.json" > "$T/o.json" && mv "$T/o.json" "$HF/orchy.json"
ORCHY_HOME="$HF" ORCHY_ASKS_DIR="$T/asks-none" "$ORCHY" state | jq -e '.triaged | length == 30000' >/dev/null || fail "state with a large triage list or a junk stall setting"
# waiting: one item per ref, replaced in place with its since kept; a refusal is one line and changes nothing; events carry the ref only
HV="$T/cap/hv"; mkdir -p "$HV"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$HV/"; V() { ORCHY_HOME="$HV" "$ORCHY" waiting "$@"; }
V add pr:12 "Rename the required check, then re-arm" >/dev/null && V add page:0 Sign page 0 >/dev/null || fail "waiting add"
V list --json | jq -e '.schema == "orchy.waiting/1" and [.waiting[] | keys] == [["ref", "since", "text"], ["ref", "since", "text"]] and [.waiting[].ref] == ["pr:12", "page:0"]
  and .waiting[1].text == "Sign page 0" and all(.waiting[].since; test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' >/dev/null || fail "waiting list --json: $(V list --json)"
jq '.waiting[0].since = "2026-01-01T00:00:00Z"' "$HV/waiting.json" > "$T/w.json" && mv "$T/w.json" "$HV/waiting.json"
V add pr:12 "Fix the branch rules, then re-arm" >/dev/null || fail "waiting add on an existing ref"
V list --json | jq -e '.waiting | length == 2 and .[0] == {ref: "pr:12", text: "Fix the branch rules, then re-arm", since: "2026-01-01T00:00:00Z"}' >/dev/null || fail "a second add did not replace the text in place and keep since: $(V list --json)"
V "done" pr:12 >/dev/null && V list --json | jq -e '[.waiting[].ref] == ["page:0"]' >/dev/null || fail "waiting done: $(V list --json)"
ORCHY_HOME="$HV" "$ORCHY" snapshot 2>&1 | sed -n '/^-- waiting/,/^--/p' | grep -qx 'page:0  [0-9]*m  Sign page 0' || fail "snapshot does not list the waiting record"
e160=$(printf 'é%.0s' $(seq 160)); V add pr:13 "$e160" >/dev/null && V "done" pr:13 >/dev/null || fail "160 code points were refused"
wb=$(md5sum "$HV/waiting.json" "$HV/events.jsonl")
bad=("pr:012" x "pr:1x" x "page:" x "lane:-x" x "other:$(printf 'a%.0s' $(seq 33))" x $'pr:1\npr:2' x "ask:7" x "pr:1234567890" x "other:acct-a" x
  pr:1 "" pr:1 "${e160}é" pr:1 $'a\tb' pr:1 $'a\xc2\x85b' pr:1 $'a\xe2\x80\xa8b' pr:1 $'a\xe2\x80\xaeb' pr:1 $'a\xe2\x81\xa6b' pr:1 $'\xff' pr:1 "Ask acct-a to log in again")
for ((i = 0; i < ${#bad[@]}; i += 2)); do o=$(V add "${bad[i]}" "${bad[i+1]}" 2>&1) && fail "waiting add accepted $(printf '%q %q' "${bad[i]}" "${bad[i+1]}")"
  [ "$(grep -c '' <<<"$o")" = 1 ] || fail "a waiting refusal is not one line: $o"; done
o=$(V "done" pr:12 2>&1) && fail "done succeeded on a ref nothing waits on: $o"
[ "$(md5sum "$HV/waiting.json" "$HV/events.jsonl")" = "$wb" ] || fail "a refused waiting command changed the record or the events"
ps=(); for i in 1 2 3 4 5 6; do ( V add "issue:$i" "Answer the question on issue $i" >/dev/null ) & ps+=($!); done; wait "${ps[@]}" || true
V list --json | jq -e '[.waiting[].ref | select(startswith("issue:"))] | sort == ["issue:1", "issue:2", "issue:3", "issue:4", "issue:5", "issue:6"]' >/dev/null || fail "concurrent adds lost an item: $(V list --json)"
jq -se '[.[] | select(.kind | startswith("waiting."))] | all(keys == ["at", "kind", "ref", "schema"])
  and [.[:4][] | [.kind, .ref]] == [["waiting.add", "pr:12"], ["waiting.add", "page:0"], ["waiting.add", "pr:12"], ["waiting.done", "pr:12"]]' "$HV/events.jsonl" >/dev/null || fail "waiting events: $(head -4 "$HV/events.jsonl")"
V add other:acct-z "Log in again" >/dev/null || fail "waiting add other:acct-z"
jq '.prompt_ban += "|acct-z"' "$HV/local.json" > "$T/l.json" && mv "$T/l.json" "$HV/local.json"; wb=$(md5sum "$HV/waiting.json" "$HV/events.jsonl")
o=$(V "done" other:acct-z 2>&1) && fail "done wrote a ref banned after its add into the events: $o"
[ "$(grep -c '' <<<"$o")" = 1 ] || fail "a waiting refusal is not one line: $o"
[ "$(md5sum "$HV/waiting.json" "$HV/events.jsonl")" = "$wb" ] || fail "a refused done changed the record or the events"
one='{"ref":"pr:1","text":"a","since":"2026-01-01T00:00:00Z"}'; ok="{\"schema\":\"orchy.waiting/1\",\"waiting\":[$one]}"
for m in '' "$ok"$'\n'"$ok" '{"schema":"orchy.waiting/1","waiting":[{"ref":"pr:1"}]}' "{\"schema\":\"orchy.waiting/1\",\"waiting\":[$one,$one]}" '{"schema":"orchy.waiting/1","waiting":[{"ref":"pr:1","text":"a","since":"bad-date"}]}'; do
  printf '%s' "$m" > "$HV/waiting.json"; wb=$(md5sum "$HV/waiting.json")
  V list --json >/dev/null 2>&1 && fail "waiting list read a malformed record: $m"
  ORCHY_HOME="$HV" "$ORCHY" state | jq -e '.waiting == null and (.errors | index("waiting"))' >/dev/null || fail "state over a malformed waiting record: $m"
  V add pr:2 "Merge it" >/dev/null 2>&1 && fail "waiting add replaced a malformed record: $m"; [ "$(md5sum "$HV/waiting.json")" = "$wb" ] || fail "waiting add changed a malformed record: $m"
done
ln -sf "$G/receipt/waiting.json" "$HV/waiting.json"; V list --json >/dev/null 2>&1 && fail "waiting list followed a symlink"
# an unmarked log orders by its mtime and the session's running total, never by file name
HL="$T/cap/legacy"; mkdir -p "$HL/leads"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$HL/"
for k in l-plan:1.0:2026-10-20T01:00:00Z l-a1:1.5:2026-10-20T02:00:00Z; do IFS=: read -r n c _ <<<"$k"; m=${k#*:*:}
  printf '{"type":"system","subtype":"init","session_id":"s-legacy"}\n{"type":"result","total_cost_usd":%s}\n' "$c" > "$HL/leads/$n.log"; touch -d "$m" "$HL/leads/$n.log"; done
ORCHY_HOME="$HL" "$ORCHY" receipt --json --offline | jq -e '[.lanes[0].runs[] | {key, cost_usd}] == [{key: "l-plan", cost_usd: 1.0}, {key: "l-a1", cost_usd: 0.5}] and .lanes[0].cost_usd == 1.5' >/dev/null \
  || fail "legacy run order: $(ORCHY_HOME="$HL" "$ORCHY" receipt --json --offline | jq -c '.lanes[0].runs')"
# a watcher's marker is its newest marker line, not its last line (a runs table follows REQUIRED FAILED, status lines follow a missing check)
mkdir -p "$HL/watch"; for n in 5 6 7 8; do echo "999999 1" > "$HL/watch/merge-$n.pid"; done
printf '10:00Z required ok=1/2\n10:01Z REQUIRED FAILED: lint\n| lint | failure |\n' > "$HL/watch/merge-5.out"
printf '10:00Z MISSING REQUIRED CHECK (no run or status after 10 rounds): e2e\n10:02Z required ok=1/2 report_done=yes state: MERGEABLE CLEAN\n' > "$HL/watch/merge-6.out"
printf '#7 state unreadable after the merge call; check it by hand\n' > "$HL/watch/merge-7.out"; printf '10:00Z TRUNK RED at 1234abcd: ci; waiting\n#8 MERGED 0123abc\n--- teardown x\n' > "$HL/watch/merge-8.out"
ORCHY_HOME="$HL" "$ORCHY" state | jq -e '[.watchers[] | {pr, marker}] == [{pr: 5, marker: "REQUIRED FAILED"}, {pr: 6, marker: "MISSING REQUIRED CHECK"}, {pr: 7, marker: "AMBIGUOUS"}, {pr: 8, marker: "MERGED"}]' >/dev/null \
  || fail "watcher markers: $(ORCHY_HOME="$HL" "$ORCHY" state | jq -c '[.watchers[] | {pr, marker, last}]')"
# a PR merged or closed by hand, or a disarm, ends the hand-back before it
HT="$T/cap/terminal"; mkdir -p "$HT/watch"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$HT/"; m='10:00Z MISSING REQUIRED CHECK (no run or status after 10 rounds): e2e'
printf '%s\n#2 is CLOSED; watcher stopped\n' "$m" > "$HT/watch/merge-2.out"; printf '%s\n10:05Z DISARMED\n' "$m" > "$HT/watch/merge-3.out"; printf '%s\n#9 is MERGED; watcher stopped\n' "$m" > "$HT/watch/merge-9.out"
# ...but only as whole lines: a check name carrying one leaves the hand-back standing
printf '%s 10:05Z DISARMED\n' "$m" > "$HT/watch/merge-1.out"; printf '%s #4 is MERGED; watcher stopped\n' "$m" > "$HT/watch/merge-4.out"
for n in 1 2 3 4 9; do echo "999999 1" > "$HT/watch/merge-$n.pid"; done
ORCHY_HOME="$HT" "$ORCHY" state | jq -e '[.watchers[] | {pr, marker}] == [{pr: 1, marker: "MISSING REQUIRED CHECK"}, {pr: 2, marker: null}, {pr: 3, marker: null}, {pr: 4, marker: "MISSING REQUIRED CHECK"}, {pr: 9, marker: "MERGED"}]' >/dev/null \
  || fail "terminal watcher lines: $(ORCHY_HOME="$HT" "$ORCHY" state | jq -c '[.watchers[] | {pr, marker, last}]')"
# a killed resume stamped in the same second as the run it resumes still counts its tokens
printf '%s\n' '{"type":"orchy_invocation","key":"t-a1","lane":"t","cmd":"launch","at":"2026-10-20T03:00:00Z"}' '{"type":"system","subtype":"init","session_id":"s-tie"}' \
  '{"type":"result","total_cost_usd":1.0}' '{"type":"orchy_invocation","key":"t-a1","lane":"t","cmd":"resume","at":"2026-10-20T03:00:00Z"}' \
  '{"type":"system","subtype":"init","session_id":"s-tie"}' '{"type":"assistant","message":{"id":"k1","usage":{"input_tokens":37}}}' > "$HL/leads/t-a1.log"
ORCHY_HOME="$HL" "$ORCHY" receipt --json --offline t | jq -e '.lanes[0] | .unpriced_tokens == 37 and ([.runs[].cost_usd] == [1.0, null])' >/dev/null \
  || fail "a same-second killed resume lost its tokens: $(ORCHY_HOME="$HL" "$ORCHY" receipt --json --offline t | jq -c '.lanes[0] | {unpriced_tokens, runs}')"
# an older, costlier session earlier in the same log never reorders a newer session's runs
printf '%s\n' '{"type":"system","subtype":"init","session_id":"s-old"}' '{"type":"result","total_cost_usd":10.0}' \
  '{"type":"orchy_invocation","key":"u-plan","lane":"u","cmd":"launch","at":"2026-10-20T04:00:00Z"}' '{"type":"system","subtype":"init","session_id":"s-new"}' '{"type":"result","total_cost_usd":1.0}' > "$HL/leads/u-plan.log"
printf '%s\n' '{"type":"orchy_invocation","key":"u-a1","lane":"u","cmd":"resume","at":"2026-10-20T04:00:00Z"}' '{"type":"system","subtype":"init","session_id":"s-new"}' '{"type":"result","total_cost_usd":1.5}' > "$HL/leads/u-a1.log"
ORCHY_HOME="$HL" "$ORCHY" receipt --json --offline u | jq -e '.lanes[0] | .cost_usd == 11.5 and ([.runs[] | select(.session == "s-new") | {key, cost_usd}] == [{key: "u-plan", cost_usd: 1.0}, {key: "u-a1", cost_usd: 0.5}])' >/dev/null \
  || fail "another session's total reordered a session: $(ORCHY_HOME="$HL" "$ORCHY" receipt --json --offline u | jq -c '.lanes[0] | {cost_usd, runs}')"
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
# a quick lane closes on its one report: delivered with its PR, or bounced, which reopens the ask for a planned lane
qa=$(A add "quick case"); A public "$qa" "Quick-lane requirement" >/dev/null; A lane "$qa" qk quick >/dev/null || fail "ask lane $qa qk quick"
printf 'LEAD_DONE\nPR #33 fix it ready checks: green\nHEAD %s\nCODEX: converged in 1 rounds\nOWNER_ASKS: none\nASKS: delivered %s\nPLAN: none\n' "$SHA" "$qa" > "$RP/qk-a1.md"
A close-lane qk >/dev/null || fail "close-lane qk"; [ "$(st "$qa")" = "done delivered in qk PR #33" ] || fail "a quick lane's delivery: $(st "$qa")"
qb=$(A add "bounce case"); A public "$qb" "Bounced requirement" >/dev/null; A lane "$qb" qb quick >/dev/null || fail "ask lane $qb qb quick"
printf 'LEAD_BLOCKED: needs a plan\nOWNER_ASKS: none\nASKS: left out %s needs a plan\nPLAN: none\n' "$qb" > "$RP/qb-a1.md"
A close-lane qb >/dev/null || fail "close-lane qb"; [ "$(st "$qb")" = "open lane qb closed without delivering it: needs a plan" ] || fail "a bounce did not reopen its ask: $(st "$qb")"
A lane "$qb" qb2 "planned after a bounce" >/dev/null || fail "a bounced ask was not laned again"
o=$("$ORCHY" wt-new qb 2>&1 || true); grep -q 'never reused' <<<"$o" || fail "wt-new reused a bounced lane: $o"
# a dispatch-only release delivers with no PR line
ra=$(A add "release case"); A public "$ra" "Release requirement" >/dev/null; A lane "$ra" rl release >/dev/null || fail "ask lane $ra rl release"
printf 'LEAD_DONE\nRELEASE: 2.3.0 complete\nASKS: delivered %s\nPLAN: none\n' "$ra" > "$RP/rl-a3.md"
A close-lane rl >/dev/null || fail "close-lane rl"; [ "$(st "$ra")" = "done delivered in rl" ] || fail "a delivery with no PR: $(st "$ra")"
# snapshot names asks by id and state only, flags an ask whose lane is gone, and lists no untriaged issue for an empty backlog
g=$(A add "my sister Ana wants the gone lane"); A public "$g" "Gone-lane requirement" >/dev/null; A lane "$g" gone-1 "a repo change" >/dev/null
echo '[]' > "$MOCK_DIR/issues.json"; : > "$ORCHY_HOME/triaged.txt"; "$ORCHY" snapshot > "$T/snap.out" 2>&1
sed -n '/^-- asks/,/^--/p' "$T/snap.out" | grep -q "^$g lane gone-1 .*lane closed: run ask close-lane gone-1" || fail "snapshot asks: $(sed -n '/^-- asks/,/^--/p' "$T/snap.out")"
grep -q 'Ana\|close-lane case' "$T/snap.out" && fail "snapshot printed an ask's text"
if sed -n '/^-- untriaged/,/^--/p' "$T/snap.out" | grep -q '^#'; then fail "untriaged issues listed for an empty backlog"; fi
r=$(A add "receipt case"); A public "$r" "Receipt requirement" >/dev/null; A lane "$r" r "a repo change" >/dev/null; A "done" "$r" "delivered" >/dev/null
o=$(ORCHY_HOME="$HR" "$ORCHY" receipt r); grep -qF "asks done 1 ($r)" <<<"$o" || fail "receipt asks: $o"
# readers write nothing: the home, the ledger and gh's log stay byte-for-byte; the state names asks by id and flags only
fp() { find "$HR" "$T/asks" -printf '%p %s %T@ %m\n' | sort; md5sum < "$MOCK_DIR/gh.log"; }
mkdir -p "$HR/runbooks"; printf -- '- [x] Publish the build\n- [ ] Announce it (proof: release v1.0.0)\n' > "$HR/runbooks/rb-r.md"
b=$(fp); R() { ORCHY_HOME="$HR" "$ORCHY" "$@" >/dev/null || fail "reader $*"; }
R state; R ask list; R ask list --all --json; R ask show "$r"; R receipt --offline; R receipt --json --offline; R waiting list; R waiting list --json; R accounts; R accounts --json; R grants; R grants --json; R hold list; R hold list --json; R runbook show rb-r; R goals; R goals --json
[ "$(fp)" = "$b" ] || fail "a reader changed the home, the ledger or gh.log: $(diff <(echo "$b") <(fp))"
"$ORCHY" state > "$T/st.json"; jq -e --arg g "$g" '.asks | any(.id == $g and .lane == "gone-1" and .has_public) and all(has("text") | not)' "$T/st.json" >/dev/null || fail "state asks: $(jq -c .asks "$T/st.json")"
grep -q 'Ana' "$T/st.json" && fail "state printed an ask's text"
"$ORCHY" ask list --json | jq -e --arg g "$g" '.schema == "orchy.asks/1" and (.asks | any(.id == $g and (.text | test("Ana")) and has("held") and has("age_s")))' >/dev/null || fail "ask list --json: $("$ORCHY" ask list --json | head -c 300)"
# launch and say: an ask reaches a lead only as its stored wording, laned there, not held, never copied from the owner
l=$(A add "Please add the greeting on the home page because my landlord asked twice"); A public "$l" "Show a greeting on the home page" >/dev/null; A lane "$l" x "a repo change" >/dev/null
lt() { printf 'You are a subagent.\n%s\n' "$1" > "$ORCHY_HOME/prompts/x-lt.md"; "$ORCHY" launch x-lt x acct-a 2>&1 || true; }
o=$(lt "$l: Show a greeting"); grep -q 'not its stored public wording' <<<"$o" || fail "launch with a reworded ask line: $o"
o=$(lt "$l: Show a greeting on the home page, a vulnerability fix"); grep -q 'SENSITIVE' <<<"$o" || fail "launch with a sensitive ask line: $o"
o=$(lt "$r: Receipt requirement"); grep -q "$r is not laned to x" <<<"$o" || fail "launch with another lane's ask: $o"
# a goal's line reaches a lead only once the orchestrator has written answered: ready and laned it
gq=$(A add "the beta list"); A public "$gq" "Beta: the onboarding fixes" >/dev/null; A goal "$gq" beta >/dev/null || fail "ask goal"
o=$(lt "$gq: Beta: the onboarding fixes"); grep -q "$gq is waiting: goal beta" <<<"$o" || fail "launch with a held goal's line: $o"
A note "$gq" "answered: ready" >/dev/null && A lane "$gq" x "a repo change" >/dev/null || fail "lane the ready goal"
o=$(lt "$gq: Beta: the onboarding fixes"); grep -q '^x-lt launched on acct-a' <<<"$o" || fail "launch with a ready goal's line: $o"; "$ORCHY" stop x-lt >/dev/null
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
"$ORCHY" unlock >/dev/null; L="$ORCHY_HOME/orchestrator.lock"; TOK="tok-$RANDOM$RANDOM"
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
# a live watcher's new hand-back wakes the wait once
mkdir -p "$HW/watch"; sleep 60 & sw=$!; echo "$sw $(awk '{print $22}' /proc/$sw/stat)" > "$HW/watch/merge-7.pid"; printf '10:00Z required ok=1/2\n' > "$HW/watch/merge-7.out"
w 3; echo "10:01Z MISSING REQUIRED CHECK (no run or status after 10 rounds): e2e" >> "$HW/watch/merge-7.out"
w 3; grep -q 'CHANGED (reports/leads/watchers)' "$T/w.out" || fail "a live watcher's new marker did not wake the wait: $(cat "$T/w.out")"
w 2; [ "$(cat "$T/w.out")" = "TIMEOUT after 2s, no change" ] || fail "a standing marker woke the wait again: $(cat "$T/w.out")"
kill "$sw"; wait "$sw" 2>/dev/null || true
rm -f "$MOCK_DIR/issues.json" "$MOCK_DIR/trunk.json"
# events: one orchy.event/1 line per hooked command, ids only; a relaunch keeps the failure it replaces; an unwritable log changes nothing
E="$ORCHY_HOME/events.jsonl"; en() { grep -c '' "$E"; }
one() { [ "$(en)" = $(( $1 + 1 )) ] && tail -1 "$E" | jq -e "$2" >/dev/null || fail "events after $3: $(tail -2 "$E")"; }
n=$(en); "$ORCHY" lock >/dev/null; one "$n" '.kind == "seat.lock"' lock
n=$(en); "$ORCHY" unlock >/dev/null; one "$n" '.kind == "seat.unlock"' unlock
"$ORCHY" lock >/dev/null
printf 'work\nARC_FAILED: gate red\nretry\nARC_FAILED: gate red again\n' > "$ORCHY_HOME/reports/x-ev.md"; printf 'You are a subagent.\n' > "$ORCHY_HOME/prompts/x-ev.md"
sha=$(printf 'ARC_FAILED: gate red again' | sha256sum | cut -d' ' -f1)
n=$(en); MOCK_LEAD_SECS=30 "$ORCHY" launch --force-cap x-ev x acct-b >/dev/null || fail "launch x-ev"
one "$n" ".kind == \"lead.launch\" and .key == \"x-ev\" and .lane == \"x\" and .prior == \"ARC_FAILED\" and .prior_failed_lines == 2 and .prior_failed_sha == \"$sha\"" "a relaunch over a failed report"
"$ORCHY" state | jq -e '.leads[] | select(.key == "x-ev") | .alive and .lane == "x" and .weight == "heavy" and (.newest.cmd | type) == "string" and (.quiet_s | type) == "number" and .stalled == false' >/dev/null || fail "state of a live lead: $("$ORCHY" state | jq -c '.leads')"
n=$(en); "$ORCHY" stop x-ev >/dev/null; one "$n" '.kind == "lead.stop" and .key == "x-ev"' stop
n=$(en); MOCK_LEAD_SECS=30 "$ORCHY" resume --force-cap x-ev x acct-b 00000000-0000-4000-8000-000000000009 >/dev/null || fail "resume x-ev"
one "$n" '.kind == "lead.resume" and .key == "x-ev" and .prior_failed_lines == 2' resume; "$ORCHY" stop x-ev >/dev/null; "$ORCHY" unlock >/dev/null
n=$(en); A add "an event row" >/dev/null; one "$n" '.kind == "ask.row" and (.ask | test("^ask[0-9]+$")) and .state == "open"' "ask add"
grep -q 'acct-\|event row\|gate red' "$E" && fail "an event carries an account name or text: $(grep 'acct-\|event row\|gate red' "$E")"
jq -se 'all(.schema == "orchy.event/1" and (.at | test("Z$")))' "$E" >/dev/null || fail "an event without its schema"
q() { sed '/^rc=/!s/[0-9]\{1,\}/N/g'; }   # numbers vary run to run; exit codes must not
w1=$({ "$ORCHY" lock; echo "rc=$?"; "$ORCHY" unlock; echo "rc=$?"; A add "writable"; echo "rc=$?"; } 2>&1 | q)
chmod 400 "$E"; n=$(en)
w2=$({ "$ORCHY" lock; echo "rc=$?"; "$ORCHY" unlock; echo "rc=$?"; A add "writable"; echo "rc=$?"; } 2>&1 | q); chmod 600 "$E"
[ "$w1" = "$w2" ] && [ "$(en)" = "$n" ] || fail "an unwritable events log changed output or exit codes: $(diff <(echo "$w1") <(echo "$w2"))"
# a symlink or a FIFO at the log's path is skipped: never followed, never waited on
mv "$E" "$T/ev.keep"; ln -s "$T/ev.elsewhere" "$E"; "$ORCHY" lock >/dev/null; "$ORCHY" unlock >/dev/null; [ ! -e "$T/ev.elsewhere" ] || fail "an event followed a symlink"
rm "$E"; mkfifo "$E"; timeout 10 "$ORCHY" lock >/dev/null || fail "an event waited on a FIFO"; timeout 10 "$ORCHY" unlock >/dev/null; rm "$E"; mv "$T/ev.keep" "$E"
# the account policy, in a home of its own: the never-lists, the orchestrator's own account and each reading decide; auto spends
# the headroom that expires soonest first, and a renamed account launches by its key
HA="$T/cap/acct"; CA="$T/cu-a"; PA="$T/acct-policy.json"; mkdir -p "$HA/prompts" .claude/worktrees/acc; cp "$ORCHY_HOME/orchy.json" "$HA/"
jq '.accounts = {use: ["p-bravo"], never: ["p-mike"]}' "$K/examples/local.example.json" > "$HA/local.json"
AC() { MOCK_LEAD_SECS=${MOCK_LEAD_SECS:-120} ORCHY_HOME="$HA" MOCK_CU="$CA" ORCHY_ACCOUNTS="$PA" "$ORCHY" "$@"; }
roster "$CA" p-echo p-alpha p-bravo p-charlie p-delta p-echo p-fox p-golf p-hotel p-india p-juliet p-kilo p-lima-new=p-lima p-mike p-oscar p-zulu
cu_rows() { { row p-alpha 60 20; row p-bravo 60 100; row p-charlie 20 5; row p-delta 90 100; row p-echo 90 100; row p-fox 25 150
  row p-golf 90 100 80 10800; row p-hotel 90 -1; row p-india 84 null; row p-juliet 90 100 80 60 "logged out"; row p-kilo 90 100 0
  row p-lima-new 40 100; row p-mike 90 100; row p-oscar 0 100; row main 10 50; } | jq -s . > "$CA/rows.json"; }
cu_rows; echo '{"schema": "orchy.accounts/1", "never": ["p-delta"]}' > "$PA"
for k in 1 2 3 4 5 6 7 8 9; do printf 'You are a subagent.\n' > "$HA/prompts/acc-a$k.md"; done
AC lock >/dev/null || fail "lock the policy home"
picked() { tail -1 "$MOCK_DIR/cu.log" | grep -oE '=[a-z-]+' | head -1; }
AC launch acc-a1 acc auto >/dev/null && [ "$(picked)" = =p-alpha ] || fail "auto did not spend the heavy headroom that expires soonest: $(tail -1 "$MOCK_DIR/cu.log")"
AC launch --light acc-a2 acc auto >/dev/null && [ "$(picked)" = =p-charlie ] || fail "a light auto did not take the account under the floor: $(tail -1 "$MOCK_DIR/cu.log")"
for x in "p-delta:on a never-list" "p-mike:on a never-list" "p-echo:the orchestrator runs on it" "p-juliet:claude-usage notes logged out" "p-kilo:its session is spent" "p-oscar:its week is spent"; do
  o=$(AC launch --light acc-a3 acc "${x%%:*}" 2>&1 || true); grep -qF "${x%%:*}: ${x#*:}" <<<"$o" || fail "launch on ${x%%:*}: $o"; done
for x in "p-charlie:week 20% is under the 25% floor" "p-golf:the reading is over 2 h old" "p-hotel:its week reset after the reading" "p-zulu:no reading in the snapshot"; do
  o=$(AC launch acc-a3 acc "${x%%:*}" 2>&1 || true); grep -qF "${x%%:*} takes light leads only: ${x#*:}" <<<"$o" || fail "a heavy launch on ${x%%:*}: $o"; done
AC launch acc-a3 acc p-fox >/dev/null || fail "exactly the floor is not heavy"
AC launch --light acc-a4 acc p-golf >/dev/null || fail "a stale reading refused a light lead"
AC launch --force-cap acc-a5 acc p-charlie >/dev/null || fail "--force-cap did not pass the floor"
o=$(AC launch --force-cap acc-a8 acc p-golf 2>&1 || true); grep -qx 'refused: p-golf takes light leads only: the reading is over 2 h old; --light' <<<"$o" || fail "--force-cap passed a stale reading: $o"
AC launch acc-a6 acc p-lima-new >/dev/null && [ "$(picked)" = =p-lima ] || fail "a renamed account did not launch by its key: $(tail -1 "$MOCK_DIR/cu.log")"
AC accounts --json | jq -e '.schema == "orchy.headroom/1" and .orchestrator == "p-echo" and ([.accounts[] | select(.verdict == "heavy") | .key] == ["p-alpha", "p-bravo", "p-india", "p-lima", "p-fox"])
  and (.accounts[] | select(.key == "p-echo") | .verdict == "no" and .why == "the orchestrator runs on it") and all(.accounts[]; (.why | length) > 0)
  and (.accounts[] | select(.key == "p-alpha") | .heavy_leads == 1) and ([.accounts[] | select(.floor) | .key] == ["p-charlie"])
  and ([.accounts[] | select(.key == "p-hotel" or .key == "p-zulu") | .verdict] == ["light", "light"])' >/dev/null || fail "accounts --json: $(AC accounts --json)"
AC accounts | grep -qE '^orchestrator: p-echo  week 90% session 80% resets in (99|100)h$' || fail "accounts text: $(AC accounts)"
echo main > "$CA/current.txt"; AC accounts | grep -q '^orchestrator: main  week 10% ' || fail "a slot orchestrator lost its reading: $(AC accounts)"; echo p-echo > "$CA/current.txt"
o=$(AC resume acc-a7 acc p-charlie 00000000-0000-4000-8000-000000000007 2>&1 || true); grep -q 'light leads only' <<<"$o" || fail "a heavy resume below the floor: $o"
AC resume --light acc-a7 acc p-charlie 00000000-0000-4000-8000-000000000007 >/dev/null || fail "a light resume below the floor"
for f in "" --light; do o=$(AC resume $f acc-a8 acc p-kilo 00000000-0000-4000-8000-000000000008 2>&1 || true); grep -q 'its session is spent' <<<"$o" || fail "a resume $f on a spent session: $o"; done
o=$(AC resume acc-a8 acc auto 00000000-0000-4000-8000-000000000008 2>&1 || true); grep -q "own account; name it" <<<"$o" || fail "resume took auto: $o"
mv "$CA/rows.json" "$T/rows.keep"; o=$(AC launch acc-a8 acc auto 2>&1 || true); mv "$T/rows.keep" "$CA/rows.json"; grep -q 'run claude-usage once' <<<"$o" || fail "launch without a snapshot: $o"
# the ban: every roster name, a label and its key alike, whether or not the bootstrap saw it; the slot label main never
printf 'Base the release PR on main\n' > "$T/main.md"; AC check-text "$T/main.md" >/dev/null || fail "check-text refused the branch main"
for n in p-bravo p-lima p-lima-new; do printf 'run it on %s.\n' "$n" > "$T/n.md"; AC check-text "$T/n.md" >/dev/null 2>&1 && fail "check-text passed the roster name $n"; done
printf 'see p-bravox and xp-bravo\n' > "$T/n.md"; AC check-text "$T/n.md" >/dev/null || fail "check-text matched a roster name inside a longer one"
jq '.prompt_ban = "\\b(main|acct-a)\\b"' "$HA/local.json" > "$T/l.json" && mv "$T/l.json" "$HA/local.json"
AC check-text "$T/main.md" >/dev/null 2>&1 && fail "the stored ban did not hold main before the resume"
AC lock | grep -q 'no longer bans the slot label main' || fail "the resume kept main in the stored ban"
[ "$(jq -r .prompt_ban "$HA/local.json")" = '\b(acct-a)\b' ] || fail "stored ban after the resume: $(jq -r .prompt_ban "$HA/local.json")"
AC check-text "$T/main.md" >/dev/null || fail "check-text refused main after the resume"
printf 'use acct-a\n' > "$T/n.md"; AC check-text "$T/n.md" >/dev/null 2>&1 && fail "the resume dropped acct-a from the ban"
echo '{"never": ["p-delta", "p-lima-new"]}' > "$PA"; for n in p-lima p-lima-new; do
  o=$(AC launch --light acc-a8 acc "$n" 2>&1 || true); grep -q 'on a never-list' <<<"$o" || fail "a never entry by label let $n launch: $o"; done
echo '{"schema": "orchy.accounts/1", "never": ["p-delta"]}' > "$PA"
# the policy file: missing is the defaults; malformed, foreign-shaped or symlinked refuses every reader
ORCHY_HOME="$HA" ORCHY_ACCOUNTS="$T/none.json" "$ORCHY" state | jq -e '.caps == {week_floor_pct: 25, heavy: 2, light: 3, load_max: 144}' >/dev/null || fail "state without a policy file"
B() { ORCHY_HOME="$HA" MOCK_CU="$CA" ORCHY_ACCOUNTS="$T/bad.json" "$ORCHY" "$@"; }
for m in '{"heavy_floor_pct": 101}' '[]' '{"x": 1}' '{"never": ["a b"]}' '{"schema": "orchy.accounts/2"}' '{"light_per_account": 1.5}' '{}{}' '' '{"never": false}' '{"never": ["p-delta\n"]}' '{"heavy_per_account": null}'; do
  printf '%s' "$m" > "$T/bad.json"; o=$(B accounts 2>&1) && fail "accounts read a malformed policy: $m"; grep -q 'not orchy.accounts/1' <<<"$o" || fail "accounts on $m: $o"; done
o=$(B launch --light acc-a8 acc auto 2>&1) && fail "launch read a malformed policy: $o"
B state | jq -e '.caps == null and (.errors | index("caps"))' >/dev/null || fail "state over a malformed policy"
ln -s "$PA" "$T/lnk.json"; LK() { ORCHY_HOME="$HA" MOCK_CU="$CA" ORCHY_ACCOUNTS="$T/lnk.json" "$ORCHY" "$@"; }
for c in accounts "launch --light acc-a8 acc auto"; do o=$(LK $c 2>&1) && fail "$c read a symlinked policy"; grep -q 'not a symlink' <<<"$o" || fail "$c on a symlinked policy: $o"; done
LK state | jq -e '.caps == null' >/dev/null || fail "state read a symlinked policy"
# the seat: only its holder spawns; two programs racing for an account's last heavy slot take that one and the next
for f in "$HA"/leads/*.started; do read -r p _ < "$f"; kill "$p" 2>/dev/null || true; done; sleep 1
for k in r0 r1 r2; do printf 'You are a subagent.\n' > "$HA/prompts/acc-$k.md"; done
HB="$T/cap/acct2"; mkdir -p "$HB/prompts"; cp "$HA/orchy.json" "$HA/local.json" "$HB/"; cp "$HA/prompts/acc-r2.md" "$HB/prompts/"
ORCHY_HOME="$HB" "$ORCHY" lock >/dev/null || fail "lock the racing home"
MOCK_LEAD_SECS=30 AC launch acc-r0 acc p-alpha >/dev/null || fail "first heavy lead on p-alpha"
: > "$T/race.log"; ( MOCK_LEAD_SECS=30 AC launch acc-r1 acc auto >> "$T/race.log" 2>&1 ) & r1=$!
( MOCK_LEAD_SECS=30 ORCHY_HOME="$HB" MOCK_CU="$CA" ORCHY_ACCOUNTS="$PA" "$ORCHY" launch acc-r2 acc auto >> "$T/race.log" 2>&1 ) & r2=$!; wait "$r1" "$r2" || true
[ "$(grep -oE ' on p-[a-z]+ ' "$T/race.log" | sort | tr -d ' ' | paste -sd, -)" = "onp-alpha,onp-bravo" ] || fail "two programs racing for the last slot: $(cat "$T/race.log")"
# a launch that waited on the spawn lock checks the seat again inside it
"$T/sess/claude" 600 & s2=$!; sess="$sess $s2"; exec {sl}>"$T/cap/.spawn.lock"; flock "$sl"
( exec {sl}>&-; AC launch --light acc-a9 acc auto > "$T/late.out" 2>&1 ) & lw=$!
w8=0; for _ in $(seq 300); do for q in $(pgrep -f 'orchy.sh launch --light acc-a9 acc auto'); do readlink /proc/"$q"/fd/* 2>/dev/null | grep -q 'spawn.lock$' && { w8=1; break 2; }; done; sleep 0.1; done
[ "$w8" = 1 ] || fail "the launch never reached the spawn lock: $(cat "$T/late.out")"; cp "$HA/orchestrator.lock" "$T/seat.keep"; echo "$s2 $(awk '{print $22}' /proc/$s2/stat) 2026-01-01T00:00:00Z - -" > "$HA/orchestrator.lock"
exec {sl}>&-; wait "$lw" || true; cp "$T/seat.keep" "$HA/orchestrator.lock"
grep -q 'does not hold the seat' "$T/late.out" || fail "a launch spawned after its seat changed hands: $(cat "$T/late.out")"
mkdir -p "$HA/watch"; sleep 60 & sw=$!; echo "$sw $(awk '{print $22}' /proc/$sw/stat)" > "$HA/watch/merge-41.pid"; printf '10:00Z required ok=1/2\n' > "$HA/watch/merge-41.out"
AC unlock | grep -qx unlocked || fail "unlock the policy home"
for c in "launch --light acc-a9 acc auto" "resume --light acc-a9 acc p-alpha 00000000-0000-4000-8000-000000000009"; do
  o=$(AC $c 2>&1 || true); grep -q 'no session holds the seat' <<<"$o" || fail "$c ran with no seat holder: $o"; done
CLAUDE_PID=$s2 AC lock | grep -q '^locked' || fail "another session could not take a handed-over seat"
for c in "launch --light acc-a9 acc auto" "resume --light acc-a9 acc p-alpha 00000000-0000-4000-8000-000000000009"; do
  o=$(AC $c 2>&1 || true); grep -q 'does not hold the seat' <<<"$o" || fail "the session that handed the seat over ran $c: $o"; done
"$T/sess/claude" 600 & s3=$!; sess="$sess $s3"
o=$(CLAUDE_PID=$s3 AC launch --light acc-a9 acc auto 2>&1 || true); grep -q "(pid $s3) does not hold the seat" <<<"$o" || fail "a session that never held the seat launched: $o"
: > "$MOCK_DIR/refresh.log"; o=$(CLAUDE_PID=$s2 AC snapshot 2>&1); grep -qx refresh "$MOCK_DIR/refresh.log" || fail "snapshot did not refresh the readings"; grep -q '^alive acc-r0 ' <<<"$o" && grep -qx "alive merge-41 pid $sw" <<<"$o" || fail "a handed-over seat lost a lead or a watcher: $o"
CLAUDE_PID=$s2 AC unlock >/dev/null; ORCHY_HOME="$HB" "$ORCHY" unlock >/dev/null; kill "$sw"; wait "$sw" 2>/dev/null || true
for f in "$T"/cap/*/leads/*.started; do read -r p _ < "$f"; kill "$p" 2>/dev/null || true; done; for f in "$MOCK_DIR"/gc.*; do kill "$(cat "$f")" 2>/dev/null || true; done
wait "$pgp" || { tail -n 20 "$T/page.log"; fail "page smoke"; }; pgp=
# no project names, home paths or roster names anywhere in the skills
if grep -rnE 'nulo|Nulo|program-2|program2|/mnt/user-data|/Users/|martu|proton|icloud|GzKw77' "$K" "$HERE/skills/pause-orchy" "$HERE/skills/my-stack" \
  "$HERE/tests/orchy-release-profile.test.ts" "$HERE/tests/live-orchy-release.sh" "$HERE/tests/mocks/orchy/release" --include='*.md' --include='*.sh' \
  --include='*.py' --include='*.js' --include='*.ts' --include='*.json' --include='*.cjs' --include='*.yml' --include='*.jq' --include=gh | grep -v 'page/fixtures' ; then
  fail "project-specific text in the skill"; fi
[ ! -e "$MOCK_DIR/locked.log" ] || fail "a call held holds.lock: $(cat "$MOCK_DIR/locked.log")"
echo "smoke-orchy: ok"
