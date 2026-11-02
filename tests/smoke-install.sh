#!/usr/bin/env bash
# Smoke test for install.sh's per-platform skills: a copy of install.sh in a throwaway repo with two fake skills, one
# limited by a `platforms` file, installed into a throwaway HOME under a faked `uname -s`. The real HOME is never touched.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$S"' EXIT
R="$S/repo"
FAIL=0

assert_install() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok    $label"; else echo "FAIL  $label"; FAIL=1; fi; }

mkdir -p "$R/skills/anywhere" "$R/skills/linuxy" "$S/fake" "$S/home/.claude/skills" "$S/home/.agents/skills" "$S/elsewhere"
cp "$ROOT/install.sh" "$R/"
echo '# anywhere' > "$R/skills/anywhere/SKILL.md"
echo '# linuxy' > "$R/skills/linuxy/SKILL.md"
printf 'Linux\n' > "$R/skills/linuxy/platforms"
git -C "$R" init -q -b main
printf '#!/bin/sh\n[ "$1" = -s ] && echo "$FAKE_OS" || exec /usr/bin/uname "$@"\n' > "$S/fake/uname"
chmod +x "$S/fake/uname"

install_as() { env HOME="$S/home" PATH="$S/fake:$PATH" FAKE_OS="$1" bash "$R/install.sh" > "$S/out.$1" 2>&1; }
linked() { [ "$(readlink "$S/home/$1/skills/$2")" = "$R/skills/$2" ]; }

# An earlier install linked linuxy into ~/.claude; ~/.agents holds someone else's skill of the same name.
ln -s "$R/skills/linuxy" "$S/home/.claude/skills/linuxy"
ln -s "$S/elsewhere" "$S/home/.agents/skills/linuxy"

install_as Darwin; rc=$?
assert_install "darwin: install succeeds" test "$rc" = 0
assert_install "darwin: a skill without platforms links into both roots" eval 'linked .claude anywhere && linked .agents anywhere'
assert_install "darwin: a Linux-only skill's earlier link from this repo is removed" test ! -L "$S/home/.claude/skills/linuxy"
assert_install "darwin: a same-named link to somewhere else is left alone" test "$(readlink "$S/home/.agents/skills/linuxy")" = "$S/elsewhere"
assert_install "darwin: the skip names the platforms" grep -qx 'skip    linuxy (Linux only)' "$S/out.Darwin"

install_as Linux; rc=$?
assert_install "linux: install succeeds" test "$rc" = 0
assert_install "linux: the Linux-only skill links into both roots" eval 'linked .claude linuxy && linked .agents linuxy'

echo ""
if [ "$FAIL" = 0 ]; then echo "ALL SMOKE TESTS PASSED"; else sed 's/^/  | /' "$S"/out.*; echo "SMOKE FAILURES PRESENT"; exit 1; fi
