# shellcheck shell=bash disable=SC2016  # jq programs are single-quoted on purpose: their $vars are jq's
# Capacity: the machine-wide account policy, the roster, each account's headroom and the leads counted against it.
ACCOUNTS=$(realpath -sm "${ORCHY_ACCOUNTS:-$HOME/.agents/orchy/accounts.json}")
# A home's accounts.use, caps and min_week_left_pct are retired by the machine-wide policy; its accounts.never still holds.
policy() { # orchy.accounts/1 with its defaults filled in; a missing file is the defaults, a symlinked, foreign or malformed one refuses
  local f=$ACCOUNTS j='{}'
  if [ -L "$f" ] || { [ -e "$f" ] && { [ ! -f "$f" ] || [ ! -O "$f" ]; }; }; then echo "refused: $f must be a regular file owned by $(id -un), not a symlink" >&2; return 1; fi
  if [ -e "$f" ]; then j=$(cat "$f") || { echo "refused: cannot read $f" >&2; return 1; }; fi
  # a present key is checked as written (`//` reads false and null as absent); \z, since $ also matches before a final newline
  jq -sce 'def opt($k; f): (has($k) | not) or (.[$k] | f); def whole: type == "number" and . == floor and . >= 0;
    select(length == 1) | .[0] | select(type == "object" and (keys - ["schema", "never", "heavy_floor_pct", "heavy_session_floor_pct", "heavy_per_account", "light_per_account"]) == []
      and opt("schema"; . == "orchy.accounts/1")
      and opt("never"; type == "array" and length <= 64 and all(.[]; type == "string" and test("\\A[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}\\z")))
      and opt("heavy_floor_pct"; whole and . <= 100) and opt("heavy_session_floor_pct"; whole and . <= 100)
      and opt("heavy_per_account"; whole and . <= 9) and opt("light_per_account"; whole and . <= 9))
    | {schema: "orchy.accounts/1", never: (.never // []), heavy_floor_pct: (.heavy_floor_pct // 25), heavy_session_floor_pct: (.heavy_session_floor_pct // 30),
       heavy_per_account: (.heavy_per_account // 2), light_per_account: (.light_per_account // 3)}' <<<"$j" 2>/dev/null \
    || { echo "refused: $f is not orchy.accounts/1 (never: names; heavy_floor_pct, heavy_session_floor_pct: 0-100; heavy_per_account, light_per_account: 0-9)" >&2; return 1; }
}
roster_rows() { # "<key> <label>" per roster account, never the ~/.claude slot: `run =` takes a directory key, the cached rows carry labels
  local out; out=$(claude-usage list 2>/dev/null) || { echo "refused: claude-usage list failed, so the roster is unknown" >&2; return 1; }
  awk '{ k = $2; sub(/.*\//, "", k) } $1 != "main" && k != "main" && $1 ~ /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/ && k ~ /^[A-Za-z0-9_-][A-Za-z0-9._-]*$/ { print k, $1 }' <<<"$out"
}
roster_re() { # every roster key and label as one literal alternation, matched only as a whole name
  local r; r=$(roster_rows) || return 1
  r=$(tr ' ' '\n' <<<"$r" | grep -v '^$' | sort -u | sed 's/[.]/\\./g' | paste -sd'|' -)
  [ -z "$r" ] || printf '(^|[^A-Za-z0-9_])(%s)($|[^A-Za-z0-9_])' "$r"
}
acct_view() { # {policy, orchestrator, known, accounts}: one row per roster account, best first, with its verdict (heavy, light, no) and why
  local pol ro rows cur never=
  pol=$(policy) || return 1; ro=$(roster_rows) || return 1
  rows=$(claude-usage --json --cached 2>/dev/null) && jq -e 'type == "array"' <<<"$rows" >/dev/null 2>&1 \
    || { echo "refused: no headroom snapshot to read; run claude-usage once" >&2; return 1; }
  # after the cached read: a snapshot exists, so current never probes
  cur=$(claude-usage current 2>/dev/null) || { echo "refused: cannot tell which account this session runs on (claude-usage current)" >&2; return 1; }
  if [ -f "$LOCAL" ]; then never=$(jq -r '.accounts.never // [] | .[] | strings' "$LOCAL") || { echo "refused: cannot read accounts.never in $LOCAL" >&2; return 1; }; fi
  jq -nc --argjson pol "$pol" --argjson rows "$rows" --arg ro "$ro" --arg cur "$cur" --arg never "$never" --argjson now "$(date +%s)" '
    def hrs($t): if ($t | type) != "number" then 168 else ([($t - $now) / 3600, 0.5] | max) end;
    ($ro | split("\n") | map(select(. != "") | split(" ") | {key: .[0], label: .[1]})) as $roster
    | ($roster | map({(.label): .key}, {(.key): .key}) | add // {}) as $key
    | ([$pol.never[], ($never | split("\n")[] | select(. != ""))] | map($key[.] // .)) as $nk
    | ($key[$cur] // $cur) as $me
    | {policy: $pol, orchestrator: $cur, known: ($me == "main" or ($roster | any(.key == $me))), me: ([$rows[] | objects | select(.account == $cur)] | first),
       accounts: ([$roster[] | . as $a | ([$rows[] | objects | select(.account == $a.label)] | first) as $r
        # a reading stands for 2 h, and never past the weekly reset it was taken before
        | ($r != null and ($r.observed_at | type) == "number" and $now - $r.observed_at <= 7200
           and (($r.week_resets_at | type) != "number" or $r.week_resets_at > $now)) as $fresh
        # a spent bucket stays spent until its own reset, so a 0 refuses however old its reading; --force-cap passes only the floor
        | (if ($nk | index($a.key)) != null then ["no", "on a never-list"]
           elif $a.key == $me then ["no", "the orchestrator runs on it"]
           elif $r == null then ["light", "no reading in the snapshot"]
           elif ($r.note // "") != "" then ["no", "claude-usage notes \($r.note)"]
           elif $r.week_left_pct == 0 and (($r.week_resets_at | type) != "number" or $r.week_resets_at > $now) then ["no", "its week is spent"]
           elif $r.session_left_pct == 0 and (($r.session_resets_at | type) != "number" or $r.session_resets_at > $now) then ["no", "its session is spent"]
           elif ($fresh | not) then ["light", (if ($r.week_resets_at | type) == "number" and $r.week_resets_at <= $now
               then "its week reset after the reading" else "the reading is over 2 h old" end)]
           elif ($r.week_left_pct | type) != "number" then ["light", "its week headroom is unknown"]
           elif ($r.session_left_pct | type) != "number" then ["light", "its session headroom is unknown"]
           elif $r.week_left_pct < $pol.heavy_floor_pct then ["light", "week \($r.week_left_pct)% is under the \($pol.heavy_floor_pct)% floor", true]
           # like a spent session, a low one counts only until its own reset
           elif $r.session_left_pct < $pol.heavy_session_floor_pct and (($r.session_resets_at | type) != "number" or $r.session_resets_at > $now)
             then ["light", "session \($r.session_left_pct)% is under the \($pol.heavy_session_floor_pct)% floor", true]
           else ["heavy", "week \($r.week_left_pct)% left"] end) as [$v, $why, $floor]
        | {key: $a.key, label: $a.label, verdict: $v, why: $why, floor: ($floor // false), week_left_pct: $r.week_left_pct, session_left_pct: $r.session_left_pct,
           week_resets_at: $r.week_resets_at, observed_at: $r.observed_at,
           # the headroom that expires soonest goes first: week left per hour to its reset
           score: (if $v != "no" and $fresh then ($r.week_left_pct // 0) / hrs($r.week_resets_at) else -1 end)}]
        | sort_by(-.score, .key))}'
}
all_rows() { # <acct> <weight> <home>: every live lead of every program under the capacity root
  local f pid st acct weight
  for f in "$CAP"/*/leads/*.started; do [ -f "$f" ] || continue; read -r pid st acct _ weight _ < "$f"; alive "$pid" "$st" && echo "$acct ${weight:-heavy} ${f%/leads/*}"; done
}
cap_root_ok() { # the root holds every home and the spawn lock: whoever can rename or replace it can swap a lead's hook settings
  local p
  [ -d "$CAP" ] && [ ! -L "$CAP" ] && [ -O "$CAP" ] || { echo "refused: capacity root $CAP must be a directory owned by $(id -un), not a symlink" >&2; return 1; }
  for p in "$CAP" "$(dirname "$CAP")"; do case "$(stat -c %a "$p")" in *[2367]?|*[2367]) echo "refused: $p is group- or world-writable" >&2; return 1;; esac; done
  case "$(basename "$H")" in .*) echo "refused: a home named $(basename "$H") is invisible to the capacity count" >&2; return 1;; esac
  [ "$(cd "$(dirname "$H")" && pwd -P)" = "$(cd "$CAP" && pwd -P)" ] || { echo "refused: $H is not directly under the capacity root $CAP (ORCHY_CAPACITY_ROOT); its leads would escape the shared cap" >&2; return 1; }
}
lead_counts() { # <acct_view json>: {"<key>": {"heavy": n, "light": n}} over every program's live leads; an older .started may name a label
  local key label ac wt; declare -A K=()
  while read -r key label; do K[$label]=$key; K[$key]=$key; done < <(jq -r '.accounts[] | "\(.key) \(.label)"' <<<"$1")
  all_rows | while read -r ac wt _; do printf '%s %s\n' "${K[$ac]:-$ac}" "$wt"; done | jq -Rn '[inputs | split(" ")] | reduce .[] as [$k, $w] ({}; .[$k][$w] += 1)'
}
orchy_accounts() {
  need claude-usage; v=$(acct_view) || exit 1; c=$(lead_counts "$v")
  v=$(jq -c --argjson c "$c" '.accounts |= map(. + {heavy_leads: ($c[.key].heavy // 0), light_leads: ($c[.key].light // 0)})' <<<"$v")
  if [ "${1:-}" = --json ]; then jq -c --arg at "$(utc_now)" '{schema: "orchy.headroom/1", at: $at, policy, orchestrator, accounts}' <<<"$v"; exit 0; fi
  jq -r --argjson now "$(date +%s)" 'def reading: "week \(.week_left_pct // "?")% session \(.session_left_pct // "?")%"
      + (if (.week_resets_at | type) != "number" then "" elif .week_resets_at > $now then " resets in \((.week_resets_at - $now) / 3600 | floor)h" else " reset passed" end);
    .policy as $p
    | "policy: heavy leads need \($p.heavy_floor_pct)% of the week and \($p.heavy_session_floor_pct)% of the session left, light ones any; \($p.heavy_per_account) heavy and \($p.light_per_account) light per account",
      "orchestrator: \(.orchestrator)  \(.me // {} | reading)",
      (.accounts[] | "\(.label)\(if .key != .label then " (\(.key))" else "" end)  \(.verdict)  \(reading)  leads \(.heavy_leads) heavy \(.light_leads) light  \(.why)")' <<<"$v"
}
