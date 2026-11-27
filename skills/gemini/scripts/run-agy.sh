#!/usr/bin/env bash
# The Gemini review leg: one call of the pinned agy (engines/agy run) on a repository, in place, running commands with
# the key in its environment and everything this user can do. Its edit tools are denied as hardening; nothing here is
# a boundary. Linux only.
#   run-agy.sh <prompt-file> <cwd> <effort> <profile> <model> [limit]
#   run-agy.sh --check <cwd>
# prompt-file: a regular file of at most 1 MiB, never the key file. cwd: inside a git work tree; Gemini works in its top
# level. effort: low|medium|high. profile: open. model: neon|carbon. limit: counted tokens (input, output and cached
# reads), 100000 to 4000000, default 4000000: one figure for the call and its wrap-up, a trigger on observed tokens, not
# a bound on dollars.
# Exit: 0 answered · 1 sent, no answer · 2 usage, or a prompt that holds the key: one stderr line, no trailer · 4 nothing
# sent (off, or the engine's setup checks): the record line only. --check stops after the off checks with 0 or 4.
# Stdout on 0 and 1: the record line, then GEMINI_DIR=, SESSION_ID=, RESPONSE_FILE= (empty when no answer was kept) and
# LOG_FILE=. Record line: "GEMINI: answered (<model> <effort> rev=<sha7>[-dirty] in=<n> out=<n> cached=<n> tools=<n>
# <m>m<s>s[ tree=changed| tree=unknown])" or "GEMINI: unavailable (<reason>[ in=<n> out=<n> cached=<n>][ tree=…])".
# The run dir, ~/.cache/gemini-leg/<UTC stamp>-<random>/, is kept on 0 and 1 and removed on 2 and 4.
set -uo pipefail
unset CDPATH
case "${BASH_SOURCE[0]}" in */*) HERE="${BASH_SOURCE[0]%/*}" ;; *) HERE=. ;; esac
HERE="$(cd -P -- "${HERE}" && pwd -P)" || exit 2
GL_NAME=run-agy
# shellcheck source=SCRIPTDIR/leg-lib.sh
. "${HERE}/leg-lib.sh" || exit 2

[[ ${HOME:-} == /* ]] || gl_die 2 "HOME is not set"
if [[ ${1:-} == --check ]]; then
  (($# == 2)) || gl_die 2 "usage: run-agy.sh --check <cwd>"
  gl_top "$2"
  gl_env
  gl_off_checks
  exit 0
fi
(($# == 5 || $# == 6)) || gl_die 2 "usage: run-agy.sh <prompt-file> <cwd> <effort> <profile> <model> [limit] | --check <cwd>"
gl_prompt "$1"
gl_top "$2"
gl_effort "$3"
[[ $4 == open ]] || gl_die 2 "the profile must be open, got: $4"
case "$5" in neon | carbon) GL_MODEL="gemini-4-$5" ;; *) gl_die 2 "the model must be neon or carbon, got: $5" ;; esac
gl_limit "${6:-4000000}"
gl_env
gl_engine_check
gl_off_checks

gl_root make
gl_begin
DIR=$(mktemp -d -- "${GL_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX") || gl_die 2 "cannot create a run dir under ${GL_ROOT}"
# Created exclusively: the lock is never opened with truncation, here or by a resume.
if ! (set -C && printf 'top=%s\ncommit=%s\ndirty=%s\nmodel=%s\nprofile=open\neffort=%s\nlimit=%s\n' "${GL_TOP}" "${GL_START_HEAD:-unknown}" \
  "${GL_START_DIRTY}" "${GL_MODEL}" "${GL_EFFORT}" "${GL_LIMIT}" > "${DIR}/meta" && : > "${DIR}/lock") || ! exec 9< "${DIR}/lock"; then
  rm -rf -- "${DIR}"
  gl_die 2 "cannot write the run dir ${DIR}"
fi
# Held through the call, so a resume of this dir waits for it.
flock 9 || { rm -rf -- "${DIR}"; gl_die 2 "cannot lock ${DIR}/lock"; }
gl_engine "${DIR}" 1
gl_refusal fresh "${DIR}"
gl_report "${DIR}" 1
