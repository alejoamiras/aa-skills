#!/usr/bin/env bash
# Run a fresh Kimi Code session non-interactively and print a structured trailer.
#
# Usage: run-kimi.sh <prompt-file> [cwd] [effort] [model]
#   prompt-file  Required. Path to a file containing the prompt for kimi.
#   cwd          Optional. Defaults to $PWD. The script cds there (kimi has no
#                -C flag; the workspace is the process working directory).
#   effort       Optional. Defaults to max. Exported as KIMI_MODEL_THINKING_EFFORT
#                (kimi's forced thinking-effort override). Valid: off|low|high|max
#                (models can restrict the set; kimi warns on unsupported values).
#   model        Optional. Defaults to $KIMI_MODEL, else empty = the account's
#                default_model from ~/.kimi-code/config.toml (login-managed).
#                Pass a model ALIAS as kimi knows it (see `kimi provider list`).
#
# SAFETY: kimi -p mode auto-approves tool calls and has NO read-only sandbox
# (unlike codex --sandbox read-only). The prompt should instruct kimi not to
# modify files, and this script fingerprints `git status` before/after and
# reports FILES_CHANGED in the trailer so silent writes get noticed.
#
# Output: human-readable progress on stderr; kimi's stderr (thinking/tool
# progress + resume hint) goes to the log file. The last 5 lines of stdout
# are guaranteed to be:
#
#   KIMI_DIR=<absolute path>
#   SESSION_ID=<session_... or empty>
#   RESPONSE_FILE=<absolute path>
#   LOG_FILE=<absolute path>
#   FILES_CHANGED=<none|DETECTED|unknown>
#
# The caller (Claude) should read SESSION_ID and KIMI_DIR into the conversation
# transcript so follow-up turns can resume the same session.
#
# Exit codes are kimi's own: 0 completed, 3 blocked, 6 paused, else error.

set -euo pipefail

PROMPT_FILE="${1:?prompt file required}"
CWD="${2:-$PWD}"
EFFORT="${3:-max}"
MODEL="${4:-${KIMI_MODEL:-}}"
MODEL_ARGS=()
[[ -n "$MODEL" ]] && MODEL_ARGS=(-m "$MODEL")

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi
if [[ ! -d "$CWD" ]]; then
  echo "ERROR: cwd is not a directory: $CWD" >&2
  exit 2
fi
# The prompt travels as a single argv entry (-p has no stdin mode); guard ARG_MAX.
if [[ "$(wc -c < "$PROMPT_FILE")" -gt 200000 ]]; then
  echo "ERROR: prompt file exceeds 200KB; point kimi at files in cwd instead of inlining them" >&2
  exit 2
fi

KIMI_DIR=$(mktemp -d -t kimi-XXXXXXXX)
RESPONSE_FILE="$KIMI_DIR/response.md"
LOG_FILE="$KIMI_DIR/log.txt"
SESSION_ID_FILE="$KIMI_DIR/session_id"

cp "$PROMPT_FILE" "$KIMI_DIR/prompt.md"
CWD=$(cd "$CWD" && pwd)
printf '%s' "$CWD" > "$KIMI_DIR/cwd"

# Fingerprint the worktree so unrequested writes are detectable afterwards.
IS_GIT=""
GIT_BEFORE=""
if git -C "$CWD" rev-parse --git-dir > /dev/null 2>&1; then
  IS_GIT=1
  GIT_BEFORE=$(git -C "$CWD" status --porcelain 2>/dev/null | sort)
fi

echo "Running kimi (model=${MODEL:-config default}, effort=$EFFORT, cwd=$CWD)..." >&2
echo "Output dir: $KIMI_DIR" >&2

set +e
(
  cd "$CWD" &&
  KIMI_MODEL_THINKING_EFFORT="$EFFORT" kimi \
    "${MODEL_ARGS[@]}" \
    --prompt="$(cat "$PROMPT_FILE")" \
    > "$RESPONSE_FILE" 2> "$LOG_FILE"
)
EXIT=$?
set -e

# In text mode kimi prints "To resume this session: kimi -r <id>" on stderr.
# The id's SHAPE is not a stable contract across kimi versions (uuid-suffixed
# today, ULID-like in doc examples), so take the last token of the hint line
# rather than pattern-matching the id itself.
SID=$(grep 'To resume this session:' "$LOG_FILE" 2>/dev/null | tail -n 1 | awk '{print $NF}' || true)
[[ "$SID" =~ ^[A-Za-z0-9._-]+$ ]] || SID=""
printf '%s' "$SID" > "$SESSION_ID_FILE"

if [[ -z "$SID" ]]; then
  echo "WARNING: could not extract session id from log; resume will be impossible." >&2
fi

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
