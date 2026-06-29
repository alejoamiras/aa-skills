#!/usr/bin/env bash
# Run a fresh codex session and print a structured trailer for the caller.
#
# Usage: run-codex.sh <prompt-file> [cwd] [effort] [sandbox]
#   prompt-file  Required. Path to a file containing the prompt for codex.
#   cwd          Optional. Defaults to $PWD. Passed to codex via -C.
#   effort       Optional. Defaults to xhigh. Passed via -c model_reasoning_effort=...
#   sandbox      Optional. Defaults to read-only. Passed via --sandbox.
#
# Output: human-readable progress on stderr, codex log redirected to a file.
# The last 4 lines of stdout are guaranteed to be:
#
#   CODEX_DIR=<absolute path>
#   SESSION_ID=<uuid or empty>
#   RESPONSE_FILE=<absolute path>
#   LOG_FILE=<absolute path>
#
# The caller (Claude) should read the SESSION_ID into the conversation
# transcript so follow-up turns can resume the same session.

set -euo pipefail

PROMPT_FILE="${1:?prompt file required}"
CWD="${2:-$PWD}"
EFFORT="${3:-xhigh}"
SANDBOX="${4:-read-only}"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi
if [[ ! -d "$CWD" ]]; then
  echo "ERROR: cwd is not a directory: $CWD" >&2
  exit 2
fi

CODEX_DIR=$(mktemp -d -t codex-XXXXXXXX)
RESPONSE_FILE="$CODEX_DIR/response.md"
LOG_FILE="$CODEX_DIR/log.jsonl"
SESSION_ID_FILE="$CODEX_DIR/session_id"

cp "$PROMPT_FILE" "$CODEX_DIR/prompt.md"

echo "Running codex (effort=$EFFORT, sandbox=$SANDBOX, cwd=$CWD)..." >&2
echo "Output dir: $CODEX_DIR" >&2

set +e
codex exec \
  --json \
  --sandbox "$SANDBOX" \
  --skip-git-repo-check \
  -c "model_reasoning_effort=$EFFORT" \
  -C "$CWD" \
  -o "$RESPONSE_FILE" \
  - < "$PROMPT_FILE" \
  > "$LOG_FILE" 2>&1
EXIT=$?
set -e

# First JSONL event is `thread.started` and carries thread_id (== session id).
# Anchored on key name to avoid matching unrelated UUIDs in the stream.
SID=$(head -n 1 "$LOG_FILE" 2>/dev/null \
  | grep -oE '"thread_id":"[0-9a-f-]{36}"' \
  | grep -oE '[0-9a-f-]{36}' \
  | head -n 1 || true)
printf '%s' "$SID" > "$SESSION_ID_FILE"

if [[ -z "$SID" ]]; then
  echo "WARNING: could not extract session id from log; resume will be impossible." >&2
fi

if [[ $EXIT -ne 0 ]]; then
  echo "ERROR: codex exec exited with status $EXIT" >&2
  echo "--- log tail ---" >&2
  tail -50 "$LOG_FILE" >&2
fi

echo "CODEX_DIR=$CODEX_DIR"
echo "SESSION_ID=$SID"
echo "RESPONSE_FILE=$RESPONSE_FILE"
echo "LOG_FILE=$LOG_FILE"

exit $EXIT
