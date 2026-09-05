#!/usr/bin/env bash
# Resume an existing headless Claude Code session by id and print a structured
# trailer. Mirror of the codex skill's resume-codex.sh.
#
# Usage: resume-claude.sh <session-id-or-empty> <prompt-file> [claude-dir] [effort] [model]
#   session-id   The UUID returned by run-claude.sh as SESSION_ID=...
#                Pass the empty string ("") to infer it from <claude-dir>/session_id.
#   prompt-file  Required. Path to a file containing the follow-up prompt.
#   claude-dir   Optional. The CLAUDE_DIR returned by run-claude.sh. If supplied,
#                response/log files are written under it with numbered suffixes
#                so prior turns are preserved, and the run resumes in the cwd
#                (and, by default, the model) recorded there. If both session-id
#                and claude-dir are supplied, the script verifies they match and
#                refuses to run if they do not. If claude-dir is omitted, a fresh
#                dir is created with the same metadata, so it too can be resumed
#                later with "" as the id; the session then resumes in $PWD.
#   effort       Optional. Defaults to xhigh.
#   model        Optional. Defaults to $CLAUDE_MODEL, else the model recorded in
#                <claude-dir>/model, else fable — so a session that fell back to
#                opus stays on opus unless you say otherwise.
#
# The isolation flags (--safe-mode --restricted --strict-mcp-config, read-only
# tools) do not persist in a session and are re-applied on every resume.
#
# Output: same structured trailer as run-claude.sh. Exit 1 if Claude reported an
# error, produced malformed output, or answered under a DIFFERENT session id —
# the trailer then carries the id Claude actually used.
#
# WARNING: Do not run resume-claude.sh in parallel against the same CLAUDE_DIR.
# The numbered-suffix selection is not atomic. Sequential resumes are safe.

set -euo pipefail

SID="${1-}"
PROMPT_FILE="${2:?prompt file required}"
CLAUDE_DIR="${3:-}"
EFFORT="${4:-xhigh}"
MODEL_ARG="${5:-}"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi
if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required to parse Claude's JSON result" >&2
  exit 2
fi

# Resolve session id: explicit arg, else read from CLAUDE_DIR/session_id.
if [[ -z "$SID" ]]; then
  if [[ -z "$CLAUDE_DIR" || ! -f "$CLAUDE_DIR/session_id" ]]; then
    echo "ERROR: no session id supplied and no $CLAUDE_DIR/session_id to recover from" >&2
    exit 2
  fi
  SID=$(cat "$CLAUDE_DIR/session_id")
fi

if [[ ! "$SID" =~ ^[0-9a-f-]{36}$ ]]; then
  echo "ERROR: session id does not look like a UUID: $SID" >&2
  exit 2
fi

# If we have both, verify they belong together.
if [[ -n "$CLAUDE_DIR" && -f "$CLAUDE_DIR/session_id" ]]; then
  STORED=$(cat "$CLAUDE_DIR/session_id")
  if [[ -n "$STORED" && "$STORED" != "$SID" ]]; then
    echo "ERROR: session id mismatch: arg=$SID, stored in $CLAUDE_DIR/session_id=$STORED" >&2
    echo "       Refusing to run — passing the wrong CLAUDE_DIR would cross-contaminate artifacts." >&2
    exit 2
  fi
fi

# Everything below cd's into the recorded cwd, so resolve caller-relative paths first.
CWD="$PWD"
MODEL="fable"
if [[ -z "$CLAUDE_DIR" ]]; then
  CLAUDE_DIR=$(mktemp -d -t claude-XXXXXXXX)
  printf '%s' "$SID" > "$CLAUDE_DIR/session_id"
elif [[ ! -d "$CLAUDE_DIR" ]]; then
  echo "ERROR: claude dir does not exist: $CLAUDE_DIR" >&2
  exit 2
