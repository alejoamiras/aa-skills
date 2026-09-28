#!/usr/bin/env bash
# Checks the op-remote UI sandbox and terminal handoff on this Mac. Uses no secrets and never runs `op`.
#
#   check.sh measure   deny the forbidden classes, allow the rest WITH REPORT, and record what Bun uses
#   check.sh           the real ../sandbox.sb: every check must pass (exit 0)
#
# Results go to stdout (redirect them to a file); prompts are on the terminal. macOS /bin/bash 3.2.
set -uo pipefail

mode=${1:-gate}
case $mode in gate | measure) ;; *) echo "usage: check.sh [measure]" >&2; exit 2 ;; esac
[ "$(uname)" = Darwin ] || { echo "check.sh: macOS only" >&2; exit 2; }
{ : < /dev/tty; } 2> /dev/null || { echo "check.sh: needs a terminal" >&2; exit 2; }

spike=$(cd "$(dirname "$0")" && pwd -P)
ui=$(cd "$spike/.." && pwd -P)
# shellcheck source-path=SCRIPTDIR/.. source=handoff.sh
. "$ui/handoff.sh"
bun=$(command -v bun) || { echo "check.sh: bun is not on PATH" >&2; exit 2; }
sbx=$(command -v sandbox-exec) || { echo "check.sh: sandbox-exec not found" >&2; exit 2; }
bun_real=$(perl -MCwd -e 'print Cwd::abs_path(shift)' "$bun")
profile=$ui/sandbox.sb
[ "$mode" = gate ] || profile=$spike/sandbox-measure.sb
# Sandbox paths match after symlink resolution: /var is /private/var.
work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT
cache=$HOME/.cache/op-remote
mkdir -p "$cache" && printf 'canary\n' > "$cache/canary"
tmpd=$(cd "${TMPDIR:-/tmp}" && pwd -P)
mach=$(launchctl print "gui/$(id -u)" 2> /dev/null | grep -io '[a-z0-9._-]*1password[a-z0-9._-]*' | sort -u | paste -sd, - || true)
iterm=''
[ "${TERM_PROGRAM:-}" != iTerm.app ] || iterm=iterm
start=$(date '+%Y-%m-%d %H:%M:%S')
fails=0

section() { printf '\n== %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
note() { printf 'NOTE  %s\n' "$*"; }
shown() { printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' '?' | head -c 300; }
ask() { printf '\n%s ' "$1" > /dev/tty; REPLY=''; IFS= read -r REPLY < /dev/tty || true; }

# spike_run <sandbox|plain> <result-file> <script> [args...]: the launch op-remote will use, with the
# caller's stdin/stdout/stderr. fd 4 is the result file; every other descriptor above 4 is closed.
spike_run() {
  local how=$1 result=$2 fd
  shift 2
  : > "$result"
  (
    for fd in /dev/fd/*; do
      fd=${fd##*/}
      if [ "$fd" -gt 4 ] 2> /dev/null; then eval "exec $fd>&-"; fi
    done
    cd "$ui" || exit 1
    if [ "$how" = sandbox ]; then
      exec env -i HOME=/var/empty TERM="${TERM:-dumb}" LANG=C "$sbx" -f "$profile" \
        -D BUN="$bun_real" -D UI="$ui" -D RESULT="$result" -D HOME_DIR="$HOME" \
        "$bun_real" --no-env-file --no-install "$@"
    fi
    exec env -i HOME=/var/empty TERM="${TERM:-dumb}" LANG=C "$bun_real" --no-env-file --no-install "$@"
  ) 3< /dev/null 4> "$result"
}

section "environment"
echo "mode=$mode commit=$(git -C "$ui" rev-parse HEAD 2> /dev/null)"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m); bun $("$bun_real" --version) at $bun_real"
echo "terminal: TERM_PROGRAM=${TERM_PROGRAM:-?} ${TERM_PROGRAM_VERSION:-} TERM=${TERM:-?} tmux=${TMUX:+yes} ITERM_PROFILE=${ITERM_PROFILE:-}"
echo "1Password Mach services: ${mach:-none found}"
echo "profile: $profile"
echo "production tree:"
(cd "$ui" && "$bun_real" pm ls --all 2> /dev/null)

section "probes: outside (positive controls), then inside the sandbox"
args=(spike/probe.ts "$cache/canary" "$tmpd" "$cache/probe-write" "$bun_real" "$mach")
err=$(spike_run plain "$work/outside" "${args[@]}" 2>&1 > /dev/null < /dev/null)
[ -s "$work/outside" ] || fail "probe produced nothing outside the sandbox: $(shown "$err")"
err=$(spike_run sandbox "$work/inside" "${args[@]}" 2>&1 > /dev/null < /dev/null)
if [ ! -s "$work/inside" ] && [ "$mode" = measure ] && printf '%s' "$err" | grep -q '^sandbox-exec:'; then
  note "measure profile rejected ($(shown "$err")); retrying without (with report)"
  sed 's/ (with report)//' "$spike/sandbox-measure.sb" > "$work/measure.sb"
  profile=$work/measure.sb
  err=$(spike_run sandbox "$work/inside" "${args[@]}" 2>&1 > /dev/null < /dev/null)
