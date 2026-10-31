# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# The owner's authority for an irreversible act: the act and scope grammar, and the go, OK and grant read from raw
# ledger rows, spent once under the ledger lock.
act_norm() { # act_norm <kind> <field>...: the act's one text, which OK, used and revoke rows name; a refusal on stderr
  local k=${1:-} i names=(); shift || true
  case "$k" in
  merge) [ $# = 4 ] && [[ "$1" =~ ^[1-9][0-9]{0,8}$ ]] && sha_ok "$2" && ref_ok "$3" && [[ "$4" =~ ^(merge|squash|rebase)$ ]] \
    || { echo "refused: merge <pr> <sha40> <base> <merge|squash|rebase>" >&2; return 1; };;
  approve) [ $# = 3 ] && [[ "$1" =~ ^[1-9][0-9]{0,19}$ && "$2" =~ ^[1-9][0-9]{0,3}$ && "$3" =~ ^[A-Za-z0-9._-]{1,100}$ ]] \
    || { echo "refused: approve <run-id> <attempt> <environment>" >&2; return 1; };;
  dispatch) [ $# -ge 3 ] && [[ "$1" =~ ^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$ ]] && ref_ok "$2" && sha_ok "$3" \
    || { echo "refused: dispatch <.github/workflows/name.yml> <ref> <sha40> [<input>=<value>...]" >&2; return 1; }
    for i in "${@:4}"; do [[ "$i" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,63}=[A-Za-z0-9._+:/-]{0,128}$ ]] || { echo "refused: an input is <name>=<value>" >&2; return 1; }; names+=("${i%%=*}"); done
    [ ${#names[@]} = 0 ] || printf '%s\n' "${names[@]}" | LC_ALL=C sort -cu 2>/dev/null || { echo "refused: inputs are sorted by name, each named once" >&2; return 1; };;
  tag) [ $# = 2 ] && ref_ok "$1" && sha_ok "$2" || { echo "refused: tag <name> <sha40>" >&2; return 1; };;
  *) echo "refused: an act is merge, approve, dispatch or tag" >&2; return 1;;
  esac; echo "$k $*"
}
scope_norm() { [ $# = 4 ] && [ "$1 $2" = "merge dependabot" ] && ref_ok "$3" && [[ "$4" =~ ^(merge|squash|rebase)$ ]] \
  || { echo "refused: the one scope is merge dependabot <trunk> <method>" >&2; return 1; }; echo "$*"; }
act_scope() { local a; read -ra a <<<"$1"; [ "${a[0]}" = merge ] && echo "merge dependabot ${a[3]} ${a[4]}"; }   # the grant a merge act falls under
# Authority is read from raw rows in ledger order, never from the fold, which keeps `said` and `note` apart: a row counts
# only when it carries the owner's words itself. Approval coverage ignores the attempt: another attempt needs a per-act OK.
LIVE_JQ='
def mine($id): map(select(.id == $id));
def state_of: [.[] | select((.state | type) == "string")] | last;
def akey: if startswith("approve ") then (split(" ") | del(.[2]) | join(" ")) else . end;
def go_live($lane): to_entries as $e
  | ([$e[] | select(.value.note == "go" or .value.note == "revoke:")] | last) as $g
  | $g != null and $g.value.note == "go" and ($g.value.said | type) == "string"
    and ([$e[] | select(.key > $g.key and (.value.state | type) == "string")] | length == 0 or (length == 1 and .[0].value.state == "lane"))
    and (state_of | . != null and .state == "lane" and .lane == $lane);
def go_covers($x): ($x | akey) as $k | all(.[]; (.note // "") | (startswith("used: ") and (ltrimstr("used: ") | akey) == $k) | not);
def ok_live($x): (state_of | . != null and (.state == "open" or .state == "lane"))
  and ([.[] | select(.note == "ok: \($x)" or .note == "revoke: \($x)" or .note == "used: \($x)")] | last | . != null and .note == "ok: \($x)" and (.said | type) == "string");
def grant_live($s): [.[] | select(.note == "grant: \($s)" or .note == "revoke: \($s)")] | last | . != null and .note == "grant: \($s)" and (.said | type) == "string";
def ok_spent($x): (state_of | . != null and (.state == "open" or .state == "lane"))
  and ([.[] | select(.note == "ok: \($x)" or .note == "revoke: \($x)" or .note == "used: \($x)")] | last | . != null and .note == "used: \($x)");
def unmoved($u; f): to_entries | ([.[] | select(.value | f)] | last | .key // -1) < ([.[] | select(.value.note == $u)] | last | .key // -1);
def unused($x): all(.[]; (.note // "") as $n | ($n == "used: \($x)" or ($n | startswith("used: \($x) under "))) | not);
def live_grants: . as $all | [.[] | select((.note // "") | startswith("grant: ")) | {scope: (.note | ltrimstr("grant: ")), ask: .id, since: .at}]
  | group_by([.ask, .scope]) | map(last) | map(select(. as $g | $all | mine($g.ask) | grant_live($g.scope)));
'
lane_go() { # lane_go <slug>: the one ask laned there with a live go
  local ids; ids=$(ledger_rows | jq -r --arg l "$1" "$LIVE_JQ"'. as $all | [.[].id] | unique[] | . as $id | select($all | mine($id) | go_live($l))') || return 1
  case $(grep -c . <<<"$ids") in
    1) echo "$ids";; 0) echo "refused: no ask laned to $1 has a live go" >&2; return 1;;
    *) echo "refused: $(paste -sd' ' <<<"$ids") each have a live go on $1; revoke all but one" >&2; return 1;; esac; }
grant_ask() { ledger_rows | jq -er --arg s "$1" "$LIVE_JQ"'live_grants | map(select(.scope == $s)) | first | .ask' 2>/dev/null \
  || { echo "refused: no live grant for $1" >&2; return 1; }; }
authorized() { # authorized go|ok|grant <ask> <act> [<lane>]: the authority is live now and covers the act
  local r; r=$(ledger_rows) || return 1
  case $1 in
  go) jq -e --arg id "$2" --arg x "$3" --arg l "${4:-}" "$LIVE_JQ"'mine($id) | go_live($l) and go_covers($x)' <<<"$r" >/dev/null;;
  ok) jq -e --arg id "$2" --arg x "$3" "$LIVE_JQ"'mine($id) | ok_live($x)' <<<"$r" >/dev/null;;
  grant) jq -e --arg id "$2" --arg x "$3" --arg s "$(act_scope "$3")" "$LIVE_JQ"'unused($x) and (mine($id) | grant_live($s))' <<<"$r" >/dev/null;;
  *) return 1;; esac; }
unrevoked() { # unrevoked go|ok|grant <ask> <act> [<lane>]: the authority that spent the act is live, and no revoke or replacement followed its claim
  local r; r=$(ledger_rows) || return 1
  case $1 in
  go) jq -e --arg id "$2" --arg x "$3" --arg l "${4:-}" "$LIVE_JQ"'mine($id) | go_live($l) and unmoved("used: \($x)"; .note == "go" or .note == "revoke:")' <<<"$r" >/dev/null;;
  ok) jq -e --arg id "$2" --arg x "$3" "$LIVE_JQ"'mine($id) | ok_spent($x)' <<<"$r" >/dev/null;;
  grant) jq -e --arg id "$2" --arg x "$3" --arg s "$(act_scope "$3")" "$LIVE_JQ"'mine($id) | grant_live($s)
    and unmoved("used: \($x) under \($s)"; .note == "grant: \($s)" or .note == "revoke: \($s)")' <<<"$r" >/dev/null;;
  *) return 1;; esac; }
