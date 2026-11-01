#!/usr/bin/env bash
# orchy: the backlog-program orchestrator's shell half. One entry point, subcommands below; each concern's code is a file
# in orchy/ beside this one, found through the script's real path, so a symlinked skill dir and a worktree both work.
# State lives in $ORCHY_HOME (default ~/.cache/orchy/<owner>-<repo>): orchy.json (policy), local.json (ban, load_max),
# briefs, prompts, reports, leads, watch, wt, page. Nothing in the repo. Which accounts leads run on is one machine-wide
# policy for every program: ~/.agents/orchy/accounts.json (ORCHY_ACCOUNTS).
set -u
usage() { sed -n '/^# Subcommands/,/^# End/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
# Subcommands
#   home                         print ORCHY_HOME
#   config <jq-expr>             read $ORCHY_HOME/orchy.json ('.trunk', '.merge.required_checks[]')
#   local <jq-expr>              read $ORCHY_HOME/local.json (prompt_ban, load_max, session_url)
#   lock | unlock                claim this repo's orchestrator seat (refuses while another session holds it)
#   render [--keep K,...] <template> K=V ...   substitute <K> tokens to stdout; exit 1 on a token left over that --keep does not name
#   check-text <file>...         refuse a file carrying a banned string (local.json prompt_ban, and every claude-usage roster name)
#   check-private <file>...      refuse a file that copies six consecutive words of the owner's verbatim words in the ask ledger
#   check-public [--no-sensitive] <file>   check-private, then the leak and sensitive patterns and gitleaks; any check error refuses
#   ask add <text>               capture the owner's words verbatim; prints the new id (askN)
#   ask public <id> <text>       the restatement every handoff carries; ask said <id> <text>: the owner's later words, verbatim
#   ask lane <id> <slug> <route> | done|drop|reopen <id> <note> | note <id> <text>   route or move an ask
#   ask list [--all] [--json] | show <id>   one line per open or laned ask (every ask with --all; orchy.asks/1 with --json); one ask's fold and history
#   ask file <id> <title> <body-file>   file an ask as a GitHub issue: check, dedupe, create and record under one lock
#   ask go <id> -- <words>       the owner's go for the release or hotfix the ask is laned to: each act of that lane, once
#   ask ok <id> <act> -- <words> | grant <id> <scope> -- <words>   the owner's OK for one act; a standing grant (one scope in v1:
#                                merge dependabot <trunk> <method>); the words are the owner's, verbatim, and stay in the ledger
#   ask revoke <id> [<act>|<scope>]   end a go (bare), an OK or a grant
#   ask goal <id> <name> [by|on <YYYY-MM-DD>] [then release]   make an open ask a goal: milestone <name>, created with its
#                                title only, and the ask held as 'waiting: goal <name>'; the date stays in the ledger
#   goals [--json]               each goal: its ask, state, milestone counts, runbook goal-<name>, days left and whether it is
#                                ready (orchy.goals/1 with --json)
#   grants [--json]              the live standing grants (orchy.grants/1 with --json)
#   act <act> (--lane <slug> | --ok <id> | --grant) [--check] | --check   an irreversible act on an authority; --check runs
#                                its checks, and the authority's when one is named, and calls nothing; acts are
#                                merge <pr> <sha> <base> <method>, approve <run> <attempt> <env>, dispatch <workflow> <ref> <sha>
#                                [<input>=<value>...], tag <name> <sha>; a merge arms watch-merge --act, the others call at once
#   ask close-lane <slug>        after teardown: each ask laned there is done (delivered, with its PR) or reopened, from the reports' ASKS: lines
#   waiting add <ref> <text> | done <ref> | list [--json]   what waits on the owner, one item per ref (pr:N issue:N page:N
#                                ask:askN lane:<slug> other:<slug>); add replaces the text and keeps since; orchy.waiting/1 with --json
#   request add <ref> <spec-file> [--again]   a question that waits on the owner, from a JSON spec (references/requests.md);
#                                created, refreshed (rev+1 when its content changed) or unchanged; it owns the ref's waiting row
#   request note <rid> [--re <aid>] <text> | stale <rid> <reason> | done <rid> <outcome> | withdraw <rid> <reason>
#                                a note in its thread, or a move; done and withdraw close it into closed/
#   request list [--json] [--all] | show <rid>   the open requests (every one with --all; orchy.requests/1 with --json); one request
#   hold add <ref> <all|trunk> | done <ref> | list [--json]   pause the program for a peer or a release freeze, one hold per
#                                waiting ref: all refuses worktrees, leads and acts and holds every merge; trunk holds trunk merges
#   runbook add <slug> <file> | tick <slug> <n> | check <slug> | show <slug>   the owner's own steps for a release or a goal, one
#                                per line ('- [ ] <step>', ending ' (proof: run <id>)' or ' (proof: release <tag>)' or not), kept
#                                as the record waiting other:<slug>; add appends; check ticks a step whose run succeeded or
#                                whose release is published
#   wt-new <slug>... [--base <branch>]   create worktrees from origin/<trunk>, or a merge.branches base, and install deps;
#                                sequential; refuses an existing slug; teardown proves each against its base
#   launch [--light] <key> <slug> <account|auto>       start a headless lead on prompts/<key>.md inside the lane worktree; only the
#                                seat holder launches, on an account the policy allows (auto: the one whose headroom expires soonest)
#   resume [--light] <key> <slug> <account> <session>  resume a lead's session with prompts/<key>.md, on that session's account
#                                (both take --force-cap, on the owner's word only: it passes the caps and the heavy floor)
#   accounts [--json]            per roster account: week and session left, the weekly reset, and heavy, light or no with the
#                                reason (orchy.headroom/1 with --json); the account this shell's session runs on is marked
#   stop <key>                   end a live lead and every process it started
#   say <key> <text>             queue a steering note; a live lead gets it after its next tool call (inbox-hook.sh)
#   session-id <key>             the session id of a lead's latest run
#   snapshot                     the tick's facts: reports, leads, watchers, PRs, worktrees, load, headroom
#   state [--json]               a poller's view as orchy.state/1 JSON: local facts only, no gh, usage or network call, nothing written
#   wait [seconds]               block until a report, lead or watcher changes, or (every wait.poll_sec, default 120) open PRs, open issues or the trunk head (default 1500)
#   scan <pr> [<full-sha>] [--quick]   gate-weakening and leak scan of a PR's diff, title, body and commit messages (plus the
#                                local ban), the content read at that sha (default: the head now); SCAN FAILED unless it is the head
#                                before and after; --quick exits 3 past a quick lane's bounds
#   watch-merge <pr> <full-sha> <lane> <report> [archive-name|-]   merge a lane PR on the standing policy, then tear the lane
#                                down (archive -: no plan to wait for and no teardown); act merge arms it with --act instead
#   arm-merge  <pr> <full-sha> <lane> <report-name> [archive-name|-] [delay-s]   watch-merge detached (nohup, .out + .pid)
#   disarm [<pr>]                stop one merge watcher, or every one
#   receipt [--json] [--offline] [<lane>]   per lane: API-equivalent dollars, tokens, wall-clock, PRs merged, issues closed, failed arcs,
#                                Codex rounds; --json prints orchy.receipt/1 with per-run costs, --offline skips the gh joins
#   teardown <slug>              remove a lane worktree whose HEAD is exactly a merged PR's head and whose tree is clean
# End
need() { command -v "$1" >/dev/null 2>&1 || { echo "orchy: $1 not found" >&2; exit 1; }; }
need jq; need git
ROOT=${ORCHY_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}
[ -n "$ROOT" ] || { echo "orchy: not inside a git repository (or set ORCHY_ROOT)" >&2; exit 1; }
origin=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
REPO=${ORCHY_REPO:-$(printf '%s' "$origin" | sed -E 's#^(git@|ssh://git@|https?://)[^/:]+[:/]##; s#\.git$##')}
[ -n "$REPO" ] || { echo "orchy: no origin remote; set ORCHY_REPO=owner/name" >&2; exit 1; }
slug=$(echo "$REPO" | tr '/' '-')
# Every program's home sits under one capacity root, so a launch can count all programs' leads under one lock.
# Lexical normalization only: with a trailing slash, -L would look through a symlinked home to its target.
CAP=$(realpath -sm "${ORCHY_CAPACITY_ROOT:-$HOME/.cache/orchy}")
ORCHY_HOME=$(realpath -sm "${ORCHY_HOME:-$CAP/$slug}")
H="$ORCHY_HOME"; CFG="$H/orchy.json"; LOCAL="$H/local.json"
# The owner's verbatim words live outside $H, where leads write their reports and would find them.
ASKS_DIR=$(realpath -sm "${ORCHY_ASKS_DIR:-$HOME/.agents/orchy/asks}")
# shellcheck disable=SC2034  # read by the sourced parts
LEDGER="$ASKS_DIR/$slug.jsonl"
SCRIPTS=$(dirname "$(realpath "$0")")
cmd=${1:-help}; shift || true
case "$cmd" in help|-h|--help) usage 0;; home) echo "$H"; exit 0;; esac
[ -f "$CFG" ] || { echo "orchy: no $CFG (run /start-orchy in the repo first)" >&2; exit 1; }
cfg() { jq -r "$1" "$CFG"; }
lcl() { [ -f "$LOCAL" ] && jq -r "$1" "$LOCAL" || echo ""; }
# shellcheck disable=SC2034  # read by the sourced parts
TRUNK=$(cfg '.trunk // "main"')
case "$cmd" in wt-new|launch|resume|arm-merge|watch-merge|act)
  [ "$(cfg '.mode // empty')" = triage ] && { echo "refused: orchy.json mode is triage (labels, comments and pages only; no worktree, lead or merge)" >&2; exit 1; };; esac
