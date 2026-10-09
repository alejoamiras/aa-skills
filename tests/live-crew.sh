#!/usr/bin/env bash
# Live check of crew against a real claude-usage account: spawn a worker,
# confirm it registered with no first-run prompt, stop it, confirm it exited.
# Spends a sliver of that account's quota (one session start, no prompt).
#
#   CREW_LIVE=<account> bash tests/live-crew.sh
#
# Run it from a Claude Code session's Bash tool: spawn needs the director's
# CLAUDE_PID and messaging socket. Without CREW_LIVE it skips.
# shellcheck disable=SC2329 # cleanup runs from trap
set -uo pipefail

[ -n "${CREW_LIVE:-}" ] || { echo "skip  set CREW_LIVE=<account> to run"; exit 0; }
if [ -z "${CLAUDE_PID:-}" ] || [ -z "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ]; then
  echo "FAIL  run this from a Claude Code session's Bash tool (spawn needs the director)"
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PATH="$ROOT/bin:$PATH" CREW_TMUX_SOCKET="crew-live-$$"
CREW="$ROOT/skills/crew/scripts/crew.sh"
# Under the repo root, which the director trusts when it works in this repo.
DIR="$ROOT/.crew-live-$$"
mkdir -p "$DIR"
OUT=$(mktemp)
cleanup() {
  "$CREW" stop --mine > /dev/null 2>&1
  tmux -L "$CREW_TMUX_SOCKET" kill-server 2> /dev/null
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$CREW_TMUX_SOCKET"
  rm -rf "$DIR" "$OUT"
}
trap cleanup EXIT
FAIL=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; FAIL=1; }

"$CREW" spawn "$CREW_LIVE" "$DIR" --permission-mode default --name live > "$OUT"; rc=$?
PID=$(sed -n 's/^CREW_PID=//p' "$OUT")
KEY=$(sed -n 's/^CREW_ACCOUNT=//p' "$OUT")
if [ "$rc" -eq 0 ] && [ -n "$PID" ]; then ok "spawn: $KEY registered as pid $PID"; else bad "spawn exited $rc"; exit 1; fi

HOME_DIR="${CLAUDE_ACCOUNTS_ROOT:-$HOME/.claude-accounts}/$KEY"
[ "$KEY" = main ] && HOME_DIR="$HOME/.claude"
if jq -e '.messagingSocketPath and .version' "$HOME_DIR/sessions/$PID.json" > /dev/null 2>&1; then
  ok "registration: Claude Code $(jq -r .version "$HOME_DIR/sessions/$PID.json") with a messaging socket"
else
  bad "registration file incomplete"
fi
PANE=$(tmux -L "$CREW_TMUX_SOCKET" capture-pane -p -t "=crew-live:")
if printf '%s' "$PANE" | grep -qiE 'trust (this|the files)|choose the text style|select.*theme'; then bad "a first-run prompt is on screen"; else ok "no first-run prompt on screen"; fi

if "$CREW" stop live > /dev/null; then ok "stop: crew-live stopped"; else bad "stop refused"; fi
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2> /dev/null || break; sleep 1; done
if kill -0 "$PID" 2> /dev/null; then bad "pid $PID still alive after stop"; else ok "the worker process exited"; fi

exit "$FAIL"
