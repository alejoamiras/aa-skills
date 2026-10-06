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
# The isolation flags (--safe-mode --restricted --strict-mcp-config, and the
# tool set of the session's sandbox) do not persist in a session and are
# re-applied on every resume. The sandbox comes from <claude-dir>/sandbox and
# from the per-session record run-claude.sh keeps under
# ${XDG_STATE_HOME:-~/.local/state}/claude-consult/sessions; the two must agree,
# and a session with neither predates web-read, so it was read-only.
#
# The session is resumed on the account recorded by run-claude.sh
# (<claude-dir>/account): a session lives in the projects/ of the config dir
# that created it, so CLAUDE_ACCOUNT is ignored here. Without that record the
# account is found by the session's transcript across ~/.claude and every
# `claude-usage` roster home.
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
if [[ -n "${CLAUDE_ACCOUNTS_ROOT:-}" && "$CLAUDE_ACCOUNTS_ROOT" != /* ]]; then
  export CLAUDE_ACCOUNTS_ROOT="$PWD/$CLAUDE_ACCOUNTS_ROOT"
fi
MODEL="fable"
SANDBOX=""  # only ever read back from the records, never inherited
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
  if [[ -f "$CLAUDE_DIR/sandbox" ]]; then
    SANDBOX="$(cat "$CLAUDE_DIR/sandbox")"
    [[ -n "$SANDBOX" ]] || { echo "ERROR: empty sandbox record: $CLAUDE_DIR/sandbox" >&2; exit 2; }
  fi
fi
REGISTERED=""
REGISTRY_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/claude-consult/sessions/$SID"
if [[ -f "$REGISTRY_FILE" ]]; then
  REGISTERED="$(cat "$REGISTRY_FILE")"
  [[ -n "$REGISTERED" ]] || { echo "ERROR: empty sandbox record: $REGISTRY_FILE" >&2; exit 2; }
fi
if [[ -n "$SANDBOX" && -n "$REGISTERED" && "$SANDBOX" != "$REGISTERED" ]]; then
  echo "ERROR: sandbox records disagree for $SID: $CLAUDE_DIR/sandbox=$SANDBOX, $REGISTRY_FILE=$REGISTERED" >&2
  exit 2
fi
SANDBOX="${SANDBOX:-${REGISTERED:-read-only}}"
case "$SANDBOX" in
  read-only) ALLOW=(); TOOLS="Read,Grep,Glob" ;;
  web-read) ALLOW=(--allowedTools WebFetch); TOOLS="WebSearch,WebFetch" ;;
  *) echo "ERROR: unrecognised sandbox record for $SID: $SANDBOX" >&2; exit 2 ;;
esac
printf '%s' "$SANDBOX" > "$CLAUDE_DIR/sandbox"
MODEL="${MODEL_ARG:-${CLAUDE_MODEL:-$MODEL}}"
if [[ ! -d "$CWD" ]]; then
  echo "ERROR: recorded cwd no longer exists: $CWD" >&2
  exit 2
fi
printf '%s' "$CWD" > "$CLAUDE_DIR/cwd"
printf '%s' "$MODEL" > "$CLAUDE_DIR/model"

# An empty ACCOUNT_KEY means a plain `claude` with the caller's environment.
if [[ -f "$CLAUDE_DIR/account" ]]; then
  ACCOUNT_KEY=$(cat "$CLAUDE_DIR/account")
else
  ACCOUNT_KEY=""
  if command -v claude-usage > /dev/null 2>&1; then
    # Exactly one home may hold the transcript; two is ambiguous, and none is
    # left to claude, which reports the missing session itself.
    FOUND=()
    for home in "$HOME/.claude" "${CLAUDE_ACCOUNTS_ROOT:-$HOME/.claude-accounts}"/*/; do
      home="${home%/}"
      [[ -d "$home/projects" ]] || continue
      [[ -n "$(find "$home/projects" -maxdepth 2 -name "$SID.jsonl" -print -quit 2> /dev/null)" ]] || continue
      FOUND+=("$home")
    done
    case ${#FOUND[@]} in
      0) ;;
      1) if [[ "${FOUND[0]}" == "$HOME/.claude" ]]; then ACCOUNT_KEY=main; else ACCOUNT_KEY=$(basename "${FOUND[0]}"); fi ;;
      *) echo "ERROR: session $SID exists under several accounts (${FOUND[*]}) — pass the CLAUDE_DIR from the first call" >&2; exit 2 ;;
    esac
  fi
  printf '%s' "$ACCOUNT_KEY" > "$CLAUDE_DIR/account"
fi
CLAUDE_CMD=(claude)
if [[ -n "$ACCOUNT_KEY" ]]; then
  if command -v claude-usage > /dev/null 2>&1; then
    # Exact, or the account is gone: a near-miss name would resume elsewhere.
    if [[ "$(claude-usage resolve "=$ACCOUNT_KEY" 2> /dev/null)" != "$ACCOUNT_KEY" ]]; then
      echo "ERROR: recorded account no longer exists: $ACCOUNT_KEY (see: claude-usage list)" >&2
      exit 2
    fi
    CLAUDE_CMD=(claude-usage run "=$ACCOUNT_KEY")
  elif [[ "$ACCOUNT_KEY" != main ]]; then
    echo "ERROR: this session runs on account $ACCOUNT_KEY, which needs claude-usage on PATH" >&2
    exit 2
  fi
fi
[[ -n "${CLAUDE_ACCOUNT:-}" ]] && echo "NOTE: CLAUDE_ACCOUNT is ignored on resume; staying on ${ACCOUNT_KEY:-~/.claude}" >&2

N=1
while [[ -e "$CLAUDE_DIR/response-$N.md" ]]; do
  N=$((N + 1))
done
# Reviewers and workers never touch the shared memory; the owner's AGENTS.md tells sessions to.
MEMO_PREAMBLE="You are a subagent. Don't run memo."
RESPONSE_FILE="$CLAUDE_DIR/response-$N.md"
LOG_FILE="$CLAUDE_DIR/log-$N.json"
FOLLOWUP="$CLAUDE_DIR/followup-$N.md"

{ echo "$MEMO_PREAMBLE"; echo; cat "$PROMPT_FILE"; } > "$FOLLOWUP"

echo "Resuming claude session $SID (model=$MODEL, effort=$EFFORT, cwd=$CWD, account=${ACCOUNT_KEY:-~/.claude})..." >&2
echo "Output dir: $CLAUDE_DIR" >&2

set +e
(
  cd "$CWD" && CLAUDE_CODE_EFFORT_LEVEL="$EFFORT" "${CLAUDE_CMD[@]}" -p \
    --resume "$SID" \
    --safe-mode \
    --restricted \
    --strict-mcp-config \
    --tools "$TOOLS" \
    ${ALLOW[@]+"${ALLOW[@]}"} \
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
