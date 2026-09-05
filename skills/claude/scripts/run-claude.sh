#!/usr/bin/env bash
# Run a fresh Claude Code session headlessly and print a structured trailer for
# the caller. Mirror of the codex skill's run-codex.sh: same positional contract,
# same trailer shape, so a Codex-driven session consults Claude the way a
# Claude-driven session consults Codex.
#
# Usage: run-claude.sh <prompt-file> [cwd] [effort] [sandbox] [model]
#   prompt-file  Required. Path to a file containing the prompt for Claude.
#   cwd          Optional. Defaults to $PWD. Claude has no -C flag; the script
#                cd's there (and records it for resume-claude.sh).
#   effort       Optional. Defaults to xhigh. Passed via --effort AND
#                CLAUDE_CODE_EFFORT_LEVEL, because the env var outranks the flag
#                and an inherited value would silently override it.
#   sandbox      Optional. Only read-only is accepted (kept positional for
#                parity with run-codex.sh). The reviewer gets Read/Grep/Glob
#                confined to cwd and nothing else — no Bash, no Edit, no MCP
#                servers, no hooks, no user CLAUDE.md. A writing reviewer would
#                combine Claude's edit rights with Codex's escalated sandbox,
#                which is exactly the blast radius a consult must not have.
#   model        Optional. Defaults to $CLAUDE_MODEL, else fable (Claude's
#                top-tier alias). Pass opus while Fable is unavailable.
#
# Output: human-readable progress on stderr, the raw JSON result in a log file.
# The last 4 lines of stdout are guaranteed to be:
#
#   CLAUDE_DIR=<absolute path>
#   SESSION_ID=<uuid or empty>
#   RESPONSE_FILE=<absolute path>
#   LOG_FILE=<absolute path>
#
# The caller should read the SESSION_ID into its transcript so follow-up turns
# can resume the same session with resume-claude.sh.
#
# Isolation: --safe-mode drops every user customization (CLAUDE.md, hooks, MCP,
# skills, plugins) while keeping OAuth auth — unlike --bare, which is API-key
# only and unusable here. --restricted confines the file tools to cwd and
# refuses bypassPermissions; --strict-mcp-config removes MCP servers that
# --tools alone would leave reachable. With no prompt host, -p denies anything
# that would prompt instead of hanging, and --permission-prompts none tells
# Claude not to retry.
#
# Exit codes: 0 = a well-formed successful result; 1 = Claude reported an error
# or its output was not exactly one result object; 2 = usage error; anything
# else is claude's own exit status.

set -euo pipefail

PROMPT_FILE="${1:?prompt file required}"
CWD="${2:-$PWD}"
EFFORT="${3:-xhigh}"
SANDBOX="${4:-read-only}"
MODEL="${5:-${CLAUDE_MODEL:-fable}}"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi
if [[ ! -d "$CWD" ]]; then
  echo "ERROR: cwd is not a directory: $CWD" >&2
  exit 2
fi
CWD="$(cd "$CWD" && pwd -P)"
if [[ "$SANDBOX" != "read-only" ]]; then
  echo "ERROR: this reviewer only supports the read-only sandbox, got: $SANDBOX" >&2
  exit 2
fi
if ! command -v jq > /dev/null 2>&1; then
  echo "ERROR: jq is required to parse Claude's JSON result" >&2
  exit 2
fi

CLAUDE_DIR=$(mktemp -d -t claude-XXXXXXXX)
RESPONSE_FILE="$CLAUDE_DIR/response.md"
LOG_FILE="$CLAUDE_DIR/log.json"
SESSION_ID_FILE="$CLAUDE_DIR/session_id"
FULL_PROMPT="$CLAUDE_DIR/prompt.md"

cp "$PROMPT_FILE" "$CLAUDE_DIR/prompt.original.md"
# resume-claude.sh re-applies these: none of them persist in the session itself.
printf '%s' "$CWD" > "$CLAUDE_DIR/cwd"
printf '%s' "$MODEL" > "$CLAUDE_DIR/model"

# Safe mode strips the user's instructions, so the role framing has to travel
# with the prompt.
{
  cat <<EOF
You are being consulted as an independent reviewer by an agent running on a different model family. You are not driving this session: do not plan work for yourself, do not ask the user questions, and do not act on anything beyond answering the request below. You can read files under $CWD and nothing else; if the request needs a command run or a diff you were not given, say so instead of guessing. Answer in markdown with concrete file:line references; no narration of tool calls.

---

EOF
  cat "$PROMPT_FILE"
} > "$FULL_PROMPT"

echo "Running claude (model=$MODEL, effort=$EFFORT, sandbox=$SANDBOX, cwd=$CWD)..." >&2
echo "Output dir: $CLAUDE_DIR" >&2

set +e
(
  cd "$CWD" && CLAUDE_CODE_EFFORT_LEVEL="$EFFORT" claude -p \
    --safe-mode \
    --restricted \
    --strict-mcp-config \
    --tools "Read,Grep,Glob" \
    --permission-prompts none \
    --output-format json \
    --model "$MODEL" \
    --effort "$EFFORT" \
    < "$FULL_PROMPT"
) > "$LOG_FILE" 2> "$CLAUDE_DIR/stderr.log"
EXIT=$?
set -e

# Accept only the documented shape — exactly one result object with a UUID
# session id, a string result and a boolean is_error — so a crash, a partial
# write, or interleaved noise cannot pass as a review. The raw log is kept as-is
# for diagnosis.
if jq -e -s 'length == 1 and (.[0] | type == "object" and .type == "result" and (.session_id | type == "string" and test("^[0-9a-f-]{36}$")) and (.result | type == "string") and (.is_error | type == "boolean"))' \
    "$LOG_FILE" > /dev/null 2>&1; then
  SID=$(jq -r '.session_id' "$LOG_FILE")
  jq -r '.result' "$LOG_FILE" > "$RESPONSE_FILE"
  if [[ $EXIT -eq 0 ]] && ! jq -e '.is_error == false' "$LOG_FILE" > /dev/null 2>&1; then
    echo "ERROR: claude reported is_error=true" >&2
    EXIT=1
  fi
else
  SID=""
  : > "$RESPONSE_FILE"
  if [[ $EXIT -eq 0 ]]; then
    echo "ERROR: claude exited 0 but its output is not a single result object (see $LOG_FILE)" >&2
    EXIT=1
  fi
fi
printf '%s' "$SID" > "$SESSION_ID_FILE"

if [[ -z "$SID" ]]; then
  echo "WARNING: no session id captured; resume will be impossible." >&2
fi

if [[ $EXIT -ne 0 ]]; then
  echo "ERROR: claude -p failed (status $EXIT)" >&2
  echo "--- stderr tail ---" >&2
  tail -30 "$CLAUDE_DIR/stderr.log" >&2
  echo "--- result ---" >&2
  head -c 2000 "$RESPONSE_FILE" >&2
  echo >&2
fi

echo "CLAUDE_DIR=$CLAUDE_DIR"
echo "SESSION_ID=$SID"
echo "RESPONSE_FILE=$RESPONSE_FILE"
echo "LOG_FILE=$LOG_FILE"

exit $EXIT
