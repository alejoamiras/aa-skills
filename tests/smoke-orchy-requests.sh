#!/usr/bin/env bash
# Smoke for start-orchy's requests: request add|note|stale|done|withdraw|list|show against a throwaway home and ask folder,
# the waiting projection, the refusals, and the viewers' bare PATH. claude-usage and gitleaks are mocks.
set -eEuo pipefail
trap 'echo "FAIL: line $LINENO: $BASH_COMMAND" >&2' ERR
HERE=$(cd "$(dirname "$0")/.." && pwd); K="$HERE/skills/start-orchy"; ORCHY="$K/scripts/orchy.sh"; G="$HERE/tests/mocks/orchy"
T=$(mktemp -d -t orchy-requests-XXXX); ps=(); trap '[ ${#ps[@]} = 0 ] || kill "${ps[@]}" 2>/dev/null || true; rm -rf "$T"' EXIT
flunk() { echo "FAIL: $*" >&2; exit 1; }
# the viewer's unit passes PATH, HOME and, per call, ORCHY_HOME, ORCHY_REPO and ORCHY_ROOT, so everything else sits at
# its default under the viewer's HOME
VH="$T/vh"; export PATH="$G:$PATH" MOCK_DIR="$T/mock" ORCHY_CAPACITY_ROOT="$VH/.cache/orchy" ORCHY_HOME="$VH/.cache/orchy/example-app" \
  ORCHY_ASKS_DIR="$VH/.agents/orchy/asks" ORCHY_ACCOUNTS="$VH/.agents/orchy/accounts.json" ORCHY_REPO=example/app ORCHY_ROOT="$T/repo" ORCHY_GITLEAKS=fake-gitleaks
mkdir -p "$MOCK_DIR/cu" "$VH/.agents/orchy" "$ORCHY_HOME/page/shots"; echo '{"schema": "orchy.accounts/1", "never": []}' > "$ORCHY_ACCOUNTS"
printf 'main %s\nacct-a %s\n' "$T/slot" "$T/acct-a" > "$MOCK_DIR/cu/list.txt"; echo acct-a > "$MOCK_DIR/cu/current.txt"   # the roster check-public bans
# two sessions named claude (python via a symlink): the seat's, and one that never holds it
mkdir -p "$T/sess"; ln -s "$(command -v python3)" "$T/sess/claude"
for _ in 1 2; do "$T/sess/claude" -c 'import time; time.sleep(3600)' & ps+=($!); done; export CLAUDE_PID=${ps[0]}
git init -q -b dev "$T/repo"; cd "$T/repo"
jq '.install = "true"' "$K/examples/orchy.example.json" > "$ORCHY_HOME/orchy.json"; cp "$K/examples/local.example.json" "$ORCHY_HOME/local.json"
"$ORCHY" lock >/dev/null
RQX() { "$ORCHY" request "$@"; }
mkspec() { printf '%s\n' "$2" > "$T/$1.json"; echo "$T/$1.json"; }   # mkspec <name> <json>: the spec file's path
RQ="$ORCHY_ASKS_DIR/example-app.requests"; W="$ORCHY_HOME/waiting.json"; EV="$ORCHY_HOME/events.jsonl"
sums() { { find "$RQ" -type f -exec md5sum {} + | sort; md5sum "$W" "$EV"; } | md5sum; }
since0() { jq -c --arg r "$1" --arg s "$2" '(.waiting[] | select(.ref == $r)).since = $s' "$W" > "$T/w.json" && mv "$T/w.json" "$W"; }

# --- add: one waiting.add event with the ref only, and the projected row; every shape against the golden
printf 'unit run' > "$ORCHY_HOME/page/shots/unit.png"
P='{"shape": "pick", "title": "Choose the test path for the docs lane", "context": "Both paths **pass** today.\nOne is `bun test`.", "blocks": ["pr:12"],
  "options": [{"id": "unit", "label": "Unit tests", "consequence": "Fast, no browser", "pictures": [{"file": "unit.png", "alt": "The unit run"}]},
    {"id": "e2e", "label": "Browser tests", "consequence": "Slower, closer to what people see"}], "recommend": {"id": "unit", "why": "The change has no screen"}}'
: >> "$EV"; e0=$(wc -l < "$EV")
[ "$(RQX add other:test-path "$(mkspec pick "$P")")" = "rq1 r1 created" ] || flunk "request add"
"$ORCHY" waiting list --json | jq -e '.waiting == [{ref: "other:test-path", text: "Choose the test path for the docs lane", since: .waiting[0].since}] and (has("errors") | not)' >/dev/null \
  || flunk "the projected row: $("$ORCHY" waiting list --json)"
tail -n +"$((e0 + 1))" "$EV" | jq -se 'length == 1 and (.[0] | keys == ["at", "kind", "ref", "schema"] and .kind == "waiting.add" and .ref == "other:test-path")' >/dev/null \
  || flunk "the add's events: $(tail -n +"$((e0 + 1))" "$EV")"
