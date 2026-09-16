#!/usr/bin/env bash
# Resume an existing codex session by id and print a structured trailer.
#
# Usage: resume-codex.sh <session-id-or-empty> <prompt-file> [codex-dir] [effort]
#   session-id   The UUID returned by run-codex.sh as SESSION_ID=...
#                Pass the empty string ("") to infer it from <codex-dir>/session_id.
#   prompt-file  Required. Path to a file containing the follow-up prompt.
#   codex-dir    Optional. The CODEX_DIR returned by run-codex.sh. If supplied,
#                response/log files are written under it with numbered suffixes
#                so prior turns are preserved. If both session-id and codex-dir
#                are supplied, the script verifies they match and refuses to run
#                if they do not. If codex-dir is omitted, a fresh dir is created.
#   effort       Optional. Defaults to xhigh.
#   model        Optional. Defaults to $CODEX_MODEL, else gpt-6-astra.
#                (See run-codex.sh header; verified current 2026-09-04.
#                Pass a 5th arg or $CODEX_MODEL to override.)
#
# The session is resumed in the CODEX_HOME recorded by run-codex.sh
# (<codex-dir>/codex_home) — sessions live under the home that created them, so
# CODEX_ACCOUNT is ignored here and the file wins over an inherited CODEX_HOME.
# Without codex-dir the home is found by the session's rollout file; that pins
# a path, not a login — re-logging a roster home as someone else moves its
# sessions with it. Exit 2 (usage error) prints no trailer.
#
# Output: same structured trailer as run-codex.sh; exit 2 (usage error) prints none.
#
# WARNING: Do not run resume-codex.sh in parallel against the same CODEX_DIR.
# The numbered-suffix selection is not atomic. Sequential resumes are safe.

set -euo pipefail
unset CDPATH   # `cd x && pwd -P` must print one path

SID="${1-}"
PROMPT_FILE="${2:-}"
[[ -n "$PROMPT_FILE" ]] || { echo "usage: resume-codex.sh <session-id-or-\"\"> <prompt-file> [codex-dir] [effort] [model]" >&2; exit 2; }
CODEX_DIR="${3:-}"
EFFORT="${4:-xhigh}"
MODEL="${5:-${CODEX_MODEL:-gpt-6-astra}}"
# A roster home carries AGENTS.md but no config.toml, so a global
# project_doc_max_bytes never reaches it and instructions silently truncate at
# Codex's 32 KiB default. Pass it per call so every home agrees.
DOC_MAX="${CODEX_PROJECT_DOC_MAX_BYTES:-131072}"
MODEL_ARGS=()
[[ -n "$MODEL" ]] && MODEL_ARGS=(-m "$MODEL")

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi

# Resolve session id: explicit arg, else read from CODEX_DIR/session_id.
if [[ -z "$SID" ]]; then
  if [[ -z "$CODEX_DIR" || ! -f "$CODEX_DIR/session_id" ]]; then
    echo "ERROR: no session id supplied and no $CODEX_DIR/session_id to recover from" >&2
    exit 2
  fi
  SID=$(cat "$CODEX_DIR/session_id")
fi

if [[ ! "$SID" =~ ^[0-9a-f-]{36}$ ]]; then
  echo "ERROR: session id does not look like a UUID: $SID" >&2
  exit 2
fi

# If we have both, verify they belong together.
if [[ -n "$CODEX_DIR" && -f "$CODEX_DIR/session_id" ]]; then
  STORED=$(cat "$CODEX_DIR/session_id")
  if [[ -n "$STORED" && "$STORED" != "$SID" ]]; then
    echo "ERROR: session id mismatch: arg=$SID, stored in $CODEX_DIR/session_id=$STORED" >&2
    echo "       Refusing to run — passing the wrong CODEX_DIR would cross-contaminate artifacts." >&2
    exit 2
  fi
fi

if [[ -z "$CODEX_DIR" ]]; then
  CODEX_DIR=$(mktemp -d -t codex-XXXXXXXX)
elif [[ ! -d "$CODEX_DIR" ]]; then
  echo "ERROR: codex dir does not exist: $CODEX_DIR" >&2
  exit 2
fi

