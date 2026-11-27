# shellcheck shell=bash
# The repository check shared by skills/gemini/scripts/worker-gemini.sh and the review leg (scripts/leg-lib.sh): agy
# runs .agents/ hooks and MCP servers from its working directory before it reads any message.

# Prints why agy would run code from top level $1 before any message and succeeds; fails, printing nothing, when it
# would not.
agy_repo_runs_code() {
  local f
  if [[ -L $1/.agents ]]; then
    printf '%s/.agents is a symlink\n' "$1"
    return 0
  fi
  for f in hooks.json mcp_config.json; do
    if [[ -e $1/.agents/${f} || -L $1/.agents/${f} ]]; then
      printf '%s/.agents/%s would run code before any message\n' "$1" "${f}"
      return 0
    fi
  done
  return 1
}