# A lead runs the hook its settings file names, so nobody but the owner may write here. chmod tightens a fresh or loose
# home (a umask would also reach wt-new's product checkout), but cannot undo what another user planted while it was loose.
under=0; ds=("$H"); [ "$(dirname "$H")" = "$CAP" ] && under=1 && ds+=("$CAP")
for d in "${ds[@]}"; do [ ! -L "$d" ] && [ -O "$d" ] || { echo "orchy: $d must be a directory owned by $(id -un), not a symlink" >&2; exit 1; }; done
f=$({ find "$H" -maxdepth 2 ! -user "$EUID"; [ $under = 0 ] || find "$CAP" -maxdepth 1 ! -user "$EUID"; } 2>/dev/null | head -1)
[ -z "$f" ] || { echo "orchy: $f belongs to another user; refusing a home someone else could write" >&2; exit 1; }
# Readers keep the ownership checks but create nothing, so a poller never changes the home it reads.
ro=0; case "$cmd" in state|config|local|session-id|receipt|accounts|grants|goals) ro=1;; ask) case "${1:-}" in list|show) ro=1;; esac;; waiting|hold) case "${1:-}" in list) ro=1;; esac;; request) case "${1:-}" in list|show) ro=1;; esac;; runbook) case "${1:-}" in show) ro=1;; esac;; esac
if [ $ro = 0 ]; then
  mkdir -p "$H"/{briefs,prompts,reports,leads,watch,wt,scratch,inbox,page/shots,page/build}
  chmod 700 "$H"; [ $under = 1 ] && chmod 700 "$CAP"
