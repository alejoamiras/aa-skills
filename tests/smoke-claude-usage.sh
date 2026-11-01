#!/usr/bin/env bash
# Smoke test for bin/claude-usage, bin/clu, lib/usage.sh and the claude skill's
# reviewer scripts — a stub `claude` on PATH, a fake HOME and a throwaway accounts root.
# No real login, keychain, token or ~/.claude is touched.
# shellcheck disable=SC2016,SC2012,SC2329 # literal $… in sh -c bodies; ls counts names we created; helpers run through t
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CU="$ROOT/bin/claude-usage"
RUNC="$ROOT/skills/claude/scripts/run-claude.sh"
RESC="$ROOT/skills/claude/scripts/resume-claude.sh"
# Physical path: claude-usage canonicalises the accounts root (/var → /private/var).
S="$(cd "$(mktemp -d)" && pwd -P)"
trap '[ -n "${KEEP:-}" ] && echo "kept $S" || rm -rf "$S"' EXIT
export HOME="$S/home" CLAUDE_ACCOUNTS_ROOT="$S/accounts" XDG_CACHE_HOME="$S/cache" XDG_STATE_HOME="$S/state" CLAUDE_USAGE_SKIP_MAIN=1
export TMPDIR="$S/tmp" CALLS="$S/calls"
export PATH="$S/bin:$ROOT/bin:$PATH"
unset CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_ACCOUNT
mkdir -p "$HOME" "$TMPDIR"
FAIL=0

t() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok    $label"; else echo "FAIL  $label"; FAIL=1; fi; }
tn() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL  $label (expected failure)"; FAIL=1; else echo "ok    $label"; fi; }

# Current CLI format ("Sep 26, 5:59pm"), N days ahead in UTC as the stub's clause says, under GNU or BSD date.
ahead() {
  { date -u -d "+$1 day" '+%b %-d, %-I:%M%p' 2>/dev/null || date -u -v+"$1"d '+%b %-d, %-I:%M%p'; } |
    sed -e 's/AM$/am/' -e 's/PM$/pm/'
}

mkdir -p "$S/bin"
cat > "$S/bin/claude" <<'STUB'
#!/usr/bin/env bash
acct=$(basename "${CLAUDE_CONFIG_DIR:-main}")
plan=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plan" 2>/dev/null || echo max)
org=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/org" 2>/dev/null || echo "org-$acct")
[[ $1 == --version ]] && { echo "9.9.9 (Claude Code)"; exit 0; }
[[ $1 == auth ]] && { printf '{\n  "loggedIn": true,\n  "email": "%s@x",\n  "orgId": "%s",\n  "subscriptionType": "%s"\n}\n' "$acct" "$org" "$plan"; exit 0; }
if [[ " $* " == *" /usage "* ]]; then
  echo "$acct" >> "$CALLS.usage"
  echo "You are currently using your subscription to power your Claude Code usage"
  [[ -f $CLAUDE_CONFIG_DIR/reset ]] || exit 0   # idle: no window open anywhere
  # flaky: the first reply of a busy account comes back windowless.
  [[ -f $CLAUDE_CONFIG_DIR/flaky ]] && { rm -f "$CLAUDE_CONFIG_DIR/flaky"; exit 0; }
  r=$(cat "$CLAUDE_CONFIG_DIR/reset")
  s=$r; [[ -f $CLAUDE_CONFIG_DIR/session ]] && s=$(cat "$CLAUDE_CONFIG_DIR/session")
  z=UTC; [[ -f $CLAUDE_CONFIG_DIR/zone ]] && z=$(cat "$CLAUDE_CONFIG_DIR/zone")
  w=50; [[ -f $CLAUDE_CONFIG_DIR/spent ]] && w=100
  printf '\nCurrent session: 0%% used · resets %s (%s)\n' "$s" "$z"
  printf 'Current week (all models): %s%% used · resets %s (%s)\n' "$w" "$r" "$z"
  printf 'Current week (Fable): 100%% used · resets %s (%s)\n' "$r" "$z"
  exit 0
fi
# A session: record what it ran with, one line per call.
printf 'dir=%s token=%s apikey=%s bedrock=%s argv=%s\n' "${CLAUDE_CONFIG_DIR-unset}" \
  "${CLAUDE_CODE_OAUTH_TOKEN-unset}" "${ANTHROPIC_API_KEY-unset}" "${CLAUDE_CODE_USE_BEDROCK-unset}" "$*" >> "$CALLS"
if [[ " $* " == *" --output-format json "* ]]; then
  sid=11111111-2222-3333-4444-555555555555
  prev=""; for a in "$@"; do [[ $prev == --resume || $prev == --session-id ]] && sid=$a; prev=$a; done
  printf '{"type":"result","session_id":"%s","result":"ok","is_error":false}\n' "$sid"
fi
STUB
chmod +x "$S/bin/claude"
# Every --json reply must parse strictly: python3 refuses what grep and jq let through, such as an
# epoch with a leading zero. Traced runs (bash -x) call the script itself.
CU_BIN="$CU"
CU="$S/claude-usage-json"
cat > "$CU" <<STUB
#!/usr/bin/env bash
[[ " \$* " == *" --json "* ]] || exec "$CU_BIN" "\$@"
out=\$("$CU_BIN" "\$@"); rc=\$?
printf '%s\n' "\$out"
((rc)) || python3 -c 'import json,sys; json.load(sys.stdin)' <<< "\$out" 2>/dev/null || echo "\$*" >> "$S/badjson"
exit \$rc
STUB
chmod +x "$CU"
# An account's session, week and premium reset epochs from a --json reply; "null" for none.
epochs() {
  python3 -c 'import json,sys
r = next(x for x in json.load(open(sys.argv[1])) if x["account"] == sys.argv[2])
print(*(json.dumps(r[k + "_resets_at"]) for k in ("session", "week", "premium")))' "$1" "$2"
}
same_epochs() { local a x; for a in "${@:3}"; do x=$(epochs "$1" "$a") && [[ $x == "$(epochs "$2" "$a")" ]] || return 1; done; }
# A reset read from minute-precision text written at $2 lies within the minute before it.
near() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= $2 - 60 && $1 <= $2 + 1 )); }
login_epochs() { local s w p; read -r s w p <<< "$(epochs "$1" "$2")"; [[ $s == null ]] && near "$w" "$3" && near "$p" "$3"; }
last() { tail -1 "$CALLS"; }
# The API: replies come from $NET/<cksum of the bearer token> ("<code>" then
# header lines); no file means unreachable, as real curl reports it.
export NET="$S/net"; mkdir -p "$NET"
cat > "$S/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s keylog=%s\n' "$*" "${SSLKEYLOGFILE-unset}" >> "$NET/argv"
[[ -f $NET/slow ]] && sleep 1
tok=$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p')
f="$NET/$(printf '%s' "$tok" | cksum | cut -d' ' -f1)"
[[ -n $tok && -f $f ]] || { printf '\n000\n'; exit 7; }
code=$(head -1 "$f")
printf 'HTTP/2 %s\r\n' "$code"; tail -n +2 "$f" | sed 's/$/\r/'; printf '\r\n\n%s\n' "$code"
exit "$(cat "$f.exit" 2>/dev/null || echo 0)"   # e.g. 28: timed out after the headers
STUB
chmod +x "$S/bin/curl"

# The slot's stack, as install.sh would leave it.
mkdir -p "$HOME/.claude/skills/alpha" "$HOME/.claude/skills/beta" "$HOME/.claude/skills/synced"
for f in CLAUDE.md AGENTS.md statusline.sh settings.json; do echo "main $f" > "$HOME/.claude/$f"; done
mkdir -p "$HOME/.claude/plugins/cache"

# Named so alphabetical order is the WRONG answer: only a parsed reset date
# puts zzz-soon ahead of aaa-late.
mkdir -p "$CLAUDE_ACCOUNTS_ROOT"/{aaa-late,zzz-soon,fresh,fresh.lock}
ahead 3 > "$CLAUDE_ACCOUNTS_ROOT/aaa-late/reset"
SOON=$(( $(date +%s) + 86400 )); ahead 1 > "$CLAUDE_ACCOUNTS_ROOT/zzz-soon/reset"
touch "$CLAUDE_ACCOUNTS_ROOT/zzz-soon/flaky"

