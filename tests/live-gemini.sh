#!/usr/bin/env bash
# Live check of the gemini skill against Google: three short paid turns, none ever resent. A follow-up must recall a
# nonce that only Google's stored conversation holds, and a new conversation inviting hosted tools must exit 0, so its
# response showed no tool step or tool usage: evidence about what the response reveals, not proof that tools stay off.
#   GEMINI_LIVE=spend bash tests/live-gemini.sh
set -euo pipefail
[[ "${GEMINI_LIVE:-}" == spend ]] || { echo "skip  set GEMINI_LIVE=spend to run three paid Gemini turns"; exit 0; }
CONF="${HOME:-}/.agents/gemini-engine"
[[ -f "$CONF" && "$(cat "$CONF" 2> /dev/null)" == api ]] || { echo "FAIL  ~/.agents/gemini-engine must hold exactly: api" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPTS="$ROOT/skills/gemini/scripts"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/live-gemini-XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
NONCE="n$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$NONCE" =~ ^n[0-9a-f]{16}$ ]] || { echo "FAIL  no nonce read from /dev/urandom" >&2; exit 1; }
printf 'Remember this code word for later in this conversation: %s\nFor now, reply with exactly one word: READY\n' "$NONCE" > "$WORK/nonce.md"
echo "What is the code word I asked you to remember in my first message? Reply with the code word only." > "$WORK/recall.md"
printf '%s\n' "If you can use tools here, do all three: search the web for today's date, fetch https://example.com/ and quote its page title, and run code that prints 6 * 7." \
  "If you cannot, do not guess what they would return: reply with exactly NO-TOOLS and nothing else." > "$WORK/tools.md"
if grep -qF -- "$NONCE" "$WORK/recall.md"; then echo "FAIL  the follow-up prompt holds the nonce, so a recall would prove nothing" >&2; exit 1; fi

DIR1=""
for TURN in 1 2 3; do
  case $TURN in
    1) WHAT="turn 1 (run, nonce)" && set -- "$SCRIPTS/run-gemini.sh" "$WORK/nonce.md" "" low ;;
    2) WHAT="turn 2 (resume, recall)" && set -- "$SCRIPTS/resume-gemini.sh" "$DIR1" "$WORK/recall.md" ;;
    *) WHAT="turn 3 (run, no-tools probe)" && set -- "$SCRIPTS/run-gemini.sh" "$WORK/tools.md" "" low ;;
  esac
  echo "== $WHAT"
  rc=0
  OUT="$("$@" < /dev/null)" || rc=$?
  GD="$(printf '%s\n' "$OUT" | sed -n 's/^GEMINI_DIR=//p')"
  RESP="$(printf '%s\n' "$OUT" | sed -n 's/^RESPONSE_FILE=//p')"
  LOG="$(printf '%s\n' "$OUT" | sed -n 's/^LOG_FILE=//p')"
  WHY="" NEXT="" FAIL=""
  if [[ -n "$LOG" ]]; then
    WHY="$(grep '^ERROR: ' "$LOG" 2> /dev/null | tail -n 1 || true)"
    NEXT="$(grep '^NEXT: ' "$LOG" 2> /dev/null | tail -n 1 || true)"
  fi
  if [[ $rc -eq 0 ]]; then
    # The id never leaves this script: only its length and character classes are printed.
    IDF="${RESP%.md}.txt" && IDF="${IDF%/response*}/id${IDF##*/response}"
    MASK=""
    if [[ -f "$IDF" ]]; then MASK="$(LC_ALL=C sed 's/[A-Za-z]/a/g; s/[0-9]/9/g' "$IDF")"; fi
    echo "  dir: $GD"
    echo "  $(grep '^served: ' "$LOG" | tail -n 1 || echo 'served: missing from the log')"
    echo "  $(grep '^OK: ' "$LOG" | tail -n 1 || echo 'OK: missing from the log')"
    echo "  $(grep '^steps: ' "$LOG" | tail -n 1 || echo 'steps: missing from the log')"
    echo "  id: ${#MASK} characters, mask ${MASK:-none}"
    case $TURN in
      1) DIR1="$GD" ;;
      2) if grep -qF -- "$NONCE" "$RESP"; then echo "  nonce recalled: yes"; else FAIL="$WHAT: the answer does not hold the nonce, so Google did not keep the conversation"; fi ;;
      *) if grep -qF NO-TOOLS "$RESP"; then echo "  answer says NO-TOOLS: yes"; else echo "  answer says NO-TOOLS: no; read $RESP"; fi ;;
    esac
  elif [[ $rc -eq 3 ]]; then
    FAIL="$WHAT is pending (exit 3) and is never resent"
  else
    FAIL="$WHAT exited $rc: ${WHY:-see its stderr above}"
  fi
  if [[ -n "$FAIL" ]]; then
    echo "FAIL  $FAIL" >&2
    [[ $rc -eq 0 || -z "$NEXT" ]] || echo "$NEXT" >&2
    echo "LOG_FILE=${LOG:-none: the consult script exited before the engine ran}" >&2
    exit 1
  fi
done
echo "ok    three turns answered, the nonce recalled from Google's stored conversation, no tool shown"
