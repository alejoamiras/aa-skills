#!/usr/bin/env bash
# Symlinks this repo's skills, bin/ CLIs, and (from the private submodule)
# CLAUDE.md + the status line into ~/.claude, and wires the status line into
# settings.json. Idempotent: existing non-symlink targets are moved to a
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

# Personal status line (private submodule too): symlink the script AND point
# settings.json at it — both are needed for it to render. Idempotent.
if [ -f "${REPO_DIR}/claude/statusline.sh" ]; then
  chmod +x "${REPO_DIR}/claude/statusline.sh"
  link "${REPO_DIR}/claude/statusline.sh" "${CLAUDE_DIR}/statusline.sh"
  SETTINGS="${CLAUDE_DIR}/settings.json"
  if command -v jq > /dev/null 2>&1; then
    current="$(jq -r '.statusLine.command // ""' "${SETTINGS}" 2>/dev/null || echo "")"
    # Literal comparison: this IS the string stored in settings.json (Claude Code
    # expands the ~ at runtime, not us), so the tilde must stay unexpanded here.
    # shellcheck disable=SC2088
    if [ "${current}" = "~/.claude/statusline.sh" ]; then
      echo "ok      settings.json statusLine"
    else
      [ -f "${SETTINGS}" ] || echo '{}' > "${SETTINGS}"
      mkdir -p "${BACKUP_DIR}" && cp "${SETTINGS}" "${BACKUP_DIR}/settings.json" 2>/dev/null || true
      tmp="$(mktemp)"
      jq '.statusLine = {type: "command", command: "~/.claude/statusline.sh", refreshInterval: 30}' \
        "${SETTINGS}" > "${tmp}" && mv "${tmp}" "${SETTINGS}"
      echo "wire    settings.json statusLine -> ~/.claude/statusline.sh"
    fi
  else
    echo 'note    jq not found — add "statusLine":{"type":"command","command":"~/.claude/statusline.sh"} to settings.json yourself'
  fi
fi

# Wire the versioned pre-commit hook (gitleaks secret scan).
git -C "${REPO_DIR}" config core.hooksPath hooks
echo "hooks   core.hooksPath = hooks"

echo "done."
