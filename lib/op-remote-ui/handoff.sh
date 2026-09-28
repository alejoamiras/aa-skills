# shellcheck shell=bash
# Returns the terminal to the owner after a UI process exits. Sourced by op-remote and spike/check.sh.
# bash 3.2. Call it only once the UI process has been reaped: nothing may write to the tty after it.

# op_remote_handoff <stty -g saved before the launch>: fails if any step fails, and then the caller
# must refuse to prompt.
op_remote_handoff() {
  local saved=$1 re='^[ -~]+$'
  local LC_ALL=C
  stty "$saved" < /dev/tty 2> /dev/null || return 1
  # CAN aborts a half-sent CSI; ST ends an unterminated OSC/DCS/APC string.
  printf '\030\033\134' > /dev/tty || return 1
  # Alt screen, SGR, scroll region, cursor, mouse and focus reports, bracketed paste, kitty keyboard
  # flags (pop the whole stack, then zero), palette.
  printf '\033[?1049l\033[0m\033[r\033[?25h\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1004l\033[?2004l\033[<99u\033[=0;1u\033]104\007' > /dev/tty || return 1
  # A profile carries its own key mappings, so a UI that switched it could change what a key sends.
  if [ "${TERM_PROGRAM:-}" = iTerm.app ] && [[ ${ITERM_PROFILE:-} =~ $re ]]; then
    printf '\033]1337;SetProfile=%s\007' "$ITERM_PROFILE" > /dev/tty || return 1
  fi
  printf '\033c' > /dev/tty || return 1
  # Discards whatever was queued while the UI ran, including TIOCSTI injections.
  perl -MPOSIX -e 'POSIX::tcflush(0, POSIX::TCIFLUSH()) or exit 1' < /dev/tty
}
