#!/usr/bin/env bash
# Installs this repo for BOTH harnesses that read the Agent Skills format:
# skills are symlinked into ~/.claude/skills (Claude Code) and ~/.agents/skills
# (Codex), bin/ CLIs go on PATH, and from the private submodule the generic
# AGENTS.md is linked where each harness looks for global instructions
# (~/.claude/AGENTS.md via CLAUDE.md's @import, ~/.codex/AGENTS.md directly),
# plus the status line and the managed settings.json keys for Claude Code.
# Idempotent: existing non-symlink targets are moved to a timestamped backup
# dir first.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_REAL="$(cd "${REPO_DIR}" && pwd -P)"
CLAUDE_DIR="${HOME}/.claude"
AGENTS_DIR="${HOME}/.agents"
CODEX_DIR="${HOME}/.codex"
BACKUP_DIR="${CLAUDE_DIR}/backups/aa-skills-$(date +%Y%m%d-%H%M%S)"

mkdir -p "${CLAUDE_DIR}/skills" "${AGENTS_DIR}/skills"

# Backups keep the destination's home-relative path: the same basename now
# exists under several roots (~/.claude/AGENTS.md and ~/.codex/AGENTS.md,
# ~/.claude/skills/x and ~/.agents/skills/x), so a flat backup dir would
# overwrite one with the other.
backup() {
  local dst="$1" rel="${1#"${HOME}"/}" dest
  dest="${BACKUP_DIR}/${rel}"
  mkdir -p "$(dirname "${dest}")"
  mv "${dst}" "${dest}"
  echo "backup  ${dst} -> ${dest}"
}

link() {
  local src="$1" dst="$2"
  if [ -L "${dst}" ]; then
    [ "$(readlink "${dst}")" = "${src}" ] && { echo "ok      ${dst}"; return; }
    backup "${dst}"
  elif [ -e "${dst}" ]; then
    backup "${dst}"
  fi
  ln -s "${src}" "${dst}"
  echo "link    ${dst} -> ${src}"
}

# Same SKILL.md, two discovery roots: Claude Code reads ~/.claude/skills, Codex
# reads ~/.agents/skills (neither reads the other's). Both follow symlinks.
for skill in "${REPO_DIR}"/skills/*/; do
  name="$(basename "${skill%/}")"
  link "${REPO_DIR}/skills/${name}" "${CLAUDE_DIR}/skills/${name}"
  link "${REPO_DIR}/skills/${name}" "${AGENTS_DIR}/skills/${name}"
done

# ~/.codex/skills was the pre-~/.agents Codex location. A link there that points
# into this repo now duplicates the ~/.agents one (Codex lists both), so retire
# it. Anything not pointing into this repo is left alone.
if [ -d "${CODEX_DIR}/skills" ]; then
  for legacy in "${CODEX_DIR}"/skills/*; do
    [ -L "${legacy}" ] || continue
    case "$(readlink -f "${legacy}" 2>/dev/null || true)" in
      "${REPO_REAL}/skills/"*)
        rm "${legacy}"
        echo "retire  ${legacy} (superseded by ${AGENTS_DIR}/skills/$(basename "${legacy}"))"
        ;;
    esac
  done
fi

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
# AGENTS.md holds the harness-neutral instructions; CLAUDE.md is a thin file
# that @imports it and appends Claude Code specifics. Claude Code resolves the
# relative @AGENTS.md against CLAUDE.md's location, so AGENTS.md must sit next
# to the CLAUDE.md link too, not only next to the real file. Codex has no
# import mechanism and reads ~/.codex/AGENTS.md as its global instructions.
if [ -f "${REPO_DIR}/claude/AGENTS.md" ]; then
  link "${REPO_DIR}/claude/AGENTS.md" "${CLAUDE_DIR}/AGENTS.md"
  if command -v codex > /dev/null 2>&1 || [ -d "${CODEX_DIR}" ]; then
    mkdir -p "${CODEX_DIR}"
    link "${REPO_DIR}/claude/AGENTS.md" "${CODEX_DIR}/AGENTS.md"
  else
    echo "skip    ~/.codex/AGENTS.md (codex not installed)"
  fi
else
  echo "skip    AGENTS.md (private submodule not initialized — fine for non-owner clones)"
fi
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
      mkdir -p "${BACKUP_DIR}/.claude"
      cp "${SETTINGS}" "${BACKUP_DIR}/.claude/settings.json"
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
