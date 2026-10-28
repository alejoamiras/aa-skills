#!/usr/bin/env bash
# Smoke for start-orchy's release acts: the owner's go, OKs and grants in the ask ledger, act with watch-merge --act, and holds, against
# a throwaway home with a mocked gh. Every PR, run and tag is a fixture; nothing reaches GitHub.
set -eEuo pipefail
trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2' ERR
HERE=$(cd "$(dirname "$0")/.." && pwd); K="$HERE/skills/start-orchy"; ORCHY="$K/scripts/orchy.sh"
T=$(mktemp -d -t orchy-release-XXXX); trap '"$ORCHY" disarm >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export PATH="$HERE/tests/mocks/orchy:$PATH" MOCK_DIR="$T/mock" ORCHY_CAPACITY_ROOT="$T/cap" ORCHY_HOME="$T/cap/home" ORCHY_REPO=example/app \
  ORCHY_WATCH_SLEEP=1 ORCHY_ASKS_DIR="$T/asks" ORCHY_GITLEAKS=fake-gitleaks ORCHY_ACCOUNTS="$T/accounts.json"; mkdir -p "$MOCK_DIR/cu"
printf 'main %s\nacct-a %s\n' "$T/slot" "$T/a" > "$MOCK_DIR/cu/list.txt"; echo acct-a > "$MOCK_DIR/cu/current.txt"   # the roster check-public bans
git init -q -b dev "$T/repo"; cd "$T/repo"
# the promote fixture's profile as the bootstrap derives it: trunk dev, release branch main (merge only, its own check),
# release-please on main, v* tags made only by the release App, a publishing release.yml; here the back-sync's head is main
P=$(PATH="$HERE/tests/mocks/orchy/release:$PATH" RP_GH_LOG="$T/rp.log" RP_FIXTURES="$HERE/tests/mocks/orchy/release/promote" \
  bun "$K/scripts/release-profile.ts" --repo "$ORCHY_REPO") || fail "the promote fixture's derivation exited $?"
mkdir -p "$ORCHY_HOME"; jq --argjson p "$P" '.install = "true" | .merge.trunk_methods = ["squash", "merge"]
  | .merge.branches = {main: {method: "merge", required_checks: ["release-gate"]}, frozen: {method: "merge", required_checks: []}}
  | .release = ($p | .sync.head = "main")' "$K/examples/orchy.example.json" > "$ORCHY_HOME/orchy.json"
cp "$K/examples/local.example.json" "$ORCHY_HOME/local.json"
TS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; MC=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef   # the trunk head; the mock's merge commit
jq -n --arg s "$TS" '{sha: $s}' > "$MOCK_DIR/trunk.json"
jq -n '{check_runs: [{id: 1, name: "quality-status", status: "completed", conclusion: "success"}, {id: 2, name: "e2e-status", status: "completed", conclusion: "success"},
  {id: 3, name: "release-gate", status: "completed", conclusion: "success"}]}' > "$MOCK_DIR/checks.json"; jq -n '{statuses: []}' > "$MOCK_DIR/status.json"
