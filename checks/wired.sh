#!/usr/bin/env bash
# Every smoke and bun test either runs in a workflow (`bash <file>` / `bun test <file>`) or is listed in one as
# `# <file>: <why CI cannot run it>`, so a new one cannot land unrun.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
rc=0
for f in tests/smoke-*.sh tests/*.test.ts; do
  grep -rqF -e "bash $f" -e "bun test $f" -e "# $f: " .github/workflows || { echo "$f: no workflow runs it or says why it cannot" >&2; rc=1; }
done
exit "$rc"
