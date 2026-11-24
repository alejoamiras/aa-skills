#!/usr/bin/env bash
# Send a follow-up in a conversation run-gemini.sh started; effort and model stay as recorded at turn 0.
# Usage: resume-gemini.sh <gemini-dir> <prompt-file>   One call at a time per dir.
# Stdout is only the trailer (GEMINI_DIR, RESPONSE_FILE, LOG_FILE, ENGINE), also printed on stderr before the engine starts.
# Exit: 0 answered; 1 ended, or no recorded outcome; 2 usage, configuration or conversation state, no trailer; 3 pending: run fetch-gemini.sh.
set -euo pipefail
unset CDPATH

[[ $# -eq 2 && -n "$1" ]] || { echo "usage: resume-gemini.sh <gemini-dir> <prompt-file>" >&2; exit 2; }
GEMINI_DIR="$1"
PROMPT_FILE="$2"
[[ -f "$PROMPT_FILE" && -r "$PROMPT_FILE" ]] || { echo "ERROR: prompt file not found: $PROMPT_FILE" >&2; exit 2; }
# By identity only, before any turn file exists: the engine would refuse to send it, but the copy would stay behind.
for h in "$(getent passwd "$UID" 2> /dev/null | cut -d: -f6)" "${HOME:-}"; do
  if [[ -n "$h" && "$PROMPT_FILE" -ef "$h/.config/gemini/.env" ]]; then
    echo "ERROR: refusing the key file as a prompt: never send a secret to Gemini" >&2
    exit 2
  fi
done

while [[ "$GEMINI_DIR" == */ && "$GEMINI_DIR" != / ]]; do GEMINI_DIR="${GEMINI_DIR%/}"; done
PRIVATE=""
if [[ ! -L "$GEMINI_DIR" && -d "$GEMINI_DIR" ]]; then
  GEMINI_DIR="$(cd "$GEMINI_DIR" && pwd -P)"
  # Columns 5-10 of ls -ld are the group and other bits.
  [[ -O "$GEMINI_DIR" && "$(ls -ld "$GEMINI_DIR" | cut -c5-10)" == ------ ]] && PRIVATE=1
fi
[[ -n "$PRIVATE" ]] || { echo "ERROR: not a conversation dir (a real directory you own, with no group or other access): $1" >&2; exit 2; }
for r in effort model; do
  [[ -f "$GEMINI_DIR/$r" && ! -L "$GEMINI_DIR/$r" ]] || { echo "ERROR: $GEMINI_DIR/$r must be a regular file, not a symlink" >&2; exit 2; }
done

CONF="${HOME:-}/.agents/gemini-engine"
[[ -e "$CONF" || -L "$CONF" ]] || { echo "ERROR: no engine configured" >&2; exit 2; }
[[ -f "$CONF" && "$(cat "$CONF" 2> /dev/null)" == api ]] || { echo "ERROR: $CONF must hold exactly: api" >&2; exit 2; }
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENGINE="$SKILL_DIR/engines/api"
if [[ -L "$SKILL_DIR/engines" || -L "$ENGINE" || ! -f "$ENGINE" || ! -x "$ENGINE" ]]; then
  echo "ERROR: the engine must be a regular executable file in a real directory: $ENGINE" >&2
  exit 2
fi

# Pick N, then check the newest turn, then claim N once: checking first would let a second call
# skip a slot claimed meanwhile and submit beside it. Any trace of a turn, a dangling link or FIFO included, takes its slot.
N=1
while :; do
  TAKEN=""
  for f in "followup-$N.md" "id-$N.txt" "response-$N.md" "ended-$N.txt" "log-$N.txt"; do
    if [[ -e "$GEMINI_DIR/$f" || -L "$GEMINI_DIR/$f" ]]; then TAKEN=1; fi
  done
  if [[ -z "$TAKEN" ]]; then break; fi
  N=$((N + 1))
done

K=0
for f in "$GEMINI_DIR"/followup-*.md; do
  k="${f##*/followup-}"
  k="${k%.md}"
  if [[ "$k" =~ ^[1-9][0-9]{0,8}$ ]] && ((k > K)); then K=$k; fi
done
KS=""
[[ $K -eq 0 ]] || KS="-$K"
if [[ ! -e "$GEMINI_DIR/response$KS.md" && ! -e "$GEMINI_DIR/ended$KS.txt" ]]; then
  if [[ -e "$GEMINI_DIR/id$KS.txt" ]]; then
    echo "ERROR: turn $K is not collected yet: run fetch-gemini.sh $GEMINI_DIR" >&2
  else
    echo "ERROR: turn $K has no recorded outcome: another call may still be submitting it, or it was cut and may have been billed with no id to collect. Wait for that call, or start a new conversation with run-gemini.sh" >&2
  fi
  exit 2
fi
[[ -e "$GEMINI_DIR/response.md" ]] || { echo "ERROR: turn 0 has no answer: see its log's NEXT line, then start again with run-gemini.sh" >&2; exit 2; }

FOLLOWUP="$GEMINI_DIR/followup-$N.md"
RESPONSE_FILE="$GEMINI_DIR/response-$N.md"
LOG_FILE="$GEMINI_DIR/log-$N.txt"
# Reviewers never touch the shared memory; the owner's AGENTS.md tells sessions to.
MEMO_PREAMBLE="You are a subagent. Don't run memo."
REVIEWER="You are consulted as an independent reviewer. You cannot read files or run commands: judge only the material below, and say what is missing instead of guessing."

# noclobber creates a missing file exclusively: this is the claim on turn N.
set -C
{ : > "$FOLLOWUP"; } 2> /dev/null || { echo "ERROR: another call is using this conversation" >&2; exit 2; }
{ echo "$MEMO_PREAMBLE"; echo "$REVIEWER"; echo; cat < "$PROMPT_FILE"; } >> "$FOLLOWUP" || { echo "ERROR: cannot write $FOLLOWUP" >&2; exit 2; }

TRAILER="GEMINI_DIR=$GEMINI_DIR
RESPONSE_FILE=$RESPONSE_FILE
LOG_FILE=$LOG_FILE
ENGINE=api"
echo "$TRAILER" >&2

# The outcome is read from the turn's files, never from the engine's status.
"$ENGINE" "$GEMINI_DIR" "$N" submit < /dev/null >> "$LOG_FILE" 2>&1 || true

if [[ -e "$RESPONSE_FILE" ]]; then
  grep '^OK: ' "$LOG_FILE" 2> /dev/null | tail -n 1 >&2 || true
  RC=0
elif [[ -e "$GEMINI_DIR/ended-$N.txt" ]]; then
  WORD=""
  [[ -f "$GEMINI_DIR/ended-$N.txt" ]] && WORD="$(head -c 64 "$GEMINI_DIR/ended-$N.txt" | tr -cd 'a-z_-')"
  echo "ENDED: turn $N: ${WORD:-unknown}" >&2
  tail -n 20 "$LOG_FILE" >&2 2> /dev/null || true
  RC=1
elif [[ -e "$GEMINI_DIR/id-$N.txt" ]]; then
  echo "PENDING: run fetch-gemini.sh $GEMINI_DIR" >&2
  echo "The answer is not collected yet; sending the prompt again would be billed twice." >&2
  tail -n 20 "$LOG_FILE" >&2 2> /dev/null || true
  RC=3
else
  echo "ERROR: turn $N has no recorded outcome: another call may still be submitting it, or it was cut and may have been billed with no id to collect. Wait for that call, or start a new conversation with run-gemini.sh" >&2
  tail -n 20 "$LOG_FILE" >&2 2> /dev/null || true
  RC=1
fi
echo "$TRAILER"
exit "$RC"