fi
# The parts define functions and globals only, and every subcommand, a reader too, sources each of them in this order.
# Named, never globbed, so a stray file in orchy/ never runs.
parts=(
  accounts
  acts
  asks
  authority
  goals
  holds
  leads
  ledger
  merges
  plumbing
  receipts
  requests
  runbooks
  seat
  status
  text
  waiting
)
for part in "${parts[@]}"; do [ -r "$SCRIPTS/orchy/$part.sh" ] || { echo "orchy: cannot read $SCRIPTS/orchy/$part.sh" >&2; exit 1; }; done
for part in "${parts[@]}"; do
  # shellcheck source=/dev/null
  . "$SCRIPTS/orchy/$part.sh"
done
case "$cmd" in
config) cfg "$1";;
local) lcl "$1";;
lock) orchy_lock;;
unlock) orchy_unlock;;
render) orchy_render "$@";;
check-text) orchy_check_text "$@";;
check-private) orchy_check_private "$@";;
check-public) orchy_check_public "$@";;
ask) orchy_ask "$@";;
goals) orchy_goals "$@";;
grants) orchy_grants "$@";;
waiting) orchy_waiting "$@";;
hold) orchy_hold "$@";;
request) orchy_request "$@";;
runbook) orchy_runbook "$@";;
wt-new) orchy_wt_new "$@";;
launch|resume) orchy_launch "$cmd" "$@";;
stop) orchy_stop "$@";;
say) orchy_say "$@";;
session-id) orchy_session_id "$@";;
snapshot) orchy_snapshot;;
accounts) orchy_accounts "$@";;
state) orchy_state;;
wait) orchy_wait "$@";;
scan) orchy_scan "$@";;
watch-merge) orchy_watch_merge "$@";;
arm-merge) orchy_arm_merge "$@";;
act) orchy_act "$@";;
disarm) orchy_disarm "$@";;
teardown) orchy_teardown "$@";;
receipt) orchy_receipt "$@";;
*) echo "orchy: unknown subcommand $cmd" >&2; usage 1;;
esac