for b in dev main; do echo '{"status": "ahead"}' > "$MOCK_DIR/compare-$b.json"; done
pr() { # pr <n> <head sha> <base> <head ref> [<jq edit>]
  jq -n --arg s "$2" --arg b "$3" --arg h "$4" '{state: "OPEN", isDraft: false, baseRefName: $b, headRefOid: $s, headRefName: $h, isCrossRepository: false,
    author: {login: "owner", is_bot: false}, mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", commits: []}' | jq "${5:-.}" > "$MOCK_DIR/pr-$1.json"; }
sha() { printf '%040d' "$1"; }
A() { "$ORCHY" ask "$@"; }
W() { "$ORCHY" act "$@" 2>&1; }   # act's refusals go to stderr
X() { o=$("$ORCHY" act "$@" 2>&1) && rc=0 || rc=$?; }   # sets o and rc, for the cases that check act's exit code
done_line() { # done_line <pr>: the watcher's last line, once it has ended (at most 60 s)
  for _ in $(seq 1 120); do grep -qE '^#[0-9]+ MERGED|REFUSED|HEAD MOVED|DIRTY|TIMEOUT|NOT MERGED' "$ORCHY_HOME/watch/merge-$1.out" 2>/dev/null && break; sleep 0.5; done
  tail -n 1 "$ORCHY_HOME/watch/merge-$1.out"; }
merges() { grep -c "^pr merge $1 " "$MOCK_DIR/gh.log" || true; }
used() { jq -Rc 'fromjson? | select(.note? and (.note | startswith("used: ")))' "$ORCHY_ASKS_DIR/example-app.jsonl" | grep -c -- "$1" || true; }
plant() { jq -nc --arg id "$1" --arg n "$2" '{id: $id, at: "2031-01-15T00:00:00Z", note: $n}' >> "$ORCHY_ASKS_DIR/example-app.jsonl"; }
ev0=0

# --- ledger rows: go, ok, grant, revoke, and the notes nothing else may write
a=$(A add "cut the stable release"); A public "$a" "Cut the stable release" >/dev/null; A lane "$a" release-7 release >/dev/null
[ -f "$ORCHY_HOME/events.jsonl" ] && ev0=$(wc -l < "$ORCHY_HOME/events.jsonl")
o=$(A go "$a" 2>&1 || true); grep -q "the owner's words follow --" <<<"$o" || fail "go without words: $o"
q=$(A add "an open ask"); A public "$q" "An open ask" >/dev/null
o=$(A go "$q" -- yes 2>&1 || true); grep -q 'a go needs a laned ask or a goal' <<<"$o" || fail "go on an ask neither laned nor a goal: $o"
A go "$a" -- "cut it and ship it" >/dev/null || fail "go"
A show "$a" | sed -n '/^-- history/,$p' | tail -n 1 | jq -e '.said == "cut it and ship it" and .note == "go"' >/dev/null || fail "a go row carries the words and the note together"
S1=$(sha 1); ok=$(A add "merge PR 41"); A public "$ok" "Merge PR 41" >/dev/null
for bad in "merge 41 abc main merge -- yes" "merge 41 $S1 main merge" "merge 41 $S1 main fastforward -- yes"; do
  read -ra w <<<"$bad"; o=$(A ok "$ok" "${w[@]}" 2>&1 || true); grep -q '^refused' <<<"$o" || fail "ask ok took $bad: $o"; done
for st in "done" drop; do x=$(A add "an ask to $st"); A public "$x" "An ask to $st" >/dev/null; A "$st" "$x" "closed" >/dev/null
  o=$(A ok "$x" merge 41 "$S1" main merge -- yes 2>&1 || true); grep -q 'does not apply' <<<"$o" || fail "ask ok on a $st ask: $o"; done
x=$(A add "a held ask"); A public "$x" "A held ask" >/dev/null; A note "$x" "waiting: wording" >/dev/null
o=$(A ok "$x" merge 41 "$S1" main merge -- yes 2>&1 || true); grep -q 'settle its wording first' <<<"$o" || fail "ask ok on a wording-held ask: $o"
A ok "$ok" merge 41 "$S1" main merge -- "yes, merge 41" >/dev/null || fail "ask ok"
h=$(A show "$ok" | sed -n '/^-- history/,$p' | tail -n 1); jq -e --arg s "$S1" '.said == "yes, merge 41" and .note == "ok: merge 41 \($s) main merge"' <<<"$h" >/dev/null || fail "ok row: $h"
! A show "$ok" | grep -q 'answered:' || fail "an OK with no hold wrote answered:"
y=$(A add "merge PR 50 when asked"); A public "$y" "Merge PR 50" >/dev/null; A note "$y" "waiting: ok merge 50" >/dev/null
A ok "$y" merge 50 "$S1" dev squash -- "go ahead" >/dev/null; A show "$y" | sed -n '/^-- history/,$p' | tail -n 1 | jq -e '.note == "answered: ok"' >/dev/null || fail "an OK after a waiting: hold did not answer it"
for c in "note|ok: merge 41 $S1 main merge" "done|used: merge 41 $S1 main merge" "note|go" "note|grant: merge dependabot dev squash"; do
  o=$(A "${c%%|*}" "$ok" "${c#*|}" 2>&1 || true); grep -q 'is written only by' <<<"$o" || fail "ask ${c%%|*} wrote ${c#*|}: $o"; done
x=$(A add "a done ask"); A public "$x" "A done ask" >/dev/null; A "done" "$x" "delivered" >/dev/null
A revoke "$x" >/dev/null || fail "revoke on a done ask"

# --- a go merges the four shapes once each, and nothing else
pr 41 "$S1" main dev; o=$(W merge 41 "$S1" main merge --lane release-7 || true); grep -qx "armed merge-41 (go $a)" <<<"$o" || fail "act merge on the go: $o"
o=$(done_line 41); [[ "$o" == "#41 MERGED $MC" ]] || fail "the promote did not merge: $o"
grep -qx "pr merge 41 --repo example/app --merge --match-head-commit $S1" "$MOCK_DIR/gh.log" || fail "the promote's merge call: $(grep '^pr merge 41' "$MOCK_DIR/gh.log")"
! grep -qE -- '--delete-branch|--admin' <(grep '^pr merge 41' "$MOCK_DIR/gh.log") || fail "an act merge passed --delete-branch or --admin"
[ "$(used "merge 41 $S1 main merge")" = 1 ] || fail "the promote's used: row"
o=$(W merge 41 "$S1" main merge --lane release-7 || true); grep -q 'has run merge 41 .* once; a retry needs a per-act OK' <<<"$o" || fail "the same act twice under a go: $o"
S2=$(sha 2); pr 41 "$S2" main dev; o=$(W merge 41 "$S2" main merge --lane release-7 || true); grep -q '^armed merge-41' <<<"$o" && [[ "$(done_line 41)" == "#41 MERGED"* ]] || fail "a new head under the same go: $o"
o=$(W merge 41 "$S1" main merge --ok "$a" || true); grep -q "no live OK on $a" <<<"$o" || fail "an OK nobody gave: $o"
A ok "$a" merge 41 "$S1" main merge -- "merge it once more" >/dev/null; pr 41 "$S1" main dev
o=$(W merge 41 "$S1" main merge --ok "$a" || true); grep -qx "armed merge-41 (OK $a)" <<<"$o" && [[ "$(done_line 41)" == "#41 MERGED"* ]] || fail "a per-act OK after the go's used: row: $o"
pr 41 "$S1" main dev; o=$(W merge 41 "$S1" main merge --ok "$a" || true); grep -q "no live OK on $a" <<<"$o" || fail "an OK covered a second retry: $o"
S3=$(sha 3); pr 45 "$S3" main feature-x; X merge 45 "$S3" main merge --lane release-7; [ "$rc" = 1 ] && grep -q 'none of the shapes a go merges' <<<"$o" || fail "a fifth shape under a go (exit $rc): $o"
o=$("$ORCHY" watch-merge 45 "$S3" --act main merge go "$a" release-7 2>&1 || true)
grep -qx "REFUSED: #45 is none of the shapes a go merges" <<<"$o" && [ "$(merges 45)" = 0 ] || fail "a watcher started by hand outside the shapes: $o"
S13=$(sha 13); pr 46 "$S13" main release-7-fix; o=$(W merge 46 "$S13" main merge --lane release-7 || true); grep -q '^armed' <<<"$o" && [[ "$(done_line 46)" == "#46 MERGED"* ]] || fail "the lane's own PR: $o"
pr 46 "$(sha 14)" main release-7-fix '.author = {login: "app/other", is_bot: true}'; o=$(W merge 46 "$(sha 14)" main merge --lane release-7 || true)
grep -q 'none of the shapes' <<<"$o" || fail "an app's PR on the lane's branch: $o"
S4=$(sha 4); pr 42 "$S4" main release-please--branches--main '.author = {login: "app/release-bot", is_bot: true}'
o=$(W merge 42 "$S4" main merge --lane release-7 || true); grep -q '^armed' <<<"$o" && [[ "$(done_line 42)" == "#42 MERGED"* ]] || fail "the release tool's PR: $o"
S5=$(sha 5); pr 44 "$S5" dev main; o=$(W merge 44 "$S5" dev merge --lane release-7 || true); grep -q '^armed' <<<"$o" && [[ "$(done_line 44)" == "#44 MERGED"* ]] || fail "the back-sync: $o"
cp "$ORCHY_HOME/orchy.json" "$T/orchy.bak"; jq '.release.tool.head = null' "$T/orchy.bak" > "$ORCHY_HOME/orchy.json"
S6=$(sha 6); pr 43 "$S6" main release-please--branches--main '.author = {login: "app/release-bot", is_bot: true}'
o=$(W merge 43 "$S6" main merge --lane release-7 || true); cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"; grep -q 'none of the shapes' <<<"$o" || fail "the tool's PR with tool.head unknown: $o"
o=$(W merge 43 "$S6" main merge --lane release-8 || true); grep -q 'no ask laned to release-8 has a live go' <<<"$o" || fail "--lane with no ask: $o"
b=$(A add "a second release ask"); A public "$b" "A second release ask" >/dev/null; A lane "$b" release-7 release >/dev/null; A go "$b" -- "this one too" >/dev/null
o=$(W merge 43 "$S6" main merge --lane release-7 || true); grep -q 'each have a live go on release-7' <<<"$o" || fail "two live gos on one lane: $o"
A revoke "$b" >/dev/null
c=$(A add "a release that moved"); A public "$c" "A release that moved" >/dev/null; A lane "$c" release-a release >/dev/null; A go "$c" -- "ship a" >/dev/null
A "done" "$c" "shipped" >/dev/null; A reopen "$c" "again" >/dev/null; A lane "$c" release-b release >/dev/null
o=$(W merge 43 "$S6" main merge --lane release-b || true); grep -q 'no ask laned to release-b has a live go' <<<"$o" || fail "a go that outlived done, reopen and a new lane: $o"
g=$(A add "a planted go"); A public "$g" "A planted go" >/dev/null; A lane "$g" release-p release >/dev/null; plant "$g" go
o=$(W merge 43 "$S6" main merge --lane release-p || true); grep -q 'no ask laned to release-p has a live go' <<<"$o" || fail "a planted go row: $o"

# --- approve, dispatch and tag under the go, each refusal before the call
run() { # run <id> <head> <event> <workflow> [<created_at>]: a run waiting on registry, started now unless named
  jq -n --arg h "$2" --arg e "$3" --arg w "$4" --arg c "${5:-$(date -u +%FT%TZ)}" '{status: "waiting", run_attempt: 1, event: $e, head_sha: $h, head_branch: "main", path: $w, created_at: $c}' > "$MOCK_DIR/run-$1.json"
  echo '[{"environment": {"id": 5, "name": "registry"}, "current_user_can_approve": true}]' > "$MOCK_DIR/pending-$1.json"; }
run 812 "$MC" push .github/workflows/release.yml
echo '[{"environment": {"id": 5, "name": "registry"}, "current_user_can_approve": true}]' > "$MOCK_DIR/pending-812.json"
rn() { jq "$1" "$MOCK_DIR/run-812.json" > "$T/run" && mv "$T/run" "$MOCK_DIR/run-812.json"; }
cp "$MOCK_DIR/run-812.json" "$T/run.ok"; cp "$MOCK_DIR/pending-812.json" "$T/pending.ok"
for c in '.status = "completed"|is completed' '.run_attempt = 2|at attempt 2' '.event = "pull_request_target"|came from pull_request_target' \
         '.head_sha = "1234567890123456789012345678901234567890"|is no run this go produced' '.created_at = "2020-01-01T00:00:00Z"|is no run this go produced'; do
  cp "$T/run.ok" "$MOCK_DIR/run-812.json"; rn "${c%%|*}"; X approve 812 1 registry --lane release-7; [ "$rc" = 1 ] && grep -q "${c#*|}" <<<"$o" || fail "approve with ${c%%|*} (exit $rc): $o"; done
cp "$T/run.ok" "$MOCK_DIR/run-812.json"
for p in '[]' '[{"environment": {"id": 5, "name": "registry"}, "current_user_can_approve": false}]'; do echo "$p" > "$MOCK_DIR/pending-812.json"
  o=$(W approve 812 1 registry --lane release-7 || true); grep -q 'is not waiting on this login' <<<"$o" || fail "approve, pending $p: $o"; done
cp "$T/pending.ok" "$MOCK_DIR/pending-812.json"
for b in dev main; do echo '{"status": "diverged"}' > "$MOCK_DIR/compare-$b.json"; done
o=$(W approve 812 1 registry --lane release-7 || true); grep -q 'on neither the trunk nor a merge.branches base' <<<"$o" || fail "approve on a diverged head: $o"
for b in dev main; do echo '{"status": "ahead"}' > "$MOCK_DIR/compare-$b.json"; done
[ ! -s "$MOCK_DIR/posts.log" ] || fail "a refused act reached a POST: $(cat "$MOCK_DIR/posts.log")"
o=$(W approve 812 1 registry --lane release-7 || true); grep -q "^approved run 812 attempt 1 for registry: .github/workflows/release.yml, push on main (go $a)$" <<<"$o" || fail "approve: $o"
grep -c 'runs/812/pending_deployments' "$MOCK_DIR/posts.log" | grep -qx 1 || fail "approve did not POST exactly once"
grep 'runs/812/pending_deployments' "$MOCK_DIR/posts.log" | cut -d' ' -f3- | jq -e '.environment_ids == [5] and (.environment_ids[0] | type) == "number" and .state == "approved"' >/dev/null || fail "the approval body: $(cat "$MOCK_DIR/posts.log")"
rn '.run_attempt = 2'; o=$(W approve 812 2 registry --lane release-7 || true); grep -q 'a retry needs a per-act OK' <<<"$o" || fail "a second approval of run 812 at registry under the go: $o"
A ok "$a" approve 812 2 registry -- "approve the re-run" >/dev/null; o=$(W approve 812 2 registry --ok "$a" || true); grep -q "^approved run 812 attempt 2 .*(OK $a)$" <<<"$o" || fail "a per-act OK for the re-run: $o"
A revoke "$a" >/dev/null; A go "$a" -- "go again" >/dev/null; run 817 "$MC" push .github/workflows/release.yml
o=$(W approve 817 1 registry --lane release-7 || true); grep -q 'is no run this go produced' <<<"$o" || fail "a replacement go approved what the revoked one produced: $o"
S7=$(sha 7); o=$(W dispatch .github/workflows/release.yml dev "$S7" version=1.4.0 --lane release-7 || true); grep -q "dev's head is aaaaaaaa, not 00000000" <<<"$o" || fail "dispatch at a moved ref: $o"
o=$(W dispatch .github/workflows/lint.yml dev "$TS" --lane release-7 || true); grep -q 'does not mark .github/workflows/lint.yml as publishing' <<<"$o" || fail "a go dispatched a workflow that publishes nothing: $o"
echo '{"workflow_run_id": 901}' > "$MOCK_DIR/dispatch.json"
o=$(W dispatch .github/workflows/release.yml dev "$TS" version=1.4.0 --lane release-7 || true); [ "$o" = "dispatched .github/workflows/release.yml at dev (aaaaaaaa): run 901 (go $a)" ] || fail "dispatch: $o"
[ "$(grep -c 'workflows/release.yml/dispatches' "$MOCK_DIR/posts.log")" = 1 ] && grep 'workflows/release.yml/dispatches' "$MOCK_DIR/posts.log" | cut -d' ' -f3- \
  | jq -e '. == {ref: "dev", inputs: {version: "1.4.0"}, return_run_details: true}' >/dev/null || fail "the dispatch's one POST: $(cat "$MOCK_DIR/posts.log")"
rm "$MOCK_DIR/dispatch.json"; o=$(W dispatch .github/workflows/release.yml dev "$TS" dry_run=true version=1.4.0 --lane release-7 || true); grep -q ': run unknown (go' <<<"$o" || fail "a dispatch answered 204: $o"
run 813 "$TS" workflow_dispatch .github/workflows/release.yml; run 814 "$TS" workflow_dispatch .github/workflows/release.yml 2020-01-01T00:00:00Z
run 815 "$TS" workflow_dispatch .github/workflows/deploy.yml; run 816 "$TS" push .github/workflows/release.yml
for c in "814|already waiting" "815|another workflow" "816|a push"; do o=$(W approve "${c%%|*}" 1 registry --lane release-7 || true)
  grep -q 'is no run this go produced' <<<"$o" || fail "approved a run at the dispatch's sha but ${c#*|}: $o"; done
o=$(W approve 813 1 registry --lane release-7 || true); grep -q "^approved run 813 attempt 1 .*workflow_dispatch on main (go $a)$" <<<"$o" || fail "the dispatch's own run: $o"
! grep -q -- ' -F ' "$MOCK_DIR/gh.log" || fail "-F reached gh"
echo '{"ref": "refs/tags/old"}' > "$MOCK_DIR/tag-old.json"
for c in "old|tag old exists" "v2|whose tags only the release tool creates"; do o=$(W tag "${c%%|*}" "$TS" --lane release-7 || true); grep -q "${c#*|}" <<<"$o" || fail "tag ${c%%|*}: $o"; done
o=$(W tag -x "$TS" --lane release-7 || true); grep -q 'refused: tag <name> <sha40>' <<<"$o" || fail "a tag name with a leading dash: $o"
for b in dev main; do echo '{"status": "diverged"}' > "$MOCK_DIR/compare-$b.json"; done
o=$(W tag build-7 "$TS" --lane release-7 || true); for b in dev main; do echo '{"status": "ahead"}' > "$MOCK_DIR/compare-$b.json"; done
grep -q 'on neither the trunk nor a merge.branches base' <<<"$o" || fail "a tag on an unreachable commit: $o"
jq 'del(.release.tags)' "$T/orchy.bak" > "$ORCHY_HOME/orchy.json"; o=$(W tag build-7 "$TS" --lane release-7 || true); cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"
grep -q 'release.tags is unknown' <<<"$o" || fail "a tag while release.tags is unknown: $o"
n=$(grep -c . "$MOCK_DIR/posts.log"); o=$(W tag build-7 "$TS" --lane release-7 || true); [ "$o" = "tagged build-7 at aaaaaaaa (go $a)" ] || fail "tag: $o"
[ "$(grep -c . "$MOCK_DIR/posts.log")" = $((n+1)) ] && tail -n 1 "$MOCK_DIR/posts.log" | grep -q '^POST repos/example/app/git/refs {"ref":"refs/tags/build-7","sha":"a' || fail "the tag's POST: $(tail -n 1 "$MOCK_DIR/posts.log")"
t=$(A add "tag build-8"); A public "$t" "Tag build-8" >/dev/null; A ok "$t" tag build-8 "$TS" -- "tag it" >/dev/null
( W tag build-8 "$TS" --ok "$t" > "$T/race.1" || true ) & ( W tag build-8 "$TS" --ok "$t" > "$T/race.2" || true ) & wait
[ "$(used "tag build-8 $TS")" = 1 ] && [ "$(grep -c 'refs/tags/build-8' "$MOCK_DIR/posts.log")" = 1 ] || fail "two acts raced on one OK: $(cat "$T"/race.?)"
for c in "post|1|refused: GitHub refused" "post-net|6|AMBIGUOUS" "post-timeout|6|AMBIGUOUS"; do IFS='|' read -r fm ex msg <<<"$c"; nm="build-$fm"
  t=$(A add "tag $nm"); A public "$t" "Tag $nm" >/dev/null; A ok "$t" tag "$nm" "$TS" -- "tag it" >/dev/null
  o=$(MOCK_GH_FAIL=$fm "$ORCHY" act tag "$nm" "$TS" --ok "$t" 2>&1) && rc=0 || rc=$?
  [ "$rc" = "$ex" ] && grep -q "^$msg" <<<"$o" && [ "$(used "tag $nm $TS")" = 1 ] || fail "a POST that failed as $fm (exit $rc): $o"; done

# --- act merge: refusals before any watcher, the OK's merge, a moved base, and an authority lost while the watcher waits
S8=$(sha 8); pr 48 "$S8" main hotfix-x
o=$(W merge 48 "$S8" main merge --ok "$ok" || true); grep -q "no live OK on $ok for merge 48" <<<"$o" && [ ! -e "$ORCHY_HOME/watch/merge-48.pid" ] || fail "an act without its authority: $o"
for c in "release merge|release is neither the trunk nor a merge.branches base" "frozen merge|frozen has no required check" "main squash|main takes merge, not squash"; do
  read -r bb mm <<<"${c%%|*}"; pr 48 "$S8" "$bb" hotfix-x; o=$(W merge 48 "$S8" "$bb" "$mm" --check || true); grep -q "${c#*|}" <<<"$o" || fail "act merge into $bb with $mm: $o"; done
f=$(A add "merge the fork"); A public "$f" "Merge the fork" >/dev/null; A ok "$f" merge 48 "$S8" main merge -- "merge it" >/dev/null
pr 48 "$S8" main hotfix-x '.isCrossRepository = true'; o=$(W merge 48 "$S8" main merge --ok "$f" || true); grep -q 'a fork never merges into main' <<<"$o" || fail "a fork into the release branch on an OK: $o"
pr 48 "$S8" main hotfix-x; o=$(W merge 48 "$S8" main merge --ok "$f" || true); grep -qx "armed merge-48 (OK $f)" <<<"$o" && [[ "$(done_line 48)" == "#48 MERGED"* ]] || fail "act merge on an OK: $o"
[ "$(used "merge 48 $S8 main merge")" = 1 ] || fail "the OK's used: row"
MH=$(sha 20); jq -n --arg s "$MH" '{sha: $s}' > "$MOCK_DIR/commit-main.json"
ck() { jq -n --arg q "$2" --arg r "$3" '{check_runs: [{id: 1, name: "quality-status", status: "completed", conclusion: $q}, {id: 3, name: "release-gate", status: "completed", conclusion: $r}]}' > "$MOCK_DIR/checks-$1.json"; }
S21=$(sha 21); u=$(A add "merge PR 51"); A public "$u" "Merge PR 51" >/dev/null; A ok "$u" merge 51 "$S21" main merge -- "merge 51" >/dev/null
pr 51 "$S21" main hotfix-q; ck "$S21" failure success; ck "$TS" failure success; ck "$MH" success failure
o=$(W merge 51 "$S21" main merge --ok "$u" || true); for _ in $(seq 1 60); do grep -q 'TRUNK RED' "$ORCHY_HOME/watch/merge-51.out" 2>/dev/null && break; sleep 0.5; done
grep -q "TRUNK RED at ${MH:0:8}: release-gate; waiting" "$ORCHY_HOME/watch/merge-51.out" && [ "$(merges 51)" = 0 ] || fail "a red release-gate on main's head did not hold: $(cat "$ORCHY_HOME/watch/merge-51.out")"
rm "$MOCK_DIR/checks-$MH.json"; [[ "$(done_line 51)" == "#51 MERGED"* ]] || fail "a merge into main read the trunk's checks: $(cat "$ORCHY_HOME/watch/merge-51.out")"
rm "$MOCK_DIR/checks-$TS.json" "$MOCK_DIR/commit-main.json"
S9=$(sha 9); r=$(A add "merge PR 49"); A public "$r" "Merge PR 49" >/dev/null; A ok "$r" merge 49 "$S9" main merge -- "merge 49" >/dev/null
pr 49 "$S9" main hotfix-y; echo . > "$MOCK_DIR/merge-race-49.jq"; o=$(W merge 49 "$S9" main merge --ok "$r" || true); l=$(done_line 49)
[[ "$l" == "#49 MERGED"* ]] && [ "$(merges 49)" = 2 ] && [ "$(used "merge 49 $S9 main merge")" = 1 ] || fail "a retry on a moved base claimed again or did not merge: $l"
wait_loop() { for _ in $(seq 1 60); do grep -q "commits/$1/check-runs" "$MOCK_DIR/gh.log" && return 0; sleep 0.5; done; fail "the watcher for $1 never polled"; }
S22=$(sha 22); v=$(A add "merge PR 53"); A public "$v" "Merge PR 53" >/dev/null; A ok "$v" merge 53 "$S22" main merge -- "merge 53" >/dev/null
pr 53 "$S22" main hotfix-r; echo . > "$MOCK_DIR/merge-race-53.jq"; ORCHY_WATCH_SLEEP=10 "$ORCHY" act merge 53 "$S22" main merge --ok "$v" >/dev/null   # a 5 s wait before the retry
for _ in $(seq 1 200); do [ "$(merges 53)" = 1 ] && break; sleep 0.1; done; A revoke "$v" merge 53 "$S22" main merge >/dev/null; l=$(done_line 53)
[[ "$l" == "REFUSED at merge time: merge 53 $S22 main merge was revoked before its retry" ]] && [ "$(merges 53)" = 1 ] || fail "a retry after a revoke: $l"
pend() { jq -n '{check_runs: [{id: 9, name: "release-gate", status: "in_progress", conclusion: null}]}' > "$MOCK_DIR/checks-$1.json"; }
for how in revoke "done"; do
  n=$((60 + ${#how})); s=$(sha "$n"); x=$(A add "merge PR $n"); A public "$x" "Merge PR $n" >/dev/null; A ok "$x" merge "$n" "$s" main merge -- "merge $n" >/dev/null
  pr "$n" "$s" main hotfix-z; pend "$s"; W merge "$n" "$s" main merge --ok "$x" >/dev/null; wait_loop "$s"
  if [ "$how" = revoke ]; then A revoke "$x" merge "$n" "$s" main merge >/dev/null; else A "done" "$x" "closed" >/dev/null; fi
  rm "$MOCK_DIR/checks-$s.json"; l=$(done_line "$n")
  [[ "$l" == "REFUSED at merge time: merge $n $s main merge is no longer authorized" ]] && [ "$(merges "$n")" = 0 ] || fail "an OK lost by $how while its watcher waited: $l"; done
S10=$(sha 10); pr 47 "$S10" main dev; pend "$S10"; W merge 47 "$S10" main merge --lane release-7 >/dev/null; wait_loop "$S10"
A revoke "$a" >/dev/null; d=$(A add "the release, again"); A public "$d" "The release, again" >/dev/null; A lane "$d" release-7 release >/dev/null; A go "$d" -- "go on" >/dev/null
rm "$MOCK_DIR/checks-$S10.json"; l=$(done_line 47)
[[ "$l" == "REFUSED at merge time: merge 47 $S10 main merge is no longer authorized" ]] && [ "$(merges 47)" = 0 ] || fail "a revoked go's watcher merged on another ask's go: $l"

# --- grants: Dependabot's own PRs into the trunk, nothing else, never an act text spent before
gr=$(A add "merge dependabot PRs"); A public "$gr" "Merge Dependabot PRs into dev" >/dev/null
o=$(A grant "$gr" merge dependabot main merge -- "x" 2>&1 || true); grep -q "into the trunk, dev" <<<"$o" || fail "a grant into a branch other than the trunk: $o"
A grant "$gr" merge dependabot dev squash -- "merge dependabot into dev yourself" >/dev/null
"$ORCHY" grants --json | jq -e --arg g "$gr" '.schema == "orchy.grants/1" and .grants == [{scope: "merge dependabot dev squash", ask: $g, since: .grants[0].since}]' >/dev/null || fail "grants --json: $("$ORCHY" grants --json)"
dep() { pr "$1" "$2" dev "${3:-dependabot/npm/x-1.2}" ".author = {login: \"${4:-app/dependabot}\", is_bot: true} | .commits = [{authors: [{login: \"${5:-dependabot[bot]}\"}]}]"; }
S11=$(sha 11); dep 70 "$S11"; o=$(W merge 70 "$S11" dev squash --grant || true); grep -qx "armed merge-70 (grant $gr)" <<<"$o" && [[ "$(done_line 70)" == "#70 MERGED"* ]] || fail "a Dependabot merge under the grant: $o"
[ "$(used "merge 70 $S11 dev squash under merge dependabot dev squash")" = 1 ] || fail "the grant's used: row"
dep 70 "$S11"; o=$(W merge 70 "$S11" dev squash --grant || true); grep -q 'a grant never covers it again' <<<"$o" || fail "a grant covered a spent act: $o"
S12=$(sha 12); for c in "owner|dependabot/x|dependabot[bot]" "app/dependabot|fix/x|dependabot[bot]" "app/dependabot|dependabot/x|someone"; do
  IFS='|' read -r au hd ca <<<"$c"; dep 71 "$S12" "$hd" "$au" "$ca"; o=$(W merge 71 "$S12" dev squash --grant || true)
  grep -q "not Dependabot's own PR" <<<"$o" || fail "a grant merged author $au, head $hd, commit $ca: $o"; done
for cm in '[{authors: [{login: "dependabot[bot]"}, {login: "someone"}]}]' '[{authors: [{login: "dependabot[bot]"}]}, {authors: [{login: "someone"}]}]'; do
  pr 71 "$S12" dev dependabot/x ".author = {login: \"app/dependabot\", is_bot: true} | .commits = $cm"; o=$(W merge 71 "$S12" dev squash --grant || true)
  grep -q "not Dependabot's own PR" <<<"$o" || fail "a grant merged commits $cm: $o"; done
# a revoke and a fresh go or grant during a retry's wait: the retry was the old authority's
S23=$(sha 23); pr 54 "$S23" main release-7-fix; dep 72 "$S23"; echo . > "$MOCK_DIR/merge-race-54.jq"; echo . > "$MOCK_DIR/merge-race-72.jq"
ORCHY_WATCH_SLEEP=16 "$ORCHY" act merge 54 "$S23" main merge --lane release-7 >/dev/null; ORCHY_WATCH_SLEEP=16 "$ORCHY" act merge 72 "$S23" dev squash --grant >/dev/null
for _ in $(seq 1 200); do [ "$(merges 54)$(merges 72)" = 11 ] && break; sleep 0.1; done
A revoke "$d" >/dev/null; A go "$d" -- "go on, again" >/dev/null; A revoke "$gr" merge dependabot dev squash >/dev/null; A grant "$gr" merge dependabot dev squash -- "merge them" >/dev/null
for p in "54|main merge" "72|dev squash"; do l=$(done_line "${p%%|*}")
  [[ "$l" == "REFUSED at merge time: merge ${p%%|*} $S23 ${p#*|} was revoked before its retry" ]] && [ "$(merges "${p%%|*}")" = 1 ] || fail "a retry revived by a fresh go or grant: $l"; done
A revoke "$gr" merge dependabot dev squash >/dev/null; dep 71 "$S12"; o=$(W merge 71 "$S12" dev squash --grant || true); grep -q 'no live grant' <<<"$o" || fail "a revoked grant: $o"
pg=$(A add "a planted grant"); A public "$pg" "A planted grant" >/dev/null; plant "$pg" "grant: merge dependabot dev squash"
o=$(W merge 71 "$S12" dev squash --grant || true); grep -q 'no live grant' <<<"$o" && "$ORCHY" grants --json | jq -e '.grants == []' >/dev/null || fail "a planted grant row: $o"
A said "$pg" "words on another row" >/dev/null; o=$(W merge 71 "$S12" dev squash --grant || true); grep -q 'no live grant' <<<"$o" || fail "a planted grant beside other said rows: $o"
po=$(A add "a planted ok"); A public "$po" "A planted OK" >/dev/null; A said "$po" "the owner said something else" >/dev/null; plant "$po" "ok: merge 71 $S12 dev squash"
o=$(W merge 71 "$S12" dev squash --ok "$po" || true); grep -q "no live OK on $po" <<<"$o" || fail "a planted ok row beside other said rows: $o"

# --- holds: an all hold stops new work and an act's call, a trunk hold only merges into the trunk; a call in flight ends first
o=$("$ORCHY" hold list); [ "$o" = "no holds" ] && [ ! -e "$ORCHY_HOME/holds.json" ] || fail "hold list: $o"
for c in "lane:../x trunk" "other:peer-Q all" "other:peer-q some"; do read -ra w <<<"$c"
  o=$("$ORCHY" hold add "${w[@]}" 2>&1 || true); grep -q '^refused' <<<"$o" || fail "hold add $c: $o"; done
echo '{"schema": "orchy.holds/1", "holds": [{"ref": "other:peer-q", "scope": "all"}]}' > "$ORCHY_HOME/holds.json"; echo '{"schema": "orchy.holds/1", "holds": []}' > "$T/holds.other"
for f in malformed symlink; do [ "$f" = symlink ] && ln -sf "$T/holds.other" "$ORCHY_HOME/holds.json"
  for c in list "add other:peer-q all"; do read -ra w <<<"$c"; o=$("$ORCHY" hold "${w[@]}" 2>&1 || true); grep -q '^refused' <<<"$o" || fail "hold $c on a $f holds.json: $o"; done; done
rm "$ORCHY_HOME/holds.json"; jq -e '.holds == []' "$T/holds.other" >/dev/null || fail "hold add wrote through a symlink"
"$ORCHY" hold add other:peer-q all >/dev/null || fail "hold add"
for c in "wt-new h1" "launch k1 h1 acct-a" "resume k1 h1 acct-a s1"; do read -ra w <<<"$c"
  o=$("$ORCHY" "${w[@]}" 2>&1 || true); [ "$o" = "refused: other:peer-q holds the program (ORCHY hold list)" ] || fail "$c under an all hold: $o"; done
hq=$(A add "approve run 830"); A public "$hq" "Approve run 830" >/dev/null; A ok "$hq" approve 830 1 registry -- "approve 830" >/dev/null; run 830 "$MC" push .github/workflows/release.yml
X approve 830 1 registry --ok "$hq"; [ "$rc" = 1 ] && [ "$o" = "refused: other:peer-q holds the program (ORCHY hold list)" ] && [ "$(used "approve 830")" = 0 ] || fail "approve under an all hold (exit $rc): $o"
"$ORCHY" hold "done" other:peer-q >/dev/null; o=$(W approve 830 1 registry --ok "$hq" || true); grep -q '^approved run 830 attempt 1' <<<"$o" || fail "the held approval, after hold done: $o"
# hold add returns only after a merge call already past its check has written its outcome; a watcher checking after it says HELD
S25=$(sha 25); x=$(A add "merge PR 82"); A public "$x" "Merge PR 82" >/dev/null; A ok "$x" merge 82 "$S25" main merge -- "merge 82" >/dev/null; pr 82 "$S25" main hotfix-m
MOCK_GH_MERGE_SLEEP=3 "$ORCHY" act merge 82 "$S25" main merge --ok "$x" >/dev/null
for _ in $(seq 1 200); do [ "$(merges 82)" = 1 ] && break; sleep 0.1; done; ! grep -q '^#82 MERGED' "$ORCHY_HOME/watch/merge-82.out" || fail "the merge call did not wait"
"$ORCHY" hold add other:peer-r all >/dev/null; grep -q '^#82 MERGED' "$ORCHY_HOME/watch/merge-82.out" || fail "hold add returned before the call in flight ended: $(cat "$ORCHY_HOME/watch/merge-82.out")"
"$ORCHY" hold "done" other:peer-r >/dev/null; S26=$(sha 26); y=$(A add "merge PR 83"); A public "$y" "Merge PR 83" >/dev/null; A ok "$y" merge 83 "$S26" main merge -- "merge 83" >/dev/null
pr 83 "$S26" main hotfix-n; c0=$(grep -c '/compare/.*\.\.\.main' "$MOCK_DIR/gh.log"); MOCK_GH_COMPARE_SLEEP=3 "$ORCHY" act merge 83 "$S26" main merge --ok "$y" >/dev/null
for _ in $(seq 1 200); do [ "$(grep -c '/compare/.*\.\.\.main' "$MOCK_DIR/gh.log")" -gt "$c0" ] && break; sleep 0.1; done; "$ORCHY" hold add other:peer-r all >/dev/null   # past its last poll
for _ in $(seq 1 60); do grep -q 'HELD: other:peer-r' "$ORCHY_HOME/watch/merge-83.out" && break; sleep 0.5; done
grep -q 'HELD: other:peer-r; waiting' "$ORCHY_HOME/watch/merge-83.out" && [ "$(merges 83)" = 0 ] || fail "a watcher past its poll when a hold landed: $(cat "$ORCHY_HOME/watch/merge-83.out")"
"$ORCHY" hold "done" other:peer-r >/dev/null; [[ "$(done_line 83)" == "#83 MERGED"* ]] || fail "the held watcher, after hold done: $(done_line 83)"
# under a trunk hold a lane watcher says HELD once and waits, while an act into main merges
"$ORCHY" hold add lane:release-7 trunk >/dev/null; mkdir -p "$ORCHY_HOME/reports"
S27=$(sha 27); pr 84 "$S27" dev worktree-hold-1; printf 'PR #84\nHEAD %s\nLEAD_DONE\n' "$S27" > "$ORCHY_HOME/reports/hold-1.md"
"$ORCHY" arm-merge 84 "$S27" hold-1 hold-1.md - >/dev/null; for _ in $(seq 1 60); do grep -q 'HELD' "$ORCHY_HOME/watch/merge-84.out" && break; sleep 0.5; done
S28=$(sha 28); z=$(A add "merge PR 85"); A public "$z" "Merge PR 85" >/dev/null; A ok "$z" merge 85 "$S28" main merge -- "merge 85" >/dev/null; pr 85 "$S28" main hotfix-o
W merge 85 "$S28" main merge --ok "$z" >/dev/null; [[ "$(done_line 85)" == "#85 MERGED"* ]] || fail "an act into main under a trunk hold: $(done_line 85)"
[ "$(grep -c 'HELD' "$ORCHY_HOME/watch/merge-84.out")" = 1 ] && [ "$(merges 84)" = 0 ] || fail "a lane watcher under a trunk hold: $(cat "$ORCHY_HOME/watch/merge-84.out")"
"$ORCHY" hold "done" lane:release-7 >/dev/null; for _ in $(seq 1 60); do grep -q '^#84 MERGED' "$ORCHY_HOME/watch/merge-84.out" && break; sleep 0.5; done
grep -q '^#84 MERGED' "$ORCHY_HOME/watch/merge-84.out" || fail "the lane watcher, after hold done: $(cat "$ORCHY_HOME/watch/merge-84.out")"
# an act's call in flight when a hold is added finishes first, as a merge call does
tq=$(A add "tag build-h"); A public "$tq" "Tag build-h" >/dev/null; A ok "$tq" tag build-h "$TS" -- "tag build-h" >/dev/null
c0=$(grep -c '^api repos/example/app/git/refs ' "$MOCK_DIR/gh.log" || true); MOCK_GH_POST_SLEEP=3 "$ORCHY" act tag build-h "$TS" --ok "$tq" > "$T/tag-h.out" 2>&1 & tp=$!
for _ in $(seq 1 200); do [ "$(grep -c '^api repos/example/app/git/refs ' "$MOCK_DIR/gh.log")" -gt "$c0" ] && break; sleep 0.1; done
"$ORCHY" hold add other:peer-t all >/dev/null; grep -q 'refs/tags/build-h' "$MOCK_DIR/posts.log" || fail "hold add returned before an act's call in flight ended"
wait "$tp" || true; grep -q '^tagged build-h' "$T/tag-h.out" || fail "the tag in flight: $(cat "$T/tag-h.out")"; "$ORCHY" hold "done" other:peer-t >/dev/null
[ ! -e "$MOCK_DIR/locked.log" ] || fail "a call held holds.lock: $(cat "$MOCK_DIR/locked.log")"

# --- triage mode refuses act; the acts above wrote only ask rows to the event log
jq '.mode = "triage"' "$T/orchy.bak" > "$ORCHY_HOME/orchy.json"; o=$(W tag build-9 "$TS" --check || true); cp "$T/orchy.bak" "$ORCHY_HOME/orchy.json"
grep -q 'mode is triage' <<<"$o" || fail "act in triage mode: $o"
k=$(tail -n +"$((ev0 + 1))" "$ORCHY_HOME/events.jsonl" | jq -r .kind | sort -u | paste -sd,); [ "$k" = ask.row ] || fail "the event log gained $k"
# --- a hotfix under its go: the lane's own PR into main merges with a merge commit; another head or an app's PR does not
hx=$(A add "hotfix the footer into main"); A public "$hx" "Hotfix the footer into main" >/dev/null; A lane "$hx" hotfix-2 hotfix >/dev/null
A go "$hx" -- "hotfix it into main" >/dev/null; S30=$(sha 30); pr 86 "$S30" main worktree-hotfix-2
W merge 86 "$S30" main merge --lane hotfix-2 >/dev/null; [[ "$(done_line 86)" == "#86 MERGED"* ]] && grep -q "^pr merge 86 .*--merge --match-head-commit $S30" "$MOCK_DIR/gh.log" \
  || fail "the hotfix PR under its go: $(done_line 86)"
S31=$(sha 31); pr 87 "$S31" main fix/x; o=$(W merge 87 "$S31" main merge --lane hotfix-2 || true); grep -q 'none of the shapes a go merges' <<<"$o" || fail "a hotfix from another head: $o"
pr 87 "$S31" main worktree-hotfix-2 '.author = {login: "app/other", is_bot: true}'; o=$(W merge 87 "$S31" main merge --lane hotfix-2 || true)
grep -q 'none of the shapes a go merges' <<<"$o" && [ "$(merges 87)" = 0 ] || fail "an app's PR on the hotfix branch: $o"

# --- runbooks: the owner's own steps behind one record that says what is next; check ticks what a run or a release proves
w() { "$ORCHY" waiting list --json | jq -r --arg r "other:$1" '.waiting[] | select(.ref == $r) | .text'; }
rbadd() { o=$("$ORCHY" runbook add "$1" "$2" 2>&1) && rc=0 || rc=$?; }
printf 'Publish the build in the store\n' > "$T/rb1.md"; printf -- '- [ ] Check it (proof: curl https://example.com)\n' > "$T/rb2.md"
printf -- '- [ ] Check the notes (proof: release -Rx/y)\n' > "$T/rb3.md"; for i in $(seq 1 21); do printf -- '- [ ] Step %s\n' "$i"; done > "$T/rb4.md"
printf -- '- [ ] Bad\001step\n' > "$T/rb5.md"
for c in "rb1|is not '- \[ \] <step>'" "rb2|a proof is" "rb3|a release proof names a tag" "rb4|not 21" "rb5|carries a control"; do
  rbadd rel-7 "$T/${c%%|*}.md"; [ "$rc" = 1 ] && grep -q -- "${c#*|}" <<<"$o" || fail "runbook add took ${c%%|*}: $o"; done
[ ! -e "$ORCHY_HOME/runbooks/rel-7.md" ] && [ -z "$(w rel-7)" ] || fail "a refused runbook left a file or a record"
printf -- '- [ ] Publish the staged build in the store dashboard\n- [ ] Answer the store review\n- [ ] Announce the release\n' > "$T/rb6.md"
rbadd rel-7 "$T/rb6.md"; [ "$rc" = 0 ] && [ "$(w rel-7)" = "0 of 3 done; next: Publish the staged build in the store dashboard" ] || fail "runbook add: $o; $(w rel-7)"
"$ORCHY" runbook tick rel-7 1 >/dev/null; [ "$(w rel-7)" = "1 of 3 done; next: Answer the store review" ] || fail "tick: $(w rel-7)"
# a record that cannot be written leaves the runbook as it was; the tick of step 2 below retries both
cp -p "$ORCHY_HOME/waiting.json" "$T/waiting.keep"; ln -sf "$T/waiting.keep" "$ORCHY_HOME/waiting.json"
o=$("$ORCHY" runbook tick rel-7 2 2>&1) && rc=0 || rc=$?; rm -f "$ORCHY_HOME/waiting.json"; mv "$T/waiting.keep" "$ORCHY_HOME/waiting.json"
[ "$rc" != 0 ] && grep -q 'must be a regular file' <<<"$o" && "$ORCHY" runbook show rel-7 | grep -qx '2. \[ \] Answer the store review' && [ "$(w rel-7)" = "1 of 3 done; next: Answer the store review" ] \
  || fail "a failed record update ticked the runbook: $o"
o=$("$ORCHY" runbook tick rel-7 1 2>&1 || true); grep -q 'already done' <<<"$o" || fail "a step ticked twice: $o"
o=$("$ORCHY" runbook tick rel-7 4 2>&1 || true); grep -q 'has no step 4' <<<"$o" || fail "a step past the end: $o"
"$ORCHY" runbook tick rel-7 3 >/dev/null; "$ORCHY" runbook tick rel-7 2 >/dev/null; [ -z "$(w rel-7)" ] || fail "the last tick left the record: $(w rel-7)"
printf -- '- [ ] Run the store check (proof: run 901)\n- [ ] Publish the release notes (proof: release v1.4.0)\n- [ ] Confirm the listing\n' > "$T/rb7.md"
rbadd rel-8 "$T/rb7.md"; [ "$rc" = 0 ] || fail "runbook add with proofs: $o"
# a run not completed though its conclusion reads success; a draft though it carries a publication time; a release without
# a draft flag, or with a publication time that does not parse
echo '{"status": "in_progress", "conclusion": "success"}' > "$MOCK_DIR/run-901.json"; "$ORCHY" runbook check rel-8 > "$T/chk.out"
echo '{"status": "completed", "conclusion": "failure"}' > "$MOCK_DIR/run-901.json"; jq -n '{draft: true, published_at: "2031-01-15T00:00:00Z"}' > "$MOCK_DIR/release-v1.4.0.json"
"$ORCHY" runbook check rel-8 >> "$T/chk.out"
for r in '{published_at: "2031-01-15T00:00:00Z"}' '{draft: false, published_at: "2031-01-15T"}'; do
  jq -n "$r" > "$MOCK_DIR/release-v1.4.0.json"; "$ORCHY" runbook check rel-8 >> "$T/chk.out"; done
[ "$(w rel-8)" = "0 of 3 done; next: Run the store check" ] && "$ORCHY" runbook show rel-8 | grep -qx '1. \[ \] Run the store check (proof: run 901)' || fail "check ticked an unproven step: $(cat "$T/chk.out")"
for l in 'run 901: in_progress success' 'release v1.4.0: not published' 'release v1.4.0: a draft' 'release v1.4.0: unreadable'; do
  grep -q "^step [12]: $l\$" "$T/chk.out" || fail "check's lines lack '$l': $(cat "$T/chk.out")"; done
echo '{"status": "completed", "conclusion": "success"}' > "$MOCK_DIR/run-901.json"; jq -n '{draft: false, published_at: "2031-01-15T00:00:00Z"}' > "$MOCK_DIR/release-v1.4.0.json"
"$ORCHY" runbook check rel-8 >/dev/null; [ "$(w rel-8)" = "2 of 3 done; next: Confirm the listing" ] || fail "check after the run succeeded and the release published: $(w rel-8)"
"$ORCHY" snapshot 2>/dev/null | sed -n '/^-- runbooks/,/^--/p' | grep -qx 'rel-8 2/3' || fail "the snapshot's runbooks: $("$ORCHY" snapshot 2>&1 | sed -n '/^-- runbooks/,/^--/p')"
# --- goals: a milestone with its title only, the date kept in the ledger, ready only when the work is done
G=2031-01-15; g=$(A add "before launch: the listing copy, then ship it"); A public "$g" "Launch: the listing copy, then the release" >/dev/null
for c in "Launch!|a name is" "launch on 2031-02-30|not a calendar date" "launch by 2031-01-01 on $G|at most one date" \
  "launch on $G then party|the only end action" "launch-$G on $G|carries its date"; do
  read -ra av <<<"${c%%|*}"; o=$(A goal "$g" "${av[@]}" 2>&1 || true); grep -q -- "${c#*|}" <<<"$o" || fail "ask goal ${c%%|*}: $o"; done
o=$(A note "$g" "goal: x" 2>&1 || true); grep -q 'written only by' <<<"$o" || fail "a goal note by hand: $o"
d=$(A add "a dated ask"); A public "$d" "Ship it before January 15" >/dev/null
o=$(A goal "$d" launch on "$G" 2>&1 || true); grep -q "carries the goal's date" <<<"$o" || fail "ask goal over a dated public text: $o"
: > "$MOCK_DIR/posts.log"; A goal "$g" launch on "$G" "then" release >/dev/null || fail "ask goal"
[ "$(grep -c "\"id\":\"$g\".*\"note\":\"goal: " "$ORCHY_ASKS_DIR/example-app.jsonl")" = 1 ] || fail "ask goal wrote other than one goal row"
[ "$(cat "$MOCK_DIR/posts.log")" = 'POST repos/example/app/milestones {"title":"launch"}' ] || fail "the milestone POST: $(cat "$MOCK_DIR/posts.log")"
! grep -q -- "$G" "$MOCK_DIR/gh.log" "$MOCK_DIR/posts.log" || fail "the goal's date left the ledger: $(grep -h -- "$G" "$MOCK_DIR/gh.log" "$MOCK_DIR/posts.log")"
o=$(A public "$g" "Launch on 15 Jan: the listing copy" 2>&1 || true); grep -q "never carries the goal's date" <<<"$o" || fail "ask public with the date: $o"
jq -n '[{title: "launch", open_issues: 5, closed_issues: 4}, {title: "beta", open_issues: 0, closed_issues: 3}]' > "$MOCK_DIR/milestones.json"
: > "$MOCK_DIR/posts.log"; A goal "$g" launch on "$G" "then" release >/dev/null && [ ! -s "$MOCK_DIR/posts.log" ] || fail "ask goal on an existing milestone posted: $(cat "$MOCK_DIR/posts.log")"
jq -n '[range(100) | {title: "m\(.)", open_issues: 0, closed_issues: 0}]' > "$T/ms100.json"; cp "$MOCK_DIR/milestones.json" "$T/ms.keep"; cp "$T/ms100.json" "$MOCK_DIR/milestones.json"
o=$(A goal "$d" other 2>&1 || true); cp "$T/ms.keep" "$MOCK_DIR/milestones.json"; grep -q '100 milestones or more' <<<"$o" && [ ! -s "$MOCK_DIR/posts.log" ] || fail "ask goal past a page of milestones: $o"
printf -- '- [ ] Publish the listing copy\n- [ ] Check the store preview\n- [ ] Confirm the launch post\n' > "$T/goal.md"
"$ORCHY" runbook add goal-launch "$T/goal.md" >/dev/null && "$ORCHY" runbook tick goal-launch 1 >/dev/null
fp() { find "$ORCHY_HOME" "$ORCHY_ASKS_DIR" -printf '%p %s %T@ %m\n' | sort | sha256sum; }
f0=$(fp); gj=$("$ORCHY" goals --json); "$ORCHY" goals >/dev/null; [ "$(fp)" = "$f0" ] || fail "goals wrote something"
jq -e --arg g "$g" '.schema == "orchy.goals/1" and (.goals[] | select(.ask == $g) | .milestone == {open: 5, closed: 4} and .runbook == {done: 1, steps: 3}
  and .kind == "on" and .then == "release" and .ready == false)' <<<"$gj" >/dev/null || fail "goals --json: $gj"
"$ORCHY" snapshot 2>/dev/null | sed -n '/^-- goals/,/^--/p' | grep -qx 'goal launch 4/9 runbook 1/3' || fail "the snapshot's goals: $("$ORCHY" snapshot 2>&1 | sed -n '/^-- goals/,/^--/p')"
# a goal waits for its work: the go leaves it held, and no lane takes it until the orchestrator writes answered: ready
A go "$g" -- "launch it and ship" >/dev/null || fail "ask go on an open goal ask"
A list --json | jq -e --arg g "$g" '.asks[] | select(.id == $g) | .held == "waiting: goal launch"' >/dev/null || fail "the go released the goal's hold"
o=$(A lane "$g" release-8 release 2>&1 || true); grep -q 'waiting: goal launch' <<<"$o" || fail "a held goal was laned: $o"
# ready: a by-goal once its milestone and runbook are done, an on-goal also once its day comes, a laned goal never
ms() { jq -n --argjson b "$1" '[{title: "launch", open_issues: 0, closed_issues: 9}, {title: "beta", open_issues: $b, closed_issues: 3}]' > "$MOCK_DIR/milestones.json"; }; ms 1
"$ORCHY" runbook tick goal-launch 2 >/dev/null; "$ORCHY" runbook tick goal-launch 3 >/dev/null
b=$(A add "the beta, by the date"); A public "$b" "Beta: the onboarding fixes" >/dev/null; A goal "$b" beta by "$G" >/dev/null
r() { "$ORCHY" goals --json | jq -r --arg a "$1" '.goals[] | select(.ask == $a) | .ready'; }
[ "$(r "$b")" = false ] || fail "ready with an open milestone issue"; ms 0
printf -- '- [ ] Post the beta notes\n' > "$T/beta.md"; "$ORCHY" runbook add goal-beta "$T/beta.md" >/dev/null; [ "$(r "$b")" = false ] || fail "ready with a runbook step open"
"$ORCHY" runbook tick goal-beta 1 >/dev/null; [ "$(r "$g")/$(r "$b")" = false/true ] || fail "ready: launch $(r "$g"), beta $(r "$b")"
d0=$(date -u +%F); dl=$("$ORCHY" goals --json | jq -r --arg a "$g" '.goals[] | select(.ask == $a) | .days')
[ "$dl" = $(( ($(date -ud "$G" +%s) - $(date -ud "$d0" +%s)) / 86400 )) ] || fail "days to the launch: $dl"
A go "$b" -- "ship the beta" >/dev/null && A note "$b" "answered: ready" >/dev/null && A lane "$b" release-9 release >/dev/null || fail "lane the ready goal"
[ "$(r "$b")" = false ] || fail "a laned goal is still ready"
pr 95 "$(sha 95)" main dev; o=$(W merge 95 "$(sha 95)" main merge --lane release-9 --check)
[ "$o" = "checked: merge 95 $(sha 95) main merge (go $b)" ] || fail "the goal's go on its release lane: $o"
echo "smoke-orchy-release: ok"
