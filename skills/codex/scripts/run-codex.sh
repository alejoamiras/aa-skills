#!/usr/bin/env bash
# Run a fresh codex session and print a structured trailer for the caller.
#
# Usage: run-codex.sh <prompt-file> [cwd] [effort] [sandbox] [model]
#   prompt-file  Required. Path to a file containing the prompt for codex.
#   cwd          Optional. Defaults to $PWD. Passed to codex via -C.
#   effort       Optional. Defaults to xhigh. Passed via -c model_reasoning_effort=...
#   sandbox      Optional. Defaults to read-only. Passed via --sandbox, except
#                approve-for-me, which becomes --approve-for-me: workspace-write
#                plus a model auto-reviewer that may rerun a command outside
#                the sandbox. Refused unless this machine opted in (see Env).
#   model        Optional. Defaults to $CODEX_MODEL, else gpt-6-astra.
#                (gpt-6-astra became the default 2026-09-04: OpenAI's
#                flagship since 2026-09-03 (Codex CLI >= 0.153.1), runs on
#                ChatGPT-account auth, verified end to end at xhigh. The
#                GPT-5.6 family — gpt-5.6-sol / -terra / -luna — stays
#                valid as cheaper overrides. Pass a 5th arg or set
#                $CODEX_MODEL to override per call.)
#
# Env: CODEX_ACCOUNT  Optional. A `codex-usage` roster account to run on, or
#                     "best" to let it pick the one with headroom. The run then
#                     uses that account's CODEX_HOME instead of ~/.codex, and
#                     the home is recorded so resume-codex.sh stays on it.
#      ~/.agents/codex-sandbox  Optional machine-local file holding the single
#                     word approve-for-me. It upgrades a read-only request on
#                     hosts whose kernel policy blocks bwrap (nested containers,
#                     AppArmor userns restriction), where read-only means codex
#                     can run nothing at all. Absent everywhere else.
#      CODEX_PROJECT_DOC_MAX_BYTES  Optional. Instruction-file budget, default
#                     131072. Raise it when a global + project AGENTS.md pair
#                     exceeds it; anything past the cap is dropped in silence.
#
# Output: human-readable progress on stderr, codex log redirected to a file.
# Exit 2 is a usage error (bad arguments, unresolvable account) and prints no
# trailer; on every other exit the last 4 lines of stdout are guaranteed to be:
#
#   CODEX_DIR=<absolute path>
#   SESSION_ID=<uuid or empty>
#   RESPONSE_FILE=<absolute path>
#   LOG_FILE=<absolute path>
#
# The caller (Claude) should read the SESSION_ID into the conversation
# transcript so follow-up turns can resume the same session.

set -euo pipefail
unset CDPATH   # `cd x && pwd -P` must print one path

PROMPT_FILE="${1:-}"
[[ -n "$PROMPT_FILE" ]] || { echo "usage: run-codex.sh <prompt-file> [cwd] [effort] [sandbox] [model]" >&2; exit 2; }
CWD="${2:-$PWD}"
EFFORT="${3:-xhigh}"
SANDBOX="${4:-read-only}"
MODEL="${5:-${CODEX_MODEL:-gpt-6-astra}}"
# A roster home carries AGENTS.md but no config.toml, so a global
# project_doc_max_bytes never reaches it and instructions silently truncate at
# Codex's 32 KiB default. Pass it per call so every home agrees.
DOC_MAX="${CODEX_PROJECT_DOC_MAX_BYTES:-131072}"
MODEL_ARGS=()
[[ -n "$MODEL" ]] && MODEL_ARGS=(-m "$MODEL")

# The override file may only name approve-for-me: a stray file must never be
# able to widen a consult to danger-full-access.
SANDBOX_OVERRIDE_FILE="$HOME/.agents/codex-sandbox"
HOST_OPT_IN=""
if [[ -r "$SANDBOX_OVERRIDE_FILE" ]]; then
  HOST_OPT_IN=$(tr -d '[:space:]' < "$SANDBOX_OVERRIDE_FILE")
  if [[ "$HOST_OPT_IN" != approve-for-me ]]; then
    echo "ERROR: $SANDBOX_OVERRIDE_FILE must contain exactly: approve-for-me" >&2
    exit 2
  fi
fi
# The machine opts in, never the caller: a prompt-driven agent must not be able
# to pick automatic approvals on a host whose sandbox works.
if [[ "$SANDBOX" == approve-for-me && -z "$HOST_OPT_IN" ]]; then
  echo "ERROR: approve-for-me needs this machine's opt-in ($SANDBOX_OVERRIDE_FILE)" >&2
  exit 2