else
  CLAUDE_DIR="$(cd "$CLAUDE_DIR" && pwd -P)"
  [[ -f "$CLAUDE_DIR/cwd" ]] && CWD="$(cat "$CLAUDE_DIR/cwd")"
  [[ -f "$CLAUDE_DIR/model" ]] && MODEL="$(cat "$CLAUDE_DIR/model")"
fi
MODEL="${MODEL_ARG:-${CLAUDE_MODEL:-$MODEL}}"
if [[ ! -d "$CWD" ]]; then
  echo "ERROR: recorded cwd no longer exists: $CWD" >&2
  exit 2
fi
printf '%s' "$CWD" > "$CLAUDE_DIR/cwd"
printf '%s' "$MODEL" > "$CLAUDE_DIR/model"

N=1
while [[ -e "$CLAUDE_DIR/response-$N.md" ]]; do
  N=$((N + 1))
done
RESPONSE_FILE="$CLAUDE_DIR/response-$N.md"
LOG_FILE="$CLAUDE_DIR/log-$N.json"
FOLLOWUP="$CLAUDE_DIR/followup-$N.md"

cp "$PROMPT_FILE" "$FOLLOWUP"

echo "Resuming claude session $SID (model=$MODEL, effort=$EFFORT, cwd=$CWD)..." >&2
echo "Output dir: $CLAUDE_DIR" >&2

set +e
(
  cd "$CWD" && CLAUDE_CODE_EFFORT_LEVEL="$EFFORT" claude -p \
    --resume "$SID" \
    --safe-mode \
    --restricted \
    --strict-mcp-config \
    --tools "Read,Grep,Glob" \
    --permission-prompts none \
    --output-format json \
    --model "$MODEL" \
    --effort "$EFFORT" \
    < "$FOLLOWUP"
) > "$LOG_FILE" 2> "$CLAUDE_DIR/stderr-$N.log"
EXIT=$?
set -e

GOT=""
if jq -e -s 'length == 1 and (.[0] | type == "object" and .type == "result" and (.session_id | type == "string" and test("^[0-9a-f-]{36}$")) and (.result | type == "string") and (.is_error | type == "boolean"))' \
    "$LOG_FILE" > /dev/null 2>&1; then
  GOT=$(jq -r '.session_id' "$LOG_FILE")
  jq -r '.result' "$LOG_FILE" > "$RESPONSE_FILE"
  if [[ $EXIT -eq 0 ]] && ! jq -e '.is_error == false' "$LOG_FILE" > /dev/null 2>&1; then
    echo "ERROR: claude reported is_error=true" >&2
    EXIT=1
  fi
else
  : > "$RESPONSE_FILE"
  if [[ $EXIT -eq 0 ]]; then
    echo "ERROR: claude exited 0 but its output is not a single result object (see $LOG_FILE)" >&2
    EXIT=1
  fi
fi

# A resume that answers under another id has silently started a new session;
# report the id Claude actually used and fail, so the caller never keeps
# "resuming" a conversation that does not exist.
if [[ -n "$GOT" && "$GOT" != "$SID" ]]; then
  echo "ERROR: claude answered under session $GOT, not $SID — the resume did not attach to the original session" >&2
  SID="$GOT"
  [[ $EXIT -eq 0 ]] && EXIT=1
fi

if [[ $EXIT -ne 0 ]]; then
  echo "ERROR: claude -p --resume failed (status $EXIT)" >&2
  echo "--- stderr tail ---" >&2
  tail -30 "$CLAUDE_DIR/stderr-$N.log" >&2
  echo "--- result ---" >&2
  head -c 2000 "$RESPONSE_FILE" >&2
  echo >&2
fi

echo "CLAUDE_DIR=$CLAUDE_DIR"
echo "SESSION_ID=$SID"
echo "RESPONSE_FILE=$RESPONSE_FILE"
echo "LOG_FILE=$LOG_FILE"

exit $EXIT
