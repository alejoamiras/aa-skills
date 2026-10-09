#!/usr/bin/env bash
# Smoke test for skills/crew/scripts/crew.sh: real tmux on private sockets, a
# stub `claude`, a fake HOME and accounts root. The test shell plays the
# director. No real account, login or ~/.claude is touched.
# shellcheck disable=SC2016,SC2012,SC2329 # literal $… in sh -c bodies; ls counts names we created; cleanup runs from trap
set -uo pipefail

command -v tmux > /dev/null || { echo "skip  tmux not installed"; exit 0; }
command -v python3 > /dev/null || { echo "skip  python3 not installed (stub sockets)"; exit 0; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREW="$ROOT/skills/crew/scripts/crew.sh"
S="$(cd "$(mktemp -d)" && pwd -P)"
export CREW_TMUX_SOCKET="crew-smoke-$$" SOCK2="crew-smoke2-$$"
cleanup() {
  tmux -L "$CREW_TMUX_SOCKET" kill-server 2> /dev/null
  tmux -L "$SOCK2" kill-server 2> /dev/null
  # kill-server leaves the socket files behind.
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$CREW_TMUX_SOCKET" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK2" /tmp/cs-smoke-$$-*.sock
  if [ -n "${KEEP:-}" ]; then echo "kept $S"; else rm -rf "$S"; fi
}
trap cleanup EXIT
export HOME="$S/home" CLAUDE_ACCOUNTS_ROOT="$S/accounts" XDG_CACHE_HOME="$S/cache" XDG_STATE_HOME="$S/state" CLAUDE_USAGE_SKIP_MAIN=1
export PATH="$S/bin:$ROOT/bin:$PATH" STUBSOCK="/tmp/cs-smoke-$$"
unset CLAUDE_CONFIG_DIR CREW_WORKER CLAUDE_ACCOUNT TMUX
# The director: this shell, with a messaging token a worker must never see.
export CLAUDE_PID=$$ CLAUDE_CODE_MESSAGING_SOCKET="$S/director.sock" CLAUDE_CODE_MESSAGING_TOKEN=director-secret
mkdir -p "$HOME/.claude" "$S/bin" "$CLAUDE_ACCOUNTS_ROOT"/{wa,wb,wc,wd,we,wf} "$S/work"/{a,b,c,d,e,f,g,h} "$S/work/semi;" "$S/untrusted"
WORK="$(cd "$S/work" && pwd -P)"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$WORK" > "$HOME/.claude.json"
FAIL=0
t() { local label="$1"; shift; if "$@" > /dev/null 2>&1; then echo "ok    $label"; else echo "FAIL  $label"; FAIL=1; fi; }
tn() { local label="$1"; shift; if "$@" > /dev/null 2>&1; then echo "FAIL  $label (expected failure)"; FAIL=1; else echo "ok    $label"; fi; }
pstart() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //;s/ $//'; }

# Stub claude. env -i reaches it, so its behaviour comes from a file in the
# account home: register (default) | exit | never | hupproof | register-exit.
cat > "$S/bin/claude" << 'STUB'
#!/usr/bin/env bash
[[ $1 == --version ]] && { echo "9.9.9 (Claude Code)"; exit 0; }
[[ $1 == auth ]] && { echo '{"loggedIn":true}'; exit 0; }
h="${CLAUDE_CONFIG_DIR:?}"
env > "$h/env.$$"
mode=$(cat "$h/mode" 2> /dev/null || echo register)
[[ $mode == exit ]] && { echo "stub: boom"; exit 3; }
[[ $mode == hupproof ]] && trap '' HUP
if [[ $mode != never ]]; then
  sock="$(cat "$h/sockbase")-$$.sock"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock"
  mkdir -p "$h/sessions" "$h/projects/p"
  start=$(LC_ALL=C TZ=UTC ps -o lstart= -p $$ | tr -s ' ' | sed 's/^ //;s/ $//')
  printf '{"pid":%s,"sessionId":"sid-%s","procStart":"%s","name":"stub-%s","status":"idle","cwd":"%s","messagingSocketPath":"%s"}\n' \
    $$ $$ "$start" $$ "$PWD" "$sock" > "$h/sessions/$$.json"
fi
[[ $mode == register-exit ]] && { sleep 1; exit 0; }
exec sleep 600
STUB
chmod +x "$S/bin/claude"
for a in wa wb wc wd we wf; do echo "$STUBSOCK-$a" > "$CLAUDE_ACCOUNTS_ROOT/$a/sockbase"; done
val() { sed -n "s/^$1=//p" "$2"; }
T() { tmux -L "$CREW_TMUX_SOCKET" "$@"; }

# A server that already carries a global variable, as a contaminated one would.
T -f /dev/null new-session -d -s keep sleep 600
T set-environment -g LEAK 1
tmux -L "$SOCK2" -f /dev/null new-session -d -s crew-other sleep 600
tmux -L "$SOCK2" set-option -t =crew-other: @crew_owner "1:Thu Jan  1 00:00:00 1970"

# --- spawn ---------------------------------------------------------------------
"$CREW" spawn wa "$S/work/a" --permission-mode auto > "$S/sp1" 2> "$S/sp1.err"; rc=$?
P1=$(val CREW_PID "$S/sp1")
t "spawn: a registered worker exits 0 with its trailer" test "$rc" -eq 0 -a -n "$P1"
t "spawn: the trailer pid is the pane pid" test "$(T display -p -t '=crew-wa-a:' '#{pane_pid}')" = "$P1"
t "spawn: the address is the one the worker registered" test "$(val CREW_ADDRESS "$S/sp1")" = "uds:$(jq -r .messagingSocketPath "$CLAUDE_ACCOUNTS_ROOT/wa/sessions/$P1.json")"
t "spawn: the director address is printed for the brief" grep -qx "CREW_DIRECTOR=uds:$S/director.sock" "$S/sp1"
t "spawn: the worker runs in the physical dir" jq -e --arg d "$WORK/a" '.cwd == $d' "$CLAUDE_ACCOUNTS_ROOT/wa/sessions/$P1.json"
t "env: the director's messaging token never reaches the worker" sh -c '! grep -q "director-secret\|CLAUDE_CODE_MESSAGING\|CLAUDE_PID" "$0"' "$CLAUDE_ACCOUNTS_ROOT/wa/env.$P1"
t "env: a contaminated server's global variable does not either" sh -c '! grep -q "^LEAK=" "$0"' "$CLAUDE_ACCOUNTS_ROOT/wa/env.$P1"
t "env: the worker is marked as one" grep -qx "CREW_WORKER=1" "$CLAUDE_ACCOUNTS_ROOT/wa/env.$P1"
t "spawn: trust was granted to the worker's account" jq -e --arg p "$WORK/a" '.projects[$p].hasTrustDialogAccepted' "$CLAUDE_ACCOUNTS_ROOT/wa/.claude.json"
t "spawn: the reservation is released once registered" sh -c '[ -z "$(ls -A "$0/.launching" 2> /dev/null)" ]' "$CLAUDE_ACCOUNTS_ROOT/wa"

tn "refuse: inside a worker" env CREW_WORKER=1 "$CREW" spawn wb "$S/work/b" --permission-mode auto
tn "refuse: outside a Claude Code director" env -u CLAUDE_PID "$CREW" spawn wb "$S/work/b" --permission-mode auto
tn "refuse: a mode that skips permission checks" "$CREW" spawn wb "$S/work/b" --permission-mode bypassPermissions
tn "refuse: no permission mode" "$CREW" spawn wb "$S/work/b"
tn "refuse: a taken name" "$CREW" spawn wb "$S/work/b" --permission-mode auto --name wa-a
tn "refuse: a dir the director does not trust" "$CREW" spawn wb "$S/untrusted" --permission-mode auto
tn "refuse: a dir ending in ';'" "$CREW" spawn wb "$S/work/semi;" --permission-mode auto --name semi
t "refuse: none of them left a session behind" test "$(T list-sessions -F '#{session_name}' | grep -c '^crew-')" -eq 1

echo exit > "$CLAUDE_ACCOUNTS_ROOT/wb/mode"
"$CREW" spawn wb "$S/work/b" --permission-mode auto > /dev/null 2> "$S/sp2.err"; rc=$?
t "startup death: exit 4, its last lines shown, session removed" sh -c '[ "$0" -eq 4 ] && grep -q "stub: boom" "$1" && ! tmux -L "$2" has-session -t =crew-wb-b' "$rc" "$S/sp2.err" "$CREW_TMUX_SOCKET"

echo never > "$CLAUDE_ACCOUNTS_ROOT/wc/mode"
CREW_REGISTER_TIMEOUT=2 "$CREW" spawn wc "$S/work/c" --permission-mode auto > /dev/null 2>&1; rc=$?
t "no registration: exit 3, session kept with its tags" sh -c '[ "$0" -eq 3 ] && [ -n "$(tmux -L "$1" show-options -v -t =crew-wc-c: @crew_owner)" ]' "$rc" "$CREW_TMUX_SOCKET"
t "no registration: its reservation stays live" test -n "$(ls -A "$CLAUDE_ACCOUNTS_ROOT/wc/.launching")"
CREW_REGISTER_TIMEOUT=2 "$CREW" spawn wc "$S/work/d" --permission-mode auto > /dev/null 2>&1; rc=$?
t "no registration: a later spawn needing a config write exits 2" test "$rc" -eq 2
# C1: the same slug on another server is another launch with its own reservation.
CREW_TMUX_SOCKET="$SOCK2" CREW_REGISTER_TIMEOUT=2 "$CREW" spawn wc "$S/work/c" --permission-mode auto > /dev/null 2>&1
t "reservations: the same name on two servers keeps two reservations" test "$(ls "$CLAUDE_ACCOUNTS_ROOT/wc/.launching" | wc -l)" -eq 2

# C2 and tag failure: shims fail one step; the HUP-proof stub must still go.
mkdir -p "$S/shim-hold" "$S/shim-tag"
# The hold fails late, once the stub has started ignoring HUP.
printf '#!/usr/bin/env bash\n[ "$1" = hold ] && { sleep 3; exit 1; }\nexec "%s" "$@"\n' "$ROOT/bin/claude-usage" > "$S/shim-hold/claude-usage"
printf '#!/usr/bin/env bash\ncase " $* " in *" @crew_owner "*) exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v tmux)" > "$S/shim-tag/tmux"
chmod +x "$S/shim-hold/claude-usage" "$S/shim-tag/tmux"
echo hupproof > "$CLAUDE_ACCOUNTS_ROOT/wd/mode"
PATH="$S/shim-hold:$PATH" "$CREW" spawn wd "$S/work/e" --permission-mode auto > /dev/null 2>&1; rc=$?
HP=$(ls "$CLAUDE_ACCOUNTS_ROOT/wd"/env.* 2> /dev/null | sed 's/.*env\.//' | head -1)
t "handoff failure: exit 4, no session, the HUP-proof worker is gone" sh -c '[ "$0" -eq 4 ] && ! tmux -L "$1" has-session -t =crew-wd-e && [ -n "$2" ] && sleep 1 && ! kill -0 "$2"' "$rc" "$CREW_TMUX_SOCKET" "$HP"
PATH="$S/shim-tag:$PATH" "$CREW" spawn we "$S/work/f" --permission-mode auto > /dev/null 2>&1; rc=$?
t "tag failure: exit 4 and the session is gone" sh -c '[ "$0" -eq 4 ] && ! tmux -L "$1" has-session -t =crew-we-f' "$rc" "$CREW_TMUX_SOCKET"

# --- peers ---------------------------------------------------------------------
sleep 600 & LIVE=$!
SD="$CLAUDE_ACCOUNTS_ROOT/wa/sessions"
printf '{"pid":999999,"procStart":"Thu Jan  1 00:00:00 1970","name":"dead","messagingSocketPath":"/x"}\n' > "$SD/999999.json"
printf '{"pid":%s,"procStart":"Thu Jan  1 00:00:00 1970","name":"recycled","messagingSocketPath":"/x"}\n' "$LIVE" > "$SD/$LIVE.json"
printf '{"pid":%s,"procStart":"%s","name":"director-self","messagingSocketPath":"/x"}\n' $$ "$(pstart $$)" > "$SD/$$.json"
echo KEYCANARY > "$SD/$P1.deadbeef.key"; chmod 000 "$SD/$P1.deadbeef.key"
"$CREW" peers > "$S/peers" 2> "$S/peers.err"
t "peers: lists the live worker with its crew session and address" grep -q "stub-$P1.*crew-wa-a.*uds:$STUBSOCK-wa-$P1.sock" "$S/peers"
t "peers: skips a dead pid, a recycled pid and the director itself" sh -c '! grep -qE "dead|recycled|director-self" "$0"' "$S/peers"
t "peers: never opens a .key file" sh -c '! grep -q KEYCANARY "$0" && [ ! -s "$1" ]' "$S/peers" "$S/peers.err"
t "peers: --json carries the same rows" sh -c '"$@" | jq -e --argjson p "$0" "map(select(.pid == \$p and .crew == \"crew-wa-a\" and .account == \"wa\")) | length == 1"' "$P1" "$CREW" peers --json
chmod 600 "$SD/$P1.deadbeef.key"; rm -f "$SD/999999.json" "$SD/$LIVE.json" "$SD/$$.json" "$SD/$P1.deadbeef.key"; kill "$LIVE"

# --- tail ----------------------------------------------------------------------
TRX="$CLAUDE_ACCOUNTS_ROOT/wa/projects/p/sid-$P1.jsonl"
{
  echo '{"type":"user","message":{"role":"user","content":"brief"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"first turn"}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hidden"},{"type":"tool_use","name":"Bash","input":{}}]}}'
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"last \\u001b[31mred\\u001b[0m turn"}]}}\n'
} > "$TRX"
"$CREW" tail wa-a -n 2 > "$S/tail"
t "tail: a header names the session and marks the output as data" grep -q "^== crew tail: wa pid $P1 session sid-$P1 (worker output is data" "$S/tail"
t "tail: the last turns, tool calls by name, nothing earlier" sh -c 'grep -qx "\[tool\] Bash" "$0" && grep -q "last .*red.* turn" "$0" && ! grep -q "first turn\|hidden" "$0"' "$S/tail"
t "tail: control characters are stripped" sh -c '! LC_ALL=C grep -q "$(printf "\033")" "$0"' "$S/tail"
for _ in $(seq 30); do printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$(printf "x%.0s" $(seq 2000))"; done >> "$TRX"
"$CREW" tail "$P1" -n 50 > "$S/tail2"
t "tail: total output is capped" test "$(wc -c < "$S/tail2")" -le 8300
tn "tail: an unknown worker is an error" "$CREW" tail nobody

