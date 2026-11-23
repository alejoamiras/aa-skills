#!/usr/bin/env bash
# Report the newest turn of a conversation in any state, collecting it if pending; submits nothing, so it never bills.
# Usage: fetch-gemini.sh <gemini-dir>
# Stdout is only the trailer (GEMINI_DIR, RESPONSE_FILE, LOG_FILE, ENGINE), also printed on stderr before the engine starts.
# Exit: 0 answered; 1 ended; 2 usage, configuration or no recorded outcome, no trailer; 3 still pending: run it again later.
set -euo pipefail
unset CDPATH

[[ $# -eq 1 && -n "$1" ]] || { echo "usage: fetch-gemini.sh <gemini-dir>" >&2; exit 2; }
GEMINI_DIR="$1"

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

N=0
for f in "$GEMINI_DIR"/followup-*.md; do
  k="${f##*/followup-}"
  k="${k%.md}"
  if [[ "$k" =~ ^[1-9][0-9]{0,8}$ ]] && ((k > N)); then N=$k; fi
done
NS=""
[[ $N -eq 0 ]] || NS="-$N"
RESPONSE_FILE="$GEMINI_DIR/response$NS.md"
LOG_FILE="$GEMINI_DIR/log$NS.txt"
ENDED="$GEMINI_DIR/ended$NS.txt"
NO_OUTCOME="ERROR: turn $N has no recorded outcome: another call may still be submitting it, or it was cut and may have been billed with no id to collect. Wait for that call, or start a new conversation with run-gemini.sh"
TRAILER="GEMINI_DIR=$GEMINI_DIR
RESPONSE_FILE=$RESPONSE_FILE
LOG_FILE=$LOG_FILE
ENGINE=api"
# A copied or unpacked dir can plant links here: tail would print their target, and the engine's output append to it.
for f in "$RESPONSE_FILE" "$ENDED" "$GEMINI_DIR/id$NS.txt" "$LOG_FILE"; do
  if [[ -L "$f" || (-e "$f" && ! -f "$f") ]]; then echo "ERROR: $f must be a regular file, not a symlink" >&2; exit 2; fi
done

if [[ ! -e "$RESPONSE_FILE" && ! -e "$ENDED" ]]; then
  [[ -e "$GEMINI_DIR/id$NS.txt" ]] || { echo "$NO_OUTCOME" >&2; exit 2; }
  echo "$TRAILER" >&2
  "$ENGINE" "$GEMINI_DIR" "$N" collect < /dev/null >> "$LOG_FILE" 2>&1 || true
fi

if [[ -e "$RESPONSE_FILE" ]]; then
  grep '^OK: ' "$LOG_FILE" 2> /dev/null | tail -n 1 >&2 || true
  RC=0
elif [[ -e "$ENDED" ]]; then
  WORD=""
  [[ -f "$ENDED" ]] && WORD="$(head -c 64 "$ENDED" | tr -cd 'a-z_-')"
  echo "ENDED: turn $N: ${WORD:-unknown}" >&2
  tail -n 20 "$LOG_FILE" >&2 2> /dev/null || true
  RC=1
elif [[ -e "$GEMINI_DIR/id$NS.txt" ]]; then
  echo "PENDING: run fetch-gemini.sh $GEMINI_DIR" >&2
  echo "The answer is not collected yet; sending the prompt again would be billed twice." >&2
  tail -n 20 "$LOG_FILE" >&2 2> /dev/null || true
  RC=3
else
  echo "$NO_OUTCOME" >&2
  tail -n 20 "$LOG_FILE" >&2 2> /dev/null || true
  RC=1
fi
echo "$TRAILER"
exit "$RC"
