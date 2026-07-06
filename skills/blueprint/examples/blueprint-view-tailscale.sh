#!/usr/bin/env bash
# blueprint-view-tailscale.sh — reference implementation of the blueprint
# skill's BLUEPRINT_VIEW_CMD contract (skills/blueprint/SKILL.md, "Remote
# viewing" section) for machines on a Tailscale tailnet.
#
# Contract:
#   blueprint-view <plan-dir>          UP: publish, print base URL (one line, no trailing slash)
#   blueprint-view --down <plan-dir>   DOWN: unpublish that plan's tree (idempotent)
#   blueprint-view --off               backstop: drop ALL mounts on the port (idempotent;
#                                      refuses extra args so it can't be confused with --down)
#
# What it serves: ONLY `implementations-plan` trees under BLUEPRINT_VIEW_ROOT
# (default ~/Projects), each repo's tree mounted at a URL path mirroring the
# filesystem, tailnet-only — never `tailscale funnel`. The blueprint skill
# calls DOWN right after the approval verdict, so serving exists only inside
# approval windows. Guards (fail closed): refuses paths outside ROOT, paths
# not inside an implementations-plan tree, non-directories, unscannable trees,
# and trees containing ANY symlink (plan trees are generated docs — a symlink
# there is either an accident or an exfiltration attempt; tailscaled serves as
# root, so symlinks must never reach it).
#
# Caveats: two concurrent gates in the SAME repo share one mount — DOWN for
# one 404s the other until its gate re-presents (UP is idempotent). Orphaned
# mounts (session died mid-gate): inspect `tailscale serve status`, then
# `blueprint-view --off` — note it drops every mount on the port, including
# other agents' live gates.
#
# Dependencies: tailscale, jq, coreutils — and, for serve MUTATIONS
# (up/down/off), root or PASSWORDLESS sudo: tailscale requires root to serve
# filesystem paths (operator alone is NOT enough — learned empirically, see
# the plan's lessons). Uses `sudo -n`; fails loudly if sudo would prompt.
# That is a real trust decision on multi-user machines; fine where the user
# is already root-equivalent.
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

# Print the handler mount-points active on OUR port, one per line.
# Tries unprivileged first (works with the operator grant), then sudo -n
# (operator-less machines). Exits non-zero (error on stderr) if neither can
# read state — callers must treat that as UNKNOWN, never as "absent".
handlers() {
  local json
  if ! json="$(tailscale serve status --json 2>/dev/null)"; then
    if ! json="$(sudo -n tailscale serve status --json 2>&1)"; then
      err "cannot query tailscale serve state: ${json}"
      return 1
    fi
  fi
  jq -r --arg port ":${PORT}" \
    '(.Web // {}) | to_entries[] | select(.key | endswith($port)) | .value.Handlers // {} | keys[]' \
    <<<"${json}"
}

case "${PORT}" in
  ''|*[!0-9]*) err "BLUEPRINT_VIEW_PORT must be numeric, got '${PORT}'"; exit 1 ;;
esac

mode=up
case "${1:-}" in
  --off)
    if [ $# -ne 1 ]; then
      err "--off takes no arguments (did you mean --down <plan-dir>?)"
      exit 1
    fi
    # Teardown is attempt-first: an unreadable status probe must not prevent
    # the cleanup attempt (lifecycle safety beats early exit).
    if existing="$(handlers)"; then
      [ -n "${existing}" ] || exit 0        # confirmed empty: nothing to drop
    fi
    msg="$(ts_mut serve --http="${PORT}" off 2>&1 >/dev/null)" || true
    state="$(handlers)" || { err "--off attempted; cannot confirm final state: ${msg:-no error output}"; exit 1; }
    [ -z "${state}" ] || { err "--off failed to clear mounts: ${msg:-no error output}"; exit 1; }
    exit 0
    ;;
  --down) mode=down; shift ;;
esac

if [ $# -ne 1 ]; then
  err "usage: blueprint-view [--down] <plan-dir> | blueprint-view --off"
  exit 1
fi

ROOT="$(realpath -- "${ROOT}")" || { err "BLUEPRINT_VIEW_ROOT does not resolve: ${ROOT}"; exit 1; }

if [ "${mode}" = down ]; then
  # -m: DOWN must work even after the plan dir was deleted (unpublish is
  # about the mount, not the files).
  plan_dir="$(realpath -m -- "$1")"
else
  plan_dir="$(realpath -e -- "$1" 2>/dev/null)" || { err "path does not exist: $1"; exit 1; }
  [ -d "${plan_dir}" ] || { err "not a directory: ${plan_dir}"; exit 1; }
fi

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

# tailscale stores path handlers slash-normalized: create with "/<rel>",
# match and remove with "/<rel>/".
rel="${mount_dir#"${ROOT}"/}"
handler="/${rel}/"

is_mounted() { grep -qxF -- "${handler}" <<<"$1"; }

if [ "${mode}" = down ]; then
  # Attempt-first: if state is readable and the mount is confirmed absent,
  # done; otherwise ALWAYS attempt removal, then verify. An unreadable probe
  # must never fake success (exit 1) nor prevent the cleanup attempt.
  if state="$(handlers)"; then
    is_mounted "${state}" || exit 0         # idempotent: confirmed absent
  fi
  msg="$(ts_mut serve --http="${PORT}" --set-path="${handler}" off 2>&1 >/dev/null)" || true
  state="$(handlers)" || { err "teardown attempted for ${handler}; cannot confirm final state: ${msg:-no error output}"; exit 1; }
  if is_mounted "${state}"; then
    err "teardown failed for ${handler}: ${msg:-no error output}"
    exit 1
  fi
  exit 0
fi

# Symlink guard (fail closed): plan trees are generated docs — refuse ANY
# symlink, which also kills multi-hop directory-symlink escapes, and refuse
# trees we cannot fully scan (tailscaled serves as root and sees more than us).
if ! links="$(find "${mount_dir}" -type l 2>&1)"; then
  err "refusing: cannot fully scan ${mount_dir}: ${links}"
  exit 1
fi
if [ -n "${links}" ]; then
  err "refusing: symlinks are not allowed in a served plan tree: $(head -n1 <<<"${links}")"
  exit 1
fi

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
state="$(handlers)" || exit 1
is_mounted "${state}" || { err "publish did not take effect (handler ${handler} missing)"; exit 1; }

# Percent-encode the URL path, keeping the / separators.
plan_rel="${plan_dir#"${ROOT}"/}"
enc_rel="$(printf '%s' "${plan_rel}" | jq -sRr '@uri | gsub("%2F"; "/")')"
echo "http://${dns_name}:${PORT}/${enc_rel}"
