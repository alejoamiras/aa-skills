#!/usr/bin/env bash
# Smoke test for bin/claude-usage — a stub `claude` on PATH and a throwaway
# accounts root. No real login, keychain or ~/.claude is touched.
set -uo pipefail

CU="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/claude-usage"
S="$(mktemp -d)"
trap 'rm -rf "$S"' EXIT
export CLAUDE_ACCOUNTS_ROOT="$S/accounts" XDG_CACHE_HOME="$S/cache" CLAUDE_USAGE_SKIP_MAIN=1
export PATH="$S/bin:$PATH"
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
[[ $1 == auth ]] && { printf '{\n  "loggedIn": true,\n  "email": "%s@x",\n  "subscriptionType": "max"\n}\n' "$acct"; exit 0; }
echo "You are currently using your subscription to power your Claude Code usage"
[[ -f $CLAUDE_CONFIG_DIR/reset ]] || exit 0   # idle: no window open anywhere
# flaky: the first reply of a busy account comes back windowless.
[[ -f $CLAUDE_CONFIG_DIR/flaky ]] && { rm -f "$CLAUDE_CONFIG_DIR/flaky"; exit 0; }
r=$(cat "$CLAUDE_CONFIG_DIR/reset")
printf '\nCurrent session: 0%% used · resets %s (UTC)\n' "$r"
printf 'Current week (all models): 50%% used · resets %s (UTC)\n' "$r"
printf 'Current week (Fable): 100%% used · resets %s (UTC)\n' "$r"
STUB
chmod +x "$S/bin/claude"

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
rm -rf "$CLAUDE_ACCOUNTS_ROOT/fresh"
"$CU" refresh
t "best: no premium anywhere picks the soonest reset" grep -q '^zzz-soon (no Fable left' <("$CU" best)

tn "add: lockfile-shaped name refused" "$CU" add evil.lock

exit "$FAIL"
