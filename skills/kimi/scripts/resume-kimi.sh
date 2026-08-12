#!/usr/bin/env bash
# Resume an existing Kimi Code session by id and print a structured trailer.
#
# Usage: resume-kimi.sh <session-id-or-empty> <prompt-file> [kimi-dir] [effort] [model]
#   session-id   The id returned by run-kimi.sh as SESSION_ID=...
#                Pass the empty string ("") to infer it from <kimi-dir>/session_id.
#   prompt-file  Required. Path to a file containing the follow-up prompt.
#   kimi-dir     Optional. The KIMI_DIR returned by run-kimi.sh. If supplied,
#                response/log files are written under it with numbered suffixes
#                so prior turns are preserved, and the run reuses the original
#                cwd stored at <kimi-dir>/cwd. If both session-id and kimi-dir
#                are supplied, the script verifies they match and refuses to run
#                if they do not. If kimi-dir is omitted, a fresh dir is created
#                and the current directory is used as cwd.
#   effort       Optional. Defaults to max (KIMI_MODEL_THINKING_EFFORT override).
#   model        Optional. Defaults to $KIMI_MODEL, else the config default_model.
#
# Output: same structured trailer as run-kimi.sh (last 5 lines of stdout):
#   KIMI_DIR= / SESSION_ID= / RESPONSE_FILE= / LOG_FILE= / FILES_CHANGED=
#
# WARNING: Do not run resume-kimi.sh in parallel against the same KIMI_DIR.
# The numbered-suffix selection is not atomic. Sequential resumes are safe.

set -euo pipefail

SID="${1-}"
PROMPT_FILE="${2:?prompt file required}"
KIMI_DIR="${3:-}"
EFFORT="${4:-max}"
MODEL="${5:-${KIMI_MODEL:-}}"
MODEL_ARGS=()
[[ -n "$MODEL" ]] && MODEL_ARGS=(-m "$MODEL")

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi
if [[ "$(wc -c < "$PROMPT_FILE")" -gt 200000 ]]; then
  echo "ERROR: prompt file exceeds 200KB; point kimi at files in cwd instead of inlining them" >&2
  exit 2
fi

# Resolve session id: explicit arg, else read from KIMI_DIR/session_id.
if [[ -z "$SID" ]]; then
  if [[ -z "$KIMI_DIR" || ! -f "$KIMI_DIR/session_id" ]]; then
    echo "ERROR: no session id supplied and no $KIMI_DIR/session_id to recover from" >&2
    exit 2
  fi
  SID=$(cat "$KIMI_DIR/session_id")
fi

# Session ids are opaque tokens (shape varies across kimi versions) — just
# reject anything that couldn't be a single CLI argument.
if [[ ! "$SID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: session id does not look like a valid token: $SID" >&2
  exit 2
fi

# If we have both, verify they belong together.
if [[ -n "$KIMI_DIR" && -f "$KIMI_DIR/session_id" ]]; then
  STORED=$(cat "$KIMI_DIR/session_id")
  if [[ -n "$STORED" && "$STORED" != "$SID" ]]; then
    echo "ERROR: session id mismatch: arg=$SID, stored in $KIMI_DIR/session_id=$STORED" >&2
    echo "       Refusing to run — passing the wrong KIMI_DIR would cross-contaminate artifacts." >&2
    exit 2
  fi
fi

if [[ -z "$KIMI_DIR" ]]; then
  KIMI_DIR=$(mktemp -d -t kimi-XXXXXXXX)
elif [[ ! -d "$KIMI_DIR" ]]; then
  echo "ERROR: kimi dir does not exist: $KIMI_DIR" >&2
  exit 2
fi

# Reuse the original run's cwd when recorded; kimi has no -C flag.
CWD="$PWD"
if [[ -f "$KIMI_DIR/cwd" ]]; then
  CWD=$(cat "$KIMI_DIR/cwd")
fi
if [[ ! -d "$CWD" ]]; then
  echo "ERROR: recorded cwd no longer exists: $CWD" >&2
  exit 2
fi

N=1
while [[ -e "$KIMI_DIR/response-$N.md" ]]; do
  N=$((N + 1))
done
RESPONSE_FILE="$KIMI_DIR/response-$N.md"
LOG_FILE="$KIMI_DIR/log-$N.txt"

cp "$PROMPT_FILE" "$KIMI_DIR/followup-$N.md"

IS_GIT=""
GIT_BEFORE=""
if git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
  IS_GIT=1
  GIT_BEFORE=$(git -C "$CWD" status --porcelain 2>/dev/null | sort)
fi

echo "Resuming kimi session $SID (model=${MODEL:-config default}, effort=$EFFORT, cwd=$CWD)..." >&2
echo "Output dir: $KIMI_DIR" >&2

set +e
(
  cd "$CWD" &&
  KIMI_MODEL_THINKING_EFFORT="$EFFORT" kimi \
    --session "$SID" \
    "${MODEL_ARGS[@]}" \
    --prompt="$(cat "$PROMPT_FILE")" \
    > "$RESPONSE_FILE" 2> "$LOG_FILE"
)
EXIT=$?
set -e

FILES_CHANGED=unknown
if [[ -n "$IS_GIT" ]]; then
  GIT_AFTER=$(git -C "$CWD" status --porcelain 2>/dev/null | sort)
  if [[ "$GIT_BEFORE" == "$GIT_AFTER" ]]; then
    FILES_CHANGED=none
  else
    FILES_CHANGED=DETECTED
    echo "WARNING: git status changed during the kimi run — review before trusting the worktree:" >&2
    diff <(printf '%s\n' "$GIT_BEFORE") <(printf '%s\n' "$GIT_AFTER") >&2 || true
  fi
fi

if [[ $EXIT -ne 0 ]]; then
  echo "ERROR: kimi exited with status $EXIT (3=blocked, 6=paused, other=failure)" >&2
  echo "--- log tail ---" >&2
  tail -50 "$LOG_FILE" >&2
fi

echo "KIMI_DIR=$KIMI_DIR"
echo "SESSION_ID=$SID"
echo "RESPONSE_FILE=$RESPONSE_FILE"
echo "LOG_FILE=$LOG_FILE"
echo "FILES_CHANGED=$FILES_CHANGED"

exit $EXIT
