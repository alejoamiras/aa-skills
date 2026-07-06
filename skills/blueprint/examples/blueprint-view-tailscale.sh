#!/usr/bin/env bash
# blueprint-view-tailscale.sh — reference implementation of the blueprint
# skill's BLUEPRINT_VIEW_CMD contract (skills/blueprint/SKILL.md, "Remote
# viewing" section) for machines on a Tailscale tailnet.
#
# Contract:
#   blueprint-view <plan-dir>          UP: publish, print base URL (one line, no trailing slash)
#   blueprint-view --down <plan-dir>   DOWN: unpublish that plan's tree (idempotent)
#   blueprint-view --off               backstop: drop ALL mounts on the port
#
# What it serves: ONLY `implementations-plan` trees under BLUEPRINT_VIEW_ROOT
# (default ~/Projects), each repo's tree mounted at a URL path mirroring the
# filesystem, tailnet-only — never `tailscale funnel`. The blueprint skill
# calls DOWN right after the approval verdict, so serving exists only inside
# approval windows. Guards: refuses paths outside ROOT, paths not inside an
# implementations-plan tree, and trees containing symlinks that resolve
# outside ROOT.
#
# Caveat: two concurrent gates in the SAME repo share one mount — DOWN for
# one 404s the other until its gate re-presents (the hook re-mounts, UP is
# idempotent). Orphaned mounts (session died mid-gate): `blueprint-view --off`
# or inspect with `tailscale serve status`.
#
# Dependencies: tailscale, jq, coreutils — and, for serve MUTATIONS (up/down/off),
# root or PASSWORDLESS sudo: tailscale requires root to serve filesystem paths
# (operator alone is NOT enough — learned empirically, see the plan's lessons).
# This script uses `sudo -n` and fails loudly if sudo would prompt. That is a
# real trust decision on multi-user machines; fine where the user is already
# root-equivalent.
# One-time machine setup:
#   sudo tailscale set --operator=$USER    # optional: sudo-free `serve status`
#   ln -s "$(pwd)/blueprint-view-tailscale.sh" ~/.local/bin/blueprint-view
#   export BLUEPRINT_VIEW_CMD="$HOME/.local/bin/blueprint-view"   # shell rc + harness env
set -euo pipefail

PORT="${BLUEPRINT_VIEW_PORT:-43117}"
ROOT="${BLUEPRINT_VIEW_ROOT:-$HOME/Projects}"

err() { echo "blueprint-view: $*" >&2; }

# Serve mutations need root (operator is not enough for path serving).
ts_mut() {
  if [ "$(id -u)" -eq 0 ]; then
    tailscale "$@"
  else
    sudo -n tailscale "$@"
  fi
}

case "${PORT}" in
  ''|*[!0-9]*) err "BLUEPRINT_VIEW_PORT must be numeric, got '${PORT}'"; exit 1 ;;
esac

mode=up
case "${1:-}" in
  --off)  ts_mut serve --http="${PORT}" off; exit $? ;;
  --down) mode=down; shift ;;
esac

if [ $# -ne 1 ]; then
  err "usage: blueprint-view [--down] <plan-dir> | blueprint-view --off"
  exit 1
fi

ROOT="$(realpath -- "${ROOT}")" || { err "BLUEPRINT_VIEW_ROOT does not resolve: ${ROOT}"; exit 1; }
plan_dir="$(realpath -e -- "$1" 2>/dev/null)" || { err "path does not exist: $1"; exit 1; }

case "${plan_dir}" in
  "${ROOT}"/*) ;;
  *) err "refusing: ${plan_dir} is outside ${ROOT}"; exit 1 ;;
esac

# Nearest `implementations-plan` ancestor (the dir itself counts) becomes the mount.
mount_dir="${plan_dir}"
while [ "${mount_dir}" != "${ROOT}" ] && [ "$(basename -- "${mount_dir}")" != "implementations-plan" ]; do
  mount_dir="$(dirname -- "${mount_dir}")"
done
if [ "$(basename -- "${mount_dir}")" != "implementations-plan" ]; then
  err "refusing: ${plan_dir} is not inside an implementations-plan tree"
  exit 1
fi

rel="${mount_dir#"${ROOT}"/}"

# tailscale normalizes path mounts to a trailing slash in `serve status`.
mounted() { tailscale serve status 2>/dev/null | grep -qF "/${rel}/"; }

if [ "${mode}" = down ]; then
  # Idempotent when the mount is absent; honest when teardown actually fails.
  mounted || exit 0
  # NB: mounts are created with "/<rel>" but tailscale stores (and matches on
  # removal) the trailing-slash form "/<rel>/".
  ts_mut serve --http="${PORT}" --set-path="/${rel}/" off >/dev/null 2>&1 || true
  if mounted; then
    err "teardown failed for /${rel} (needs root or passwordless sudo)"
    exit 1
  fi
  exit 0
fi

# Symlink-escape guard: no symlink in the tree may resolve outside ROOT.
while IFS= read -r -d '' link; do
  target="$(realpath -- "${link}" 2>/dev/null)" || target=""
  case "${target}" in
    "${ROOT}"/*) ;;
    *) err "refusing: symlink escapes root: ${link} -> ${target:-<broken>}"; exit 1 ;;
  esac
done < <(find "${mount_dir}" -type l -print0)

dns_name="$(tailscale status --json | jq -r '.Self.DNSName // empty')"
dns_name="${dns_name%.}"
if [ -z "${dns_name}" ]; then
  err "could not derive tailnet DNS name (is tailscale up?)"
  exit 1
fi

ts_mut serve --http="${PORT}" --set-path="/${rel}" --bg "${mount_dir}" >/dev/null || {
  err "publish failed (path serving needs root or passwordless sudo; operator alone is not enough)"
  exit 1
}

plan_rel="${plan_dir#"${ROOT}"/}"
echo "http://${dns_name}:${PORT}/${plan_rel}"
