#!/usr/bin/env bash
# Generate (or edit) raster images through the Codex CLI's built-in image_gen
# tool (gpt-image-2 on the ChatGPT account — no OPENAI_API_KEY involved) and
# print a structured trailer for the caller.
#
# Usage: image-codex.sh <prompt-file> <out-dir> [effort] [model] [ref-image ...]
#   prompt-file  Required. The image spec: subject, style, size/aspect, exact
#                text (verbatim), avoid-list, and the filename(s) to save as.
#                One paragraph per asset when asking for several.
#   out-dir      Required. Directory the images land in (created if missing).
#                Codex runs there under a workspace-write sandbox, so it can
#                write nothing outside it.
#   effort       Optional. Defaults to low — the reasoning model only drives
#                the image tool; higher effort buys nothing here.
#   model        Optional. Defaults to $CODEX_IMAGE_MODEL, else gpt-5.6-luna
#                (fast tier; verified to reach image_gen 2026-09-03).
#   ref-image    Optional, repeatable. Local images attached to the prompt:
#                style references, or the edit target of an "edit" request.
#
# Output: progress on stderr, codex log redirected to a file. The last 6 lines
# of stdout are guaranteed to be:
#
#   CODEX_DIR=<absolute path>
#   SESSION_ID=<uuid or empty>
#   RESPONSE_FILE=<absolute path>
#   LOG_FILE=<absolute path>
#   OUT_DIR=<absolute path>
#   IMAGE_FILES=<';'-separated absolute paths that exist on disk; empty on failure>
#
# Exit codes: 0 images saved; 3 codex reported image generation unavailable;
# 4 codex finished but saved nothing; anything else is codex's own exit status.

set -euo pipefail

PROMPT_FILE="${1:?prompt file required}"
OUT_DIR="${2:?output directory required}"
EFFORT="${3:-low}"
MODEL="${4:-${CODEX_IMAGE_MODEL:-gpt-5.6-luna}}"
shift 4 2>/dev/null || shift $#
REF_IMAGES=("$@")

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi
for ref in "${REF_IMAGES[@]}"; do
  if [[ ! -f "$ref" ]]; then
    echo "ERROR: reference image not found: $ref" >&2
    exit 2
  fi
done

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"

CODEX_DIR=$(mktemp -d -t codex-img-XXXXXXXX)
RESPONSE_FILE="$CODEX_DIR/response.md"
LOG_FILE="$CODEX_DIR/log.jsonl"
SESSION_ID_FILE="$CODEX_DIR/session_id"
FULL_PROMPT="$CODEX_DIR/prompt.md"

# The preamble pins codex to the built-in tool and to the sandboxed cwd, and
# fixes the reply format the trailer is parsed from.
{
  cat <<'EOF'
You are producing raster image assets. Use ONLY your built-in image generation tool (the `image_gen` capability, i.e. the $imagegen skill's default built-in mode). Never draw with code (no SVG, HTML/CSS, canvas, PIL, ImageMagick), never call an external API, and never use the CLI fallback script.

Rules:
- Work in the current directory; the sandbox allows writes only there. Copy every final image into it under the filename the request names. If no filename is named, use `image-1.png`, `image-2.png`, ... in request order. Never overwrite an existing file: save a `-v2` sibling instead.
- One image_gen call per requested asset or variant. Inspect each result against the spec before saving; regenerate at most once if it misses.
- Keep any quoted text verbatim. Respect every avoid-list item.
- Do not create, modify or delete any other file.
- Final reply, nothing else: one line `SAVED_PATH=<absolute path>` per saved image, in request order. If image generation is unavailable or refused, reply with the single line `IMAGEGEN_UNAVAILABLE=<one-sentence reason>`.

Request:
EOF
  cat "$PROMPT_FILE"
} > "$FULL_PROMPT"

IMAGE_ARGS=()
for ref in "${REF_IMAGES[@]}"; do
  IMAGE_ARGS+=(-i "$ref")
done

echo "Running codex image generation (model=$MODEL, effort=$EFFORT, out=$OUT_DIR, refs=${#REF_IMAGES[@]})..." >&2
echo "Output dir: $CODEX_DIR" >&2

set +e
codex exec \
  --json \
  --sandbox workspace-write \
  --skip-git-repo-check \
  -m "$MODEL" \
  -c "model_reasoning_effort=$EFFORT" \
  -C "$OUT_DIR" \
  "${IMAGE_ARGS[@]}" \
  -o "$RESPONSE_FILE" \
  - < "$FULL_PROMPT" \
  > "$LOG_FILE" 2>&1
EXIT=$?
set -e

# First JSONL event is `thread.started` and carries thread_id (== session id).
SID=$(head -n 1 "$LOG_FILE" 2>/dev/null \
  | grep -oE '"thread_id":"[0-9a-f-]{36}"' \
  | grep -oE '[0-9a-f-]{36}' \
  | head -n 1 || true)
printf '%s' "$SID" > "$SESSION_ID_FILE"

if [[ $EXIT -ne 0 ]]; then
  echo "ERROR: codex exec exited with status $EXIT" >&2
  echo "--- log tail ---" >&2
  tail -30 "$LOG_FILE" >&2
fi

# Keep only reported paths that really exist; relative ones resolve against OUT_DIR.
IMAGE_FILES=""
if [[ -f "$RESPONSE_FILE" ]]; then
  while IFS= read -r line; do
    p="${line#SAVED_PATH=}"
    [[ "$p" == /* ]] || p="$OUT_DIR/$p"
    if [[ -f "$p" ]]; then
      IMAGE_FILES="${IMAGE_FILES:+$IMAGE_FILES;}$p"
    else
      echo "WARNING: reported image does not exist: $p" >&2
    fi
  done < <(grep -E '^SAVED_PATH=' "$RESPONSE_FILE" || true)
  if grep -qE '^IMAGEGEN_UNAVAILABLE=' "$RESPONSE_FILE"; then
    grep -E '^IMAGEGEN_UNAVAILABLE=' "$RESPONSE_FILE" >&2
    [[ $EXIT -eq 0 ]] && EXIT=3
  fi
fi
if [[ $EXIT -eq 0 && -z "$IMAGE_FILES" ]]; then
  echo "ERROR: codex finished without saving any image (see $RESPONSE_FILE)" >&2
  EXIT=4
fi

echo "CODEX_DIR=$CODEX_DIR"
echo "SESSION_ID=$SID"
echo "RESPONSE_FILE=$RESPONSE_FILE"
echo "LOG_FILE=$LOG_FILE"
echo "OUT_DIR=$OUT_DIR"
echo "IMAGE_FILES=$IMAGE_FILES"

exit $EXIT
