#!/usr/bin/env bash
# Smoke test for bin/claude-usage, bin/clu and the claude skill's reviewer
# scripts — a stub `claude` on PATH, a fake HOME and a throwaway accounts root.
# No real login, keychain, token or ~/.claude is touched.
# shellcheck disable=SC2016,SC2012 # literal $… in sh -c bodies; ls counts names we created
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

# Current CLI format ("Sep 26, 5:59pm"), N days ahead, under GNU or BSD date.
ahead() {
  { date -d "+$1 day" '+%b %-d, %-I:%M%p' 2>/dev/null || date -v+"$1"d '+%b %-d, %-I:%M%p'; } |
    sed -e 's/AM$/am/' -e 's/PM$/pm/'
}

mkdir -p "$S/bin"
cat > "$S/bin/claude" <<'STUB'
#!/usr/bin/env bash
acct=$(basename "${CLAUDE_CONFIG_DIR:-main}")
plan=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plan" 2>/dev/null || echo max)
org=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/org" 2>/dev/null || echo "org-$acct")
[[ $1 == auth ]] && { printf '{\n  "loggedIn": true,\n  "email": "%s@x",\n  "orgId": "%s",\n  "subscriptionType": "%s"\n}\n' "$acct" "$org" "$plan"; exit 0; }
if [[ " $* " == *" /usage "* ]]; then
  echo "You are currently using your subscription to power your Claude Code usage"
  [[ -f $CLAUDE_CONFIG_DIR/reset ]] || exit 0   # idle: no window open anywhere
  # flaky: the first reply of a busy account comes back windowless.
  [[ -f $CLAUDE_CONFIG_DIR/flaky ]] && { rm -f "$CLAUDE_CONFIG_DIR/flaky"; exit 0; }
  r=$(cat "$CLAUDE_CONFIG_DIR/reset")
  w=50; [[ -f $CLAUDE_CONFIG_DIR/spent ]] && w=100
  printf '\nCurrent session: 0%% used · resets %s (UTC)\n' "$r"
  printf 'Current week (all models): %s%% used · resets %s (UTC)\n' "$w" "$r"
  printf 'Current week (Fable): 100%% used · resets %s (UTC)\n' "$r"
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
ahead 1 > "$CLAUDE_ACCOUNTS_ROOT/zzz-soon/reset"
touch "$CLAUDE_ACCOUNTS_ROOT/zzz-soon/flaky"

"$CU" --json > "$S/out.json"
order=$(grep -o '"account":"[^"]*"' "$S/out.json" | cut -d'"' -f4 | tr '\n' ' ')
t "roster: lockfile dir is not an account" test "$order" = "fresh zzz-soon aaa-late "
t "idle: full headroom, marked idle" grep -q '"account":"fresh".*"week_left_pct":100,"week_resets":"idle".*"premium_left_pct":100' "$S/out.json"
t "flaky: one windowless reply is re-probed, not read as idle" grep -q '"account":"zzz-soon".*"premium_left_pct":0' "$S/out.json"

"$CU" refresh
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
t "resolve: a unique part of a name" grep -q "^dir=$Z .*argv=-p a\$" <(last)
clu tok > /dev/null 2> "$S/amb.err"; rc=$?
t "resolve: ambiguous lists the candidates and fails" sh -c '[ "$1" -ne 0 ] && grep -q "tok-proton" "$2" && grep -q "tok-two" "$2"' _ "$rc" "$S/amb.err"
tn "resolve: no match fails" clu nobody -p x
CLAUDE_USAGE_MODEL=sonnet clu -p "say ok" 2> /dev/null
t "clu: a leading option means best + passthrough" grep -q "^dir=$Z .*argv=-p say ok\$" <(last)
CLAUDE_USAGE_MODEL=sonnet clu -- hello 2> /dev/null
t "clu: -- means best, the rest to claude" grep -q "^dir=$Z .*argv=hello\$" <(last)

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
reply "$TK_FREE" 200 "anthropic-organization-id: org-free" "$H-5h-utilization: 0.08" "$H-5h-reset: $(( $(date +%s) + 3600 ))" \
  "$H-7d-utilization: 0.61" "$H-7d-reset: $(( $(date +%s) + 86400 ))" "$H-7d_oi-utilization: 0.34" "$H-7d_oi-reset: $(( $(date +%s) + 86400 ))"
reply "$TK_PAIR" 200 "anthropic-organization-id: org-main" "$H-5h-utilization: 0.5" "$H-7d-utilization: 0.5"
reply "$TK_DEAD" 401 "request-id: req_x"
NR="$S/net-root"
for a in free pair dead; do v="TK_$(tr '[:lower:]' '[:upper:]' <<< "$a")"; printf '%s' "${!v}" | CLAUDE_ACCOUNTS_ROOT="$NR" "$CU" add "tk-$a" > /dev/null 2>&1; done
: > "$NET/argv"
nr() { env -u CLAUDE_USAGE_SKIP_MAIN CLAUDE_ACCOUNTS_ROOT="$NR" XDG_CACHE_HOME="$S/cache-net" "$CU" "$@"; }
nr --json > "$S/net.json"
t "probe: headers become session, week and premium headroom" grep -q '"account":"tk-free".*"plan":"token","session_left_pct":92,.*"week_left_pct":39,.*"premium_model":"Fable","premium_left_pct":66' "$S/net.json"
t "probe: the token goes to curl on stdin, never in argv" sh -c 'test -s "$1" && ! grep -q sk-ant "$1"' _ "$NET/argv"
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
{ SSLKEYLOGFILE=/k XDG_CACHE_HOME="$S/cache-x" bash -x "$CU" --json; printf '%s' "$TK_FREE" | XDG_CACHE_HOME="$S/cache-x" bash -x "$CU" add tk-free;
  XDG_CACHE_HOME="$S/cache-x" bash -x "$CU" show tk-free; XDG_CACHE_HOME="$S/cache-x" bash -x "$CU" run tk-free -p x; } > "$S/xt.out" 2>&1 \
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
f=$(ls "$S"/cache-r2/claude-usage/*/snapshot.v3.tsv)
awk -F'\t' -v OFS='\t' '$2 == "main" { $13 = 1 } { print }' "$f" > "$f.n" && mv "$f.n" "$f"
t "pairing: an older slot reading never revives a newer spent token" test "$(rkm resolve best 2>/dev/null)" = spare2
tk=$(mktok bareshow); reply "$tk" 429 "request-id: r"
printf '%s' "$tk" | CLAUDE_ACCOUNTS_ROOT="$RK" "$CU" add bareshow > /dev/null 2>&1
t "show: a bare 429 prints as refused, unknown numbers, no crash" sh -c '"$@" > "$0" 2>&1 && grep -q "^refused" "$0" && grep -q "Current session: unknown" "$0"' "$S/show.out" env CLAUDE_ACCOUNTS_ROOT="$RK" XDG_CACHE_HOME="$S/cache-r2" "$CU" show bareshow

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

exit "$FAIL"
