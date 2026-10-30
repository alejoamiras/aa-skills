#!/usr/bin/env bash
# Runs shellcheck at warning severity over exactly the files the budget check measures.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
list=$(bun checks/budget.ts --files)
files=()
while IFS= read -r f; do files+=("$f"); done <<< "$list"
shellcheck -S warning "${files[@]}"
