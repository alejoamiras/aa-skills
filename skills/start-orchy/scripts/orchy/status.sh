# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# What the orchestrator and pollers read: the tick's snapshot, the poller's state and the event wait.
orchy_snapshot() {
  need gh
  echo "== $(utc_now) load1 $(cut -d' ' -f1 /proc/loadavg 2>/dev/null) nproc $(nproc 2>/dev/null)"
  echo "-- reports (newest first)"; ls -t "$H"/reports/*.md 2>/dev/null | head -12 | while read -r f; do printf '%s %s %s\n' "$(date -u -r "$f" +%m-%dT%H:%MZ)" "$(basename "$f")" "$(grep -xE 'LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*|SHOTS_READY.*|SHOTS_BLOCKED:.*' "$f" | tail -1 | cut -c1-80)"; done
  echo "-- progress"; for f in "$H"/reports/*.progress; do [ -f "$f" ] && printf '%s: %s\n' "$(basename "$f" .progress)" "$(tail -c 200 "$f" | tr '\n' ' ')"; done
  echo "-- leads"
  # Health without sampling: how long the log has been silent, the progress file's age, and what the newest process in the
  # lead's tree is doing. STALLED? is advisory; the command and its age are the evidence.
  stall=$(( $(cfg '.leads.stall_after_min // 20') * 60 )); tnow=$(date +%s); ps_rows=$(ps -eo pid=,ppid=,etimes=,args=)
  lead_rows | while read -r k a w p; do
    q=$(( tnow - $(stat -c %Y "$H/leads/$k.log" 2>/dev/null || echo "$tnow") ))
    pf="$H/reports/$k.progress"; pa=$([ -f "$pf" ] && echo "$(( (tnow - $(stat -c %Y "$pf")) / 60 ))m" || echo "-")
    newest=$(newest_proc "$p" "$ps_rows"); [ -z "$newest" ] || newest="${newest#*$'\t'} ($(( ${newest%%$'\t'*} / 60 ))m)"
    flag=""; [ "$q" -gt "$stall" ] && flag="STALLED? "
    echo "alive $k $a $w pid $p ${flag}quiet $((q / 60))m progress $pa ${newest:+$newest}"
  done
  # a dead lead stopped by a usage limit, while its lane's worktree stands
  logs=(); for f in "$H"/leads/*.started; do [ -f "$f" ] || continue; read -r pid st _ _ _ _ _ lane _ < "$f"
    alive "$pid" "$st" || { [ -n "${lane:-}" ] && [ ! -d "$WT_ROOT/$lane" ]; } || logs+=("${f%.started}.log"); done
  [ ${#logs[@]} = 0 ] || python3 -I "$SCRIPTS/orchy/limit.py" "${logs[@]}" | while read -r k e t; do
    echo "LIMITED $k resets $t$([[ "$e" =~ ^[0-9]+$ ]] && [ "$e" -le "$tnow" ] && echo ' (passed)')"; done
  echo "-- inbox"; for f in "$H"/inbox/*.jsonl; do [ -f "$f" ] || continue
    c=$(cat "${f%.jsonl}.cursor" 2>/dev/null); [[ "$c" =~ ^[0-9]{1,15}$ ]] && c=$((10#$c)) || c=0
    n=$(tail -c +"$((c + 1))" "$f" | grep -c ''); [ "$n" -gt 0 ] && echo "$(basename "$f" .jsonl): $n undelivered"; done
  # ids and states only: the owner's words stay in the ledger (ask show)
  echo "-- asks"; live=$(lead_rows | cut -d' ' -f1)
  fold | jq -r --argjson now "$(date +%s)" 'map(select(.state == "open" or .state == "lane")) | sort_by(.id | ltrimstr("ask") | tonumber? // 0) | .[]
    | ($now - (.at | fromdateiso8601? // $now)) as $s
    | "\(.id) \(.state) \(.lane // "-") \(if $s < 3600 then "\($s / 60 | floor)m" else "\($s / 3600 | floor)h" end)"
      + (if .public then "" else " no-public-wording" end) + (if ([ '"$ASK_HOLD"' ] | length) > 0 then " waiting" else "" end)' |
  while read -r i st l rest; do
    if [ "$st" = lane ] && [ ! -d "$WT_ROOT/$l" ] && ! grep -qE "^$l-(plan|a[0-9]+|arc[0-9]+|closeout)$" <<<"$live"; then rest="$rest lane closed: run ask close-lane $l"; fi
    echo "$i $st $l $rest"
  done
  echo "-- watchers"; for f in "$H"/watch/*.pid; do [ -f "$f" ] || continue; n=$(basename "$f" .pid); if watcher_alive "$f"; then mk=$(watch_marker "$H/watch/$n.out"); echo "alive $n pid $(cut -d' ' -f1 "$f")${mk:+ $mk}"; else echo "ended $n: $(tail -n 1 "$H/watch/$n.out" 2>/dev/null | cut -c1-120)"; fi; done
  echo "-- trunk"; if t=$(trunk_state); then f=$(tail -n +2 <<<"$t" | paste -sd, -); echo "$TRUNK ${t:0:8}: ${f:+RED }${f:-no failed trunk check}"; else echo "(trunk checks unreadable)"; fi
  echo "-- open PRs"; gh pr list --repo "$REPO" --state open --json number,title,headRefOid,mergeable,mergeStateStatus,isDraft,baseRefName --jq '.[]|"#\(.number) \(.headRefOid[0:8]) \(.mergeable) \(.mergeStateStatus) draft=\(.isDraft) -> \(.baseRefName) \(.title)"' 2>/dev/null || echo "(gh pr list failed)"
  echo "-- worktrees"; git -C "$ROOT" worktree list | tail -n +2
  echo "-- untriaged issues"
  if [ ! -f "$H/triaged.txt" ]; then echo "(no triaged.txt: write every triaged issue number into it, one per line)"
  elif iss=$(gh issue list --repo "$REPO" --state open --limit 1000 --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null); then
    awk -F'\t' 'FILENAME == ARGV[1] {t[$1]=1; next} $1 != "" && !($1 in t) {print "#" $1 " " substr($2, 1, 100)}' <(grep -xE '[0-9]+' "$H/triaged.txt") <(printf '%s\n' "$iss")
  else echo "(gh issue list failed)"; fi
  echo "-- unsigned pages"; [ -f "$H/page/unsigned.json" ] && jq -r --argjson now "$(date +%s)" --slurpfile u "$H/page/unsigned.json" '.pages[] | select(.no as $n | $u[0] | index($n)) |
    "page \(.no) \(.name): " + (if .added_at then (($now - (.added_at | fromdateiso8601)) | "waiting \(. / 86400 | floor)d\(. % 86400 / 3600 | floor)h") else "age unknown" end)' "$H/page/decisions.json" 2>/dev/null
  echo "-- waiting"; "$0" waiting list 2>&1
  echo "-- grants"; "$0" grants 2>&1
  echo "-- holds"; "$0" hold list 2>&1
  echo "-- goals"; g=$("$0" goals --json 2>/dev/null) && jq -r '.goals[] | '"$GOAL_LINE" <<<"$g" 2>/dev/null || echo "goals: unreadable (ORCHY goals)"
  echo "-- runbooks"; [ ! -L "$RUNBOOKS" ] || echo "runbooks: $RUNBOOKS is a symlink; refusing"
  [ -L "$RUNBOOKS" ] || for f in "$RUNBOOKS"/*.md; do [ -f "$f" ] || continue; b=$(basename "$f" .md); j=$(rb_parse "$f" 2>&1) || { echo "$b: $j"; continue; }
    jq -r --arg b "$b" '(map(select(.[0])) | length) as $k | select($k < length) | "\($b) \($k)/\(length)"' <<<"$j"; done
  # launch reads only the cached snapshot, so the tick refreshes it: a reading over 2 h old allows light leads only
  echo "-- headroom"; claude-usage refresh >/dev/null 2>&1; "$0" accounts 2>&1 | head -20
}
orchy_state() {
  # orchy.state/1 for a poller: local facts only (no gh, usage or network call) and nothing written. The seat and the
  # pages are left to the reader, who parses those files directly. An unreadable source is null and named in errors.
  errs=(); tnow=$(date +%s); sm=$(cfg '.leads.stall_after_min // 20' 2>/dev/null); [[ "$sm" =~ ^[0-9]{1,6}$ ]] || sm=20; stall=$(( 10#$sm * 60 )); ps_rows=$(ps -eo pid=,ppid=,etimes=,args=)
  leads=$(for f in "$H"/leads/*.started; do [ -f "$f" ] && [ ! -L "$f" ] || continue; k=$(basename "$f" .started)
      read -r pid st acct t weight _ pg lane _ < "$f" || continue
      a=false; alive "$pid" "$st" && a=true; nw=""; [ $a = true ] && nw=$(newest_proc "$pid" "$ps_rows")
      q=$(( tnow - $(stat -c %Y "$H/leads/$k.log" 2>/dev/null || echo "$tnow") ))
      pa=null; [ -f "$H/reports/$k.progress" ] && pa=$(( tnow - $(stat -c %Y "$H/reports/$k.progress") ))
      jq -nc --arg key "$k" --arg lane "${lane:-}" --arg account "${acct:-}" --arg weight "${weight:-heavy}" --argjson alive "$a" \
        --arg pid "$pid" --arg pgid "${pg:-}" --arg started "${t:-}" --argjson q "$q" --argjson pa "$pa" --arg nw "$nw" --argjson stall "$stall" \
        '{key: $key, lane: (if $lane == "" then null else $lane end), account: $account, weight: $weight, alive: $alive,
          pid: ($pid | tonumber? // null), pgid: ($pgid | tonumber? // null), started: $started, quiet_s: $q, progress_age_s: $pa,
          newest: (if $nw == "" then null else ($nw | split("\t") | {cmd: (.[1:] | join("\t")), age_s: (.[0] | tonumber)}) end),
          stalled: ($alive and $q > $stall)}'
    done | jq -sc .) || { leads=null; errs+=(leads); }
  rep=$(python3 -I "$SCRIPTS/orchy/reports.py" "$H/reports") || { rep='{"reports": null, "progress": null}'; errs+=(reports); }
  watchers=$(for f in "$H"/watch/*.pid; do [ -f "$f" ] || continue; n=$(basename "$f" .pid); a=false; watcher_alive "$f" && a=true
      mk=$(watch_marker "$H/watch/$n.out")
      jq -nc --arg n "$n" --argjson a "$a" --arg last "$(tail -n 1 "$H/watch/$n.out" 2>/dev/null | cut -c1-120)" --arg mk "$mk" \
        '{name: $n, alive: $a, pr: (($n | capture("^merge-(?<n>[0-9]+)$").n | tonumber) // null), last: (if $last == "" then null else $last end),
          marker: (if $mk == "" then null else $mk end)}'
    done | jq -sc .) || { watchers=null; errs+=(watchers); }
  inbox=$(for f in "$H"/inbox/*.jsonl; do [ -f "$f" ] || continue
      c=$(cat "${f%.jsonl}.cursor" 2>/dev/null); [[ "$c" =~ ^[0-9]{1,15}$ ]] && c=$((10#$c)) || c=0
      jq -nc --arg k "$(basename "$f" .jsonl)" --argjson n "$(tail -c +"$((c + 1))" "$f" | grep -c '')" '{key: $k, undelivered: $n}'
    done | jq -sc .) || { inbox=null; errs+=(inbox); }
  # ids, states and flags only: the owner's words stay behind ask list --json
  asks=null; if ledger_ro 2>/dev/null; then
    asks=$(fold | jq -c --argjson now "$tnow" '[map(select(.state == "open" or .state == "lane")) | sort_by(.id | ltrimstr("ask") | tonumber? // 0) | .[]
      | {id, state, lane: (.lane // null), age_s: ($now - (.at | fromdateiso8601? // $now)), has_public: (.public != null),
         waiting: (([ '"$ASK_HOLD"' ] | length) > 0)}]') || { asks=null; errs+=(asks); }
  else errs+=(asks); fi
  waiting=null; if w=$(waiting_read 2>/dev/null); then waiting=$(jq -c .waiting <<<"$w"); else errs+=(waiting); fi
  triaged=null; if [ -e "$H/triaged.txt" ]; then
    if [ -f "$H/triaged.txt" ] && [ -r "$H/triaged.txt" ]; then triaged=$(grep -xE '[0-9]+' "$H/triaged.txt" | jq -Rsc 'split("\n") | map(select(. != "") | tonumber)')
    else errs+=(triaged); fi
  fi
  wts=null; if wl=$(git -C "$ROOT" worktree list --porcelain 2>/dev/null); then
    wts=$(awk -v r="$WT_ROOT/" '
      function out() { s = substr(p, length(r) + 1); if (index(p, r) == 1 && s != "" && index(s, "/") == 0) print s "\t" b "\t" h }
      /^worktree / { if (p != "") out(); p = substr($0, 10); b = ""; h = "" } /^HEAD / { h = $2 } /^branch / { b = substr($2, 12) } END { if (p != "") out() }' <<<"$wl" |
      jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {slug: .[0], branch: (if .[1] == "" then null else .[1] end), head: .[2]})')
  else errs+=(worktrees); fi
  caps=null; lj='{}'; if pol=$(policy 2>/dev/null) && { [ ! -f "$LOCAL" ] || lj=$(cat "$LOCAL"); }; then
    caps=$(jq -c --argjson p "$pol" '{week_floor_pct: $p.heavy_floor_pct, heavy: $p.heavy_per_account, light: $p.light_per_account,
      load_max: (.load_max | if type == "number" then . else null end)}' <<<"$lj" 2>/dev/null) || { caps=null; errs+=(caps); }
  else errs+=(caps); fi
  j() { printf '%s' "${1:-null}"; }   # each source travels as a file: a large array would overflow one argv string
  jq -nc --arg repo "$REPO" --arg at "$(utc_now)" --slurpfile leads <(j "$leads") --slurpfile rep <(j "$rep") --slurpfile watchers <(j "$watchers") \
    --slurpfile inbox <(j "$inbox") --slurpfile asks <(j "$asks") --slurpfile waiting <(j "$waiting") --slurpfile triaged <(j "$triaged") --slurpfile wts <(j "$wts") --argjson caps "${caps:-null}" \
    --arg mode "$(cfg '.mode // empty')" --arg boot "$(cfg '.bootstrap // empty')" --arg trunk "$TRUNK" \
    --arg load1 "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)" --arg nproc "$(nproc 2>/dev/null)" --arg errs "${errs[*]}" \
    '{schema: "orchy.state/1", repo: $repo, at: $at, leads: $leads[0], reports: $rep[0].reports, progress: $rep[0].progress, watchers: $watchers[0],
      inbox: $inbox[0], asks: $asks[0], waiting: $waiting[0], triaged: $triaged[0], worktrees: $wts[0], caps: $caps,
      mode: (if $mode == "" then null else $mode end), bootstrap: (if $boot == "" then null else $boot end), trunk: $trunk,
      load1: ($load1 | tonumber? // null), nproc: ($nproc | tonumber? // null), errors: ($errs | split(" ") | map(select(. != "")))}'
}
orchy_wait() {
  LIMIT=${1:-1500}
  snap() {
    ls -l --time-style=+%s "$H"/reports/*.md 2>/dev/null | awk '{print $6, $7}'
    lead_rows | awk '{print "alive", $1}'
    # with its marker, so a new hand-back wakes the Monitor once
    local f mk; for f in "$H"/watch/*.pid; do watcher_alive "$f" || continue; mk=$(watch_marker "${f%.pid}.out"); echo "watcher $(basename "$f" .pid)${mk:+ $mk}"; done
  }
  # GitHub every poll_sec, in three independent reads: one that fails keeps its baseline and never hides another's change.
  read_src() { local o; case $1 in
    prs) o=$(timeout 30 gh pr list --repo "$REPO" --state open --limit 1000 --json number,headRefOid,mergeable,isDraft --jq '.[]|"\(.number) \(.headRefOid[0:8]) \(.mergeable) \(.isDraft)"' 2>/dev/null) || return 1;;
    issues) o=$(timeout 30 gh issue list --repo "$REPO" --state open --limit 1000 --json number,updatedAt --jq '.[]|"\(.number) \(.updatedAt)"' 2>/dev/null) || return 1;;
    trunk) o=$(timeout 30 gh api "repos/$REPO/commits/$TRUNK" --jq .sha 2>/dev/null) && sha_ok "$o" || return 1;;
    esac; sort <<<"$o"; }
  tick=${ORCHY_WAIT_TICK:-20}; every=$(( $(cfg '.wait.poll_sec // 120') / tick )); [ "$every" -ge 1 ] || every=1
  # Baselines persist in seen/, so what moved while nobody waited (the orchestrator handling the last event) fires at the
  # first look. A source with no seen file is unknown: its first successful read fires. An exit advances only what it printed,
  # so seen/ only ever holds reported values: a second concurrent wait can report a change twice, never lose one.
  SEEN="$H/seen"; mkdir -p "$SEEN"
  declare -A last=() new=() unread=(); srcs=(prs issues trunk)
  for s in local "${srcs[@]}"; do [ -f "$SEEN/$s" ] && last[$s]=$(cat "$SEEN/$s"); done
  report() { local s l
    for s in "$@"; do l=$s; [ "$s" = local ] && l="reports/leads/watchers"
      echo "CHANGED ($l):" || return 1; diff <(echo "${last[$s]:-}") <(echo "${new[$s]}") | grep '^[<>]' | head -20; done
    for s in "$@"; do printf '%s\n' "${new[$s]}" > "$SEEN/.$s.$$" && mv "$SEEN/.$s.$$" "$SEEN/$s" || return 1; done; }
  t0=$(date +%s); n=0
  while :; do
    sleep "$tick"; n=$((n+1)); changed=()
    new[local]=$(snap); { [ -n "${last[local]+x}" ] && [ "${new[local]}" = "${last[local]}" ]; } || changed+=(local)
    # the first tick polls too: local events re-arm the wait, and a burst of them must not starve GitHub
    if [ "$n" = 1 ] || [ $((n % every)) -eq 0 ]; then
      for s in "${srcs[@]}"; do
        v=$(read_src "$s") || { unread[$s]=1; continue; }; unset "unread[$s]"
        # GitHub answers UNKNOWN while it recomputes mergeability; that is not a change
        [ "$s" = prs ] && [ -n "${last[$s]+x}" ] && v=$(awk 'NR==FNR{m[$1]=$3; next} ($1 in m) && $3=="UNKNOWN"{$3=m[$1]} {print}' <(echo "${last[$s]}") <(echo "$v"))
        if [ -z "${last[$s]+x}" ] || [ "$v" != "${last[$s]}" ]; then changed+=("$s"); new[$s]=$v; fi
      done
    fi
    if [ ${#changed[@]} -gt 0 ]; then report "${changed[@]}"; exit $?; fi
    if [ $(( $(date +%s) - t0 )) -ge "$LIMIT" ]; then u="${!unread[*]}"; echo "TIMEOUT after ${LIMIT}s, no change${u:+; unreadable: $u}"; exit 0; fi
  done
}
