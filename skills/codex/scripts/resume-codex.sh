#!/usr/bin/env bash
# Resume an existing codex session by id and print a structured trailer.
#
# Usage: resume-codex.sh <session-id-or-empty> <prompt-file> [codex-dir] [effort]
#   session-id   The UUID returned by run-codex.sh as SESSION_ID=...
#                Pass the empty string ("") to infer it from <codex-dir>/session_id.
#   prompt-file  Required. Path to a file containing the follow-up prompt.
#   codex-dir    Optional. The CODEX_DIR returned by run-codex.sh. If supplied,
#                response/log files are written under it with numbered suffixes
#                so prior turns are preserved. If both session-id and codex-dir
#                are supplied, the script verifies they match and refuses to run
#                if they do not. If codex-dir is omitted, a fresh dir is created.
#   effort       Optional. Defaults to xhigh.
#
# Output: same structured trailer as run-codex.sh.
#
# WARNING: Do not run resume-codex.sh in parallel against the same CODEX_DIR.
# The numbered-suffix selection is not atomic. Sequential resumes are safe.

set -euo pipefail

SID="${1-}"
PROMPT_FILE="${2:?prompt file required}"
CODEX_DIR="${3:-}"
EFFORT="${4:-xhigh}"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi

# Resolve session id: explicit arg, else read from CODEX_DIR/session_id.
if [[ -z "$SID" ]]; then
  if [[ -z "$CODEX_DIR" || ! -f "$CODEX_DIR/session_id" ]]; then
    echo "ERROR: no session id supplied and no $CODEX_DIR/session_id to recover from" >&2
    exit 2
  fi
  SID=$(cat "$CODEX_DIR/session_id")
fi

if [[ ! "$SID" =~ ^[0-9a-f-]{36}$ ]]; then
  echo "ERROR: session id does not look like a UUID: $SID" >&2
  exit 2
fi

# If we have both, verify they belong together.
if [[ -n "$CODEX_DIR" && -f "$CODEX_DIR/session_id" ]]; then
  STORED=$(cat "$CODEX_DIR/session_id")
  if [[ -n "$STORED" && "$STORED" != "$SID" ]]; then
    echo "ERROR: session id mismatch: arg=$SID, stored in $CODEX_DIR/session_id=$STORED" >&2
    echo "       Refusing to run — passing the wrong CODEX_DIR would cross-contaminate artifacts." >&2
    exit 2
  fi
fi

if [[ -z "$CODEX_DIR" ]]; then
  CODEX_DIR=$(mktemp -d -t codex-XXXXXXXX)
elif [[ ! -d "$CODEX_DIR" ]]; then
  echo "ERROR: codex dir does not exist: $CODEX_DIR" >&2
  exit 2
fi

N=1
while [[ -e "$CODEX_DIR/response-$N.md" ]]; do
  N=$((N + 1))
done
RESPONSE_FILE="$CODEX_DIR/response-$N.md"
LOG_FILE="$CODEX_DIR/log.jsonl"

cp "$PROMPT_FILE" "$CODEX_DIR/followup-$N.md"

echo "Resuming codex session $SID (effort=$EFFORT)..." >&2
echo "Output dir: $CODEX_DIR" >&2

set +e
codex exec resume "$SID" \
  --json \
  --skip-git-repo-check \
  -c "model_reasoning_effort=$EFFORT" \
  -o "$RESPONSE_FILE" \
  - < "$PROMPT_FILE" \
  >> "$LOG_FILE" 2>&1
EXIT=$?
set -e

if [[ $EXIT -ne 0 ]]; then
  echo "ERROR: codex exec resume exited with status $EXIT" >&2
  echo "--- log tail ---" >&2
  tail -50 "$LOG_FILE" >&2
fi

echo "CODEX_DIR=$CODEX_DIR"
echo "SESSION_ID=$SID"
echo "RESPONSE_FILE=$RESPONSE_FILE"
echo "LOG_FILE=$LOG_FILE"

exit $EXIT