claim() { # claim go|ok|grant <ask> <act> [<lane>]: the authority read again and its used: row written under one ledger lock, so racing claims leave one
  local k=$1 id=$2 x=$3 l=${4:-} n="used: $3"; [ "$k" = grant ] && n="used: $3 under $(act_scope "$3")"
  need flock; ledger_ok || return 1
  claim_in() { authorized "$k" "$id" "$x" "$l" || { echo "refused: $x is not authorized by $k $id" >&2; return 1; }
    ledger_append "$(jq -nc --arg id "$id" --arg at "$(utc_now)" --arg n "$n" '{id: $id, at: $at, note: $n}')"; }
  with_ledger claim_in; }
ask_cmd_auth() { # ask_cmd_auth go|ok|grant <askN> <field>... -- <the owner's words>
  local sub=$1 id=$2; shift 2
  x=(); w=(); seen=0; for t in "$@"; do if [ $seen = 1 ]; then w+=("$t"); elif [ "$t" = -- ]; then seen=1; else x+=("$t"); fi; done
  words="${w[*]}"; [ $seen = 1 ] && [ -n "$words" ] || { echo "refused: the owner's words follow -- (ask $sub <askN>$([ "$sub" = go ] || echo " <$([ "$sub" = ok ] && echo act || echo scope)>") -- <words>)" >&2; exit 1; }
  case $sub in
    go) [ ${#x[@]} = 0 ] || { echo "usage: ask go <askN> -- <words>" >&2; exit 1; }; n=go;;
    ok) xt=$(act_norm "${x[@]}") || exit 1; n="ok: $xt";;
    grant) xt=$(scope_norm "${x[@]}") || exit 1
      [ "${x[2]}" = "$TRUNK" ] || { echo "refused: a grant covers Dependabot's PRs into the trunk, $TRUNK" >&2; exit 1; }; n="grant: $xt";;
  esac
  ask_auth() { local a st w; a=$(ask_get "$id"); [ -n "$a" ] || { echo "refused: no $id" >&2; return 1; }
    st=$(jq -r .state <<<"$a")
    case "$sub/$st" in go/lane | ok/open | ok/lane | grant/open | grant/lane) ;;
      go/open) jq -e 'any(.notes[]; startswith("goal:"))' <<<"$a" >/dev/null || { echo "refused: a go needs a laned ask or a goal; $id is open" >&2; return 1; };;
      *) echo "refused: $id is $st; $sub does not apply" >&2; return 1;; esac
    w=$(jq -r "$ASK_HOLD" <<<"$a")
    case "$w" in "waiting: wording"*) echo "refused: $id is $w; settle its wording first" >&2; return 1;; esac
    ledger_append "$(ask_row --arg s "$words" --arg n "$n" '{id: $id, at: $at, said: $s, note: $n}')" || return 1
    # the go or OK answers the question the ask waited on; a goal waits for its work, and a grant answers nothing
    case "$sub/$w" in */ | grant/* | */"waiting: goal"*) ;; *) ledger_append "$(ask_row --arg t "answered: $sub" '{id: $id, at: $at, note: $t}')" || return 1;; esac
    echo "$id $n recorded"; }
  with_ledger ask_auth
}
ask_cmd_revoke() { # ask_cmd_revoke <askN> [<act>|<scope>]
  local id=$1; shift
  # only removes authority, so it checks the grammar and that the ask exists, whatever its state
  n="revoke:"; if [ $# -gt 0 ]; then xt=$(act_norm "$@" 2>/dev/null || scope_norm "$@" 2>/dev/null) || { echo "refused: revoke takes nothing (a go), an act or a scope" >&2; exit 1; }; n="revoke: $xt"; fi
  ask_rev() { [ -n "$(ask_get "$id")" ] || { echo "refused: no $id" >&2; return 1; }
    ledger_append "$(ask_row --arg n "$n" '{id: $id, at: $at, note: $n}')" && echo "$id $n recorded"; }
  with_ledger ask_rev
}
orchy_grants() {
  ledger_ro || exit 1
  g=$(ledger_rows | jq -c "$LIVE_JQ"'{schema: "orchy.grants/1", grants: live_grants}') || exit 1
  if [ "${1:-}" = --json ]; then echo "$g"; else jq -r 'if .grants == [] then "no standing grants" else .grants[] | "\(.scope)  \(.ask)  since \(.since)" end' <<<"$g"; fi
}