# Sessions live under the home that created them. The recorded home wins; with
# a UUID-only resume (no codex-dir), find the rollout file that carries the id
# across the slot and every roster home instead of searching the slot blindly.
if [[ -f "$CODEX_DIR/codex_home" ]]; then
  RECORDED=$(cat "$CODEX_DIR/codex_home")
  if [[ -n "$RECORDED" ]]; then
    [[ -d "$RECORDED" ]] || { echo "ERROR: recorded CODEX_HOME no longer exists: $RECORDED" >&2; exit 2; }
    export CODEX_HOME="$RECORDED"
  else
    unset CODEX_HOME
  fi
else
  # Exactly one home may own the rollout. Two (a copied session, a roster
  # entry symlinked to the slot) is ambiguous, and none means the caller has
  # to say — guessing would pin a wrong home into this dir for every later resume.
  FOUND=()
  for home in "${CODEX_HOME:-}" "$HOME/.codex" "${CODEX_ACCOUNTS_ROOT:-$HOME/.codex-accounts}"/*/; do
    [[ -n "$home" && -d "$home/sessions" ]] || continue
    real=$(cd "$home" && pwd -P) || continue
    [[ -n "$(find -L "$real/sessions" -maxdepth 4 -type f -name "rollout-*-${SID}.jsonl" -print -quit 2> /dev/null)" ]] || continue
    for seen in "${FOUND[@]:-}"; do [[ "$seen" == "$real" ]] && continue 2; done
    FOUND+=("$real")
  done
  case ${#FOUND[@]} in
    1) export CODEX_HOME="${FOUND[0]}" ;;
    0) echo "ERROR: no rollout for $SID under ~/.codex or any roster home — pass the CODEX_DIR from the first call" >&2; exit 2 ;;
    *) echo "ERROR: rollout for $SID exists in several homes (${FOUND[*]}) — pass the CODEX_DIR from the first call" >&2; exit 2 ;;
  esac
fi
[[ -n "${CODEX_ACCOUNT:-}" ]] && echo "NOTE: CODEX_ACCOUNT is ignored on resume; staying on ${CODEX_HOME:-~/.codex}" >&2

# A fresh dir must carry the same metadata run-codex.sh writes, or the next
# resume against it has no id and no home to go on.
[[ -f "$CODEX_DIR/session_id" ]] || printf '%s' "$SID" > "$CODEX_DIR/session_id"
[[ -f "$CODEX_DIR/codex_home" ]] || printf '%s' "${CODEX_HOME:-}" > "$CODEX_DIR/codex_home"

N=1
while [[ -e "$CODEX_DIR/response-$N.md" ]]; do
  N=$((N + 1))
done
RESPONSE_FILE="$CODEX_DIR/response-$N.md"
LOG_FILE="$CODEX_DIR/log.jsonl"

cp "$PROMPT_FILE" "$CODEX_DIR/followup-$N.md"

echo "Resuming codex session $SID (model=${MODEL:-config default}, effort=$EFFORT, home=${CODEX_HOME:-~/.codex})..." >&2
echo "Output dir: $CODEX_DIR" >&2

set +e
codex exec resume "$SID" \
  --json \
  --skip-git-repo-check \
  "${MODEL_ARGS[@]}" \
  -c "model_reasoning_effort=$EFFORT" \
  -c "project_doc_max_bytes=$DOC_MAX" \
  -o "$RESPONSE_FILE" \
  - < "$PROMPT_FILE" \
  >> "$LOG_FILE" 2>&1
EXIT=$?
set -e

# Observed on codex-cli 0.154.0: `codex exec resume` can exit 0 having written
# nothing — no events, no response file. That is not a review; report it as
# the failure it is rather than handing the caller an empty RESPONSE_FILE.
# (A consult is a text answer by contract; image work goes through
# image-codex.sh, so "no final message" is never a legitimate outcome here.)
if [[ $EXIT -eq 0 && ! -s "$RESPONSE_FILE" ]]; then
  echo "ERROR: codex exited 0 but produced no response (empty or missing $RESPONSE_FILE)" >&2
  EXIT=1
fi

if [[ $EXIT -ne 0 ]]; then
  echo "ERROR: codex exec resume exited with status $EXIT" >&2
  echo "--- log tail ---" >&2
  tail -50 "$LOG_FILE" >&2
fi

echo "CODEX_DIR=$CODEX_DIR"
echo "SESSION_ID=$SID"
echo "RESPONSE_FILE=$RESPONSE_FILE"
echo "LOG_FILE=$LOG_FILE"

exit $EXIT