fi
[[ "$SANDBOX" == read-only && -n "$HOST_OPT_IN" ]] && SANDBOX="$HOST_OPT_IN"
SANDBOX_ARGS=(--sandbox "$SANDBOX")
[[ "$SANDBOX" == approve-for-me ]] && SANDBOX_ARGS=(--approve-for-me)

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi
if [[ ! -d "$CWD" ]]; then
  echo "ERROR: cwd is not a directory: $CWD" >&2
  exit 2
fi

# Account routing. A roster account is just another CODEX_HOME; codex-usage
# owns the mapping (and, for "best", the choice). A fallback pick — nothing
# usable, this one frees up first — still runs, with a warning, because the
# caller asked for whatever is best and the alternative is no consult at all.
if [[ -n "${CODEX_ACCOUNT:-}" ]]; then
  if ! command -v codex-usage > /dev/null 2>&1; then
    echo "ERROR: CODEX_ACCOUNT=$CODEX_ACCOUNT needs codex-usage on PATH" >&2
    exit 2
  fi
  set +e
  ACCOUNT_HOME=$(codex-usage home "$CODEX_ACCOUNT" 2> /dev/null)
  RC=$?
  set -e
  if [[ $RC -ne 0 && ( -z "$ACCOUNT_HOME" || ! -d "$ACCOUNT_HOME" ) ]]; then
    echo "ERROR: cannot resolve CODEX_ACCOUNT=$CODEX_ACCOUNT (try: codex-usage list)" >&2
    exit 2
  fi
  [[ $RC -ne 0 ]] && echo "WARNING: no Codex account has headroom right now; using the one that frees up first" >&2
  export CODEX_HOME="$ACCOUNT_HOME"
fi

CODEX_DIR=$(mktemp -d -t codex-XXXXXXXX)
RESPONSE_FILE="$CODEX_DIR/response.md"
LOG_FILE="$CODEX_DIR/log.jsonl"
SESSION_ID_FILE="$CODEX_DIR/session_id"

# Without being told, codex reports the bwrap failure as its answer instead of
# asking the auto-reviewer for an unsandboxed rerun.
if [[ "$SANDBOX" == approve-for-me ]]; then
  {
    echo "[Host note: the command sandbox cannot start here (bwrap fails). When a command fails with a bwrap/sandbox error, rerun it requesting escalated permissions with a one-line justification. This is a review: read and inspect only, do not modify files.]"
    echo
    cat "$PROMPT_FILE"
  } > "$CODEX_DIR/prompt.md"
else
  cp "$PROMPT_FILE" "$CODEX_DIR/prompt.md"
fi
# Sessions live under the home that created them, so a resume must reuse it.
# Recorded canonical: a relative or symlinked home would mean something else
# from another cwd. Empty means the slot (~/.codex).
if [[ -n "${CODEX_HOME:-}" ]]; then
  CODEX_HOME=$(cd "$CODEX_HOME" && pwd -P) || { echo "ERROR: CODEX_HOME is not a directory: $CODEX_HOME" >&2; exit 2; }
  export CODEX_HOME
fi
printf '%s' "${CODEX_HOME:-}" > "$CODEX_DIR/codex_home"
printf '%s' "$SANDBOX" > "$CODEX_DIR/sandbox"

echo "Running codex (model=${MODEL:-config default}, effort=$EFFORT, sandbox=$SANDBOX, cwd=$CWD, home=${CODEX_HOME:-~/.codex})..." >&2
echo "Output dir: $CODEX_DIR" >&2

set +e
codex exec \
  --json \
  "${SANDBOX_ARGS[@]}" \
  --skip-git-repo-check \
  "${MODEL_ARGS[@]}" \
  -c "model_reasoning_effort=$EFFORT" \
  -c "project_doc_max_bytes=$DOC_MAX" \
  -C "$CWD" \
  -o "$RESPONSE_FILE" \
  - < "$CODEX_DIR/prompt.md" \
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

# Observed on codex-cli 0.154.0: `codex exec` can exit 0 having written
# nothing — no events, no response file. That is not a review; report it as
# the failure it is rather than handing the caller an empty RESPONSE_FILE.
# (A consult is a text answer by contract; image work goes through
# image-codex.sh, so "no final message" is never a legitimate outcome here.)
if [[ $EXIT -eq 0 && ! -s "$RESPONSE_FILE" ]]; then
  echo "ERROR: codex exited 0 but produced no response (empty or missing $RESPONSE_FILE)" >&2
  EXIT=1
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
