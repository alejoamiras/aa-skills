#!/usr/bin/env bash
# Symlinks this repo's skills (+ CLAUDE.md, if the private submodule is initialized)
# into ~/.claude. Idempotent: existing non-symlink targets are moved to a
# timestamped backup dir first.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
BACKUP_DIR="${CLAUDE_DIR}/backups/aa-skills-$(date +%Y%m%d-%H%M%S)"

mkdir -p "${CLAUDE_DIR}/skills"

link() {
  local src="$1" dst="$2"
  if [ -L "${dst}" ]; then
    [ "$(readlink "${dst}")" = "${src}" ] && { echo "ok      ${dst}"; return; }
    rm "${dst}"
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

# claude/ is a PRIVATE submodule (owner-only). Skip gracefully when absent.
if [ -f "${REPO_DIR}/claude/CLAUDE.md" ]; then
  link "${REPO_DIR}/claude/CLAUDE.md" "${CLAUDE_DIR}/CLAUDE.md"
else
  echo "skip    CLAUDE.md (private submodule not initialized — fine for non-owner clones)"
fi

# Wire the versioned pre-commit hook (gitleaks secret scan).
git -C "${REPO_DIR}" config core.hooksPath hooks
echo "hooks   core.hooksPath = hooks"

echo "done."
