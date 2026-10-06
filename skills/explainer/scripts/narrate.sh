#!/usr/bin/env bash
# The only sanctioned way to give ELEVENLABS_API_KEY to tts.ts (AGENTS.md's one named op-run exception).
# Usage: narrate.sh <abs narration.json> <abs out-dir>
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "narrate.sh: the op-run exception is Mac-only; on a remote host use a keyed run (see SKILL.md)" >&2
  exit 5
fi
[[ $# -eq 2 && "$1" == /* && "$2" == /* ]] || { echo "usage: narrate.sh <abs narration.json> <abs out-dir>" >&2; exit 1; }

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
op="$(command -v op)"
bun="$(command -v bun)"
# Absolute, and checked before 1Password is asked: without it a bad alignment cannot be rescued.
ffprobe="$(command -v ffprobe)" || { echo "narrate.sh: ffprobe not found (brew install ffmpeg)" >&2; exit 1; }
# env -i drops inherited BUN_OPTIONS, NODE_OPTIONS and the like; op keeps the real HOME to reach 1Password.
# bun then gets an empty HOME and cwd, so no global or local bunfig, preload or .env loads beside the key,
# and the key travels only in the environment, never in an argv.
empty="$(mktemp -d)"
trap 'rm -rf "$empty"' EXIT
cd "$empty"
# shellcheck disable=SC2016  # the inner bash expands $1/$@ itself
env -i HOME="$HOME" USER="${USER:-}" PATH="/usr/bin:/bin" TMPDIR="${TMPDIR:-/tmp}" \
  ELEVENLABS_VOICE_ID="${ELEVENLABS_VOICE_ID:-}" EXPLAINER_FFPROBE="$ffprobe" \
  "$op" run --env-file="$dir/elevenlabs.env.example" -- \
  /bin/bash -c 'export HOME="$1" XDG_CONFIG_HOME="$1"; shift; exec "$@"' _ "$empty" \
  "$bun" --no-env-file "$dir/scripts/tts.ts" "$1" "$2"
