# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Answers: the owner's replies to requests, in the inbox beside them (answers.ts holds the format). put is the viewer's
# one write and needs no seat; take and refuse are the seat's. The ledger lock is never held with another: take files the
# owner's sentences under it first, then runs its span under requests.lock and the seat's takeover lock.
an_dirs_ro() { # the readers' check: creates nothing; a missing inbox holds no answers
  local p; for p in "$ASKS_DIR" "$AN" "$AN/.tmp" "$AN/taken" "$AN/refused"; do
    if [ -L "$p" ] || { [ -e "$p" ] && { [ ! -d "$p" ] || [ ! -O "$p" ]; }; }; then echo "refused: $p must be a directory owned by $(id -un), not a symlink" >&2; return 1; fi; done
}
an_dirs_ok() {
  an_dirs_ro && mkdir -p "$AN/.tmp" "$AN/taken" "$AN/refused" && chmod 700 "$ASKS_DIR" "$AN" "$AN/.tmp" "$AN/taken" "$AN/refused" && an_dirs_ro \
    || { echo "refused: cannot create $AN" >&2; return 1; }
}
an_ready() { # the folders a take writes, each created when missing; one that exists keeps its mode
  rq_dirs_ro && an_dirs_ro && { [ -d "$RQ/closed" ] || rq_dirs_ok; } && { [ -d "$AN/taken" ] && [ -d "$AN/refused" ] && [ -d "$AN/.tmp" ] || an_dirs_ok; }
}
an_names() { # the pending answers' ids, by file name alone: any other name is skipped, so none reaches a reader as text
  an_dirs_ro 2>/dev/null || return 0
  local f b; for f in "$AN"/rq*.json; do b=${f##*/}; [[ $b =~ ^rq[1-9][0-9]{0,8}\.[1-9][0-9]?\.json$ ]] && echo "${b%.json}"; done | LC_ALL=C sort
}
an_added() { LC_ALL=C comm -13 <(printf '%s\n' "$1") <(printf '%s\n' "$2") | grep .; }
an_ts() { ts_run answers "$1" "$WREF" "$RQ" "$AN" "$(gitleaks_path)" "${@:2}"; }
an_put() { # one answer on stdin; every verdict exits 0 on stdout, since the viewer drops stdout on a nonzero exit; 2 could not run
  local l o
  if l=$(lead_below); then echo "refused: this process runs under lead pid $l; only the owner answers" >&2
    jq -nc '{schema: "orchy.answer-put/1", state: "refused", request: null, rev: null, reason: "policy"}'; return 0; fi
  rq_dirs_ro && an_dirs_ok || return 2
  # the screen runs before the lock, which it would hold for a gitleaks run otherwise
  o=$(head -c 16385 | ts_body answers put-check "$WREF" "$RQ" "$AN" "$(gitleaks_path)" "$(utc_now)") || return 2
  jq -e 'has("input")' <<<"$o" >/dev/null || { printf '%s\n' "$o"; return 0; }
  ( flock -w 10 5 || { echo "cannot run: requests.lock is busy for 10 s" >&2; exit 2; }
    an_ts put "$(jq -c .input <<<"$o")" "$(utc_now)" || exit 2 ) 5>>"$RQ/requests.lock"
}
# an_file <aid> <row>, under the ledger lock: the ask id its sentences went to, filing them once by answer id; 3 when the
# row filed earlier holds other sentences, so the file changed since
an_file() {
  local had; had=$(jq -Rnc --arg a "$1" 'first(inputs | fromjson? | select(type == "object" and .answer == $a)) // empty' "$LEDGER") || return 1
  if [ -n "$had" ]; then jq -r '.id // empty' <<<"$had"
    [ "$(jq -r '.said // .text // ""' <<<"$had")" = "$(jq -r '.said // .text // ""' <<<"${2:-null}")" ] || return 3; return 0; fi
  [ -n "$2" ] || return 0
  ledger_append "$2" && jq -r '.id // empty' <<<"$2"
}
an_take() { # an_take <aid> [<reason>]: take it, or with a reason refuse it
  local s row ask rc fx=${2:-}
  s=$(an_ts screen "$1" "$LEDGER" "$(utc_now)"); rc=$?; [ $rc = 0 ] || return $rc
  row=$(jq -c '.row // empty' <<<"$s")
  ask=$(with_ledger an_file "$1" "$row"); rc=$?
  case $rc in 0) ;; 3) echo "warning: $1 changed after its sentences were filed, so it is refused" >&2; fx=${fx:-invalid};; *) return 2;; esac
  RQ_BUSY=2 rq_locked an_ts take "$1" "$(jq -r .sha <<<"$s")" "$(jq -r 'if .flagged then 1 else 0 end' <<<"$s")" "$ask" "$([ -n "${2:-}" ] && echo refuse || echo take)" "$fx" "$(utc_now)"
}
orchy_answer() {
  sub=${1:-}; shift || true
  local use="usage: answer put (stdin: one answer) | list [--json] [--all] | show <aid> | take <aid> | refuse <aid> <stale|closed|invalid|policy|withdrawn>"
  case "$sub" in
  put) [ $# = 0 ] || { echo "$use" >&2; exit 1; }; need flock; an_put; exit;;
  list) rq_dirs_ro && an_dirs_ro || exit 1
    all=0; js=0; for o in "$@"; do case "$o" in --all) all=1;; --json) js=1;; *) echo "$use" >&2; exit 1;; esac; done
    an_ts list "$all" "$js" "$(utc_now)"; exit;;
  show|take|refuse) [[ "${1:-}" =~ ^rq[1-9][0-9]{0,8}\.[1-9][0-9]?$ ]] || { echo "$use" >&2; exit 1; };;
  *) echo "$use" >&2; exit 1;;
  esac
  case "$sub" in
  show) [ $# = 1 ] || { echo "$use" >&2; exit 1; }; rq_dirs_ro && an_dirs_ro || exit 1; an_ts show "$1" "$(utc_now)"; exit;;
  take) [ $# = 1 ] || { echo "$use" >&2; exit 1; };;
  refuse) [ $# = 2 ] && [[ $2 =~ ^(stale|closed|invalid|policy|withdrawn)$ ]] || { echo "$use" >&2; exit 1; };;
  esac
  need flock
  l=$(lead_below) && { echo "refused: this process runs under lead pid $l; only the orchestrator takes answers" >&2; exit 1; }
  seat_held && an_ready && ledger_ok || exit 1
  an_take "$1" "${2:-}"
}