"$CU" --json > "$S/out.json"
order=$(grep -o '"account":"[^"]*"' "$S/out.json" | cut -d'"' -f4 | tr '\n' ' ')
t "roster: lockfile dir is not an account" test "$order" = "fresh zzz-soon aaa-late "
t "idle: full headroom, marked idle" grep -q '"account":"fresh".*"week_left_pct":100,"week_resets":"idle".*"premium_left_pct":100' "$S/out.json"
t "flaky: one windowless reply is re-probed, not read as idle" grep -q '"account":"zzz-soon".*"premium_left_pct":0' "$S/out.json"
t "epochs: week and premium from the text; a session beyond one window has none" login_epochs "$S/out.json" zzz-soon "$SOON"
t "epochs: idle has none" test "$(epochs "$S/out.json" fresh)" = "null null null"
TZ=Asia/Tokyo XDG_CACHE_HOME="$S/cache-tokyo" "$CU" --json > "$S/tokyo.json"
t "epochs: the (UTC) clause wins over the process zone" same_epochs "$S/out.json" "$S/tokyo.json" fresh zzz-soon aaa-late
BR="$S/bare-root"; mkdir -p "$BR/bare"; ahead 2 > "$BR/bare/reset"
hour=$(( ( $(date +%s) / 3600 + 2 ) * 3600 ))
{ date -u -d "@$hour" '+%-I%p' 2>/dev/null || date -u -r "$hour" '+%-I%p'; } | tr '[:upper:]' '[:lower:]' > "$BR/bare/session"
env CLAUDE_ACCOUNTS_ROOT="$BR" XDG_CACHE_HOME="$S/cache-bare" "$CU" --json > "$S/bare.json"
t "epochs: a bare session hour is that hour on the observation's day" test "$(epochs "$S/bare.json" bare | cut -d' ' -f1)" = "$hour"
# Pinned clocks: a wall time a DST fall-back repeats (an hour in New York, half on Lord Howe, two at Troll) names
# no epoch, and neither does a weekly reset more than a week ahead, which only a misread year produces.
REAL_DATE=$(command -v date); mkdir -p "$S/pinned"
cat > "$S/pinned/date" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do case \$a in -d|--date*|-r|-j|-f) exec "$REAL_DATE" "\$@";; esac; done
if "$REAL_DATE" --version >/dev/null 2>&1; then exec "$REAL_DATE" -d "@\$PINNED_NOW" "\$@"; else exec "$REAL_DATE" -r "\$PINNED_NOW" "\$@"; fi
STUB
chmod +x "$S/pinned/date"
pinned() { local root=$1 now=$2; env PATH="$S/pinned:$PATH" PINNED_NOW="$now" CLAUDE_ACCOUNTS_ROOT="$root" XDG_CACHE_HOME="$root.cache" "$CU" --json; }
mkacct() { mkdir -p "$1"; echo "$2" > "$1/reset"; echo "$3" > "$1/zone"; }
DR="$S/dst-root"; mkacct "$DR/ny" "Nov 1, 1:30am" America/New_York; mkacct "$DR/near" "Nov 5, 9am" UTC; mkacct "$DR/far" "Nov 9, 9am" UTC
pinned "$DR" 1793507400 > "$S/dst.json"   # 2026-11-01 00:30 EDT: both of New York's 1:30ams lie inside the session window
LR="$S/lh-root"; mkacct "$LR/lh" "Apr 4, 1:45am" Australia/Lord_Howe
pinned "$LR" 1806624000 > "$S/lh.json"    # 2027-04-02 00:00 UTC; Lord Howe falls back half an hour on Apr 4
TR="$S/troll-root"; mkacct "$TR/troll" "Oct 25, 1:30am" Antarctica/Troll
pinned "$TR" 1792800000 > "$S/troll.json" # 2026-10-24 00:00 UTC; Troll falls back two hours on Oct 25
t "epochs: a reset in the hour a DST change repeats has none" test "$(epochs "$S/dst.json" ny)" = "null null null"
t "epochs: nor in the half hour Lord Howe repeats" test "$(epochs "$S/lh.json" lh)" = "null null null"
t "epochs: nor in the two hours Troll repeats" test "$(epochs "$S/troll.json" troll)" = "null null null"
t "epochs: a weekly reset within a week reads; one beyond has none" sh -c 'test "$1" = "null 1793869200 1793869200" && test "$2" = "null null null"' \
  _ "$(epochs "$S/dst.json" near)" "$(epochs "$S/dst.json" far)"
t "table: the CLI's comma is dropped from week resets" sh -c '"$1" > "$2" && grep -q "aaa-late" "$2" && ! grep -qE "[A-Z][a-z]{2} [0-9]{1,2}, " "$2"' _ "$CU" "$S/table.out"

