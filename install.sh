#!/usr/bin/env bash
# Symlinks this repo's skills, bin/ CLIs, and (from the private submodule)
# CLAUDE.md + the status line into ~/.claude, and overlays the managed settings
# keys onto ~/.claude/settings.json. Idempotent: existing non-symlink targets
# are moved to a timestamped backup dir first.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
BACKUP_DIR="${CLAUDE_DIR}/backups/aa-skills-$(date +%Y%m%d-%H%M%S)"

mkdir -p "${CLAUDE_DIR}/skills"

link() {
  local src="$1" dst="$2"
  if [ -L "${dst}" ]; then
    [ "$(readlink "${dst}")" = "${src}" ] && { echo "ok      ${dst}"; return; }
    mkdir -p "${BACKUP_DIR}"
    mv "${dst}" "${BACKUP_DIR}/"
    echo "backup  ${dst} (symlink elsewhere) -> ${BACKUP_DIR}/"
  elif [ -e "${dst}" ]; then
    mkdir -p "${BACKUP_DIR}"
    mv "${dst}" "${BACKUP_DIR}/"
    echo "backup  ${dst} -> ${BACKUP_DIR}/"
  fi
  ln -s "${src}" "${dst}"
  echo "link    ${dst} -> ${src}"
}

for skill in "${REPO_DIR}"/skills/*/; do
  name="$(basename "${skill%/}")"
  link "${REPO_DIR}/skills/${name}" "${CLAUDE_DIR}/skills/${name}"
done

# Helper CLIs (bin/*) go on PATH via ~/.local/bin.
if compgen -G "${REPO_DIR}/bin/*" > /dev/null; then
  mkdir -p "${HOME}/.local/bin"
  for tool in "${REPO_DIR}"/bin/*; do
    [ -f "${tool}" ] || continue
    chmod +x "${tool}"
    link "${tool}" "${HOME}/.local/bin/$(basename "${tool}")"
  done
  case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) echo "note    ~/.local/bin is not on PATH — add it to your shell profile" ;;
  esac
fi

# claude/ is a PRIVATE submodule (owner-only). Skip gracefully when absent.
if [ -f "${REPO_DIR}/claude/CLAUDE.md" ]; then
  link "${REPO_DIR}/claude/CLAUDE.md" "${CLAUDE_DIR}/CLAUDE.md"
else
  echo "skip    CLAUDE.md (private submodule not initialized — fine for non-owner clones)"
fi

# Personal status line (private submodule too): symlink the script; the
# settings.json pointer at it ships in settings.managed.json below.
if [ -f "${REPO_DIR}/claude/statusline.sh" ]; then
  chmod +x "${REPO_DIR}/claude/statusline.sh"
  link "${REPO_DIR}/claude/statusline.sh" "${CLAUDE_DIR}/statusline.sh"
fi

# Managed settings keys (private submodule): overlay claude/settings.managed.json
# onto ~/.claude/settings.json. Managed keys win; everything else (permission
# rules, model, plugins) stays machine-local. Overlay, not sync: a key dropped
# from the managed file keeps its last installed value until removed by hand.
# Claude Code rewrites this file itself (/model, /config, "always allow"), so
# run with sessions closed to avoid racing one of those writes.
MANAGED="${REPO_DIR}/claude/settings.managed.json"
SETTINGS="${CLAUDE_DIR}/settings.json"
if [ ! -f "${MANAGED}" ]; then
  echo "skip    settings.managed.json (private submodule not initialized)"
elif ! command -v jq > /dev/null 2>&1; then
  echo "note    jq not found — merge claude/settings.managed.json into ~/.claude/settings.json yourself"
elif [ -L "${SETTINGS}" ] || { [ -e "${SETTINGS}" ] && [ ! -f "${SETTINGS}" ]; }; then
  echo "error   ${SETTINGS} is not a regular file — refusing to replace it" >&2
  exit 1
else
  for f in "${MANAGED}" "${SETTINGS}"; do
    [ -e "${f}" ] || continue
    jq -e -s 'length == 1 and (.[0] | type == "object")' "${f}" > /dev/null \
      || { echo "error   ${f}: expected exactly one JSON object" >&2; exit 1; }
  done
  if [ -f "${SETTINGS}" ]; then
    merged="$(jq --slurpfile m "${MANAGED}" '. * $m[0]' "${SETTINGS}")"
    current="$(jq -S . "${SETTINGS}")"
  else
    merged="$(jq -n --slurpfile m "${MANAGED}" '$m[0]')"
    current='{}'
  fi
  if [ "${current}" = "$(printf '%s\n' "${merged}" | jq -S .)" ]; then
    echo "ok      settings.json managed keys"
  else
    if [ -f "${SETTINGS}" ]; then
      mkdir -p "${BACKUP_DIR}"
      cp "${SETTINGS}" "${BACKUP_DIR}/settings.json"
    fi
    tmp="$(mktemp "${CLAUDE_DIR}/settings.json.XXXXXX")"
    trap 'rm -f "${tmp}"' EXIT
    printf '%s\n' "${merged}" > "${tmp}"
    mv "${tmp}" "${SETTINGS}"
    trap - EXIT
    echo "merge   settings.json <- claude/settings.managed.json"
  fi
fi

# Wire the versioned pre-commit hook (gitleaks secret scan).
git -C "${REPO_DIR}" config core.hooksPath hooks
echo "hooks   core.hooksPath = hooks"

echo "done."
