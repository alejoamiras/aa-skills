# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Lanes and their leads: worktrees, launch and resume under the account policy, steering, stop and teardown.
WT_ROOT="$ROOT/$(cfg '.worktrees.root // ".claude/worktrees"')"
orchy_wt_new() {
  hold_guard; need agent-worktree; install=$(cfg '.install // empty'); rc=0; base=$TRUNK; ss=()
  while [ $# -gt 0 ]; do case "$1" in --base) [ $# -ge 2 ] || { echo "usage: wt-new <slug>... [--base <branch>]" >&2; exit 1; }; base=$2; shift 2;; *) ss+=("$1"); shift;; esac; done
  # a hotfix starts from the release branch; any other base would be proved at teardown against a branch nothing merges into
  { [ "$base" = "$TRUNK" ] || jq -e --arg b "$base" '(.merge.branches // {}) | has($b)' "$CFG" >/dev/null; } && ref_ok "$base" \
    || { echo "refused: --base $base is neither the trunk nor a merge.branches base" >&2; exit 1; }
  git -C "$ROOT" fetch -q origin "$base" || { echo "fetch failed"; exit 1; }
  for s in "${ss[@]}"; do
    out="$H/wt/$s.out"; w="$WT_ROOT/$s"
    [ -d "$w" ] && { echo "$s: worktree exists at $w; refusing"; rc=1; continue; }
    lane_reported "$s" && { echo "$s: lane $s has reports from an earlier run; a closed lane's slug is never reused"; rc=1; continue; }
    bf="$H/wt/$s.base"   # replaced by rename below, never written through a planted link
    if [ -L "$bf" ] || { [ -e "$bf" ] && [ ! -f "$bf" ]; }; then echo "$s: $bf must be a regular file, not a link; refusing"; rc=1; continue; fi
    { echo "== $(utc_now) new $s"; } >> "$out"
    # never pipe `agent-worktree new` into head: SIGPIPE kills it after the branch exists and before the directory does
    if ! (cd "$ROOT" && agent-worktree new "$s" --no-start) >> "$out" 2>&1; then echo "$s: agent-worktree new failed (see $out)"; rc=1; continue; fi
    [ -d "$w" ] || { echo "$s: no directory at $w (see $out)"; rc=1; continue; }
    { bt=$(mktemp "$H/wt/.$s.base.XXXXXX") && printf '%s\n' "$base" > "$bt" && mv -f "$bt" "$bf"; } \
      || { rm -f "${bt:-}"; echo "$s: cannot record its base in $bf; refusing"; rc=1; continue; }
    if (cd "$w" && git fetch -q origin "$base" && git reset -q --hard "origin/$base" && { [ -z "$install" ] || eval "$install"; }) >> "$out" 2>&1; then
      echo "install exit 0 $(git -C "$w" rev-parse --short HEAD) $(git -C "$w" rev-parse --abbrev-ref HEAD)" >> "$out"
    else echo "install exit 1" >> "$out"; rc=1; fi
    echo "$s: $(tail -n 1 "$out")"
  done; exit $rc
}
orchy_launch() { # orchy_launch launch|resume <arg>...
  local cmd=$1; shift
  need claude-usage; need flock; weight=heavy; force=0
  while [ "${1:-}" = --light ] || [ "${1:-}" = --force-cap ]; do [ "$1" = --light ] && weight=light; [ "$1" = --force-cap ] && force=1; shift; done
  k=${1:-}; w=${2:-}; a=${3:-}; sid=${4:-}
  # a dot-led key's .started file would be invisible to every *.started glob, so to the cap and to liveness
  [[ "$k" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && "$w" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || { echo "refused: key and slug are [A-Za-z0-9._-], not starting with a dot or a dash" >&2; exit 1; }
  [ -n "$a" ] || { echo "usage: $cmd [--light] <key> <slug> <account|auto> ..." >&2; exit 1; }
  cap_root_ok || exit 1; hold_guard; seat_held || exit 1
  [ "$cmd" = resume ] && [ "$a" = auto ] && { echo "refused: a resume runs on its session's own account; name it" >&2; exit 1; }
  v=$(acct_view) || exit 1
  jq -e .known <<<"$v" >/dev/null || { echo "refused: this session runs on $(jq -r .orchestrator <<<"$v"), which is not on the claude-usage roster, so no lead can be kept off it" >&2; exit 1; }
  if [ "$a" = auto ]; then
    cands=$(jq -r --arg w "$weight" --argjson f "$force" '.accounts[] | select(.verdict == "heavy" or (.verdict == "light" and ($w == "light" or ($f == 1 and .floor)))) | .key' <<<"$v")
    [ -n "$cands" ] || { echo "refused: no account may take a $weight lead now: $(jq -r '[.accounts[] | "\(.label) \(.verdict) (\(.why))"] | join("; ")' <<<"$v")" >&2; exit 1; }
  else
    acc=$(jq -c --arg a "$a" 'first(.accounts[] | select(.key == $a or .label == $a)) // empty' <<<"$v")
    [ -n "$acc" ] || { echo "refused: $a is not on the claude-usage roster" >&2; exit 1; }
    case "$(jq -r .verdict <<<"$acc")" in
      no) echo "refused: $a: $(jq -r .why <<<"$acc")" >&2; exit 1;;
      light) fl=$(jq -r .floor <<<"$acc"); [ "$weight" = light ] || { [ "$force" = 1 ] && [ "$fl" = true ]; } || {
        echo "refused: $a takes light leads only: $(jq -r .why <<<"$acc"); --light$([ "$fl" = true ] && echo ", or --force-cap on the owner's word")" >&2; exit 1; };;
    esac
    cands=$(jq -r .key <<<"$acc")
  fi
  capn=$(jq -r ".policy.${weight}_per_account" <<<"$v")
  # Close-outs run one at a time: each merges the trunk's plan index and lessons, and two in flight would each miss the other's.
  if [[ "$k" == *-closeout ]]; then
    open=$(gh pr list --repo "$REPO" --state open --limit 1000 --json headRefName --jq '.[].headRefName' 2>/dev/null) || { echo "refused: cannot list open PRs to serialize close-outs" >&2; exit 1; }
    other=$(grep -E -- '-closeout$' <<<"$open" | grep -vxF -- "$w-closeout" | head -1)
    [ -z "$other" ] || { echo "refused: close-out PR $other is still open; close-outs run one at a time" >&2; exit 1; }
  fi
  [ "$cmd" = resume ] && [ -z "$sid" ] && { echo "usage: resume <key> <slug> <account> <session-id>" >&2; exit 1; }
  p="$H/prompts/$k.md"; [ -f "$p" ] || { echo "orchy: no prompt $p" >&2; exit 1; }
  # What the earlier run left, read before this one can rewrite it: a retry's event keeps a first failure countable.
  rp="$H/reports/$k.md"; prior=null; pfl=null; pfs=null
  if [ -f "$rp" ]; then
    m=$(grep -xE 'LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*|SHOTS_READY.*|SHOTS_BLOCKED:.*' "$rp" | tail -1 | grep -oE '^(LEAD_DONE|LEAD_BLOCKED|ARC_FAILED|SHOTS_READY|SHOTS_BLOCKED)')
    [ -n "$m" ] && prior="\"$m\""
    pfl=$(grep -c '^ARC_FAILED:' "$rp"); [[ "$pfl" =~ ^[0-9]+$ ]] || pfl=null
    [ "$pfl" != null ] && [ "$pfl" -gt 0 ] && pfs="\"$(grep '^ARC_FAILED:' "$rp" | tail -1 | tr -d '\n' | sha256sum | cut -d' ' -f1)\""
  fi
  # Everything the lead reads passes the ban and the copy check; the owner's words reach it only as stored askN lines.
  reads=("$p"); for b in _common _planner _implementer "$w"; do [ -f "$H/briefs/$b.md" ] && reads+=("$H/briefs/$b.md"); done
  "$0" check-text "${reads[@]}" || exit 1
  "$0" check-private "${reads[@]}" || exit 1
  lb=(); [ -f "$H/briefs/$w.md" ] && lb=("$H/briefs/$w.md")
  ask_lines "$w" "$p" "${lb[@]}" || exit 1
  launch_spawn
}
launch_spawn() { # the worktree, the settings, then the seat, liveness and cap checks, the spawn and its record under the spawn lock
  d="$WT_ROOT/$w"; [ -d "$d" ] || { echo "orchy: no worktree $d" >&2; exit 3; }
  model=$(cfg '.leads.model // "opus"'); l1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "?")
  case "$(cfg '.leads.permission_mode // "auto"')" in
    auto) perm=(--permission-mode auto --permission-prompts none);;
    bypass) perm=(--dangerously-skip-permissions);;
    *) echo "orchy: leads.permission_mode must be auto or bypass" >&2; exit 1;;
  esac
  extra=(); [ "$cmd" = resume ] && extra=(--resume "$sid")
  mkdir -p "$H/scratch/$w"; S="$H/leads/$k.settings.json"; L="$H/leads/$k.log"
  dirs=(--add-dir "$H/reports" --add-dir "$H/scratch/$w")
  [ -f "$H/page/shots-plan/$k.json" ] && { mkdir -p "$H/page/shots"; dirs+=(--add-dir "$H/page/shots"); }
  hook=$(printf '%q ' bash "$(realpath "$(dirname "$0")")/inbox-hook.sh" "$H/inbox/$k.jsonl"); hook=${hook% }
  jq -n --arg c "$hook" '{hooks: {PostToolUse: [{matcher: "*", hooks: [{type: "command", command: $c}]}]}}' > "$S"
  # Seat and key checks, count, spawn and the .started write are one step: two programs cannot both take an account's last slot,
  # and a session that lost the seat while this launch waited spawns nothing.
  # Nothing in here touches the network; the lead starts with fd 9 closed, so no descendant ever holds the lock.
  exec 9>"$CAP/.spawn.lock"; flock -w 30 9 || { echo "refused: spawn lock busy for 30 s" >&2; exit 1; }
  seat_held || exit 1
  if [ -f "$H/leads/$k.started" ]; then read -r pid st _ < "$H/leads/$k.started"; alive "$pid" "$st" && { echo "refused: lead $k is alive (pid $pid)" >&2; exit 1; }; fi
  if [[ "$k" == *-closeout ]]; then other=$(lead_rows | awk -v k="$k" '$1 ~ /-closeout$/ && $1 != k {print $1; exit}')
    [ -z "$other" ] || { echo "refused: close-out lead $other is alive; close-outs run one at a time" >&2; exit 1; }; fi
  cnt=$(lead_counts "$v"); pick=
  for c in $cands; do n=$(jq -r --arg c "$c" --arg w "$weight" '.[$c][$w] // 0' <<<"$cnt")
    if [ "$force" = 1 ] || [ "$n" -lt "$capn" ]; then pick=$c; break; fi; done
  if [ -z "$pick" ]; then
    if [ "$a" = auto ]; then echo "refused: every account that may take a $weight lead already runs $capn (the cap); --force-cap only on the owner's word" >&2
    else echo "refused: $a already runs $n $weight lead(s) across programs (cap $capn); --force-cap only on the owner's word" >&2; fi; exit 1
  fi
  a=$pick
  # a killed run may end mid-line: the newline keeps the marker a line of its own
  printf '\n%s\n' "$(jq -nc --arg k "$k" --arg l "$w" --arg c "$cmd" --arg t "$(utc_now)" '{type: "orchy_invocation", key: $k, lane: $l, cmd: $c, at: $t}')" >> "$L"
  # PRINT_BG_WAIT_CEILING=0: a headless turn that yields to a background task ends the session; the brief tells leads to poll inside one tool call instead.
  # setsid: the lead leads its own process group (a background subshell is not a group leader, so setsid does not fork and $! stays the lead).
  ( cd "$d" && exec 9>&- env CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 setsid nohup claude-usage run "=$a" "${extra[@]}" -p "$(cat "$p")" --model "$model" "${perm[@]}" \
      --settings "$S" "${dirs[@]}" --verbose --output-format stream-json >> "$L" 2>> "$H/leads/$k.err" ) &
  pid=$!
  record() { printf '%s %s %s %s %s %s %s %s\n' "$pid" "$(pid_start "$pid")" "$a" "$(utc_now)" "$weight" "prompts/$k.md" "$1" "$w" > "$H/leads/$k.started.tmp" && mv "$H/leads/$k.started.tmp" "$H/leads/$k.started"; }
  # recorded at once (exec keeps the pid and its start time), so a launcher killed during the wait still leaves the lead counted and stoppable
  record "?"
  for _ in 1 2 3 4 5 6 7 8 9 10; do alive "$pid" && break; sleep 0.2; done
  pg=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' '); record "${pg:-?}"
  exec 9>&-
  echo "$k ${cmd%e}ed on $a pid $pid pgid ${pg:-?} ($weight, $(cfg '.leads.permission_mode // "auto"'), load1 $l1)"
  ev "lead.$cmd" key="$k" lane="$w" weight="$weight" prior:="$prior" prior_failed_lines:="$pfl" prior_failed_sha:="$pfs"
}
orchy_stop() {
  k=$1; f="$H/leads/$k.started"; [ -f "$f" ] || { echo "$k: no lead record"; exit 1; }
  read -r pid st _ _ _ _ pg _ < "$f"; alive "$pid" "$st" || { echo "$k: not alive"; exit 0; }
  # Claude Code starts each Bash-tool shell as its own session leader, so a group kill alone misses a hung tool process:
  # collect the whole tree first, while every child still points at its parent.
  mapfile -t tree < <(ps -eo pid=,ppid= | awk -v r="$pid" '{p[$1]=$2} END {s[r]=1; c=1; while (c) {c=0; for (x in p) if (!(x in s) && (p[x] in s)) {s[x]=1; c=1}}; for (x in s) print x}')
  ids=(); for q in "${tree[@]}"; do if [ "$q" = "$pid" ]; then ids+=("$q:$st"); else ids+=("$q:$(pid_start "$q")"); fi; done
  # A lead that exited before the walk may have handed its pid, group id and so the walked tree to a stranger: then signal
  # nothing. A lead that is simply gone leaves its orphans in the tree, and those are still ended.
  cur=$(pid_start "$pid"); [ -n "$cur" ] && [ "$cur" != "$st" ] && { echo "$k: pid $pid now belongs to another process; nothing signalled"; exit 0; }
  [ "${pg:-?}" = "$pid" ] && [ "$cur" = "$st" ] && kill -TERM -- "-$pg" 2>/dev/null
  for e in "${ids[@]}"; do [ -n "${e#*:}" ] && [ "$(pid_start "${e%%:*}")" = "${e#*:}" ] && kill -TERM "${e%%:*}" 2>/dev/null; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do left=0; for e in "${ids[@]}"; do [ "$(pid_start "${e%%:*}")" = "${e#*:}" ] && left=1; done; [ "$left" = 0 ] && break; sleep 0.5; done
  for e in "${ids[@]}"; do [ -n "${e#*:}" ] && [ "$(pid_start "${e%%:*}")" = "${e#*:}" ] && kill -KILL "${e%%:*}" 2>/dev/null; done
  echo "$k: stopped pid $pid and ${#ids[@]} process(es) in its tree"; ev lead.stop key="$k"
}
orchy_say() {
  need flock; k=$1; shift; t="$*"
  [[ "$k" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] && [ -n "$t" ] || { echo "usage: say <key> <text>" >&2; exit 1; }
  [ -f "$H/leads/$k.started" ] && read -r pid st _ _ _ _ _ lane _ < "$H/leads/$k.started" && alive "$pid" "$st" || { echo "refused: no live lead $k; fold the note into its next prompt" >&2; exit 1; }
  # leads quote their instructions into committed plans, so a note passes the same ban as a prompt
  # the sensitive pattern stays off: notes routinely name review findings
  tf="$H/scratch/say.$$"; printf '%s\n' "$t" > "$tf"
  { "$0" check-text "$tf" && "$0" check-public --no-sensitive "$tf" && ask_lines "${lane:-?}" --no-sensitive "$tf"; }; rc=$?; rm -f "$tf"; [ "$rc" = 0 ] || exit 1
  line=$(jq -nc --arg t "$(utc_now)" --arg x "$t" '{at: $t, text: $x}')
  [ "$(printf '%s' "$line" | wc -c)" -le 3072 ] || { echo "refused: a note is at most 3 KiB once serialized; put the detail in a file under the lane's scratch dir and name it" >&2; exit 1; }
  ( flock -w 5 8 || exit 1; printf '%s\n' "$line" >&8 ) 8>>"$H/inbox/$k.jsonl" || { echo "refused: inbox lock busy" >&2; exit 1; }
  echo "queued for $k"
}
orchy_session_id() { grep -oE '"session_id":"[0-9a-f-]{36}"' "$H/leads/$1.log" 2>/dev/null | tail -1 | cut -d'"' -f4; }
orchy_teardown() {
  need gh; need agent-worktree; s=$1; W="$WT_ROOT/$s"; q="$(basename "$ROOT")/$s"
  end_hold() { # a release freeze is the lane's own hold: it ends with the lane, and a teardown that cannot end it fails
    local h; h=$(holds_read) || { echo "$s: torn down, but holds.json is unreadable, so lane:$s may still hold"; exit 1; }
    jq -e --arg r "lane:$s" 'any(.holds[]; .ref == $r)' <<<"$h" >/dev/null || return 0
    "$0" hold "done" "lane:$s" || { echo "$s: torn down, but its hold remains (ORCHY hold done lane:$s)"; exit 1; }; }
  [ -d "$W" ] || { echo "$s: no worktree dir"; (cd "$ROOT" && agent-worktree "done" "$q" --forget 2>&1 | tail -1); end_hold; exit 0; }
  # a lead belongs to the lane whose worktree it runs in (launch starts it there), whatever its key
  wr=$(realpath -m "$W")
  lead_rows | while read -r k _ _ p; do c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue; { [ "$c" = "$wr" ] || [ "${c#"$wr"/}" != "$c" ]; } && echo "$k"; done | grep -q . && { echo "$s: a lead of this lane is alive; refusing"; exit 4; }
  b=$(git -C "$W" rev-parse --abbrev-ref HEAD); head=$(git -C "$W" rev-parse HEAD); dirty=$(git -C "$W" status --short | wc -l)
  [ "$dirty" = "0" ] || { echo "$s: $dirty uncommitted files; refusing"; exit 3; }
  base=$TRUNK; bf="$H/wt/$s.base"   # absent for a lane made before bases: the trunk
  if [ -e "$bf" ] || [ -L "$bf" ]; then base=$( [ -f "$bf" ] && [ ! -L "$bf" ] && head -n 1 "$bf")
    { [ "$base" = "$TRUNK" ] || jq -e --arg b "$base" '(.merge.branches // {}) | has($b)' "$CFG" >/dev/null; } && ref_ok "$base" \
      || { echo "$s: wt/$s.base names neither the trunk nor a merge.branches base; refusing"; exit 2; }; fi
  if out=$(cd "$ROOT" && agent-worktree "done" "$q" --merged --trunk "$base" 2>&1); then echo "$out" | tail -2; end_hold; exit 0; fi
  echo "$out" | grep -qi 'refus' || { echo "$s: agent-worktree failed: $(echo "$out" | tail -1)"; exit 5; }
  # the squash proof can fail after a later PR rewrote a file the squash carried; a HEAD that IS a merged PR's head is proof enough, when the config allows a hand removal
  [ "$(cfg '.teardown.hand_remove // false')" = true ] || { echo "$out" | tail -2; echo "$s: hand removal is off (teardown.hand_remove); relay the refusal"; exit 2; }
  pr=$(gh pr list --repo "$REPO" --head "$b" --state merged --json number,headRefOid,baseRefName --jq ".[] | select(.headRefOid==\"$head\" and .baseRefName==\"$base\") | .number" | head -1)
  [ -n "$pr" ] || { echo "$s: HEAD $head is not the head of a PR merged into $base from $b; refusing"; exit 2; }
  (cd "$ROOT" && git worktree remove --force "$W" && git branch -D "$b" >/dev/null) || { echo "$s: hand removal failed; the lane's hold stays"; exit 5; }
  (cd "$ROOT" && agent-worktree "done" "$q" --forget >/dev/null 2>&1; git worktree prune); echo "$s: hand-removed (branch $b at $head = merged PR #$pr)"; end_hold
}