"$CU" refresh
# --json --cached serves the snapshot: no /usage probe, no background refresh even when stale, exit 1 with nothing cached
u=$(wc -l < "$CALLS.usage"); CLAUDE_USAGE_TTL=0 "$CU" --json --cached > "$S/cached.json"; sleep 1
t "cached json: snapshot rows, never a probe or a refresh" sh -c 'test "$(wc -l < "$1")" -eq "$2" && grep -q "\"account\":\"aaa-late\"" "$3"' _ "$CALLS.usage" "$u" "$S/cached.json"
tn "cached json: no snapshot is an error" env XDG_CACHE_HOME="$S/cache-none" "$CU" --json --cached
t "cached json: no snapshot probes nothing either" test "$(wc -l < "$CALLS.usage")" -eq "$u"
TZ=Asia/Tokyo "$CU" --json --cached > "$S/cached-tokyo.json"
t "cached json: the same epochs in any zone" same_epochs "$S/cached.json" "$S/cached-tokyo.json" fresh zzz-soon aaa-late
# A PATH that finds every command $PATH finds but $1, as a user service sees it: dropping whole dirs
# would also drop the bash, jq or python3 a dir shares with the CLI.
without() {
  local d f dir="$S/without-$1" found entries="$PATH:"
  mkdir -p "$dir"
  local IFS=:
  # The extra ':' keeps a trailing empty entry; an empty or relative entry means the cwd, as in lookup.
  for d in $entries; do
    [[ $d == /* ]] || d=$PWD/$d
    found=()
    for f in "$d"/*; do [[ -f $f && -x $f && ! -e $dir/${f##*/} ]] && found+=("$f"); done
    ((${#found[@]})) && ln -s "${found[@]}" "$dir/"
  done
  rm -f "$dir/$1"
  printf '%s' "$dir"
}
NO_CLAUDE=$(without claude)
t "cached json: read with no claude CLI on PATH" sh -c 'env PATH="$1" "$2" --json --cached | grep -q "\"account\":\"aaa-late\""' _ "$NO_CLAUDE" "$CU"
t "json: a probe with no claude CLI on PATH dies naming it" sh -c '! env PATH="$1" "$2" --json > /dev/null 2> "$3" && grep -qx "claude CLI not on PATH" "$3"' _ "$NO_CLAUDE" "$CU" "$S/nocli.err"
# A v3 snapshot (14 columns) is carried into v4 once: no epochs, its note intact.
V3R="$S/v3-root"; mkdir -p "$V3R/carried"; ahead 2 > "$V3R/carried/reset"
v3() { env CLAUDE_ACCOUNTS_ROOT="$V3R" XDG_CACHE_HOME="$S/cache-v3" CLAUDE_USAGE_TTL=99999 "$CU" "$@"; }
v3 refresh
v4=$(ls "$S"/cache-v3/claude-usage/*/snapshot.v4.tsv); old="${v4%v4.tsv}v3.tsv"
awk -F'\t' -v OFS='\t' '{ $17 = "carried note"; print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$17 }' "$v4" > "$old" && rm "$v4"
v3 --json --cached > "$S/v3.json"
t "v3 snapshot: read with no epochs and its note" sh -c 'test "$1" = "null null null" && grep -q "\"account\":\"carried\".*\"note\":\"carried note\"" "$2"' _ "$(epochs "$S/v3.json" carried)" "$S/v3.json"
t "v3 snapshot: gone once carried, v4 in its place" sh -c 'test ! -e "$1" && test -s "$2"' _ "$old" "$v4"
t "describe: shows the note, not an epoch" grep -q "^claude-usage: carried — carried note$" <(v3 run carried -p x 2>&1 >/dev/null)
t "best: idle account wins" grep -q '^fresh (idle' <("$CU" best)
t "other: skips the caller's own account" test "$(CLAUDE_USAGE_MODEL=sonnet CLAUDE_CONFIG_DIR="$CLAUDE_ACCOUNTS_ROOT/fresh" "$CU" resolve other)" = zzz-soon
tn "other: Fable work refuses accounts with no Fable left" env CLAUDE_CONFIG_DIR="$CLAUDE_ACCOUNTS_ROOT/fresh" "$CU" resolve other
t "other: another caller still gets the overall best" test "$(CLAUDE_CONFIG_DIR="$CLAUDE_ACCOUNTS_ROOT/zzz-soon" "$CU" resolve other)" = fresh
tn "add: 'other' is reserved" "$CU" add other
t "current: names the caller's roster account" test "$(CLAUDE_CONFIG_DIR="$CLAUDE_ACCOUNTS_ROOT/fresh" "$CU" current)" = fresh
tn "other: an unknown caller is refused" env CLAUDE_CONFIG_DIR="$S" "$CU" resolve other
mkdir -p "$S/cold-root/a" "$S/cold-root/b"
t "other: with no snapshot yet, still skips the caller" test "$(CLAUDE_ACCOUNTS_ROOT="$S/cold-root" CLAUDE_CONFIG_DIR="$S/cold-root/a" "$CU" resolve other 2>/dev/null)" = b
rm -rf "$CLAUDE_ACCOUNTS_ROOT/fresh"
"$CU" refresh
t "best: no premium anywhere picks the soonest reset" grep -q '^zzz-soon (no Fable left' <("$CU" best)

tn "add: lockfile-shaped name refused" "$CU" add evil.lock

# --- token accounts -----------------------------------------------------------
TOK="sk-ant-oat01-Zq9_canaryTOKEN-$(printf 'a1B2%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)"
TA="$CLAUDE_ACCOUNTS_ROOT/tok-proton"
printf 'Your OAuth token (valid for 1 year):\n\n  %s\n\nStore it securely.\n' "$TOK" | "$CU" add tok-proton > "$S/add.out" 2>&1
t "add: setup-token output on stdin is saved" grep -qx "$TOK" "$TA/oauth-token"
t "add: token file is 0600" test "$(ls -l "$TA/oauth-token" | cut -c1-10)" = "-rw-------"
t "add: one success line with the expiry month" grep -q '^✓ tok-proton saved (token, expires ~[0-9]\{4\}-[0-9]\{2\})$' "$S/add.out"
"$CU" add tok-arg "$TOK" > "$S/arg.out" 2>&1; rc=$?
t "add: a token passed as an argument is refused" test "$rc" -ne 0 -a ! -e "$CLAUDE_ACCOUNTS_ROOT/tok-arg"
echo "not a token" | "$CU" add tok-junk > "$S/junk.out" 2>&1; rc=$?
t "add: junk on stdin is refused and creates nothing" test "$rc" -ne 0 -a ! -e "$CLAUDE_ACCOUNTS_ROOT/tok-junk"
printf '%s' "$TOK" | "$CU" add tok-two > /dev/null 2>&1

"$CU" refresh
{ cat "$S/add.out" "$S/arg.out" "$S/junk.out"; "$CU" list; "$CU" --json; "$CU"; "$CU" statusline; "$CU" best; "$CU" show tok-proton; } > "$S/all.out" 2>&1
tn "token: never printed by add/list/json/table/statusline/best/show" grep -q canaryTOKEN "$S/all.out"
t "token: list marks it with days left" grep -q 'tok-proton .*(token, 36[45]d left)' <("$CU" list)
t "token: table shows its expiry" grep -q 'token 36[45]d' <("$CU")
t "token: json carries days left" grep -q '"account":"tok-proton".*"plan":"token".*"token_days_left":36[45]' <("$CU" --json)

# --- run: credentials, env precedence, stack ----------------------------------
CLAUDE_CODE_OAUTH_TOKEN=stray ANTHROPIC_API_KEY=stray CLAUDE_CODE_USE_BEDROCK=1 "$CU" run tok-proton -p hi 2> "$S/run.err"
t "run token: the account's token reaches claude" grep -q "^dir=$TA token=$TOK apikey=unset bedrock=unset argv=-p hi\$" <(last)
t "run token: one stderr line, token not in it" sh -c 'test "$(wc -l < "$1")" -eq 1 && grep -q "^claude-usage: tok-proton — token, 36[45]d left" "$1" && ! grep -q canaryTOKEN "$1"' _ "$S/run.err"
CLAUDE_CODE_OAUTH_TOKEN=stray ANTHROPIC_API_KEY=stray "$CU" run aaa-late --model haiku 2> /dev/null
t "run login: stray credentials are stripped" grep -q "^dir=$CLAUDE_ACCOUNTS_ROOT/aaa-late token=unset apikey=unset bedrock=unset argv=--model haiku\$" <(last)
A="$CLAUDE_ACCOUNTS_ROOT/aaa-late"
t "stack: files link to the slot's paths" sh -c 'for f in CLAUDE.md AGENTS.md statusline.sh settings.json plugins; do [ "$(readlink "$1/$f")" = "$2/.claude/$f" ] || exit 1; done' _ "$A" "$HOME"
t "stack: skills linked one by one, synced/ left to the account" sh -c '[ -L "$1/skills/alpha" ] && [ -L "$1/skills/beta" ] && [ ! -e "$1/skills/synced" ]' _ "$A"

Z="$CLAUDE_ACCOUNTS_ROOT/zzz-soon"
echo "mine" > "$Z/CLAUDE.md"; mkdir -p "$Z/skills/alpha" "$Z/plugins/synced"; echo own > "$Z/skills/alpha/SKILL.md"
for _ in 1 2 3 4 5 6; do "$CU" run zzz-soon -p x 2> /dev/null & done; wait
t "stack: concurrent runs all reach claude" test "$(grep -c "^dir=$Z " "$CALLS")" -eq 6
t "stack: a real file is moved aside, not clobbered" sh -c 'grep -qx mine "$1"/.claude-usage-backup/*/CLAUDE.md && [ "$(readlink "$1/CLAUDE.md")" = "$2/.claude/CLAUDE.md" ]' _ "$Z" "$HOME"
t "stack: a real plugins dir is moved aside, then shared" sh -c '[ -d "$(echo "$1"/.claude-usage-backup/*/plugins/synced)" ] && [ "$(readlink "$1/plugins")" = "$2/.claude/plugins" ] && [ ! -e "$2/.claude/plugins/plugins" ]' _ "$Z" "$HOME"
t "stack: the account's own skill is left alone" grep -qx own "$Z/skills/alpha/SKILL.md"
t "stack: nothing written into the slot's skills" test "$(ls -A "$HOME/.claude/skills/alpha" | wc -l)" -eq 0
before=$(ls -A "$Z/.claude-usage-backup" | wc -l)
"$CU" run zzz-soon -p again 2> /dev/null
t "stack: relinking is a no-op" test "$(ls -A "$Z/.claude-usage-backup" | wc -l)" -eq "$before"
rm -rf "$HOME/.claude/skills/beta"
"$CU" run zzz-soon -p prune 2> /dev/null
t "stack: a skill gone from the slot is pruned" test ! -L "$Z/skills/beta"

# --- name resolution and clu ---------------------------------------------------
clu soon -p a 2> /dev/null
t "resolve: a unique part of a name" grep -q "^dir=$Z .*argv=--dangerously-skip-permissions -p a\$" <(last)
clu tok > /dev/null 2> "$S/amb.err"; rc=$?
t "resolve: ambiguous lists the candidates and fails" sh -c '[ "$1" -ne 0 ] && grep -q "tok-proton" "$2" && grep -q "tok-two" "$2"' _ "$rc" "$S/amb.err"
tn "resolve: no match fails" clu nobody -p x
CLAUDE_USAGE_MODEL=sonnet clu -p "say ok" 2> /dev/null
t "clu: a leading option means best + passthrough" grep -q "^dir=$Z .*argv=--dangerously-skip-permissions -p say ok\$" <(last)
CLAUDE_USAGE_MODEL=sonnet clu -- hello 2> /dev/null
t "clu: -- means best, the rest to claude" grep -q "^dir=$Z .*argv=--dangerously-skip-permissions hello\$" <(last)
clu soon --permission-mode plan -p b 2> /dev/null
t "clu: a permission mode of your own drops the bypass" grep -q "^dir=$Z .*argv=--permission-mode plan -p b\$" <(last)

# --- session carry and handoff ------------------------------------------------
SID=11111111-2222-4333-8444-555555555555 SID2=66666666-7777-4888-9999-000000000000
mkdir -p "$S/proj"; PK=$(cd "$S/proj" && pwd -P); PK=${PK//[^A-Za-z0-9]/-}
mkdir -p "$A/projects/$PK/$SID/subagents"; echo a1 > "$A/projects/$PK/$SID/subagents/s.jsonl"
echo '{"cwd":"'"$S/proj"'"}' > "$A/projects/$PK/$SID.jsonl"
(cd "$S/proj" && clu soon --resume "$SID" 2> /dev/null)
t "carry: --resume copies the session in from the account that holds it" cmp -s "$A/projects/$PK/$SID.jsonl" "$Z/projects/$PK/$SID.jsonl"
t "carry: its sidecar dir comes along" grep -qx a1 "$Z/projects/$PK/$SID/subagents/s.jsonl"
t "carry: the arguments reach claude unchanged" grep -q "^dir=$Z .*argv=--dangerously-skip-permissions --resume $SID\$" <(last)
echo newer-in-z >> "$Z/projects/$PK/$SID.jsonl"; touch -t 202001010000 "$A/projects/$PK/$SID.jsonl"
(cd "$S/proj" && clu soon --resume "$SID" 2> /dev/null)
t "carry: a newer copy already on the account is never overwritten" grep -qx newer-in-z "$Z/projects/$PK/$SID.jsonl"
echo diverged > "$A/projects/$PK/$SID.jsonl"
(cd "$S/proj" && clu soon --resume "$SID" 2> /dev/null)
t "carry: a copy with turns the newer one lacks is kept" grep -qx newer-in-z "$Z/projects/$PK/$SID.jsonl"
(cd "$S/proj" && clu soon -p -- --continue 2> /dev/null)
t "carry: arguments after -- are never read as flags" grep -q "^dir=$Z .*argv=--dangerously-skip-permissions -p -- --continue\$" <(last)
touch -t 201901010000 "$Z/projects/$PK/$SID.jsonl" "$A/projects/$PK/$SID.jsonl"; echo '{}' > "$A/projects/$PK/$SID2.jsonl"
(cd "$S/proj" && clu soon -c -p go 2> /dev/null)
t "carry: --continue resumes this folder's newest session from any account" sh -c 'grep -q "^dir=$1 .*argv=--dangerously-skip-permissions --resume $2 -p go\$" "$3" && test -f "$1/projects/$4/$2.jsonl"' _ "$Z" "$SID2" <(last) "$PK"
echo '{"type":"x"}'$'\n''{"cwd":"'"$S/proj"'"}' > "$A/projects/$PK/$SID.jsonl"
out=$(cd "$S" && CLAUDE_CODE_SESSION_ID=$SID CLAUDE_CONFIG_DIR="$A" "$CU" handoff zzz-soon 2> /dev/null)
t "handoff: prints the line that resumes this session there, from its own folder" grep -qF "cd $S/proj && clu =zzz-soon --resume $SID" <<< "$out"
tn "handoff: refuses outside a session" env -u CLAUDE_CODE_SESSION_ID "$CU" handoff zzz-soon

# --- ranking, rename, expiry --------------------------------------------------
touch "$A/spent" "$Z/spent"
"$CU" refresh
t "best: a token wins once every known account is spent" grep -q '^tok-proton (token account' <("$CU" best)
mkdir -p "$S/other-root/only" "$S/other-root/spent-one"; ahead 2 > "$S/other-root/spent-one/reset"; touch "$S/other-root/spent-one/spent"
CLAUDE_ACCOUNTS_ROOT="$S/other-root" "$CU" refresh
tn "other: a spent alternative is refused, not used as a fallback" env CLAUDE_ACCOUNTS_ROOT="$S/other-root" CLAUDE_CONFIG_DIR="$S/other-root/only" "$CU" resolve other
mkdir -p "$S/other-root/other"
tn "other: a legacy account named other is refused" env CLAUDE_ACCOUNTS_ROOT="$S/other-root" CLAUDE_CONFIG_DIR="$S/other-root/only" "$CU" resolve other
CLAUDE_ACCOUNTS_ROOT="$S/other-root" "$CU" rename other spare > /dev/null 2>&1
CLAUDE_ACCOUNTS_ROOT="$S/other-root" "$CU" refresh
t "other: after the rename the selector works again" env CLAUDE_ACCOUNTS_ROOT="$S/other-root" CLAUDE_CONFIG_DIR="$S/other-root/only" "$CU" resolve other
t "literal: =<key> reaches a renamed account by its key" test "$(CLAUDE_ACCOUNTS_ROOT="$S/other-root" "$CU" resolve =other)" = other
tn "literal: =<key> refuses an unknown key" "$CU" resolve =nobody
"$CU" rename tok-proton tp > /dev/null
"$CU" run tp -p r 2> /dev/null
t "rename: the token stays with the account" grep -q "^dir=$TA token=$TOK .*argv=-p r\$" <(last)
T2="$CLAUDE_ACCOUNTS_ROOT/tok-two"
echo $(( $(date +%s) - 340 * 86400 )) > "$T2/oauth-token.added"
t "expiry: table warns in the last month" grep -q '⚠ tok-two token 2[45]d left' <("$CU")
"$CU" refresh
t "expiry: statusline warns in the last month" grep -q '⚠ tok-two token 2[45]d left' <("$CU" statusline)
echo $(( $(date +%s) - 366 * 86400 )) > "$T2/oauth-token.added"
"$CU" rename tp tp2 > /dev/null   # keep tok-two the only token left once tp2 expires too
echo $(( $(date +%s) - 366 * 86400 )) > "$TA/oauth-token.added"
"$CU" refresh
t "expiry: an expired token is marked" grep -q 'token EXPIRED' <("$CU")
t "expiry: statusline says expired" grep -q '⚠ tok-two token expired' <("$CU" statusline)
t "expiry: best skips expired tokens" sh -c '! "$1" best | grep -q "token account"' _ "$CU"
tn "expiry: run refuses an expired token" "$CU" run tok-two -p x

tn "rename: 'best' is reserved" "$CU" rename tp2 best
ln -s "$HOME/.claude" "$CLAUDE_ACCOUNTS_ROOT/alias"
"$CU" run alias -p x > /dev/null 2>&1; rc=$?
t "run: a home symlinked to the slot is refused, slot untouched" sh -c '[ "$1" -ne 0 ] && [ -f "$2/.claude/settings.json" ] && [ ! -L "$2/.claude/settings.json" ]' _ "$rc" "$HOME"
rm "$CLAUDE_ACCOUNTS_ROOT/alias"

"$CU" remove tok-two > "$S/rm.out" 2>&1
t "remove: deletes the token with the account" sh -c '[ ! -e "$1" ] && grep -q "token file deleted" "$2"' _ "$T2" "$S/rm.out"

# --- token usage probe and slot pairing --------------------------------------
mktok() { printf 'sk-ant-oat01-%s-%s' "$1" "$(printf 'q%.0s' $(seq 60))"; }
reply() { local f; f="$NET/$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; shift; printf '%s\n' "$@" > "$f"; }
H=anthropic-ratelimit-unified
TK_FREE=$(mktok free) TK_PAIR=$(mktok pair) TK_DEAD=$(mktok dead)
R5=$(( $(date +%s) + 3600 )) R7=$(( $(date +%s) + 86400 ))
reply "$TK_FREE" 200 "anthropic-organization-id: org-free" "$H-5h-utilization: 0.08" "$H-5h-reset: $R5" \
  "$H-7d-utilization: 0.61" "$H-7d-reset: $R7" "$H-7d_oi-utilization: 0.34" "$H-7d_oi-reset: $R7"
reply "$TK_PAIR" 200 "anthropic-organization-id: org-main" "$H-5h-utilization: 0.5" "$H-7d-utilization: 0.5"
reply "$TK_DEAD" 401 "request-id: req_x"
NR="$S/net-root"
for a in free pair dead; do v="TK_$(tr '[:lower:]' '[:upper:]' <<< "$a")"; printf '%s' "${!v}" | CLAUDE_ACCOUNTS_ROOT="$NR" "$CU" add "tk-$a" > /dev/null 2>&1; done
: > "$NET/argv"
nr() { env -u CLAUDE_USAGE_SKIP_MAIN CLAUDE_ACCOUNTS_ROOT="$NR" XDG_CACHE_HOME="$S/cache-net" "$CU" "$@"; }
nr --json > "$S/net.json"
t "probe: headers become session, week and premium headroom" grep -q '"account":"tk-free".*"plan":"token","session_left_pct":92,.*"week_left_pct":39,.*"premium_model":"Fable","premium_left_pct":66' "$S/net.json"
t "probe: the token goes to curl on stdin, never in argv" sh -c 'test -s "$1" && ! grep -q sk-ant "$1"' _ "$NET/argv"
t "epochs: a token reading's are its reply's headers" test "$(epochs "$S/net.json" tk-free)" = "$R5 $R7 $R7"
t "probe: a rejected token is marked unusable" grep -q '"account":"tk-dead".*"note":"token rejected (HTTP 401)' "$S/net.json"
t "pairing: a token sharing the slot's personal org is the active row" sh -c 'grep -q "\"account\":\"tk-pair\",\"active\":true" "$1" && ! grep -q "\"account\":\"main\"" "$1"' _ "$S/net.json"
f=$(ls "$S"/cache-net/claude-usage/*/token-tk-pair.tsv); awk -F'\t' -v OFS='\t' -v o=$(( $(date +%s) - 3600 )) '{ $3 = o; print }' "$f" > "$f.n" && mv "$f.n" "$f"
t "pairing: a newer slot reading supplies the numbers" grep -q '"account":"tk-pair".*"week_resets":"idle"' <(CLAUDE_USAGE_TTL=99999 nr --json)
nr refresh
t "pairing: current names it from the slot" test "$(nr current)" = tk-pair
calls=$(wc -l < "$NET/argv")
nr --json > /dev/null
t "probe: a reading is reused within the TTL" test "$(wc -l < "$NET/argv")" -eq "$calls"
t "table: a session shows its 5h reset time" grep -qE 'tk-free +│[^│]*│ +92%  ([A-Z][a-z]{2} [0-9]{1,2} )?[0-9]{1,2}(:[0-9]{2})?[ap]m' <(CLAUDE_USAGE_TTL=99999 nr)
f=$(ls "$S"/cache-net/claude-usage/*/token-tk-free.tsv); awk -F'\t' -v OFS='\t' -v r=$(( $(date +%s) - 60 )) '{ $7 = r; print }' "$f" > "$f.n" && mv "$f.n" "$f"
t "table: a passed 5h reset reads as reset" grep -qE 'tk-free +│[^│]*│ +92%  reset +│' <(CLAUDE_USAGE_TTL=99999 nr)
awk -F'\t' -v OFS='\t' -v r=$(( $(date +%s) + 86400 * 300 )) '{ $7 = r; print }' "$f" > "$f.n" && mv "$f.n" "$f"
t "table: a reset beyond one window shows no time" grep -qE 'tk-free +│[^│]*│ +92% +│' <(CLAUDE_USAGE_TTL=99999 nr)
echo team > "$HOME/.claude/plan"
t "pairing: never by org on a team plan" grep -q '"account":"main","active":true' <(nr --json)
rm -f "$HOME/.claude/plan"
t "probe: no proxy, and no TLS key log reaches curl" sh -c 'grep -q -- "--noproxy \*" "$1" && ! grep -q "keylog=/" "$1"' _ "$NET/argv"
{ SSLKEYLOGFILE=/k XDG_CACHE_HOME="$S/cache-x" bash -x "$CU_BIN" --json; printf '%s' "$TK_FREE" | XDG_CACHE_HOME="$S/cache-x" bash -x "$CU_BIN" add tk-free;
  XDG_CACHE_HOME="$S/cache-x" bash -x "$CU_BIN" show tk-free; XDG_CACHE_HOME="$S/cache-x" bash -x "$CU_BIN" run tk-free -p x; } > "$S/xt.out" 2>&1 \
  < /dev/null
t "xtrace: a traced probe, add, show and run never print the token" sh -c 'grep -q "token_fetch" "$1" && ! grep -q "oat01-free" "$1"' _ "$S/xt.out"
calls=$(wc -l < "$NET/argv")
nr --json > /dev/null; nr --json > /dev/null
t "probe: a failed probe backs off for one TTL" test "$(wc -l < "$NET/argv")" -eq "$calls"
printf '%s' "$TK_FREE" | CLAUDE_ACCOUNTS_ROOT="$NR" "$CU" add tk-free > /dev/null 2>&1
nr --json > /dev/null
t "probe: a re-added token is a new credential, probed afresh" test "$(wc -l < "$NET/argv")" -eq $((calls + 1))
f=$(ls "$S"/cache-net/claude-usage/*/token-tk-free.tsv); old=$(( $(date +%s) - 7200 ))
awk -F'\t' -v OFS='\t' -v o="$old" '{ $3 = o; print }' "$f" > "$f.n" && mv "$f.n" "$f"
calls=$(wc -l < "$NET/argv")
_CLAUDE_USAGE_PASSIVE=1 nr refresh
CLAUDE_USAGE_TTL=99999 nr --json > "$S/pass.json"
t "passive refresh: never probes, rows keep the reading's own age" sh -c 'test "$(wc -l < "$1")" -eq "$2" && grep -q "\"account\":\"tk-free\".*\"observed_at\":$3" "$4"' \
  _ "$NET/argv" "$calls" "$old" "$S/pass.json"
calls=$(wc -l < "$NET/argv"); CLAUDE_USAGE_TTL=0 nr --json --cached > "$S/net-cached.json"
t "cached json: token rows from their cached reading, never probed" sh -c 'test "$(wc -l < "$1")" -eq "$2" && grep -q "\"account\":\"tk-free\"" "$3"' _ "$NET/argv" "$calls" "$S/net-cached.json"
t "statusline: an old token reading is marked stale" grep -q stale <(CLAUDE_CONFIG_DIR="$NR/tk-free" nr statusline)

# Ranking and exhaustion, on tokens alone: <name> <session used> <week used> <fable used> [status].
RK="$S/rank-root"
rk() { env CLAUDE_ACCOUNTS_ROOT="$RK" XDG_CACHE_HOME="$S/cache-rk" "$CU" "$@"; }
tokacct() {
  local tk; tk=$(mktok "$1")
  reply "$tk" "${6:-200}" "anthropic-organization-id: org-$5" "$H-5h-utilization: $2" "$H-7d-utilization: $3" \
    "$H-7d-reset: $(( $(date +%s) + 86400 ))" "$H-7d_oi-utilization: $4" "$H-7d_oi-status: ${7:-allowed}"
  printf '%s' "$tk" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add "$1" > /dev/null 2>&1
}
tokacct lopsided 0.02 0.98 0.0 a
tokacct even 0.0 0.0 0.0 b
t "rank: the tightest bucket binds, 98/2/100 below 100/100/100" test "$(rk resolve best 2>/dev/null)" = even
rm -rf "${RK:?}"/*
tokacct weekzero 0.0 1.0 0.0 c
mkdir -p "$RK/unmeasured" && printf '%s' "$(mktok nowhere)" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add unmeasured > /dev/null 2>&1
t "exhausted: an unmeasured token beats a known-spent one" test "$(rk resolve best 2>/dev/null)" = unmeasured
tn "exhausted: other never offers a known-spent token" env CLAUDE_CONFIG_DIR="$RK/unmeasured" CLAUDE_ACCOUNTS_ROOT="$RK" XDG_CACHE_HOME="$S/cache-rk" "$CU" resolve other
rm -rf "${RK:?}"/*
tk=$(mktok limited)
reply "$tk" 429 "$H-7d-utilization: 0.0" "HTTP/2 429" "anthropic-organization-id: org-d" "$H-5h-utilization: 0.1" "$H-7d-utilization: 0.2" \
  "$H-7d_sonnet-utilization: 0.0" "$H-7d_oi-utilization:  0.3 " "$H-7d_oi-status: rejected"
printf '%s' "$tk" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add limited > /dev/null 2>&1
t "headers: final block, exact Fable bucket, a rejected status spends it" grep -q '"account":"limited".*"week_left_pct":80,.*"premium_left_pct":0' <(rk --json)
tk=$(mktok down); reply "$tk" 503 "$H-5h-utilization: 0.1" "$H-7d-utilization: 0.2"
printf '%s' "$tk" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add down > /dev/null 2>&1
t "headers: a 5xx is a failed observation, no numbers" grep -q '"account":"down".*"session_left_pct":null' <(rk --json)
rm -rf "${RK:?}"/*
touch "$NET/slow"; tokacct solo 0.1 0.1 0.1 e; rm -rf "$S/cache-rk"; : > "$NET/argv"
for _ in 1 2 3; do rk --json > /dev/null & done; wait; rm -f "$NET/slow"
t "lock: concurrent tables probe an account once" test "$(wc -l < "$NET/argv")" -eq 1

# Aliases: the caller's own quota under another credential is not "other".
AL="$S/alias-root"; mkdir -p "$AL/lg"; ahead 2 > "$AL/lg/reset"
al() { env CLAUDE_ACCOUNTS_ROOT="$AL" XDG_CACHE_HOME="$S/cache-al" "$CU" "$@"; }
RK="$AL"; tokacct tk-lg 0.0 0.0 0.0 lg; tokacct tk-other 0.5 0.5 0.5 zz
t "alias: other skips a token in the caller's organization" test "$(CLAUDE_USAGE_MODEL=sonnet CLAUDE_CONFIG_DIR="$AL/lg" al resolve other 2>/dev/null)" = tk-other

pv() { env CLAUDE_ACCOUNTS_ROOT="$AL" XDG_CACHE_HOME="$S/cache-pv" "$CU" "$@"; }
_CLAUDE_USAGE_PASSIVE=1 pv refresh; pv --json > /dev/null
t "snapshot: a table's fresh readings replace a passive snapshot's blanks" grep -q '^tk-lg (' <(CLAUDE_USAGE_MODEL=sonnet pv best)


# Round two: required buckets, refusal and transfer classification, snapshot
# consistency, a dead alias of the slot, lock bounds, team organizations.
RK="$S/r2-root"; mkdir -p "$RK"
rk() { env CLAUDE_ACCOUNTS_ROOT="$RK" XDG_CACHE_HOME="$S/cache-r2" "$CU" "$@"; }
tokacct ninety 0.1 0.1 0.1 n1
tk=$(mktok nofable); reply "$tk" 200 "$H-5h-utilization: 0.0" "$H-7d-utilization: 0.0"
printf '%s' "$tk" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add nofable > /dev/null 2>&1
t "required: Fable work ranks 100/100/unknown below 90/90/90" test "$(rk resolve best 2>/dev/null)" = ninety
rm -rf "${RK:?}"/* "$S/cache-r2"
tk=$(mktok bare429); reply "$tk" 429 "request-id: r"
printf '%s' "$tk" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add bare429 > /dev/null 2>&1
printf '%s' "$(mktok offline)" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add offline > /dev/null 2>&1
t "classify: a 429 without headers is spent, not unknown" test "$(rk resolve best 2>/dev/null)" = offline
tk=$(mktok cut); reply "$tk" 200 "$H-5h-utilization: 0.0" "$H-7d-utilization: 0.0" "$H-7d_oi-utilization: 0.0"
echo 28 > "$NET/$(printf '%s' "$tk" | cksum | cut -d' ' -f1).exit"
printf '%s' "$tk" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add cut > /dev/null 2>&1
t "classify: curl timing out after 200 headers is a failed observation" grep -q '"account":"cut".*"session_left_pct":null' <(rk --json)
rm -rf "${RK:?}"/* "$S/cache-r2"
tk=$(mktok fading); tokacct fading 0.0 0.0 0.0 f1; tokacct spare 0.5 0.5 0.5 f2
rk refresh
t "consistency: setup, the fresh account is best" test "$(rk resolve best)" = fading
reply "$tk" 401 "request-id: r"
f=$(ls "$S"/cache-r2/claude-usage/*/token-fading.tsv)
awk -F'\t' -v OFS='\t' '{ $3 = 1; print }' "$f" > "$f.n" && mv "$f.n" "$f"
rk show fading > /dev/null; _CLAUDE_USAGE_PASSIVE=1 rk refresh
t "consistency: a token show found revoked is never picked after" test "$(rk resolve best)" = spare
rm -rf "${RK:?}"/* "$S/cache-r2"
tk=$(mktok mine); reply "$tk" 200 "anthropic-organization-id: org-main" "$H-5h-utilization: 0.0" "$H-7d-utilization: 0.0" "$H-7d_oi-utilization: 0.0"
printf '%s' "$tk" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add mine > /dev/null 2>&1
rkm() { env -u CLAUDE_USAGE_SKIP_MAIN CLAUDE_ACCOUNTS_ROOT="$RK" XDG_CACHE_HOME="$S/cache-r2" "$CU" "$@"; }
rkm --json > /dev/null
reply "$tk" 401 "request-id: r"
f=$(ls "$S"/cache-r2/claude-usage/*/token-mine.tsv); awk -F'\t' -v OFS='\t' '{ $3 = 1; print }' "$f" > "$f.n" && mv "$f.n" "$f"
rkm --json > "$S/dead.json"
t "dead alias: main stays the active, usable row" sh -c 'grep -q "\"account\":\"main\",\"active\":true" "$1" && grep -q "\"account\":\"mine\",\"active\":false" "$1"' _ "$S/dead.json"
t "dead alias: best launches main" test "$(rkm resolve best 2>/dev/null)" = main
rm -rf "${RK:?}"/*; tokacct locked 0.1 0.1 0.1 l1
: > "$S/notadir"
t "lock: an unwritable cache dir fails fast with a reason" grep -q 'cache dir not writable' <(env CLAUDE_ACCOUNTS_ROOT="$RK" XDG_CACHE_HOME="$S/notadir" "$CU" show locked)
d=$(rk refresh > /dev/null 2>&1; ls -d "$S"/cache-r2/claude-usage/*/)
rm -f "$d"token-locked.tsv; mkdir -p "$d"token-locked.tsv.lock; echo 999999 > "$d"token-locked.tsv.lock/pid
: > "$NET/argv"
rk show locked > /dev/null
t "lock: a dead holder's lock is reclaimed, then released" sh -c 'test "$(wc -l < "$1")" -eq 1 && [ ! -e "$2" ]' _ "$NET/argv" "$d"token-locked.tsv.lock
TM="$S/team-root"; mkdir -p "$TM/t1" "$TM/t2"
for a in t1 t2; do echo team > "$TM/$a/plan"; echo org-team > "$TM/$a/org"; ahead 2 > "$TM/$a/reset"; done
t "team: the same team organization with another email is still other" test "$(CLAUDE_USAGE_MODEL=sonnet CLAUDE_CONFIG_DIR="$TM/t1" CLAUDE_ACCOUNTS_ROOT="$TM" XDG_CACHE_HOME="$S/cache-tm" "$CU" resolve other 2>/dev/null)" = t2


# Round three: an older slot reading never undoes a newer refusal; show copes with a bare 429.
rm -rf "${RK:?}"/* "$S/cache-r2"
tokacct spare2 0.5 0.5 0.5 s2
tk=$(mktok spentmine); reply "$tk" 200 "anthropic-organization-id: org-main" "$H-5h-utilization: 1.0" "$H-7d-utilization: 1.0" "$H-7d_oi-utilization: 1.0"
printf '%s' "$tk" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add spentmine > /dev/null 2>&1
rkm refresh
f=$(ls "$S"/cache-r2/claude-usage/*/snapshot.v4.tsv)
awk -F'\t' -v OFS='\t' '$2 == "main" { $13 = 1 } { print }' "$f" > "$f.n" && mv "$f.n" "$f"
t "pairing: an older slot reading never revives a newer spent token" test "$(rkm resolve best 2>/dev/null)" = spare2
tk=$(mktok bareshow); reply "$tk" 429 "request-id: r"
printf '%s' "$tk" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add bareshow > /dev/null 2>&1
t "show: a bare 429 prints as refused, unknown numbers, no crash" sh -c '"$@" > "$0" 2>&1 && grep -q "^refused" "$0" && grep -q "Current session: unknown" "$0"' "$S/show.out" env CLAUDE_ACCOUNTS_ROOT="$RK" XDG_CACHE_HOME="$S/cache-r2" "$CU" show bareshow

# --- account-home config: onboarding seed, prepare, reservations ---------------
PR="$S/prep-root"; mkdir -p "$PR"/{pa,pb,pd,pe} "$S/trusted/sub" "$S/trusted/sub2" "$S/trusted-evil" "$S/trusted/a#b"
ln -s "$PR/pa" "$PR/pc"
pp() { env CLAUDE_ACCOUNTS_ROOT="$PR" XDG_CACHE_HOME="$S/cache-pp" "$CU" "$@"; }
ino() { ls -i "$1" | awk '{print $1}'; }
# Claude Code's procStart form: /proc stat field 22 on Linux, C-locale UTC lstart elsewhere.
pstart() {
  if [ -r "/proc/$1/stat" ]; then sed 's/.*) //' "/proc/$1/stat" | awk '{print $20}'
  else LC_ALL=C TZ=UTC ps -o lstart= -p "$1" | tr -s ' ' | sed 's/^ //;s/ $//'; fi
}
TR="$(cd "$S/trusted" && pwd -P)"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$TR" > "$HOME/.claude.json"
printf '{"keep":1,"lastOnboardingVersion":"1.0"}\n' > "$PR/pa/.claude.json"
pp run pa -p x > /dev/null 2>&1
t "seed: run marks onboarding done, keeps every existing key" jq -e '.hasCompletedOnboarding == true and .keep == 1 and .lastOnboardingVersion == "1.0"' "$PR/pa/.claude.json"
pp run pe -p x > /dev/null 2>&1
t "seed: a fresh home gets the running claude's version" jq -e '.lastOnboardingVersion == "9.9.9"' "$PR/pe/.claude.json"
i1=$(ino "$PR/pa/.claude.json"); pp run pa -p x > /dev/null 2>&1
t "seed: a second run writes nothing" test "$(ino "$PR/pa/.claude.json")" = "$i1"
pp prepare pa "$S/trusted/sub" > /dev/null 2>&1
t "prepare: trust under a trusted ancestor lands on the exact physical dir" jq -e --arg p "$TR/sub" '.projects[$p].hasTrustDialogAccepted == true' "$PR/pa/.claude.json"
tn "prepare: a sibling sharing the prefix is not covered" pp prepare pa "$S/trusted-evil"
tn "prepare: a dir with '#' is refused" pp prepare pa "$S/trusted/a#b"
tn "prepare: a symlinked home is refused" pp prepare =pc "$S/trusted/sub"
echo '{bad' > "$PR/pb/.claude.json"
tn "prepare: a malformed .claude.json is refused" pp prepare pb "$S/trusted/sub"
t "prepare: ...and left as it was" grep -qx '{bad' "$PR/pb/.claude.json"
pp prepare main "$S/trusted/sub2" > /dev/null 2>&1
t "prepare: main writes ~/.claude.json after the same check" jq -e --arg p "$TR/sub2" '.projects[$p].hasTrustDialogAccepted == true' "$HOME/.claude.json"
pp prepare pd "$S/trusted/sub" > /dev/null 2>&1 & pp prepare pd "$S/trusted/sub2" > /dev/null 2>&1 & wait
t "prepare: two in parallel keep both trust entries" jq -e --arg a "$TR/sub" --arg b "$TR/sub2" '.projects[$a] and .projects[$b]' "$PR/pd/.claude.json"
# A live session: a sleeping process registered the way Claude Code does it.
sleep 300 & LIVE=$!
mkdir -p "$PR/pa/sessions"; printf '{"pid":%s,"procStart":"%s"}\n' "$LIVE" "$(pstart "$LIVE")" > "$PR/pa/sessions/$LIVE.json"
pp prepare pa "$S/trusted/sub2" > /dev/null 2>&1; rc=$?
t "busy: a needed write exits 2 while a session lives" test "$rc" -eq 2
t "busy: a write that changes nothing still succeeds" pp prepare pa "$S/trusted/sub"
printf '{"pid":%s,"procStart":"Mon Jan  1 00:00:00 2001"}\n' "$LIVE" > "$PR/pa/sessions/$LIVE.json"
t "busy: a recycled pid (other start time) is not a live session" pp prepare pa "$S/trusted/sub2"
rm -f "$PR/pa/sessions/$LIVE.json"
mkdir -p "$PR/pd/.launching"; printf '%s %s\n' "$LIVE" "$(pstart "$LIVE")" > "$PR/pd/.launching/live1"; echo "999999 Mon Jan  1 00:00:00 2001" > "$PR/pd/.launching/dead1"
mkdir -p "$S/trusted/sub3"
pp prepare pd "$S/trusted/sub3" > /dev/null 2>&1; rc=$?
t "reserve: a live launch reservation blocks a needed write" test "$rc" -eq 2
t "reserve: a dead reservation is pruned" test ! -e "$PR/pd/.launching/dead1"
rm -f "$PR/pd/.launching/live1"
pp prepare pd "$S/trusted/sub3" --hold L1 "$LIVE" > /dev/null 2>&1
t "reserve: --hold creates the reservation with the write" grep -q "^$LIVE " "$PR/pd/.launching/L1"
tn "reserve: a launch id is never reused" pp prepare pd "$S/trusted/sub3" --hold L1 "$LIVE"
tn "reserve: only the owner may extend it" pp hold pd L1 $$ "$LIVE"
t "reserve: the owner extends it" pp hold pd L1 "$LIVE" $$
t "reserve: ...with the new process's line" grep -q "^$$ " "$PR/pd/.launching/L1"
tn "reserve: only the owner may release it" pp release pd L1 $$
t "reserve: the owner releases it" sh -c '"$@" && [ ! -e "$0" ]' "$PR/pd/.launching/L1" env CLAUDE_ACCOUNTS_ROOT="$PR" XDG_CACHE_HOME="$S/cache-pp" "$CU" release pd L1 "$LIVE"
LK="$PR/pd/.claude-usage-config.lock"; mkdir "$LK"; printf '%s %s\n' "$LIVE" "$(pstart "$LIVE")" > "$LK/holder"
pp prepare pd "$S/trusted/sub" --hold L2 "$LIVE" > /dev/null 2>&1; rc=$?
t "lock: a live holder makes prepare give up with exit 2" test "$rc" -eq 2
echo "999999 Mon Jan  1 00:00:00 2001" > "$LK/holder"
pp prepare pd "$S/trusted/sub" > "$S/lk1" 2>&1 & p1=$!
pp prepare pd "$S/trusted/sub" > "$S/lk2" 2>&1 & p2=$!
wait "$p1" "$p2"
t "lock: a dead holder is never stolen, by either of two callers" sh -c 'grep -q "no longer running" "$0" && grep -q "no longer running" "$1" && grep -q "^999999 " "$2/holder"' "$S/lk1" "$S/lk2" "$LK"
t "lock: the printed recovery clears it and prepare then succeeds" sh -c 'eval "$(sed -n "s/^  //p" "$0")" && "$@"' "$S/lk1" env CLAUDE_ACCOUNTS_ROOT="$PR" XDG_CACHE_HOME="$S/cache-pp" "$CU" prepare pd "$S/trusted/sub"
mkdir "$LK"
pp prepare pd "$S/trusted/sub" > "$S/lk3" 2>&1; rc=$?
t "lock: a lock with no holder record gets the same recovery, never a steal" sh -c '[ "$0" -eq 2 ] && grep -q "no holder record" "$1" && [ -d "$2" ]' "$rc" "$S/lk3" "$LK"
t "lock: ...which clears it" sh -c 'eval "$(sed -n "s/^  //p" "$0")" && "$@"' "$S/lk3" env CLAUDE_ACCOUNTS_ROOT="$PR" XDG_CACHE_HOME="$S/cache-pp" "$CU" prepare pd "$S/trusted/sub"
kill "$LIVE" 2> /dev/null

# --- reviewer scripts ---------------------------------------------------------
echo "review this" > "$S/prompt"; mkdir -p "$S/repo"
echo $(( $(date +%s) - 10 * 86400 )) > "$TA/oauth-token.added"
CLAUDE_ACCOUNT=tp2 "$RUNC" "$S/prompt" "$S/repo" low read-only haiku > "$S/rv.out" 2> /dev/null
CD=$(sed -n 's/^CLAUDE_DIR=//p' "$S/rv.out")
t "reviewer: CLAUDE_ACCOUNT reaches the token account" grep -q "^dir=$TA token=$TOK .*--safe-mode" <(last)
t "reviewer: the account is recorded for resume" test "$(cat "$CD/account")" = tok-proton
CLAUDE_ACCOUNT=soon "$RESC" "" "$S/prompt" "$CD" low > /dev/null 2>&1
t "reviewer: resume stays on the recorded account" grep -q "^dir=$TA token=$TOK .*--resume $(cat "$CD/session_id")" <(last)
mkdir -p "$S/nouuid"; printf '#!/bin/sh\nexit 127\n' > "$S/nouuid/uuidgen"; chmod +x "$S/nouuid/uuidgen"
PATH="$S/nouuid:$PATH" CLAUDE_ACCOUNT=tp2 "$RUNC" "$S/prompt" "$S/repo" low read-only haiku > "$S/nu.out" 2> /dev/null
t "reviewer: a missing uuidgen falls back to another id source" grep -qE '^SESSION_ID=[0-9a-f-]{36}$' "$S/nu.out"
t "reviewer: the sandbox is recorded per session before launch" test "$(cat "$XDG_STATE_HOME/claude-consult/sessions/$(cat "$CD/session_id")")" = read-only
CLAUDE_ACCOUNT=tp2 "$RUNC" "$S/prompt" "$S/repo" low web-read haiku > "$S/wr.out" 2> /dev/null
WSID=$(sed -n 's/^SESSION_ID=//p' "$S/wr.out")
"$RESC" "$WSID" "$S/prompt" > /dev/null 2>&1
t "reviewer: a bare-UUID resume of a web session keeps web tools only" grep -q -- "--resume $WSID .*--tools WebSearch,WebFetch" <(last)
: > "$XDG_STATE_HOME/claude-consult/sessions/$WSID"
tn "reviewer: an empty sandbox record is refused, not read as legacy" "$RESC" "$WSID" "$S/prompt"
mkdir -p "$Z/projects/p"; touch "$Z/projects/p/99999999-2222-3333-4444-555555555555.jsonl"
"$RESC" 99999999-2222-3333-4444-555555555555 "$S/prompt" > /dev/null 2>&1
t "reviewer: a UUID-only resume finds the account by its transcript" grep -q "^dir=$Z .*--resume 99999999" <(last)
CLAUDE_CODE_OAUTH_TOKEN=stray CLAUDE_ACCOUNTS_ROOT="$S/empty" XDG_CACHE_HOME="$S/cache2" "$RUNC" "$S/prompt" "$S/repo" low > /dev/null 2> "$S/fb.err"; rc=$?
CD=$(ls -td "$TMPDIR"/claude-* | head -1)
t "reviewer: no best account falls back to ~/.claude, stray creds stripped" sh -c '[ "$1" -eq 0 ] && grep -q "^dir=unset token=unset" "$2" && grep -q "^NOTE: claude-usage found no best account" "$3" && [ "$(cat "$4/account")" = main ]' _ "$rc" <(last) "$S/fb.err" "$CD"
tn "reviewer: an unknown CLAUDE_ACCOUNT is a usage error" env CLAUDE_ACCOUNT=nobody "$RUNC" "$S/prompt" "$S/repo" low

# --- codex-usage --json --cached ----------------------------------------------
mkdir -p "$S/cxbin"; printf '#!/usr/bin/env bash\necho "$*" >> "%s/cx.calls"\nexit 1\n' "$S" > "$S/cxbin/codex"; chmod +x "$S/cxbin/codex"; : > "$S/cx.calls"
cx() { env PATH="$S/cxbin:$PATH" CODEX_ACCOUNTS_ROOT="$S/cx-accounts" XDG_CACHE_HOME="$S/cache-cx" CODEX_USAGE_TTL=0 "$ROOT/bin/codex-usage" "$@"; }
mkdir -p "$S/cx-accounts/cx-a"; tn "codex cached json: no snapshot is an error" cx --json --cached
d="$S/cache-cx/codex-usage/$(printf '%s' "$(cd "$S/cx-accounts" && pwd -P)" | cksum | cut -d' ' -f1)"; mkdir -p "$d"
printf 'k\tcx-a\ta@x\tplus\t40\t%s\t90\t%s\t-\tfalse\t%s\t0\t-\n' "$(( $(date +%s) + 86400 ))" "$(( $(date +%s) + 3600 ))" "$(date +%s)" > "$d/snapshot.tsv"
cx --json --cached > "$S/cx.json"; sleep 1
t "json: every --json reply parses strictly" test ! -s "$S/badjson"
t "codex cached json: snapshot rows, never a probe or a refresh" sh -c 'grep -q "\"account\":\"cx-a\".*\"week_left_pct\":40" "$1" && ! test -s "$2"' _ "$S/cx.json" "$S/cx.calls"
t "codex cached json: read with no codex CLI on PATH" sh -c 'env PATH="$1" CODEX_ACCOUNTS_ROOT="$2" XDG_CACHE_HOME="$3" "$4" --json --cached | grep -q "\"account\":\"cx-a\""' _ "$(without codex)" "$S/cx-accounts" "$S/cache-cx" "$ROOT/bin/codex-usage"

# --- lib/usage.sh ---------------------------------------------------------------
# The helpers, sourced bare: "main=" is a pre-roster slot alias, k2's label is empty, the last line has no newline.
printf 'main=old\nk1=one\nk10=ten\nk2=\nk3=three' > "$S/labels.conf"
lib() { bash -uc 'die() { printf "%s\n" "$*" >&2; exit 1; }; LABELS_FILE=$1; . "$2"; shift 2; "$@"' _ "$S/labels.conf" "$ROOT/lib/usage.sh" "$@"; }
t "lib: labels map both ways, the slot alias and an empty label ignored" sh -c 'test "$*" = "one ten k2 three main k1 old k3"' _ \
  "$(lib label_for k1)" "$(lib label_for k10)" "$(lib label_for k2)" "$(lib label_for k3)" "$(lib label_for main)" \
  "$(lib key_for one)" "$(lib key_for old)" "$(lib key_for three)"
lib drop_label k1
t "lib: drop_label drops the exact key only" test "$(cat "$S/labels.conf")" = "$(printf 'main=old\nk10=ten\nk2=\nk3=three')"
t "lib: jq_str escapes quotes and backslashes, drops control chars" test "$(lib jq_str $'a"b\\c\td\ne')" = 'a\"b\\cde'
t "lib: pad_cell pads to the plain width, not the painted one" test "$(lib pad_cell $'\e[1mab\e[0m' ab 5 left)|$(lib pad_cell x x 3 right)" = $'\e[1mab\e[0m   |  x'
t "lib: hrule draws two dashes past each width" test "$(lib hrule '<' '+' '>' 1 0)" = '<───+──>'
r=$("$CU_BIN" add main 2>&1)"|"$(cx add best 2>&1)
t "lib: each tool's own wording for a reserved name" test "$r" = "'main' is reserved for ~/.claude|'best' is reserved: it means \"pick for me\" in \`home\` and CODEX_ACCOUNT"
# install.sh reaches the bins through ~/.local/bin links: a relative link to an absolute one, from an unrelated cwd,
# and a symlinked bin/ beside a decoy lib/ that only a lexical bin/.. would reach.
LNR="$S/link-root"; mkdir -p "$LNR/k1" "$S/ln/abs" "$S/ln/rel" "$S/ln/cwd" "$S/ln/lib"; echo k1=lab > "$LNR/labels.conf"
for b in claude-usage codex-usage; do ln -s "$ROOT/bin/$b" "$S/ln/abs/$b"; ln -s "../abs/$b" "$S/ln/rel/$b"; done
ln -s "$ROOT/bin" "$S/ln/bin"; echo 'exit 7' > "$S/ln/lib/usage.sh"
t "bins: both find the lib through a chain of symlinks" sh -c 'cd "$1/cwd" && for b in ../rel ../bin; do
  CLAUDE_ACCOUNTS_ROOT="$2" $b/claude-usage list | grep -q "^lab " && PATH="$3:$PATH" CODEX_ACCOUNTS_ROOT="$2" $b/codex-usage list | grep -q "^lab " || exit 1
  done' _ "$S/ln" "$LNR" "$S/cxbin"
# Stock macOS runs both bins, and so the lib, on bash 3.2.
if command -v docker > /dev/null && docker image inspect bash:3.2 > /dev/null 2>&1; then
  B32="$S/b32"; mkdir -p "$B32/stub" "$B32/acc/k1" "$B32/abs" "$B32/rel" "$B32/cwd"; echo k1=lab > "$B32/acc/labels.conf"
  for c in claude codex; do printf '#!/bin/sh\nexit 1\n' > "$B32/stub/$c"; done
  printf '#!/bin/sh\nexit 0\n' > "$B32/stub/jq"; chmod +x "$B32"/stub/*   # codex-usage only checks that jq exists
  for b in claude-usage codex-usage; do ln -s "/r/bin/$b" "$B32/abs/$b"; ln -s "../abs/$b" "$B32/rel/$b"; done
  docker run --rm --user "$(id -u):$(id -g)" -v "$ROOT:/r:ro" -v "$B32:/w" bash:3.2 bash -c 'cd /w/cwd &&
    export HOME=/w XDG_CACHE_HOME=/w/cache PATH=/w/stub:$PATH CLAUDE_USAGE_SKIP_MAIN=1 CLAUDE_ACCOUNTS_ROOT=/w/acc CODEX_ACCOUNTS_ROOT=/w/acc
    ../rel/claude-usage list; ../rel/codex-usage list; ../rel/claude-usage rename lab lab2; ../rel/codex-usage add best 2>&1
    ../rel/codex-usage refresh; ls /w/cache/codex-usage/*/; ../rel/codex-usage; ../rel/codex-usage --json --cached; ../rel/codex-usage statusline' \
    > "$B32/out" 2> "$B32/err"
  t "bash 3.2: both bins load the lib through the symlink chain" test "$(grep -cx 'lab  *\/w\/acc\/k1' "$B32/out")" -eq 2
  t "bash 3.2: rename, a reserved name, refresh, table and json run clean" sh -c 'grep -qx "lab → lab2" "$1" &&
    grep -qx "'\''best'\'' is reserved: it means \"pick for me\" in \`home\` and CODEX_ACCOUNT" "$1" && grep -qx snapshot.tsv "$1" &&
    ! grep -q refresh.lock "$1" && grep -q "│   lab2  │" "$1" && grep -q "\"account\":\"lab2\"" "$1" && test ! -s "$2"' _ "$B32/out" "$B32/err"
else
  echo "skip  bash 3.2 pass (docker or the bash:3.2 image missing)"
fi

exit "$FAIL"