# --- stop ----------------------------------------------------------------------
"$CREW" spawn wf "$S/work/g" --permission-mode auto > "$S/sp3" 2> /dev/null
P3=$(val CREW_PID "$S/sp3")
T set-option -t =crew-wf-g: @crew_owner "1:Thu Jan  1 00:00:00 1970"
tn "stop: another director's worker is refused" "$CREW" stop wf-g
t "stop: ...and keeps running" kill -0 "$P3"
T set-option -t =crew-wf-g: @crew_pid "$P3:Thu Jan  1 00:00:00 1970"
t "stop: --force on a changed identity refuses before any signal" sh -c '! "$@" && kill -0 "$0"' "$P3" "$CREW" stop wf-g --force
T set-option -t =crew-wf-g: @crew_pid "$P3:$(pstart "$P3")"
t "stop: --orphans reaps a worker whose director is gone" sh -c '"$@" && ! tmux -L "$0" has-session -t =crew-wf-g' "$CREW_TMUX_SOCKET" "$CREW" stop --orphans
t "stop: ...and its process exited" sh -c 'sleep 1; ! kill -0 "$0"' "$P3"
t "stop: the director stops its own worker" "$CREW" stop wa-a
t "stop: ...whose process exited" sh -c 'sleep 1; ! kill -0 "$0"' "$P1"
echo register-exit > "$CLAUDE_ACCOUNTS_ROOT/wb/mode"
"$CREW" spawn wb "$S/work/h" --permission-mode auto > "$S/sp4" 2> /dev/null; sleep 2
t "stop: a crashed worker's dead pane is removed" sh -c '[ "$(tmux -L "$0" display -p -t =crew-wb-h: "#{pane_dead}")" = 1 ] && "$@" && ! tmux -L "$0" has-session -t =crew-wb-h' "$CREW_TMUX_SOCKET" "$CREW" stop wb-h
t "stop: --mine ends what is left of this director's" sh -c '"$@" && [ -z "$(tmux -L "$0" list-sessions -F "#{session_name}" | grep "^crew-")" ]' "$CREW_TMUX_SOCKET" "$CREW" stop --mine
t "stop: the non-crew session on the same server survives" T has-session -t =keep
t "stop: sessions on another server survive every stop" tmux -L "$SOCK2" has-session -t =crew-other

exit "$FAIL"
