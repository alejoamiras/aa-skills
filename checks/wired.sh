#!/usr/bin/env bash
# Every smoke and bun test runs from a workflow's one-line `run: bash <file>` / `run: bun test <file>` step whose
# path filter covers that file, or a workflow lists it as a top-level `# <file>: <reason>` comment, so a new one
# cannot land unrun.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
shopt -s nullglob
rc=0 runs="" listed=""
for y in .github/workflows/*.yml .github/workflows/*.yaml; do
  pats=$(sed -nE "s/^[[:space:]]+- '([^']+)'[[:space:]]*$/\1/p" "$y")
  listed+=$(sed -nE 's/^# ([^[:space:]]+): .+/\1/p' "$y")$'\n'
  while IFS= read -r f; do
    runs+="$f"$'\n'
    covered=0
    while IFS= read -r p; do
      # shellcheck disable=SC2053 # a filter is a glob, and "**" spans directories as "*" does in [[ ]]
      [[ -n $p && $f == ${p//\*\*/*} ]] && covered=1
    done <<< "$pats"
    [ "$covered" = 1 ] || { echo "$y runs $f, but its path filter skips changes to it" >&2; rc=1; }
  done < <(sed -nE 's/^[[:space:]]*(- )?run: (bash|bun test) ([^[:space:]]+)[[:space:]]*$/\3/p' "$y")
done
while IFS= read -r f; do
  grep -qxF -- "$f" <<< "$runs$listed" || { echo "$f: no workflow runs it or says why it cannot" >&2; rc=1; }
done < <(git ls-files -co --exclude-standard -- ':(glob)**/smoke.sh' ':(glob)**/smoke-*.sh' ':(glob)**/*.test.ts')
exit "$rc"
