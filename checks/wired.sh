#!/usr/bin/env bash
# Every smoke and bun test either runs from a workflow's one-line `run: bash <file>` / `run: bun test <file>`, or
# a workflow lists it as a top-level `# <file>: <why CI cannot run it>` comment, so a new one cannot land unrun.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
shopt -s nullglob
yml=(.github/workflows/*.yml .github/workflows/*.yaml)
runs=$(sed -nE 's/^[[:space:]]*(- )?run: (bash|bun test) ([^[:space:]]+)[[:space:]]*$/\3/p' "${yml[@]}")
listed=$(sed -nE 's/^# ([^[:space:]]+): .+/\1/p' "${yml[@]}")
rc=0
while IFS= read -r f; do
  grep -qxF -- "$f" <<< "$runs"$'\n'"$listed" || { echo "$f: no workflow runs it or says why it cannot" >&2; rc=1; }
done < <(git ls-files -co --exclude-standard -- 'tests/*smoke-*.sh' '*.test.ts')
exit "$rc"
