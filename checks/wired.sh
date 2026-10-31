#!/usr/bin/env bash
# Every smoke and bun test runs from a workflow's one-line `run: bash <file>` / `run: bun test <file>` step whose
# paths-filter list `relevant` (the output every gated job reads) covers that file, or a workflow lists it as a
# top-level `# <file>: <reason>` comment, so a new one cannot land unrun.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
shopt -s nullglob
tests=(':(glob)**/smoke.sh' ':(glob)**/smoke-*.sh')
for ext in ts tsx mts cts js jsx mjs cjs; do for form in '*.test.' '*_test.' '*.spec.' '*_spec.'; do tests+=(":(glob)**/$form$ext"); done; done
rc=0 runs="" listed=""
for y in .github/workflows/*.yml .github/workflows/*.yaml; do
  pats=$(awk '/^[[:space:]]+relevant:[[:space:]]*$/ { on = 1; next }
      on && /^[[:space:]]*(#.*)?$/ { next } on && /^[[:space:]]+- / { print; next } { on = 0 }' "$y" |
    sed -nE "s/^[[:space:]]+- '([^']+)'[[:space:]]*$/\1/p")
  listed+=$(sed -nE 's/^# ([^[:space:]]+): .+/\1/p' "$y")$'\n'
  while IFS= read -r f; do
    runs+="$f"$'\n'
    [ -n "$pats" ] || { echo "$y runs $f but has no paths-filter list named relevant" >&2; rc=1; continue; }
    covered=0
    # Only an exact path, "**" or "dir/**" counts: their paths-filter meaning needs no glob engine to match.
    while IFS= read -r p; do
      case $p in
        '**') covered=1 ;;
        */'**') [[ $f == "${p%'**'}"* ]] && covered=1 ;;
        *) [[ $f == "$p" ]] && covered=1 ;;
      esac
    done <<< "$pats"
    [ "$covered" = 1 ] || { echo "$y runs $f, but its path filter skips changes to it" >&2; rc=1; }
  done < <(sed -nE 's/^[[:space:]]*(- )?run: (bash|bun test) ([^[:space:]]+)[[:space:]]*$/\3/p' "$y")
done
while IFS= read -r f; do
  grep -qxF -- "$f" <<< "$runs$listed" || { echo "$f: no workflow runs it or says why it cannot" >&2; rc=1; }
done < <(git ls-files -co --exclude-standard -- "${tests[@]}")
exit "$rc"
