# shellcheck shell=bash
# Director checks that skills/crew/scripts/crew.sh sources, so it must run on bash 3.2 (stock macOS). The
# sourcing script sets CLAUDE_PID to a numeric pid before calling them.

# A session's mode is recorded nowhere a script can read; only the flag it was
# started with shows. ps joins argv with spaces, so off Linux a prompt that
# quotes the flag reads as the flag.
director_skips_checks() {
  local -a argv=()
  local a i
  if [[ -r /proc/${CLAUDE_PID}/cmdline ]]; then
    while IFS= read -r -d '' a; do argv+=("${a}"); done < "/proc/${CLAUDE_PID}/cmdline"
  else
    read -r -a argv <<< "$(ps -o args= -p "${CLAUDE_PID}" 2> /dev/null)"
  fi
  for ((i = 0; i < ${#argv[@]}; i++)); do
    case "${argv[i]}" in
      --dangerously-skip-permissions | --permission-mode=bypassPermissions) return 0 ;;
      --permission-mode) [[ ${argv[i + 1]:-} == bypassPermissions ]] && return 0 ;;
    esac
  done
  return 1
}
