# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Irreversible acts (a merge into a release branch, an approval, a dispatch, a tag), each on a live authority.
base_req() { # base_req <base> [<method>]: {methods, req, base} for the trunk or a merge.branches base; else the reason, exit 1
  local j; j=$(jq -c --arg b "$1" --arg t "$TRUNK" 'if $b == $t then {methods: (.merge.trunk_methods // [.merge.method // "squash"]),
      req: (.merge.required_checks // []), base: (.merge.trunk_checks // .merge.required_checks // [])}
    elif (.merge.branches[$b] | type) == "object" then .merge.branches[$b] | {methods: [.method], req: (.required_checks // []), base: (.base_checks // .required_checks // [])}
    else null end' "$CFG") || { echo "orchy.json cannot be read"; return 1; }
  [ "$j" != null ] || { echo "$1 is neither the trunk nor a merge.branches base"; return 1; }
  [ -z "${2:-}" ] || jq -e --arg m "$2" '.methods | index($m)' <<<"$j" >/dev/null || { echo "$1 takes $(jq -r '.methods | join(" or ")' <<<"$j"), not $2"; return 1; }
  jq -e '.req | length > 0' <<<"$j" >/dev/null || { echo "$1 has no required check"; return 1; }
  echo "$j"; }
go_shape() { # go_shape <head-ref> <author-is-bot> <author> <base> <lane>: one of the four shapes a go merges
  local rel th tb sh; rel=$(cfg '.release.branch.name // empty'); th=$(cfg '.release.tool.head // empty'); tb=$(cfg '.release.tool.bot // empty'); sh=$(cfg '.release.sync.head // empty')
  { [ "$1" = "$TRUNK" ] && [ -n "$rel" ] && [ "$4" = "$rel" ]; } || { [ -n "$th" ] && [ -n "$tb" ] && [ "$1" = "$th" ] && [ "$3" = "$tb" ]; } \
    || { [ -n "$sh" ] && [ "$4" = "$TRUNK" ] && [ "$1" = "$sh" ]; } || { [ "$2" = false ] && { [ "$1" = "worktree-$5" ] || [[ "$1" == "$5"-* ]]; }; }; }
grant_pr_ok() { # grant_pr_ok <pr>: Dependabot's own PR, on its own branch in this repository, every commit Dependabot's
  local j; j=$(gh pr view "$1" --repo "$REPO" --json author,headRefName,isCrossRepository,commits 2>/dev/null) || return 1
  jq -e '.author.login == "app/dependabot" and .author.is_bot == true and .isCrossRepository == false and (.headRefName | startswith("dependabot/"))
    and (.commits | length > 0) and all(.commits[]; (.authors | length > 0) and all(.authors[]; .login == "dependabot[bot]"))' <<<"$j" >/dev/null; }
reach() { # reach <sha>: the commit is on the trunk or a merge.branches base
  local b bases; mapfile -t bases < <(cfg '(.merge.branches // {}) | keys[]')
  for b in "$TRUNK" "${bases[@]}"; do case $(gh api "repos/$REPO/compare/$1...$b" --jq .status 2>/dev/null) in ahead|identical) return 0;; esac; done; return 1; }
tag_state() { # yes, no, or nothing when unreadable
  local e; e=$(mktemp "$H/scratch/tag.XXXXXX") || return 0
  if gh api "repos/$REPO/git/ref/tags/$1" >/dev/null 2>"$e"; then echo yes; elif grep -q 'HTTP 404' "$e"; then echo no; fi; rm -f "$e"; }
orchy_act() {
  need gh; need timeout; how=""; who=""; chk=""; aw=()
  while [ $# -gt 0 ]; do case "$1" in
    --lane|--ok) [ -z "$how" ] && [ $# -ge 2 ] || act_usage; how=${1#--}; who=$2; shift 2;;
    --grant) [ -z "$how" ] || act_usage; how=grant; shift;;
    --check) [ -z "$chk" ] || act_usage; chk=1; shift;;
    *) aw+=("$1"); shift;; esac; done
  [ -n "$how" ] || { [ -n "$chk" ] || act_usage; how=check; }
  X=$(act_norm "${aw[@]}") || exit 1; read -ra af <<<"$X"; kind=${af[0]}; ask=""; auth=""; lbl=""; lane=-
  case $how in
    lane) name_ok "$who" || act_refuse "the lane must be a slug"; lane=$who; ask=$(lane_go "$who") || exit 1; auth=go; lbl=go
      authorized go "$ask" "$X" "$who" || act_refuse "the go on $ask has run $X once; a retry needs a per-act OK";;
    ok) [[ "$who" =~ ^ask[0-9]+$ ]] || act_usage; ask=$who; auth=ok; lbl=OK; authorized ok "$ask" "$X" || act_refuse "no live OK on $ask for $X";;
    grant) [ "$kind" = merge ] || act_refuse "the one standing grant covers Dependabot merges"
      ask=$(grant_ask "$(act_scope "$X")") || exit 1; auth=grant; lbl=grant
      authorized grant "$ask" "$X" || act_refuse "$X was spent once, and a grant never covers it again";;
  esac
  case $kind in merge) act_merge;; approve) act_approve;; dispatch) act_dispatch;; tag) act_tag;; esac
}
act_usage() { echo "usage: act <merge|approve|dispatch|tag> <field>... (--lane <slug> | --ok <askN> | --grant) [--check] | --check" >&2; exit 1; }
act_refuse() { echo "refused: $*" >&2; exit 1; }
act_call() { # act_call <api-path> <json-body>: the hold check, the claim and one POST; only an HTTP 4xx is a refusal, never retried
  local of ef rc; of=$(mktemp "$H/scratch/act.XXXXXX") && ef=$(mktemp "$H/scratch/act.XXXXXX") || act_refuse "cannot write $H/scratch"
  # holds.lock shared spans the check and the call, which runs without the descriptor: a hold added meanwhile waits for it
  ( flock -s -w 300 7 || { echo "refused: holds.lock is busy for 300 s" >&2; exit 1; }
    hold_guard; claim "$auth" "$ask" "$X" "$lane" || exit 1
    timeout 120 gh api "$1" -X POST --input - <<<"$2" >"$of" 2>"$ef" 7>&-; rc=$?; m=$(tail -n 1 "$ef" | cut -c1-160)
    [ "$rc" = 0 ] && exit 0
    [ "$rc" != 124 ] && grep -qE 'HTTP 4[0-9]{2}([^0-9]|$)' "$ef" && { echo "refused: GitHub refused $X ($m); it is spent" >&2; exit 1; }
    echo "AMBIGUOUS: $X may have happened${m:+ ($m)}; it is spent; check by hand, never retry"; exit 6 ) 7>>"$HOLDS_LOCK"
  rc=$?; CALL_OUT=$(cat "$of"); rm -f "$of" "$ef"; [ "$rc" = 0 ] || exit "$rc"; }
