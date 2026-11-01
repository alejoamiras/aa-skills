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
echo "smoke-orchy-requests: ok"