fi
[ -s "$work/inside" ] || fail "probe produced nothing inside the sandbox: $(shown "$err")"
while IFS= read -r line; do
  name=${line%%=*} out=${line#*=}
  in=$(awk -v n="$name" 'index($0, n "=") == 1 { print substr($0, length(n) + 2); exit }' "$work/inside")
  case $name=$out in
    tcp=ECONNREFUSED | unix=connected | read-canary=ok | write-tmp=ok | write-home=ok) ok=1 ;;
    spawn-true=exit=0 | spawn-bun=exit=0 | mach:*=kr=0 | procargs=ok | pidinfo=ok) ok=1 ;;
    *) ok='' ;;
  esac
  if [ -z "$ok" ]; then
    fail "$name: the control did not succeed outside the sandbox ($out), so this probe proves nothing"
  elif [ -z "$in" ]; then
    fail "$name: no result inside the sandbox"
  elif [ "$in" = "$out" ]; then
    fail "$name: same outcome inside as outside ($out)"
  else
    pass "$name: outside=$out inside=$in"
  fi
done < "$work/outside"

section "OpenTUI render inside the sandbox"
saved=$(stty -g < /dev/tty)
err=$(spike_run sandbox "$work/render" spike/render.ts < /dev/tty 2>&1 > /dev/tty)
op_remote_handoff "$saved" || fail "handoff after the render test"
if grep -qx render-ok "$work/render"; then pass "OpenTUI draws a frame and writes fd 4"; else fail "render: $(shown "$err")"; fi
if [ "$mode" = measure ]; then
  # The draft deny-default profile too: its denials land in the same log.
  measured=$profile profile=$ui/sandbox.sb
  err=$(spike_run sandbox "$work/render-draft" spike/render.ts < /dev/tty 2>&1 > /dev/tty)
  op_remote_handoff "$saved" || fail "handoff after the draft-profile render"
  note "render under the draft sandbox.sb: $(shown "$(cat "$work/render-draft")") $(shown "$err")"
  profile=$measured
fi

section "terminal handoff against a hostile UI"
err=$(spike_run sandbox "$work/control" spike/hostile.ts control $iterm < /dev/tty 2>&1 > /dev/tty)
stty "$saved" < /dev/tty
injected=''
IFS= read -r -t 1 injected < /dev/tty || true
note "control run: hostile says $(shown "$(cat "$work/control")") $(shown "$err"); unflushed read got '$(shown "$injected")'"
inj=blocked
[ "$injected" != y ] || inj=works
if [ -n "$iterm" ]; then
  ask "CONTROL: this tab should now be the red op-remote-test profile. Press F5, then Enter:"
  if [ "$REPLY" = PROFILE-SWITCHED ]; then
    pass "control: the hostile UI's profile switch took effect"
  else
    fail "control: F5 gave '$(shown "$REPLY")', not PROFILE-SWITCHED (is op-remote-test set up with F5 -> Send Text?)"
  fi
fi
op_remote_handoff "$saved" || fail "handoff after the control run"

err=$(spike_run sandbox "$work/real" spike/hostile.ts full $iterm < /dev/tty 2>&1 > /dev/tty)
if op_remote_handoff "$saved"; then pass "handoff completed after a SIGKILLed hostile UI"; else fail "handoff failed after the hostile UI"; fi
note "hostile run: $(shown "$(cat "$work/real")") $(shown "$err")"
ask "Type n, then Enter:"
if [ "$REPLY" != n ]; then
  fail "the prompt read '$(shown "$REPLY")' instead of 'n': injected input survived, or the terminal was not restored"
elif [ "$inj" = works ]; then
  pass "injection reaches an unflushed prompt here, and the handoff discarded it (I3 a)"
else
  pass "injection never reached the prompt, even unflushed (I3 b)"
fi
if [ -n "$iterm" ]; then
  ask "Press F5, then Enter:"
  case $REPLY in
    *PROFILE-SWITCHED*) fail "profile not restored: F5 still sends PROFILE-SWITCHED" ;;
    *) pass "profile restored: F5 no longer sends PROFILE-SWITCHED" ;;
  esac
fi
printf '\nDone. Results are in the file you redirected stdout to.\n' > /dev/tty

if [ "$mode" = measure ]; then
  section "sandbox log for bun since $start (full log: ~/op-remote-measure.log)"
  log show --style compact --start "$start" --predicate 'sender == "Sandbox"' 2> /dev/null |
    grep -i 'bun' > "$HOME/op-remote-measure.log" || true
  sed -nE 's/.*(allow|deny)\([0-9]+\) ([a-z*-]+)( .*)?$/\1 \2\3/p' "$HOME/op-remote-measure.log" |
    sed -E 's#/Users/[^/ ]+#~#g; s#/private/var/folders/[^ ]+#<tmp>#g' | sort | uniq -c | sort -rn | head -400
  note "measure mode: the probe results above are informational; the gate is 'check.sh' with the final sandbox.sb"
  exit 0
fi
section "result"
if [ "$fails" -eq 0 ]; then echo "ALL PASSED"; exit 0; fi
echo "FAILED: $fails"
exit 1
