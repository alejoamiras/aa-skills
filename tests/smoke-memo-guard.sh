#!/usr/bin/env bash
# shellcheck disable=SC2016 # the payloads are literal commands, never expanded here
# Smoke test for claude/memo-guard.sh, the PreToolUse hook that keeps Claude Code subagents off memo.
# Feeds it synthetic hook input; needs jq and python3. Skips when the private submodule is absent.
set -uo pipefail

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claude/memo-guard.sh"
[ -f "$GUARD" ] || { echo "skip  claude/ submodule not initialized"; exit 0; }
FAIL=0

payload() { python3 -c 'import json,sys;print(json.dumps({"agent_id":"a1","agent_type":"general-purpose","tool_input":{"command":sys.argv[1]}}))' "$1"; }
expect() { # expect <exit> <label> <input>
  printf '%s' "$3" | bash "$GUARD" 2>/dev/null
  local rc=$?
  if [ "$rc" = "$1" ]; then echo "ok    $2"; else echo "FAIL  $2 (exit $rc)"; FAIL=1; fi
}

for c in 'memo wake' ' memo status' $'ls\nmemo status' 'command memo status' '"memo" status' 'memo; echo hi' \
  'FOO=1 env -i memo note x' 'ls && ~/.local/bin/memo status' 'echo $(memo recall x)' 'printf "%s" "$(memo wake)"' \
  'memo>/dev/null' 'env -u FOO memo status' 'nice -n 5 memo status' 'if memo status; then :; fi' 'ls | xargs memo note'; do
  expect 2 "subagent blocked: $c" "$(payload "$c")"
done
for c in 'rg "x; memo status" AGENTS.md' 'rg memo src' 'cat memory.md remote-opt-memo/x' 'git commit -m "wire memo"' \
  'ls | grep memo' "rg '!memo' AGENTS.md" 'echo \; memo' 'sudo -u bob ls memo' 'rg "x; memo status $suffix" AGENTS.md'; do
  expect 0 "subagent allowed: $c" "$(payload "$c")"
done
expect 0 "main session runs memo" '{"tool_input":{"command":"memo wake"}}'
expect 2 "unreadable input blocks" 'not json'

if [ $FAIL -eq 0 ]; then echo "ALL OK"; else echo "SOME FAILED"; fi
exit $FAIL