[ "$(RQX add other:filing-list "$(mkspec approve '{"shape": "approve", "title": "File the three cleanup issues",
  "wording": "File three issues: the README typo, the stale badge and the broken link.", "binding": {"kind": "text"}}')")" = "rq2 r1 created" ] || flunk "add approve"
[ "$(RQX add pr:12 "$(mkspec "done" '{"shape": "done", "title": "Rename the required check, then say done",
  "steps": [{"text": "Rename e2e to e2e-status in the branch rules"}, {"text": "Check that the PR sees it", "command": "gh pr checks 12 --repo example/app"}]}')")" = "rq3 r1 created" ] || flunk "add done"
[ "$(RQX add issue:7 "$(mkspec reply '{"shape": "reply", "title": "Which locale ships first?", "context": "Spanish and French are both translated."}')")" = "rq4 r1 created" ] || flunk "add reply"
[ "$(RQX add page:3 "$(mkspec sign '{"shape": "sign", "title": "Sign page 3, the onboarding copy", "page": 3, "blocks": ["lane:docs"]}')")" = "rq5 r1 created" ] || flunk "add sign"
[ "$(RQX note rq4 "Both pass review; the question is only the order")" = "rq4 r1 noted" ] || flunk "request note"
RQX list --json | jq -S '.requests[] |= (del(.since, .updated, .age_s) | .thread[] |= del(.at))' > "$T/rl.json"
diff <(jq -S . "$G/requests.v1.json") "$T/rl.json" || flunk "request list JSON drifted from tests/mocks/orchy/requests.v1.json"
RQX list | grep -qxE 'rq3  r1  open  done  pr:12  [0-9]+m  Rename the required check, then say done' || flunk "request list text: $(RQX list)"
RQX show rq1 | grep -qx 'option unit (recommended): Unit tests - Fast, no browser' || flunk "request show: $(RQX show rq1)"
"$ORCHY" snapshot 2>&1 | sed -n '/^-- waiting/,/^--/p' | grep -qxE 'page:3  [0-9]+m  Sign page 3, the onboarding copy' || flunk "the snapshot does not list a request"

# --- conversion: the bare record's since is kept and its row goes, with no event; a leftover row loses to the request
"$ORCHY" waiting add issue:5 "Answer the question on issue 5" >/dev/null; since0 issue:5 2026-01-01T00:00:00Z; e0=$(wc -l < "$EV")
[ "$(RQX add issue:5 "$(mkspec i5 '{"shape": "reply", "title": "Which fix for issue 5 do you want?"}')")" = "rq6 r1 created" ] || flunk "add over a bare record"
RQX list --json | jq -e '.requests[] | select(.id == "rq6") | .since == "2026-01-01T00:00:00Z"' >/dev/null || flunk "the conversion did not keep the bare record's since"
jq -e 'all(.waiting[]; .ref != "issue:5")' "$W" >/dev/null && [ "$(wc -l < "$EV")" = "$e0" ] || flunk "the conversion kept the bare row or emitted an event"
jq -c '.waiting += [{ref: "issue:5", text: "Answer the question on issue 5", since: "2025-06-01T00:00:00Z"}]' "$W" > "$T/w.json" && mv "$T/w.json" "$W"
"$ORCHY" waiting list --json | jq -e '[.waiting[] | select(.ref == "issue:5")] == [{ref: "issue:5", text: "Which fix for issue 5 do you want?", since: "2025-06-01T00:00:00Z"}]' >/dev/null \
  || flunk "a leftover bare row was not deduped: $("$ORCHY" waiting list --json)"
"$ORCHY" state | jq -e '[.waiting[] | select(.ref == "issue:5")] | length == 1' >/dev/null || flunk "state shows the ref twice"
[ "$(RQX add issue:5 "$T/i5.json")" = "rq6 r1 unchanged" ] && jq -e 'all(.waiting[]; .ref != "issue:5")' "$W" >/dev/null \
  && RQX list --json | jq -e '.requests[] | select(.id == "rq6") | .since == "2025-06-01T00:00:00Z"' >/dev/null || flunk "a re-add did not drop the leftover row and keep its since"
printf -- '- [ ] Publish the build\n' > "$T/rb.md"; "$ORCHY" runbook add rb-x "$T/rb.md" >/dev/null
"$ORCHY" waiting add other:peer-kit "The peer lane is quiet until its release" >/dev/null

# --- refresh: unchanged, then rev+1
[ "$(RQX add other:test-path "$T/pick.json")" = "rq1 r1 unchanged" ] || flunk "an identical add"
[ "$(RQX add other:test-path "$(mkspec pick2 "${P/Browser tests/Browser runs}")")" = "rq1 r2 refreshed" ] || flunk "a changed option"

# --- refusals change no file and no event
LS=$(mkspec lead '{"shape": "reply", "title": "A question from below a lead"}'); hp="/h""ome/kit/.cache"
b=$(sums); nope() { o=$("$@" 2>&1) && flunk "accepted: $*"; grep -q -- "$want" <<<"$o" || flunk "$*: $o"; }
want='does not hold the seat'; CLAUDE_PID=${ps[1]} nope "$ORCHY" request add issue:8 "$LS"
want='runs under lead pid'; nope "$T/sess/claude" -c 'import os, subprocess, sys
st = open("/proc/self/stat").read().rsplit(")", 1)[1].split()[19]
open(sys.argv[1], "w").write(f"{os.getpid()} {st} acct-a 2031-01-15T00:00:00Z heavy prompts/x.md {os.getpid()} x\n")
sys.exit(subprocess.call(sys.argv[2:]))' "$ORCHY_HOME/leads/rq-lead.started" "$ORCHY" request add issue:8 "$LS"; rm -f "$ORCHY_HOME/leads/rq-lead.started"
want='fails check-public (LEAK)'; nope RQX add pr:13 "$(mkspec home "$(jq -nc --arg c "rm -rf $hp/x" '{shape: "done", title: "Clean the cache", steps: [{text: "Remove it", command: $c}]}')")"
want='runbook rb-x keeps other:rb-x'; nope RQX add other:rb-x "$LS"
want="a peer's hold"; nope RQX add other:peer-kit "$LS"
want='request rq3 holds pr:12'; nope "$ORCHY" waiting add pr:12 "Merge it"; nope "$ORCHY" waiting "done" pr:12
want='names an ask or a request'; nope RQX add issue:8 "$(mkspec askid '{"shape": "reply", "title": "Answer ask3 before the release"}')"
want='no open request rq99'; nope RQX note rq99 "nothing here"
[ "$(sums)" = "$b" ] || flunk "a refused command changed a request, the waiting record or the events"
"$ORCHY" waiting list --json | jq -e '[.waiting[] | select(.ref == "other:rb-x" or .ref == "other:peer-kit") | .text]
  == ["0 of 1 done; next: Publish the build", "The peer lane is quiet until its release"]' >/dev/null || flunk "a runbook or peer row changed: $("$ORCHY" waiting list --json)"

# --- stale, refresh, withdraw and done: a close moves the file to closed/, drops the row and emits waiting.done
[ "$(RQX stale rq4 "The locale list changed")" = "rq4 r1 stale" ] || flunk "request stale"
jq -c '.waiting += [{ref: "issue:7", text: "Which locale?", since: "2026-01-01T00:00:00Z"}]' "$W" > "$T/w.json" && mv "$T/w.json" "$W"; b=$(md5sum "$W")
want='rq4 is stale; done does not apply'; nope RQX "done" rq4 "shipped"; [ "$(md5sum "$W")" = "$b" ] || flunk "a refused close dropped the bare row"
[ "$(RQX add issue:7 "$T/reply.json")" = "rq4 r2 refreshed" ] && jq -e 'all(.waiting[]; .ref != "issue:7")' "$W" >/dev/null || flunk "a refresh of a stale request"
jq -c '.waiting += [{ref: "pr:12", text: "Rename the check", since: "2026-01-01T00:00:00Z"}]' "$W" > "$T/w.json" && mv "$T/w.json" "$W"   # a leftover row
e0=$(wc -l < "$EV")
[ "$(RQX "done" rq3 "Renamed the check; the watcher is armed again")" = "rq3 done" ] && [ "$(RQX withdraw rq4 "Asked in chat instead")" = "rq4 withdrawn" ] || flunk "done or withdraw"
[ -f "$RQ/closed/rq3.json" ] && [ -f "$RQ/closed/rq4.json" ] && [ ! -e "$RQ/rq3.json" ] && [ ! -e "$RQ/rq4.json" ] || flunk "a closed request was not moved"
"$ORCHY" waiting list --json | jq -e 'all(.waiting[]; .ref != "pr:12" and .ref != "issue:7")' >/dev/null && jq -e 'all(.waiting[]; .ref != "pr:12")' "$W" >/dev/null \
  || flunk "the projection kept a closed request, or its leftover row"
tail -n +"$((e0 + 1))" "$EV" | jq -se '[.[] | [.kind, .ref]] == [["waiting.done", "pr:12"], ["waiting.done", "issue:7"]]' >/dev/null || flunk "the closes' events"
RQX show rq4 | grep -qx 'outcome: Asked in chat instead' && RQX list --all --json | jq -e '[.requests[].id] == ["rq1", "rq2", "rq3", "rq4", "rq5", "rq6"]' >/dev/null || flunk "a closed request is not shown"
want='rq3 is done; done does not apply'; nope RQX "done" rq3 "again"

# --- no ghost: an unrelated waiting add beside a request leaves only its own row once the request closes
GH="$ORCHY_CAPACITY_ROOT/ghost"; mkdir -p "$GH"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$GH/"; GX() { ORCHY_HOME="$GH" ORCHY_REPO=example/ghost "$ORCHY" "$@"; }
GX lock >/dev/null && GX request add other:g1 "$LS" >/dev/null && GX waiting add other:x "Log in to the registry yourself" >/dev/null && GX request withdraw rq1 "not needed" >/dev/null || flunk "the ghost case"
jq -e '[.waiting[].ref] == ["other:x"]' "$GH/waiting.json" >/dev/null || flunk "a ghost row: $(cat "$GH/waiting.json")"
# request add holds the waiting lock from reading the ref's bare row to its write: held elsewhere, no file appears
( flock 8; sleep 3 ) 8>>"$GH/waiting.lock" & hp=$!; sleep 0.5; GX request add other:g2 "$LS" > "$T/g2.out" & ap=$!; sleep 1.5
[ ! -e "$ORCHY_ASKS_DIR/example-ghost.requests/rq2.json" ] || flunk "request add wrote before it held the waiting lock"
wait "$ap" && wait "$hp" && grep -qx 'rq2 r1 created' "$T/g2.out" || flunk "request add after the waiting lock: $(cat "$T/g2.out")"

# --- a malformed request is named, never fatal; readers change nothing
printf '{"schema": "orchy.request/1", "id": "rq900"' > "$RQ/rq900.json"; : > "$RQ/rq901.json"; jq -c '.id = "rq902"' "$RQ/rq1.json" "$RQ/rq1.json" > "$RQ/rq902.json"
prints() { find "$ORCHY_HOME" "$ORCHY_ASKS_DIR" -printf '%p %s %T@ %m\n' | sort; }; b=$(prints)
"$ORCHY" state | jq -e '(.errors | index("requests")) and any(.waiting[]; .ref == "other:test-path")' >/dev/null || flunk "state over a malformed request: $("$ORCHY" state | jq -c '.waiting, .errors')"
"$ORCHY" waiting list --json | jq -e '[.errors[].file] == ["rq900.json", "rq901.json", "rq902.json"] and any(.waiting[]; .ref == "other:test-path")' >/dev/null \
  || flunk "waiting list over a malformed request: $("$ORCHY" waiting list --json | jq -c .errors)"
"$ORCHY" waiting list 2>&1 >/dev/null | grep -qx 'error: rq900.json: not an orchy.request/1 the waiting list can show' || flunk "waiting list text names no bad file"
RQX list --json | jq -e '[.errors[] | .file + " " + .error] == ["rq900.json not JSON", "rq901.json not JSON", "rq902.json not JSON"] and ([.requests[].id] == ["rq1", "rq2", "rq5", "rq6"])' >/dev/null \
  || flunk "request list over a malformed request: $(RQX list --json | jq -c .errors)"
RQX list 2>&1 >/dev/null | grep -qx 'error: rq900.json: not JSON' && RQX show rq2 >/dev/null || flunk "request list text or show"
[ "$(prints)" = "$b" ] || flunk "a reader changed the home or the ask folder: $(diff <(echo "$b") <(prints))"
rm "$RQ"/rq90[0-2].json

# --- the viewers' environment: state needs no bun; request list finds it, and check-public gitleaks, at the install paths
for t in bun gitleaks; do ! env -i PATH=/usr/bin:/bin bash -c "command -v $t" >/dev/null || flunk "$t is in /usr/bin or /bin, so the bare-PATH check proves nothing"; done
viewer() { env -i PATH="${VPATH:-/usr/bin:/bin}" HOME="$VH" ORCHY_HOME="$ORCHY_HOME" ORCHY_REPO="$ORCHY_REPO" ORCHY_ROOT="$ORCHY_ROOT" MOCK_DIR="$MOCK_DIR" "$ORCHY" "$@"; }
vn='del(.at, .load1, .nproc) | (.requests[]?.age_s |= 0)'
same() { w=$("$ORCHY" "$@" | jq -eS "$vn") && o=$(viewer "$@" 2>&1 | jq -eS "$vn") && [ "$o" = "$w" ] || flunk "$* differs in the viewer's environment: $(diff <(echo "$w") <(echo "$o") | head -5)"; }
same state --json
mkdir -p "$VH/.bun/bin" "$VH/.local/bin"; ln -s "$(command -v bun)" "$VH/.bun/bin/bun"; ln -s "$G/fake-gitleaks" "$VH/.local/bin/gitleaks"
same state --json; same request list --json
"$ORCHY" state | jq -e '.waiting | length == 6' >/dev/null || flunk "state with requests: $("$ORCHY" state | jq -c .waiting)"
printf 'nothing to hide\n' > "$T/clean.txt"; printf 'AKIA%s\n' "$(printf 'Q%.0s' {1..16})" > "$T/key.txt"
VPATH="/usr/bin:/bin:$G" viewer check-public "$T/clean.txt" >/dev/null || flunk "check-public did not find gitleaks at ~/.local/bin"
o=$(VPATH="/usr/bin:/bin:$G" viewer check-public "$T/key.txt" 2>&1) && flunk "the gitleaks at ~/.local/bin did not run"; grep -q '^SECRET' <<<"$o" || flunk "check-public: $o"

# --- answers: a fresh home, whose ledger holds the asks its requests link
AH="$ORCHY_CAPACITY_ROOT/answers"; mkdir -p "$AH"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$AH/"
AX() { ORCHY_HOME="$AH" ORCHY_REPO=example/answers "$ORCHY" "$@"; }
AQ="$ORCHY_ASKS_DIR/example-answers.requests"; AA="$ORCHY_ASKS_DIR/example-answers.answers"; AL="$ORCHY_ASKS_DIR/example-answers.jsonl"
KEY="AKIA$(printf 'Q%.0s' {1..16})"
AXP() { local o; o=$(printf '%s' "$1" | AX answer put 2>/dev/null) || flunk "answer put exited $?: $1"; jq -r '.state + " " + (.id // .reason)' <<<"$o"; }
# ans_dep <aid> <jq object>: a file dropped straight into the inbox, as any process of the owner's can; $k is the fake key
ans_dep() { jq -nc --arg id "$1" --arg at "$(date -u +%FT%TZ)" --arg k "$KEY" '{schema: "orchy.answer/1", id: $id, request: ($id | split(".")[0]), rev: 1, at: $at} + '"$2" > "$AA/$1.json"; }
ans_ledger() { jq -Rnc --arg a "$1" '[inputs | fromjson? | select(type == "object" and .answer == $a)]' "$AL"; }
ans_logged() { local f="$AQ/${1%%.*}.json"; [ -f "$f" ] || f="$AQ/closed/${1%%.*}.json"; jq -c --arg a "$1" '[.answers[] | select(.id == $a)]' "$f"; }
ans_wait() { ORCHY_WAIT_TICK=1 AX wait "$1" > "$T/aw.out" 2>&1; }
ans_run() { "$@" && echo "rc=0" || echo "rc=$?"; }   # inside $(...): the output, then rc=<exit>
ans_lead() { "$T/sess/claude" -c 'import os, subprocess, sys
st = open("/proc/self/stat").read().rsplit(")", 1)[1].split()[19]
open(sys.argv[1], "w").write(f"{os.getpid()} {st} acct-a 2031-01-15T00:00:00Z heavy prompts/x.md {os.getpid()} x\n")
sys.exit(subprocess.call(sys.argv[2:]))' "$ORCHY_HOME/leads/ans-lead.started" env ORCHY_HOME="$AH" ORCHY_REPO=example/answers "$ORCHY" "$@"; local rc=$?
  rm -f "$ORCHY_HOME/leads/ans-lead.started"; return $rc; }
AX lock >/dev/null
for t in "keep the docs lane on the fast unit path please" "say which locale goes out with the first build" "we should ship the docs once the freeze ends"; do AX ask add "$t" >/dev/null; done
AX ask public ask1 "Choose the test path for the docs lane" >/dev/null && AX ask public ask3 "Pick the release day for the docs site" >/dev/null
PK='{"shape": "pick", "title": "Choose the test path for the docs lane", "options": [{"id": "unit", "label": "Unit tests"}, {"id": "e2e", "label": "Browser tests"}],
  "recommend": {"id": "unit", "why": "No screen changes"}}'
for x in "ask:ask1=$PK" 'issue:7={"shape": "reply", "title": "Which locale ships first?"}' 'other:closing={"shape": "reply", "title": "Is the old banner still wanted?"}' \
  'ask:ask2={"shape": "reply", "title": "Name the first locale to ship"}' 'other:filing={"shape": "approve", "title": "File the cleanup issues", "wording": "File three issues.", "binding": {"kind": "text"}}' \
  'ask:ask3={"shape": "reply", "title": "Choose the day the docs site goes out"}'; do AX request add "${x%%=*}" "$(mkspec "a-${x%%=*}" "${x#*=}")" >/dev/null; done
AX request withdraw rq3 "Asked in chat instead" >/dev/null && [ -f "$AQ/closed/rq3.json" ] || flunk "the answers home's requests"

# --- put: a 600 file in a 700 inbox and nothing in the home; one pending final and one open reply per request
ans_fh() { find "$AH" -printf '%p %s %T@ %m\n' | sort; }; b=$(ans_fh)
[ "$(AXP '{"request": "rq1", "rev": 1, "kind": "pick", "choice": "unit", "note": "the unit path is enough for docs"}')" = "pending rq1.1" ] || flunk "answer put"
[ "$(stat -c %a "$AA" "$AA/rq1.1.json" | paste -sd' ')" = "700 600" ] && [ "$(ans_fh)" = "$b" ] || flunk "answer put: the inbox's modes, or the home changed"
AX request list --json | jq -e '.requests[] | select(.id == "rq1") | .answered and [.pending[].id] == ["rq1.1"]' >/dev/null || flunk "request list shows no pending answer"
for x in '{"request": "rq1", "rev": 1, "kind": "pick", "choice": "e2e"}=refused conflict' '{"request": "rq1", "rev": 1, "kind": "reply", "text": "why not both paths?"}=pending rq1.2' \
  '{"request": "rq1", "rev": 1, "kind": "reply", "text": "and one more thing"}=refused conflict' '{"request": "rq3", "rev": 1, "kind": "reply", "text": "too late"}=refused closed' \
  '{"request": "rq1", "rev": 1, "kind": "pick", "choice": "lint"}=refused invalid' "{\"request\": \"rq2\", \"rev\": 1, \"kind\": \"reply\", \"text\": \"the key is $KEY\"}=refused secret"; do
  o=$(AXP "${x%=*}"); [ "$o" = "${x##*=}" ] || flunk "answer put ${x%=*}: $o"; done
o=$(printf '%s' '{"request": "rq2", "rev": 1, "kind": "reply", "text": "from a lead"}' | ans_lead answer put 2>/dev/null) && jq -e '.state == "refused" and .reason == "policy"' <<<"$o" >/dev/null \
  || flunk "a put from below a lead: $o"
[ "$(cd "$AA" && echo *)" = "refused rq1.1.json rq1.2.json taken" ] || flunk "a refused put left a file: $(ls -A "$AA")"

# --- wait: a new answer wakes it by id; another name in the inbox, or a take, does not
jq -n '[]' > "$MOCK_DIR/issues.json"; jq -n '{sha: "1111111111111111111111111111111111111111"}' > "$MOCK_DIR/trunk.json"; rm -f "$MOCK_DIR/open.json"
ans_wait 2; grep -qx 'CHANGED (answers):' "$T/aw.out" && [ "$(grep -cxE '> rq1\.[12]' "$T/aw.out")" = 2 ] || flunk "the first wait did not report the pending answers: $(cat "$T/aw.out")"
ans_wait 2; [ "$(cat "$T/aw.out")" = "TIMEOUT after 2s, no change" ] || flunk "a wait reported the same answers again: $(cat "$T/aw.out")"
: > "$AA/notes.json"; : > "$AA/rq2.1.json.part"; e0=$(grep -c '"ask.row"' "$AH/events.jsonl" || true)
( sleep 1.5; AXP '{"request": "rq2", "rev": 1, "kind": "reply", "text": "Spanish, then French"}' > "$T/ap.out" ) & ap=$!
ans_wait 8; wait "$ap"; [ "$(cat "$T/aw.out")" = $'CHANGED (answers):\n> rq2.1' ] && [ "$(cat "$T/ap.out")" = "pending rq2.1" ] || flunk "wait on a new answer: $(cat "$T/aw.out")"
rm "$AA/notes.json" "$AA/rq2.1.json.part"
AX answer take rq2.1 | jq -e '.verdict == "taken" and .ask == null' >/dev/null && ans_wait 2 && [ "$(cat "$T/aw.out")" = "TIMEOUT after 2s, no change" ] || flunk "a take woke the next wait: $(cat "$T/aw.out")"
ans_ledger rq2.1 | jq -e 'length == 1 and (.[0] | has("id") | not) and .[0].text == "Spanish, then French"' >/dev/null && [ "$(grep -c '"ask.row"' "$AH/events.jsonl" || true)" = "$e0" ] \
  || flunk "a reply with no linked ask: $(ans_ledger rq2.1)"

# --- take of a pick: the request is taken, the file moved, a said row on the linked ask, the choice in the output
o=$(AX answer take rq1.1) && jq -e '.verdict == "taken" and .answer.choice == "unit" and .answer.note == "the unit path is enough for docs" and .ask == "ask1" and (.recovered | not)' <<<"$o" >/dev/null || flunk "take: $o"
jq -e '.status == "taken" and .taken.answer == "rq1.1"' "$AQ/rq1.json" >/dev/null && [ -f "$AA/taken/rq1.1.json" ] && [ ! -e "$AA/rq1.1.json" ] || flunk "the take did not move the request or the file"
ans_ledger rq1.1 | jq -e 'length == 1 and .[0].id == "ask1" and .[0].said == "the unit path is enough for docs"' >/dev/null || flunk "the said row: $(ans_ledger rq1.1)"
AX answer take rq1.2 | jq -e '.verdict == "taken" and .ask == "ask1"' >/dev/null && jq -e '.status == "taken"' "$AQ/rq1.json" >/dev/null || flunk "a reply on a taken request"
ans_dep rq1.3 '{kind: "pick", choice: "e2e"}'
o=$(ans_run AX answer take rq1.3); [ "${o##*rc=}" = 4 ] && jq -e '.reason == "stale"' <<<"${o%rc=*}" >/dev/null && jq -e '.taken.answer == "rq1.1"' "$AQ/rq1.json" >/dev/null || flunk "a second final deposited on a taken request: $o"

# --- unsettled: the snapshot lists what a take left, UNSETTLED once 30 minutes old
sn() { AX snapshot 2>&1 | sed -n '/^-- requests/,/^-- waiting/p'; }
s=$(sn); grep -qxE 'rq1 taken rq1\.1 [01]m' <<<"$s" && grep -qxE 'rq1 reply rq1\.2 unanswered [01]m' <<<"$s" || flunk "the snapshot's requests: $s"
jq -c --arg t "$(date -u -d '-31 min' +%FT%TZ)" '.taken.at = $t | (.answers[] | select(.id == "rq1.2")).at = $t' "$AQ/rq1.json" > "$T/r.json" && mv "$T/r.json" "$AQ/rq1.json"
s=$(sn); grep -qx 'rq1 taken rq1.1 31m UNSETTLED' <<<"$s" && grep -qx 'rq1 reply rq1.2 unanswered 31m UNSETTLED' <<<"$s" || flunk "nothing UNSETTLED: $s"

# --- closing: refused while an answer is pending or a reply unanswered
AX request note rq1 --re rq1.2 "Both run nightly; the unit tests gate the PR" >/dev/null
[ "$(AXP '{"request": "rq1", "rev": 1, "kind": "reply", "text": "thanks"}')" = "pending rq1.4" ] || flunk "a reply once the last one is answered"
want='rq1.4 waits in the inbox'; nope AX request "done" rq1 "Unit tests chosen"
AX answer refuse rq1.4 closed | jq -e '.verdict == "refused" and .reason == "closed"' >/dev/null && [ "$(AX request "done" rq1 "Unit tests chosen")" = "rq1 done" ] || flunk "refuse, then done"
want='--re rq2.1 first'; nope AX request "done" rq2 "Spanish first"; nope AX request withdraw rq2 "asked in chat"
nope AX request add issue:7 "$(mkspec a2b '{"shape": "reply", "title": "Which locale ships next?"}')"
AX request note rq2 --re rq2.1 "Spanish first; French a week later" >/dev/null
[ "$(AXP '{"request": "rq2", "rev": 1, "kind": "reply", "text": "and German?"}')" = "pending rq2.2" ] && [ "$(AX request add issue:7 "$T/a2b.json")" = "rq2 r2 refreshed" ] || flunk "a reply, then a refresh"
AX answer take rq2.2 | jq -e '.verdict == "taken" and .request.rev == 2' >/dev/null && jq -e '.status == "open"' "$AQ/rq2.json" >/dev/null || flunk "a reply for r1 taken at r2"
AX request note rq2 --re rq2.2 "German comes later" >/dev/null

# --- the seat: a non-seat take, a take whose seat changes hands at the takeover lock, a take held at the ledger lock
[ "$(AXP '{"request": "rq5", "rev": 1, "kind": "approve", "go": false, "note": "not this week"}')" = "pending rq5.1" ] || flunk "an approve's not now"
want='does not hold the seat'; CLAUDE_PID=${ps[1]} nope AX answer take rq5.1
seat0=$(cat "$AH/orchestrator.lock")
( flock 4; sleep 3; echo "${ps[1]} $(awk '{print $22}' "/proc/${ps[1]}/stat") 2026-01-01T00:00:00Z - -" > "$AH/orchestrator.lock" ) 4>>"$AH/orchestrator.lock.takeover" & hp=$!
sleep 0.5; nope AX answer take rq5.1; wait "$hp"
[ -f "$AA/rq5.1.json" ] && [ "$(ans_logged rq5.1)" = "[]" ] || flunk "a take committed after the seat changed hands"
echo "$seat0" > "$AH/orchestrator.lock"
( flock 9; exec sleep 3 ) 9>>"$AL" & hp=$!; sleep 0.5; AX answer take rq5.1 > "$T/t5.out" 2>&1 & tp=$!; sleep 1
[ "$(AXP '{"request": "rq4", "rev": 1, "kind": "reply", "text": "Spanish"}')" = "pending rq4.1" ] && kill -0 "$tp" || flunk "a put waited behind a take held at the ledger lock"
wait "$hp"; wait "$tp" && jq -e '.verdict == "taken"' "$T/t5.out" >/dev/null || flunk "the take after the ledger lock: $(cat "$T/t5.out")"
AX answer take rq4.1 >/dev/null && AX request note rq4 --re rq4.1 "Spanish it is" >/dev/null || flunk "take rq4.1"
AX unlock >/dev/null; [ "$(AXP '{"request": "rq4", "rev": 1, "kind": "reply", "text": "French as well"}')" = "pending rq4.2" ] || flunk "a put while no seat is held"
CLAUDE_PID=${ps[1]} AX lock >/dev/null && CLAUDE_PID=${ps[1]} ans_wait 3; grep -qx '> rq4.2' "$T/aw.out" || flunk "the new seat's first wait: $(cat "$T/aw.out")"
CLAUDE_PID=${ps[1]} AX answer take rq4.2 | jq -e '.verdict == "taken"' >/dev/null && CLAUDE_PID=${ps[1]} AX request note rq4 --re rq4.2 "French next" >/dev/null \
  && CLAUDE_PID=${ps[1]} AX unlock >/dev/null && AX lock >/dev/null || flunk "the moved seat's take"

# --- a take stopped at each obstacle: the rerun ends in one logged outcome, one ledger row for a taken answer and none for a
# secret-bearing one (current, stale or for a closed request), and no raw secret on disk or in output once redacted
ans_set() { ans_dep "rq4.1$1" '{kind: "reply", text: "Spanish then French"}'; ans_dep "rq4.2$1" '{kind: "reply", text: "the token is \($k)"}'
  ans_dep "rq5.1$1" '{kind: "approve", rev: 9, go: false, note: "the token is \($k)"}'; ans_dep "rq3.1$1" '{kind: "reply", text: "the token is \($k)"}'; }
ans_takes() { local id; for id in "rq4.1$1" "rq4.2$1" "rq5.1$1" "rq3.1$1"; do
  AX answer take "$id" > "$T/$id.$2" 2> "$T/$id.e$2" && echo 0 >> "$T/$id.$2" || echo $? >> "$T/$id.$2"; done; }
ans_check() { # ans_check <k> <recovered>
  local id q n c; for id in "rq4.1$1" "rq4.2$1" "rq5.1$1" "rq3.1$1"; do
    [ "$(ans_logged "$id" | jq length)" = 1 ] && [ ! -e "$AA/$id.json" ] || flunk "obstacle $1: $id is logged $(ans_logged "$id" | jq length) times, or pending"
    if [ "$id" = "rq4.1$1" ]; then q='.verdict == "taken"'; n=1; c=0; else q='.verdict == "refused" and .reason == "invalid" and .withheld == "secret"'; n=0; c=1; fi
    head -n 1 "$T/$id.2" | jq -e "$q and .recovered == $2" >/dev/null && [ "$(tail -n 1 "$T/$id.2")" = "$c" ] || flunk "obstacle $1: $id's rerun: $(cat "$T/$id.2" "$T/$id.e2")"
    [ "$(ans_ledger "$id" | jq length)" = "$n" ] || flunk "obstacle $1: $id has $(ans_ledger "$id" | jq length) ledger rows"
  done
  ! grep -rqF "$KEY" "$AA" "$AQ" "$AL" "$T"/rq*.[12] "$T"/rq*.e[12] || flunk "obstacle $1: a secret survived: $(grep -rlF "$KEY" "$AA" "$AQ" "$AL" "$T"/rq*.[12] "$T"/rq*.e[12])"
  AX request note rq4 --re "rq4.1$1" "Noted, set $1" >/dev/null
}
ans_set 1; ( flock 5; exec sleep 40 ) 5>>"$AQ/requests.lock" & hp=$!; sleep 0.5
tps=(); for id in rq4.11 rq4.21 rq5.11 rq3.11; do ( AX answer take "$id" > "$T/$id.1" 2> "$T/$id.e1" && echo 0 >> "$T/$id.1" || echo $? >> "$T/$id.1" ) & tps+=($!); done
wait "${tps[@]}"; kill "$hp"
for id in rq4.11 rq4.21 rq5.11 rq3.11; do [ "$(tail -n 1 "$T/$id.1")" = 2 ] || flunk "a take past the lock's wait: $(cat "$T/$id.1")"; done
[ "$(ans_ledger rq4.11 | jq length)" = 1 ] && AX answer list --json | jq -e '.answers[] | select(.id == "rq4.21") | .text == null and .withheld == "secret"' >/dev/null \
  || flunk "before the lock: the ledger row, or a pending secret shown"
ans_takes 1 2; ans_check 1 false
ans_set 2; chmod a-w "$AQ" "$AQ/closed"; ans_takes 2 1; chmod u+w "$AQ" "$AQ/closed"
for id in rq4.12 rq4.22 rq5.12 rq3.12; do [ "$(tail -n 1 "$T/$id.1")" = 2 ] && [ "$(ans_logged "$id")" = "[]" ] || flunk "a take into a read-only requests folder: $(cat "$T/$id.1")"; done
! grep -qF "$KEY" "$AA"/rq*.json || flunk "a redacted answer kept its secret"
ans_takes 2 2; ans_check 2 false
ans_set 3; chmod a-w "$AA/taken" "$AA/refused"; ans_takes 3 1; chmod u+w "$AA/taken" "$AA/refused"
for id in rq4.13 rq4.23 rq5.13 rq3.13; do [ "$(tail -n 1 "$T/$id.1")" = 2 ] && [ -e "$AA/$id.json" ] || flunk "a take into read-only taken/ and refused/: $(cat "$T/$id.1")"; done
ans_takes 3 2; ans_check 3 true
ans_set 4; for id in rq4.14 rq4.24 rq5.14 rq3.14; do AX answer take "$id" > /dev/full 2> "$T/$id.e1" && echo 0 > "$T/$id.1" || echo $? > "$T/$id.1"; done
for id in rq4.14 rq4.24 rq5.14 rq3.14; do [ "$(tail -n 1 "$T/$id.1")" = 120 ] || flunk "a take whose output failed: $(cat "$T/$id.1")"; done
ans_takes 4 2; ans_check 4 true

# --- deposits that bypass put
ans_dep rq2.11 '{kind: "reply", text: "the token is \($k)"}'
AX answer list --json | jq -e '.answers[] | select(.id == "rq2.11") | .text == null and .withheld == "secret"' >/dev/null || flunk "answer list showed a pending secret"
o=$(ans_run AX answer take rq2.11); [ "${o##*rc=}" = 1 ] && jq -e '.reason == "invalid" and .withheld == "secret"' <<<"${o%rc=*}" >/dev/null || flunk "a deposited secret: $o"
ans_dep rq2.12 '{kind: "reply", text: "the token is \($k)"}'
AX answer refuse rq2.12 closed | jq -e '.reason == "invalid" and .withheld == "secret"' >/dev/null || flunk "a refused secret"
o=$(AX answer show rq2.12; AX answer list --json --all); ! grep -qF "$KEY" <<<"$o" && ! grep -rqF "$KEY" "$AA" "$AL" && [ "$(ans_ledger rq2.11)$(ans_ledger rq2.12)" = "[][]" ] \
  || flunk "a secret left a trace"
ans_dep rq4.31 '{kind: "reply", text: "first"}'; ans_dep rq4.32 '{kind: "reply", text: "second"}'
AX answer take rq4.31 | jq -e '.verdict == "taken"' >/dev/null && o=$(ans_run AX answer take rq4.32) && [ "${o##*rc=}" = 1 ] && jq -e '.reason == "invalid"' <<<"${o%rc=*}" >/dev/null \
  || flunk "two replies at once: $o"
AX request note rq4 --re rq4.31 "Both noted" >/dev/null; ans_dep rq4.33 '{kind: "reply", text: "third"}'
AX answer take rq4.33 | jq -e '.verdict == "taken"' >/dev/null && [ "$(stat -c %s "$AQ/rq4.json")" -lt 65536 ] || flunk "a reply once the last is answered"
AX request note rq4 --re rq4.33 "Third noted" >/dev/null
ans_dep rq99.1 '{kind: "reply", text: "nobody asked"}'; o=$(ans_run AX answer take rq99.1); [ "${o##*rc=}" = 1 ] && [ -f "$AA/refused/rq99.1.json" ] && [ ! -e "$AQ/rq99.json" ] || flunk "an answer to no request: $o"
ans_dep rq2.13 '{kind: "nod", rev: "1", go: "yes", text: "a plain word on locales"}'
o=$(ans_run AX answer take rq2.13); [ "${o##*rc=}" = 1 ] && ans_logged rq2.13 | jq -e '.[0] | keys == ["at", "id", "reason", "state"] and .reason == "invalid"' >/dev/null || flunk "malformed metadata: $o"
AX waiting list --json | jq -e 'any(.waiting[]; .ref == "issue:7")' >/dev/null && ans_ledger rq2.13 | jq -e '.[0] | has("id") | not' >/dev/null \
  && ! AX ask list --all --json | grep -q 'a plain word on locales' || flunk "malformed metadata: the projection, or the ledger row"
ans_dep rq2.15 '{kind: "reply", text: "first words"}'; chmod a-w "$AQ"; o=$(ans_run AX answer take rq2.15 2>/dev/null); chmod u+w "$AQ"; [ "${o##*rc=}" = 2 ] || flunk "a stopped take: $o"
ans_dep rq2.15 '{kind: "reply", text: "other words"}'; o=$(ans_run AX answer take rq2.15 2>/dev/null)
[ "${o##*rc=}" = 1 ] && jq -e '.reason == "invalid" and .answer.text == "other words"' <<<"${o%rc=*}" >/dev/null && ans_ledger rq2.15 | jq -e 'length == 1 and .[0].text == "first words"' >/dev/null \
  || flunk "a file changed after its sentences were filed: $o"
ans_dep rq2.14 '{kind: "reply", text: "the token is \($k)"}'; ( flock 5; exec sleep 2 ) 5>>"$AQ/requests.lock" & hp=$!; sleep 0.5
{ AX answer take rq2.14 > "$T/d1.out" || true; } & d1=$!; { AX answer take rq2.14 > "$T/d2.out" || true; } & d2=$!; wait "$hp" "$d1" "$d2"
jq -se '[.[].recovered] | sort == [false, true]' "$T/d1.out" "$T/d2.out" >/dev/null && [ ! -e "$AA/rq2.14.json" ] && ! grep -qF "$KEY" "$AA/refused/rq2.14.json" || flunk "two takes of one secret"
id=$(AX ask add --from rq2.1) && AX ask list --json | jq -e --arg id "$id" '.asks[] | select(.id == $id) | .text == "Spanish, then French"' >/dev/null || flunk "ask add --from"
want='already opened an ask'; nope AX ask add --from rq2.1; want='rq2.11 is withheld'; nope AX ask add --from rq2.11
want='rq1.3 is refused'; nope AX ask add --from rq1.3; want='runs under lead pid'; nope ans_lead ask add --from rq2.2

# --- capacity: a request just under 40 KiB takes a final and a reply, then refuses a further reply and a plain note
AX request add other:big "$(mkspec a-big "$PK")" >/dev/null
jq -c --arg big "$(printf '😀%.0s' {1..800})" 'def cb: del(.answers, .taken, .status) | tojson | utf8bytelength;
  until(cb > 40960 - 3400; .thread += [{at: .updated, text: $big}]) | until(cb > 40960 - 900; .thread += [{at: .updated, text: ("x" * 200)}])
  | .thread += [{at: .updated, text: ("x" * (40960 - cb - 100))}]' "$AQ/rq7.json" > "$T/r.json" && mv "$T/r.json" "$AQ/rq7.json"
[ "$(AXP '{"request": "rq7", "rev": 1, "kind": "pick", "choice": "unit"}')$(AXP '{"request": "rq7", "rev": 1, "kind": "reply", "text": "why?"}')" = "pending rq7.1pending rq7.2" ] \
  && AX answer take rq7.1 >/dev/null && AX answer take rq7.2 | jq -e '.verdict == "taken"' >/dev/null && AX request note rq7 --re rq7.2 "$(printf 'y%.0s' {1..400})" >/dev/null \
  || flunk "a request just under 40 KiB"
[ "$(AXP '{"request": "rq7", "rev": 1, "kind": "reply", "text": "and now?"}')" = "refused full" ] || flunk "a reply past 40 KiB"
want='rq7 is full'; nope AX request note rq7 "one more"; [ "$(AX request "done" rq7 "Unit tests")" = "rq7 done" ] || flunk "done past 40 KiB"
jq -c '.answers += [range(31; 91) as $i | {id: "rq5.\($i)", state: "refused", at: .updated, rev: 1, kind: "approve", go: true, reason: "stale"}]' "$AQ/rq5.json" > "$T/r.json" && mv "$T/r.json" "$AQ/rq5.json"
ans_dep rq5.31 '{kind: "approve", go: true, binding: {kind: "text", sha256: "'"$(printf 'File three issues.' | sha256sum | cut -c1-64)"'"}}'
cp "$AA/rq5.31.json" "$AA/refused/"; n=$(ans_logged rq5.31 | jq length)
o=$(ans_run AX answer take rq5.31); [ "${o##*rc=}" = 4 ] && jq -e '.recovered and .reason == "stale"' <<<"${o%rc=*}" >/dev/null && [ "$(jq '.answers | length' "$AQ/rq5.json")" = 65 ] && [ "$n" = 1 ] \
  || flunk "a replay after 60 refused answers: $o"
jq -c '.answers += [{id: "rq5.99", state: "refused", at: .updated, reason: "invalid"}]' "$AQ/rq5.json" > "$T/r.json" && mv "$T/r.json" "$AQ/rq5.json"
[ "$(AXP '{"request": "rq5", "rev": 1, "kind": "reply", "text": "one more"}')" = "refused full" ] || flunk "a put past sequence 99"

# --- a wording hold: an answer to the Done request never clears it; only wording ok does
AX ask add "word the release note so first-time users find the setup page" >/dev/null; AX ask public ask5 "Release note wording for the setup page" >/dev/null
AX ask note ask5 "waiting: wording" >/dev/null && AX request add ask:ask5 "$(mkspec a-w '{"shape": "done", "title": "Post the release note", "steps": [{"text": "Post it on the forum"}]}')" >/dev/null
AX ask public ask5 "Release note wording for the setup guide" | grep -q "needs the owner's OK again" || flunk "a changed wording under a hold"
want="only 'wording ok' ends that hold"; nope AX ask note ask5 "answered: done"
AX ask list --json | jq -e '.asks[] | select(.id == "ask5") | .waiting' >/dev/null && AX ask note ask5 "wording ok" >/dev/null \
  && AX ask list --json | jq -e '.asks[] | select(.id == "ask5") | .waiting | not' >/dev/null || flunk "the wording hold"

# --- echoes: the owner's words that repeat a restatement or a request are filed, and the two still pass check-public
t='Pick the release day for the docs site? Choose the day the docs site goes out: Friday after the freeze'
[ "$(AXP "$(jq -nc --arg t "$t" '{request: "rq6", rev: 1, kind: "reply", text: $t}')")" = "pending rq6.1" ] && AX answer take rq6.1 | jq -e '.ask == "ask3"' >/dev/null || flunk "the echo"
printf 'ask3: Pick the release day for the docs site\n' > "$T/echo.txt"; AX check-public "$T/echo.txt" >/dev/null || flunk "a restatement the owner echoed fails check-public"
AX request note rq6 --re rq6.1 "Friday it is" >/dev/null
[ "$(AX request add ask:ask3 "$(mkspec a-r6 '{"shape": "reply", "title": "Choose the day the docs site goes out", "context": "The freeze ends on Thursday."}')")" = "rq6 r2 refreshed" ] \
  || flunk "a request the owner echoed no longer refreshes"
printf 'the docs site goes out Friday after the freeze\n' > "$T/copy.txt"; o=$(AX check-public "$T/copy.txt") && flunk "a copy of the owner's own words passed"; grep -q "copies the owner" <<<"$o" || flunk "the copy: $o"

# --- a symlinked inbox, and a symlinked answer, are refused
mv "$AA" "$T/aa-real"; ln -s "$T/aa-real" "$AA"
o=$(ans_run AX answer put 2>/dev/null <<<'{"request": "rq2", "rev": 2, "kind": "reply", "text": "x"}'); [ "$o" = "rc=2" ] || flunk "a put into a symlinked inbox: $o"
want='must be a directory'; nope AX answer list --json; nope AX answer take rq2.11; rm "$AA"; mv "$T/aa-real" "$AA"
ln -s "$AA/refused/rq2.11.json" "$AA/rq2.20.json"; want='a symlink'; nope AX answer take rq2.20
AX answer list --json | jq -e 'any(.errors[]; . == {file: "rq2.20.json", error: "a symlink"})' >/dev/null || flunk "answer list over a symlinked answer"; rm "$AA/rq2.20.json"

# --- the viewer's environment: put and list find bun and gitleaks at the install paths
AV() { ORCHY_HOME="$AH" ORCHY_REPO=example/answers viewer "$@"; }
[ "$(printf '%s' '{"request": "rq2", "rev": 2, "kind": "reply", "text": "and Italian?"}' | AV answer put | jq -r .state)" = pending ] || flunk "a put in the viewer's environment"
[ "$(printf '%s' "{\"request\": \"rq4\", \"rev\": 1, \"kind\": \"reply\", \"text\": \"$KEY\"}" | AV answer put 2>/dev/null | jq -r .reason)" = secret ] || flunk "the viewer's put found no gitleaks"
[ "$(AV answer list --json)" = "$(AX answer list --json)" ] || flunk "answer list differs in the viewer's environment"

# --- the answers feed against its golden, with a withheld row; a closed request's answers only with --all
GD="$ORCHY_CAPACITY_ROOT/gold"; mkdir -p "$GD"; cp "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json" "$GD/"
GDX() { ORCHY_HOME="$GD" ORCHY_REPO=example/gold "$ORCHY" "$@"; }; GA="$ORCHY_ASKS_DIR/example-gold.answers"
GDX lock >/dev/null; GDX ask add "use the quick checks for the docs" >/dev/null
for x in "ask:ask1=$PK" 'pr:12={"shape": "done", "title": "Rename the required check, then say done", "steps": [{"text": "Rename e2e to e2e-status"}]}' \
  'other:filing={"shape": "approve", "title": "File the cleanup issues", "wording": "File three issues.", "binding": {"kind": "text"}}' 'issue:7={"shape": "reply", "title": "Which locale ships first?"}'; do
  GDX request add "${x%%=*}" "$(mkspec "g-${x%%=*}" "${x#*=}")" >/dev/null; done
gput() { printf '%s' "$1" | GDX answer put | jq -r .state; }
[ "$(gput '{"request": "rq1", "rev": 1, "kind": "pick", "choice": "other", "text": "Run both in the nightly job", "note": "Unit gates the PR"}')" = pending ] \
  && [ "$(gput "$(jq -nc '{request: "rq2", rev: 1, kind: "done", note: "Renamed it", log: "e2e-status\tpass\nlint\tpass"}')")" = pending ] \
  && [ "$(gput '{"request": "rq4", "rev": 1, "kind": "reply", "text": "Spanish first"}')" = pending ] || flunk "the golden's answers"
jq -nc --arg k "$KEY" --arg at "$(date -u +%FT%TZ)" --argjson b "$(jq -c .binding "$ORCHY_ASKS_DIR/example-gold.requests/rq3.json")" \
  '{schema: "orchy.answer/1", id: "rq3.1", request: "rq3", rev: 1, kind: "approve", at: $at, go: true, binding: $b, note: "token \($k)"}' > "$GA/rq3.1.json"
GDX answer take rq2.1 >/dev/null && ! GDX answer take rq3.1 >/dev/null && GDX answer take rq4.1 >/dev/null || flunk "the golden's takes"
GDX request note rq4 --re rq4.1 "Spanish first, then" >/dev/null && GDX request withdraw rq4 "Asked in chat instead" >/dev/null || flunk "the golden's closed request"
gn='.answers[] |= (if has("at") then .at = "2026-10-31T10:00:00Z" else . end)'
diff <(jq -S . "$G/answers.v1.json") <(GDX answer list --json | jq -S "$gn") || flunk "answer list JSON drifted from tests/mocks/orchy/answers.v1.json"
GDX answer list --json --all | jq -e '[.answers[].id] == ["rq1.1", "rq2.1", "rq3.1", "rq4.1"]' >/dev/null || flunk "--all does not add the closed request's answer"
echo "smoke-orchy-requests: ok"
