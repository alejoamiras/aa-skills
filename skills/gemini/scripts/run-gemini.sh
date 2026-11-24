#!/usr/bin/env bash
# Start a Gemini consult through the api engine; Google keeps the conversation for resume-gemini.sh.
# Usage: run-gemini.sh <prompt-file> [cwd] [effort] [model]   (an empty argument takes its default)
# Stdout is only the trailer (GEMINI_DIR, RESPONSE_FILE, LOG_FILE, ENGINE), also printed on stderr before the engine starts.
# Exit: 0 answered; 1 ended, or no recorded outcome; 2 usage or configuration, no trailer; 3 pending: run fetch-gemini.sh.
set -euo pipefail
unset CDPATH

[[ $# -ge 1 && $# -le 4 && -n "$1" ]] || { echo "usage: run-gemini.sh <prompt-file> [cwd] [effort] [model]" >&2; exit 2; }
PROMPT_FILE="$1"
CWD="${2:-$PWD}"
EFFORT="${3:-high}"
# Empty means the engine's default model.
MODEL="${4:-}"

[[ -f "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] || { echo "ERROR: prompt file not found: $PROMPT_FILE" >&2; exit 2; }
# By identity only, before any turn file exists: the engine would refuse to send it, but the copy would stay behind.
for h in "$(getent passwd "$UID" 2> /dev/null | cut -d: -f6)" "${HOME:-}"; do
  if [[ -n "$h" && "$PROMPT_FILE" -ef "$h/.config/gemini/.env" ]]; then
    echo "ERROR: refusing the key file as a prompt: never send a secret to Gemini" >&2
    exit 2
  fi
done
# Checked, never entered or recorded: it catches a shifted call such as `run-gemini.sh p.md low`.
[[ -d "$CWD" ]] || { echo "ERROR: cwd is not a directory: $CWD" >&2; exit 2; }
case "$EFFORT" in
  low | medium | high) ;;
  *) echo "ERROR: effort must be low, medium or high, got: $EFFORT" >&2; exit 2 ;;
esac
[[ -z "$MODEL" || "$MODEL" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || { echo "ERROR: model must match ^[a-z0-9][a-z0-9.-]*\$, got: $MODEL" >&2; exit 2; }

CONF="${HOME:-}/.agents/gemini-engine"
[[ -e "$CONF" || -L "$CONF" ]] || { echo "ERROR: no engine configured" >&2; exit 2; }
[[ -f "$CONF" && "$(cat "$CONF" 2> /dev/null)" == api ]] || { echo "ERROR: $CONF must hold exactly: api" >&2; exit 2; }
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE="$SKILL_DIR/engines/api"
if [[ -L "$SKILL_DIR/engines" || -L "$ENGINE" || ! -f "$ENGINE" || ! -x "$ENGINE" ]]; then
  echo "ERROR: the engine must be a regular executable file in a real directory: $ENGINE" >&2
  exit 2
fi

GEMINI_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gemini-XXXXXXXX")" || { echo "ERROR: cannot create a dir under ${TMPDIR:-/tmp}" >&2; exit 2; }
GEMINI_DIR="$(cd "$GEMINI_DIR" && pwd -P)"
RESPONSE_FILE="$GEMINI_DIR/response.md"
LOG_FILE="$GEMINI_DIR/log.txt"
# Reviewers never touch the shared memory; the owner's AGENTS.md tells sessions to.
MEMO_PREAMBLE="You are a subagent. Don't run memo."
REVIEWER="You are consulted as an independent reviewer. You cannot read files or run commands: judge only the material below, and say what is missing instead of guessing."

set -C
# The engine re-reads both on every turn: chaining at Google does not carry generation_config.
if ! { printf '%s' "$EFFORT" > "$GEMINI_DIR/effort" && printf '%s' "$MODEL" > "$GEMINI_DIR/model" &&
  { echo "$MEMO_PREAMBLE"; echo "$REVIEWER"; echo; cat < "$PROMPT_FILE"; } > "$GEMINI_DIR/prompt.md"; }; then
  echo "ERROR: cannot write the turn's files in $GEMINI_DIR" >&2
  exit 2
fi

TRAILER="GEMINI_DIR=$GEMINI_DIR
RESPONSE_FILE=$RESPONSE_FILE
LOG_FILE=$LOG_FILE
ENGINE=api"
echo "$TRAILER" >&2

# The outcome is read from the turn's files, never from the engine's status.
"$ENGINE" "$GEMINI_DIR" 0 submit < /dev/null >> "$LOG_FILE" 2>&1 || true

if [[ -e "$RESPONSE_FILE" ]]; then
  grep '^OK: ' "$LOG_FILE" 2> /dev/null | tail -n 1 >&2 || true
  RC=0
elif [[ -e "$GEMINI_DIR/ended.txt" ]]; then
  WORD=""
  [[ -f "$GEMINI_DIR/ended.txt" ]] && WORD="$(head -c 64 "$GEMINI_DIR/ended.txt" | tr -cd 'a-z_-')"
  echo "ENDED: turn 0: ${WORD:-unknown}" >&2
  tail -n 20 "$LOG_FILE" >&2 2> /dev/null || true
  RC=1
elif [[ -e "$GEMINI_DIR/id.txt" ]]; then
  echo "PENDING: run fetch-gemini.sh $GEMINI_DIR" >&2
  echo "The answer is not collected yet; sending the prompt again would be billed twice." >&2
  tail -n 20 "$LOG_FILE" >&2 2> /dev/null || true
  RC=3
else
  echo "ERROR: turn 0 has no recorded outcome: another call may still be submitting it, or it was cut and may have been billed with no id to collect. Wait for that call, or start a new conversation with run-gemini.sh" >&2
  tail -n 20 "$LOG_FILE" >&2 2> /dev/null || true
  RC=1
fi
echo "$TRAILER"
exit "$RC"
