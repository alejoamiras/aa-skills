#!/usr/bin/env bash
# The next turn of a review-leg conversation run-agy.sh started, in the recorded top level, in place, so a fix-loop
# resume sees the fixed code. One call at a time per run dir: a second waits for the first.
#   resume-agy.sh <session-id|""> <prompt-file> <gemini-dir> [effort] [limit]
# session-id: the SESSION_ID run-agy.sh printed, or "" for the one in <gemini-dir>/session_id; a mismatch is refused.
# gemini-dir: the GEMINI_DIR it printed, a real dir of this user, mode 700, directly under ~/.cache/gemini-leg/.
# effort: default the recorded one. limit: counted tokens, 100000 to 4000000, default 2000000.
# Exit, record line and trailer as run-agy.sh, with this turn's numbered files (response.<n>.md, log.<n>.ndjson); a
# resume that exits 2 or 4 leaves the run dir as it was. A last turn that ended on the mode or model tripwire bars it.
set -uo pipefail
unset CDPATH
case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd -P -- "${HERE}" && pwd -P)" || exit 2
GL_NAME=resume-agy
# shellcheck source=SCRIPTDIR/leg-lib.sh
. "${HERE}/leg-lib.sh" || exit 2

[[ ${HOME:-} == /* ]] || gl_die 2 "HOME is not set"
(($# >= 3 && $# <= 5)) || gl_die 2 "usage: resume-agy.sh <session-id|\"\"> <prompt-file> <gemini-dir> [effort] [limit]"
gl_prompt "$2"
NOT_RUN="not a run dir (a real dir of this user, mode 700, right under ~/.cache/gemini-leg/): $3"
DIR="$3"
while [[ ${DIR} == */ && ${DIR} != / ]]; do DIR="${DIR%/}"; done
[[ -d ${DIR} && ! -L ${DIR} ]] || gl_die 2 "${NOT_RUN}"
DIR=$(cd -P -- "${DIR}" && pwd -P) || gl_die 2 "${NOT_RUN}"
gl_root
[[ -O ${DIR} && $(stat -c %a -- "${DIR}") == 700 && ${DIR%/*} == "${GL_ROOT}" ]] || gl_die 2 "${NOT_RUN}"

[[ -f ${DIR}/meta && ! -L ${DIR}/meta ]] || gl_die 2 "${DIR}/meta is missing"
declare -A META=()
while IFS='=' read -r k v; do [[ -n ${k} ]] && META[${k}]="${v}"; done < "${DIR}/meta"
case "${META[model]:-}" in gemini-4-neon | gemini-4-carbon) GL_MODEL="${META[model]}" ;; *) gl_die 2 "${DIR}/meta names no model" ;; esac
gl_effort "${4:-${META[effort]:-}}"
gl_limit "${5:-2000000}"
[[ ${META[top]:-} == /* ]] || gl_die 2 "${DIR}/meta names no top level"
gl_top "${META[top]}"
[[ ${GL_TOP} == "${META[top]}" ]] || gl_die 2 "${META[top]} is no longer the top level of a git work tree"
gl_env
gl_engine_check
gl_off_checks

[[ -f ${DIR}/lock && ! -L ${DIR}/lock ]] && exec 9< "${DIR}/lock" || gl_die 2 "${DIR}/lock is missing"
flock 9 || gl_die 2 "cannot lock ${DIR}/lock"
# Under the lock: the first turn writes session_id at its end, while it still holds it.
SID="$1"
if [[ -f ${DIR}/session_id && ! -L ${DIR}/session_id ]]; then
  read -r RECORDED < "${DIR}/session_id"
  [[ -z ${SID} || ${SID} == "${RECORDED}" ]] || gl_die 2 "the session id ${SID} is not the one ${DIR}/session_id records"
  SID="${RECORDED}"
fi
[[ -n ${SID} ]] || gl_die 2 "${DIR} records no session id and none was given"
TURN=2
while [[ -e ${DIR}/prompt.${TURN}.md || -L ${DIR}/prompt.${TURN}.md ]]; do TURN=$((TURN + 1)); done
LAST="${DIR}/result.json"
((TURN > 2)) && LAST="${DIR}/result.$((TURN - 1)).json"
# A command from an earlier turn can plant a link here before the engine's exclusive create, so it is never followed.
[[ -f ${LAST} && ! -L ${LAST} ]] && TRIP=$(jq -er '.tripwire // ""' "${LAST}" 2> /dev/null) ||
  gl_die 2 "turn $((TURN - 1)) has no readable result in ${DIR}"
[[ ${TRIP} == mode || ${TRIP} == model ]] && gl_die 2 "turn $((TURN - 1)) ended on the ${TRIP} tripwire, which bars a resume"

gl_begin
gl_engine "${DIR}" "${TURN}" "${SID}"
gl_refusal resume "${DIR}"
gl_report "${DIR}" "${TURN}"