act_merge() {
  N=${af[1]}; sha=${af[2]}; base=${af[3]}; m=${af[4]}
  rj=$(base_req "$base" "$m") || act_refuse "$rj"
  pj=$(gh pr view "$N" --repo "$REPO" --json state,isDraft,baseRefName,headRefOid,headRefName,isCrossRepository,author) || act_refuse "cannot read #$N"
  IFS=$'\t' read -r st dr pb ph hr fk bt al <<<"$(jq -r '[.state, .isDraft, .baseRefName, .headRefOid, .headRefName, .isCrossRepository, .author.is_bot, .author.login] | @tsv' <<<"$pj")"
  [ "$st" = OPEN ] && [ "$dr" = false ] || act_refuse "#$N is $st$([ "$dr" = true ] && echo ", a draft")"
  [ "$pb" = "$base" ] || act_refuse "#$N targets $pb, not $base"
  [ "$ph" = "$sha" ] || act_refuse "#$N's head is $ph, not $sha"
  if [ "$fk" = true ]; then [ "$base" = "$TRUNK" ] || act_refuse "#$N comes from a fork, and a fork never merges into $base"
    [ "$how" = ok ] || [ "$how" = check ] || act_refuse "#$N comes from a fork; it merges only on a per-act OK"; fi
  case $how in
  lane) go_shape "$hr" "$bt" "$al" "$base" "$who" \
    || act_refuse "#$N is none of the shapes a go merges (the promote, the release tool's PR, the lane's own PR, the back-sync); it needs a per-act OK";;
  grant) [ "$base" = "$TRUNK" ] && grant_pr_ok "$N" || act_refuse "#$N is not Dependabot's own PR into $TRUNK with every commit Dependabot's";;
  esac
  [ -z "$chk" ] || { echo "checked: $X${lbl:+ ($lbl $ask)}"; exit 0; }
  arm_watch 0 "$N" "$sha" --act "$base" "$m" "$auth" "$ask" "$lane" || exit 1
  echo "armed merge-$N ($lbl $ask)"
}
act_approve() {
  run=${af[1]}; att=${af[2]}; env=${af[3]}
  rj=$(gh api "repos/$REPO/actions/runs/$run") || act_refuse "cannot read run $run"
  IFS=$'\t' read -r rst ratt rev rhead rbr rwf <<<"$(jq -r '[.status, .run_attempt, .event, .head_sha, .head_branch, .path] | @tsv' <<<"$rj")"
  [ "$rst" = waiting ] || act_refuse "run $run is $rst, not waiting"
  [ "$ratt" = "$att" ] || act_refuse "run $run is at attempt $ratt, not $att"
  case $rev in push|workflow_dispatch|release|schedule) ;; *) act_refuse "run $run came from $rev, which carries other code's context";; esac
  pd=$(gh api "repos/$REPO/actions/runs/$run/pending_deployments") || act_refuse "cannot read run $run's pending deployments"
  eid=$(jq -r --arg e "$env" '[.[] | select(.environment.name == $e and .current_user_can_approve == true) | .environment.id] | first // empty' <<<"$pd")
  [[ "$eid" =~ ^[1-9][0-9]*$ ]] || act_refuse "$env is not waiting on this login's approval in run $run"
  reach "$rhead" || act_refuse "run $run's head ${rhead:0:8} is on neither the trunk nor a merge.branches base"
  if [ "$how" = lane ]; then
    # a go approves only a run this go produced: started after one of its merges or dispatches claimed (60 s for clock skew),
    # at that merge's commit, or that dispatch's sha and workflow; a run already waiting is the owner's
    rc0=$(jq -r '.created_at // empty | fromdateiso8601? // empty' <<<"$rj"); [[ "$rc0" =~ ^[0-9]+$ ]] || act_refuse "run $run has no readable start time"
    p=no; while IFS=$'\t' read -r at k a1 _ a3; do [ "$rc0" -ge $((at - 60)) ] || continue; case $k in
      merge) [ "$(gh pr view "$a1" --repo "$REPO" --json mergeCommit --jq '.mergeCommit.oid // empty' 2>/dev/null)" = "$rhead" ] && p=yes;;
      dispatch) [ "$a3" = "$rhead" ] && [ "$a1" = "$rwf" ] && [ "$rev" = workflow_dispatch ] && p=yes;; esac
    done < <(ledger_rows | jq -r --arg id "$ask" 'map(select(.id == $id)) | (map(.note == "go") | rindex(true) // -1) as $g | .[$g + 1:][]
      | select((.note // "") | test("^used: (merge|dispatch) ")) | [(.at | fromdateiso8601), (.note | ltrimstr("used: ") | split(" ") | .[0:4][])] | @tsv' 2>/dev/null)
    [ "$p" = yes ] || act_refuse "run $run is no run this go produced; it needs a per-act OK"; fi
  [ -z "$chk" ] || { hold_guard; echo "checked: $X ($rwf, $rev on $rbr)${lbl:+ ($lbl $ask)}"; exit 0; }
  act_call "repos/$REPO/actions/runs/$run/pending_deployments" "$(jq -nc --argjson id "$eid" '{environment_ids: [$id], state: "approved", comment: "Approved on the repository owner'"'"'s word."}')"
  echo "approved run $run attempt $att for $env: $rwf, $rev on $rbr ($lbl $ask)"
}
act_dispatch() {
  wf=${af[1]}; r=${af[2]}; sha=${af[3]}
  if [ "$r" != "$TRUNK" ] && ! jq -e --arg r "$r" '(.merge.branches // {}) | has($r)' "$CFG" >/dev/null; then
    case $(tag_state "$r") in yes) ;; no) act_refuse "$r is neither the trunk, a merge.branches base nor a tag";; *) act_refuse "cannot read tag $r";; esac; fi
  h=$(gh api "repos/$REPO/commits/$r" --jq .sha 2>/dev/null) || act_refuse "cannot read $r's head"
  [ "$h" = "$sha" ] || act_refuse "$r's head is ${h:0:8}, not ${sha:0:8}"
  [ "$how" != lane ] || jq -e --arg p "$wf" '(.release.workflows // []) | any(.[]; .path == $p
      and (((.environments // []) | length > 0) or any((.signals // [])[]; IN("id-token", "npm publish", "gh release"))))' "$CFG" >/dev/null \
    || act_refuse "the profile does not mark $wf as publishing; it needs a per-act OK"
  [ -z "$chk" ] || { hold_guard; echo "checked: $X${lbl:+ ($lbl $ask)}"; exit 0; }
  act_call "repos/$REPO/actions/workflows/$(basename "$wf")/dispatches" \
    "$(jq -nc --arg r "$r" '{ref: $r, inputs: ($ARGS.positional | map(split("=") | {(.[0]): .[1]}) | add // {}), return_run_details: true}' --args "${af[@]:4}")"
  rid=$(jq -r '.workflow_run_id // empty' <<<"$CALL_OUT" 2>/dev/null); [[ "$rid" =~ ^[0-9]+$ ]] || rid=unknown
  echo "dispatched $wf at $r (${sha:0:8}): run $rid ($lbl $ask)"
}
act_tag() {
  t=${af[1]}; sha=${af[2]}
  tags=$(jq -c '.release.tags // null' "$CFG"); [ "$tags" != null ] || act_refuse "release.tags is unknown, so creating $t is the owner's step"
  while IFS= read -r pat; do
    # GitHub matches with Ruby's fnmatch, whose **/ may match no directory; bash cannot, and reads braces and parentheses its own way
    case $pat in *'**/'* | *'{'* | *'('*) act_refuse "$pat is a restricted pattern this check cannot evaluate; the tag is the owner's step";; esac
    # shellcheck disable=SC2053  # a glob, where bash's * and ? also cross /, which only refuses more
    [ -n "$pat" ] && [[ "$t" == $pat ]] && act_refuse "$t matches $pat, whose tags only the release tool creates; the step is the owner's"
  done < <(jq -r '.[] | select(.creation == "restricted") | .pattern' <<<"$tags")
  case $(tag_state "$t") in no) ;; yes) act_refuse "tag $t exists";; *) act_refuse "cannot read tag $t";; esac
  reach "$sha" || act_refuse "${sha:0:8} is on neither the trunk nor a merge.branches base"
  [ -z "$chk" ] || { hold_guard; echo "checked: $X${lbl:+ ($lbl $ask)}"; exit 0; }
  act_call "repos/$REPO/git/refs" "$(jq -nc --arg r "refs/tags/$t" --arg s "$sha" '{ref: $r, sha: $s}')"
  echo "tagged $t at ${sha:0:8} ($lbl $ask)"
}
