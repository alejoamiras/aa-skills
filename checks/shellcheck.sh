#!/usr/bin/env bash
# The budget check's file list is the one definition of a shell file, so both gates cover the same set.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
list=$(bun checks/budget.ts --files)
files=()
while IFS= read -r f; do files+=("$f"); done <<< "$list"
shellcheck -S warning -- "${files[@]}"
