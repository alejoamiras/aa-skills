#!/usr/bin/env bash
# Smoke test for the review leg's scripts (skills/gemini/scripts/run-agy.sh, resume-agy.sh and leg-lib.sh), staged by
# tests/fixtures/agy-leg.sh: the real launcher and scripts, the real run in-process with a staged home, a stand-in agy
# compiled from tests/fixtures/agy-stub.ts, fixture repos and real git. The engine's own cases live in
# tests/gemini-agy-run.test.ts. No real agy, key or network; everything lives under ~/.cache, never /tmp.
set -uo pipefail
export LC_ALL=C

[ "$(uname -s)" = Linux ] || { echo "skip  Linux only"; exit 0; }
for c in bun git jq flock timeout setsid; do command -v "$c" > /dev/null || { echo "skip  $c not installed"; exit 0; }; done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BASE="${XDG_CACHE_HOME:-$HOME/.cache}"
{ mkdir -p "$BASE" && S="$(mktemp -d "$BASE/smoke-gemini-leg.XXXXXX")" && S="$(cd "$S" && pwd -P)"; } || { echo "FAIL  fixture setup: a dir"; exit 1; }
FAIL=0 HOLDER=""
gls_cleanup() {
  [ -n "$HOLDER" ] && kill -- "-$HOLDER" 2> /dev/null
  if [ -n "${KEEP:-}" ]; then echo "kept $S"; else rm -rf "$S"; fi
}
trap gls_cleanup EXIT
gls_t() { local label="$1"; shift; if "$@" > /dev/null 2>&1; then echo "ok    $label"; else echo "FAIL  $label"; FAIL=1; fi; }
# Runs a script call as <name>: $S/<name>.out, .err and .rc.
gls_call() { local name="$1"; shift; "$@" < /dev/null > "$S/$name.out" 2> "$S/$name.err"; echo "$?" > "$S/$name.rc"; }
gls_rc() { cat "$S/$1.rc"; }
gls_key() { sed -n "s/^$2=//p" "$S/$1.out"; }
gls_stub() { printf '%s\n' "$1" > "$HOME/stub.json"; }
# Every entry with its type, mode and size, then every file's checksum.
gls_snap() { find "$1" -printf '%P %y %m %s\n' | sort && find "$1" -type f -print0 | sort -z | xargs -0 -r sha256sum; }
gls_runs() { find "$GL" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l; }
# The stub's newest spawn record in run dir $1.
gls_rec() { local priv="$1/home"; ls -t "$priv"/stub/*[0-9].json 2> /dev/null | head -n 1; }
gls_commit() { git -C "$1" -c user.name=t -c user.email=t@example.com commit -qm "$2"; }

# shellcheck source=fixtures/agy-leg.sh
. "$ROOT/tests/fixtures/agy-leg.sh"
agy_stage "$S/stage" "$ROOT" || { echo "FAIL  fixture setup: the staged home and tree"; exit 1; }
export HOME="$AGY_HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset CLAUDE_PID GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
RUN="$AGY_RUN" RESUME="$AGY_RESUME" GL="$HOME/.cache/gemini-leg" REPO="$S/repo" WT="$S/repo/.claude/worktrees/wt"
ANSWER='{"script":[{"answer":"stub answer"},{"result":"SUCCESS","response":"stub answer"}]}'
OFF='Gemini leg: off'
{ git init -q -b main "$REPO" && printf 'base\n' > "$REPO/README" && printf '# rules\n' > "$REPO/AGENTS.md" &&
  printf '*.log\nnode_modules/\n' > "$REPO/.gitignore" && git -C "$REPO" add . && gls_commit "$REPO" init &&
  echo '.claude/' >> "$REPO/.git/info/exclude" && git -C "$REPO" worktree add -q "$WT" && printf 'kept\n' > "$REPO/ignored.log" &&
  printf 'Name the file in this repository.\n' > "$S/p.md" && printf 'And the other one?\n' > "$S/p2.md" &&
  printf 'the key is %s\n' "$AGY_CANARY" > "$S/kp.md" && mkfifo "$S/release" && cp "$HOME/.agents/gemini-agy" "$S/pin"; } ||
  { echo "FAIL  fixture setup: the repo and its worktree"; exit 1; }
SHA7=$(git -C "$REPO" rev-parse HEAD | cut -c1-7)

# --- --check and the off checks ---------------------------------------------------------------------------------------
gls_call c0 "$RUN" --check "$REPO"
gls_t "--check: a set-up, unmarked repo exits 0 and prints nothing" sh -c '[ "$0" = 0 ] && [ ! -s "$1" ]' "$(gls_rc c0)" "$S/c0.out"
chmod 644 "$HOME/.config/gemini/.env"
gls_call c1 "$RUN" --check "$REPO"
chmod 600 "$HOME/.config/gemini/.env"
gls_t "--check: a key file not of mode 600 exits 4 off-setup, the record line alone" sh -c '[ "$0" = 4 ] && [ "$(cat "$1")" = "GEMINI: unavailable (off-setup)" ]' "$(gls_rc c1)" "$S/c1.out"
printf '%s\n' "$OFF" >> "$REPO/AGENTS.md"
gls_call c2 "$RUN" --check "$WT"
git -C "$REPO" checkout -q -- AGENTS.md
gls_t "--check: a marker added to the main checkout after the worktree was cut exits 4 off-marker there" sh -c '[ "$0" = 4 ] && [ "$(cat "$1")" = "GEMINI: unavailable (off-marker)" ]' "$(gls_rc c2)" "$S/c2.out"
printf '%s\n' "$OFF" > "$S/marker" && ln -s "$S/marker" "$REPO/CLAUDE.md"
gls_call c3 "$RUN" --check "$REPO"
rm -f "$REPO/CLAUDE.md"
gls_t "--check: a marker file that is a link is not read" test "$(gls_rc c3)" = 0
# label|what makes .agents run code before any message
while IFS='|' read -r label plant; do
  rm -rf "$REPO/.agents" && sh -c "$plant" "$REPO" "$S"
  gls_call ag "$RUN" "$S/p.md" "$REPO" high open neon
  gls_t "refuse: $label: exit 4 off-setup before any spawn, no run dir" sh -c '[ "$0" = 4 ] && [ "$(cat "$1")" = "GEMINI: unavailable (off-setup)" ] && [ "$2" = 0 ]' "$(gls_rc ag)" "$S/ag.out" "$(gls_runs)"
done << 'EOF'
.agents is a link|ln -s "$1" "$0/.agents"
.agents/hooks.json|mkdir "$0/.agents" && echo '{}' > "$0/.agents/hooks.json"
.agents/mcp_config.json|mkdir "$0/.agents" && echo '{}' > "$0/.agents/mcp_config.json"
EOF
rm -rf "$REPO/.agents"

# --- one clean run, with a bun planted in the repository first on PATH ------------------------------------------------
mkdir -p "$REPO/node_modules/.bin" && printf '#!/bin/sh\necho planted >> "%s"\nexec "%s" "$@"\n' "$S/planted" "$(command -v bun)" > "$REPO/node_modules/.bin/bun" &&
  chmod +x "$REPO/node_modules/.bin/bun" || echo "FAIL  fixture: plant a bun"
gls_stub "$ANSWER"
PATH="$REPO/node_modules/.bin:$PATH" gls_call r1 "$RUN" "$S/p.md" "$REPO" medium open neon
D1=$(gls_key r1 GEMINI_DIR) R1=$(gls_rec "$D1")
gls_t "run: CLAUDE_PID unset, a clean tree: exit 0 and every record field, no -dirty, no tree mark" sh -c '[ "$0" = 0 ] && head -n 1 "$1" | grep -qxE "GEMINI: answered \(neon medium rev=$2 in=1000 out=10 cached=500 tools=0 [0-9]+m[0-9]+s\)"' "$(gls_rc r1)" "$S/r1.out" "$SHA7"
gls_t "run: the trailer's four keys in order, naming the run dir's first-turn files" sh -c '[ "$(tail -n +2 "$1")" = "$(printf "GEMINI_DIR=%s\nSESSION_ID=8766c9db-47ac-4645-97cc-bd1cbe524c30\nRESPONSE_FILE=%s/response.md\nLOG_FILE=%s/log.ndjson" "$0" "$0" "$0")" ] && grep -qx "stub answer" "$0/response.md"' "$D1" "$S/r1.out"
gls_t "run: the run dir is mode 700 under ~/.cache/gemini-leg/, its files mode 600, meta naming the call" sh -c '[ "${0%/*}" = "$1" ] && [ "$(stat -c %a "$0")" = 700 ] && [ -z "$(find "$0" -maxdepth 1 -type f ! -perm 600)" ] && [ -f "$0/lock" ] && grep -qxF "top=$2" "$0/meta" && grep -qx "dirty=0" "$0/meta" && grep -qx "model=gemini-4-neon" "$0/meta" && grep -qx "effort=medium" "$0/meta"' "$D1" "$GL" "$REPO"
gls_t "run: the stub ran in the top level, in place, where the git-ignored file is" sh -c '[ -n "$0" ] && [ "$(jq -r .cwd "$0")" = "$1" ] && [ -f "$1/ignored.log" ]' "$R1" "$REPO"
gls_t "run: the caller's prompt reaches agy after a frame" sh -c 'p=$(cat "$1") && [ "$(jq -r .message.content "${0%.json}.in.ndjson")" = "$(cat "$2/prompt.md")" ] && [ "$(tail -c "$(wc -c < "$1")" "$2/prompt.md")" = "$p" ] && [ "$(wc -c < "$2/prompt.md")" -gt "$(($(wc -c < "$1") + 200))" ]' "$R1" "$S/p.md" "$D1"
gls_t "PATH: the bun planted inside the repository did not run" test ! -e "$S/planted"
mkdir -p "$S/outbin" && ln -s "$REPO/node_modules/.bin/bun" "$S/outbin/bun"
PATH="$S/outbin:$PATH" gls_call bl "$RUN" "$S/p.md" "$REPO" high open neon
gls_t "PATH: a link outside the repository to that bun exits 4 off-setup, no run dir" sh -c '[ "$0" = 4 ] && [ "$(cat "$1")" = "GEMINI: unavailable (off-setup)" ] && [ "$2" = 1 ] && [ ! -e "$3" ]' "$(gls_rc bl)" "$S/bl.out" "$(gls_runs)" "$S/planted"

# --- a dirty tree, a second edit, the fingerprint -----------------------------------------------------------------------
printf 'edit\n' >> "$REPO/README" && printf 'u\n' > "$REPO/untracked.txt"
gls_stub '{"script":[{"tool":"run_command","write":"README","output":"ok"},{"answer":"done"},{"result":"SUCCESS","response":"done"}]}'
gls_call r2 "$RUN" "$S/p.md" "$REPO" high open neon
R2=$(gls_rec "$(gls_key r2 GEMINI_DIR)")
gls_t "run: a dirty tree gives rev=-dirty, and a second edit to its dirty file tree=changed" sh -c '[ "$0" = 0 ] && head -n 1 "$1" | grep -qE "^GEMINI: answered \(neon high rev=$2-dirty .* tree=changed\)$"' "$(gls_rc r2)" "$S/r2.out" "$SHA7"
gls_t "run: the untracked and the git-ignored file are in the stub's cwd" sh -c 'c=$(jq -r .cwd "$0") && [ "$c" = "$1" ] && [ -f "$c/untracked.txt" ] && [ -f "$c/ignored.log" ]' "$R2" "$REPO"
git -C "$REPO" checkout -q -- README && rm -f "$REPO/untracked.txt"
gls_stub "{\"script\":[{\"tool\":\"run_command\",\"write\":\"$(realpath --relative-to="$WT" "$REPO/.git/hooks")/post-commit\"},{\"answer\":\"done\"},{\"result\":\"SUCCESS\",\"response\":\"done\"}]}"
gls_call h0 "$RUN" "$S/p.md" "$WT" high open neon
gls_t "fingerprint: from a linked worktree, a file the stub writes into the common dir's hooks/ marks tree=changed" sh -c '[ "$0" = 0 ] && [ -f "$2/post-commit" ] && [ -n "$3" ] && head -n 1 "$1" | grep -qE "^GEMINI: answered \(neon high rev=$4 .* tree=changed\)$"' "$(gls_rc h0)" "$S/h0.out" "$REPO/.git/hooks" "$(gls_rec "$(gls_key h0 GEMINI_DIR)")" "$SHA7"
rm -f "$REPO/.git/hooks/post-commit"
# A dormant hook in the dir core.hooksPath names, switched on by its mode alone while the stub runs.
{ mkdir -p "$S/hooks" && printf '#!/bin/sh\n' > "$S/hooks/post-commit" && chmod 644 "$S/hooks/post-commit" &&
  git -C "$REPO" config core.hooksPath "$S/hooks"; } || echo "FAIL  fixture: a dormant hook"
gls_stub '{"script":[{"sleep":2000},{"answer":"done"},{"result":"SUCCESS","response":"done"}]}'
spawns=$(find "$GL" -path '*/stub/*[0-9].json' | wc -l)
gls_call h1 "$RUN" "$S/p.md" "$WT" high open neon & H1=$!
for _ in $(seq 100); do [ "$(find "$GL" -path '*/stub/*[0-9].json' | wc -l)" -gt "$spawns" ] && break; sleep 0.1; done
chmod 755 "$S/hooks/post-commit"
wait "$H1"
gls_t "fingerprint: a dormant hook in core.hooksPath's dir made executable during the call marks tree=changed" sh -c '[ "$0" = 0 ] && [ -n "$2" ] && head -n 1 "$1" | grep -qE "^GEMINI: answered \(neon high rev=$3 .* tree=changed\)$"' "$(gls_rc h1)" "$S/h1.out" "$(gls_rec "$(gls_key h1 GEMINI_DIR)")" "$SHA7"
# The fingerprint never opens a hook linked to the stub key file: the key's access time, set years back, stays, where
# any read would move it under relatime, as a decoy's read shows. It runs alone first, since a call's engine reads the key.
KEYF="$HOME/.config/gemini/.env" OLD=978307200 READS=""
{ ln -s "$KEYF" "$S/hooks/pre-push" && printf 'x\n' > "$S/decoy" && touch -c -a -d "@$OLD" "$KEYF" "$S/decoy" &&
  cat "$S/decoy" > /dev/null; } || echo "FAIL  fixture: a hook linked to the key file"
if [ "$(stat -c %X "$S/decoy")" = "$OLD" ]; then
  echo "skip  fingerprint: a hook linked to the key file (this filesystem does not record reads)"
else
  READS=1
  gls_call fp bash "$(dirname "$RUN")/leg-lib.sh" fingerprint "$WT" "$S/fp.index"
  AT=$(stat -c %X "$KEYF")
  gls_stub "$ANSWER"
  gls_call hl "$RUN" "$S/p.md" "$WT" high open neon
  gls_t "fingerprint: a hook linked to the key file is never opened (its access time stays), and a call with it answers" sh -c '[ "$0" = 0 ] && [ "$(wc -l < "$1")" = 3 ] && [ "$2" = "$3" ] && [ "$4" = 0 ] && head -n 1 "$5" | grep -qE "^GEMINI: answered \(neon high rev=$6 .*[0-9]s\)$"' "$(gls_rc fp)" "$S/fp.out" "$AT" "$OLD" "$(gls_rc hl)" "$S/hl.out" "$SHA7"
fi
rm -f "$S/hooks/pre-push" "$S/fp.index"
git -C "$REPO" config --unset core.hooksPath
# The stub appends "stub edit" to each path it writes, so a new file of that name and the line that ignores it.
cp "$REPO/.git/info/exclude" "$S/exclude"
gls_stub '{"script":[{"tool":"run_command","write":"stub edit"},{"tool":"run_command","write":".git/info/exclude"},{"answer":"done"},{"result":"SUCCESS","response":"done"}]}'
gls_call ex "$RUN" "$S/p.md" "$REPO" high open neon
gls_t "fingerprint: a new file hidden by a line added to info/exclude during the call marks tree=changed" sh -c '[ "$0" = 0 ] && [ -f "$2/stub edit" ] && [ -z "$(git -C "$2" status --porcelain)" ] && head -n 1 "$1" | grep -qE "^GEMINI: answered \(neon high rev=$3 .* tree=changed\)$"' "$(gls_rc ex)" "$S/ex.out" "$REPO" "$SHA7"
rm -f "$REPO/stub edit" && mv "$S/exclude" "$REPO/.git/info/exclude"
# git diff runs a clean filter twice on a touched file, the second time holding the index lock: this one sleeps only
# then, so a fingerprint killed at its deadline is killed while the lock it took is held.
SLOW="$S/slow"
{ git init -q -b main "$SLOW" && printf 'a\n' > "$SLOW/a.txt" && echo 'a.txt filter=slow' > "$SLOW/.gitattributes" && git -C "$SLOW" add . &&
  gls_commit "$SLOW" init && git -C "$SLOW" config filter.slow.clean 'if [ -e "${GIT_INDEX_FILE:-.git/index}.lock" ]; then sleep 30; fi; cat' && touch -d '+1 minute' "$SLOW/a.txt"; } || echo "FAIL  fixture: the slow repo"
gls_stub "$ANSWER"
t0=$SECONDS
gls_call sl "$RUN" "$S/p.md" "$SLOW" high open neon
SLOW_S=$((SECONDS - t0))
gls_t "fingerprint: a clean filter past both deadlines gives tree=unknown and rev=-dirty, the answer kept (${SLOW_S} s)" sh -c '[ "$0" = 0 ] && [ -n "$3" ] && head -n 1 "$1" | grep -qE "^GEMINI: answered \(neon high rev=$2-dirty .* tree=unknown\)$"' "$(gls_rc sl)" "$S/sl.out" "$(git -C "$SLOW" rev-parse HEAD | cut -c1-7)" "$(gls_rec "$(gls_key sl GEMINI_DIR)")"
gls_t "fingerprint: no index.lock in the repo, no index copy or lock under ~/.cache/gemini-leg/" sh -c '[ ! -e "$0" ] && [ -z "$(find "$1" -mindepth 1 -maxdepth 1 ! -type d)" ]' "$(git -C "$SLOW" rev-parse --path-format=absolute --git-path index.lock)" "$GL"
# A clean filter that removes the prompt file: it runs in the starting fingerprint, after the prompt's checks and
# before the engine starts.
VANISH="$S/vanish"
{ git init -q -b main "$VANISH" && printf 'a\n' > "$VANISH/a.txt" && echo 'a.txt filter=gone' > "$VANISH/.gitattributes" && git -C "$VANISH" add . &&
  gls_commit "$VANISH" init && git -C "$VANISH" config filter.gone.clean "rm -f '$S/vp.md'; cat" && touch -d '+1 minute' "$VANISH/a.txt" &&
  printf 'The vanishing prompt.\n' > "$S/vp.md"; } || echo "FAIL  fixture: the vanish repo"
gls_call vp "$RUN" "$S/vp.md" "$VANISH" high open neon
gls_t "prompt: removed after its checks, before the engine starts: the whole prompt still reaches agy" sh -c '[ "$0" = 0 ] && [ ! -e "$2" ] && jq -e ".message.content | endswith(\"\n\nThe vanishing prompt.\n\")" "${1%.json}.in.ndjson"' "$(gls_rc vp)" "$(gls_rec "$(gls_key vp GEMINI_DIR)")" "$S/vp.md"

# --- resumes -------------------------------------------------------------------------------------------------------------
gls_call r1b "$RESUME" "" "$S/p2.md" "$D1"
R1B=$(gls_rec "$D1")
gls_t "resume: exit 0, the recorded effort, the turn-2 files in the trailer" sh -c '[ "$0" = 0 ] && head -n 1 "$1" | grep -qE "^GEMINI: answered \(neon medium rev=$3 " && grep -qx "RESPONSE_FILE=$2/response.2.md" "$1" && grep -qx "LOG_FILE=$2/log.2.ndjson" "$1" && [ -f "$2/prompt.2.md" ] && [ -f "$2/result.2.json" ] && [ -f "$2/response.md" ]' "$(gls_rc r1b)" "$S/r1b.out" "$D1" "$SHA7"
gls_t "resume: the stub resumed the conversation in the recorded top level, at the recorded effort" sh -c '[ "$0" != "$1" ] && [ "$(jq -r .cwd "$0")" = "$2" ] && jq -e "(.args | index(\"--conversation\")) as \$i | \$i != null and .args[\$i + 1] == \"8766c9db-47ac-4645-97cc-bd1cbe524c30\" and .args[(.args | index(\"--effort\")) + 1] == \"medium\"" "$0"' "$R1B" "$R1" "$REPO"
gls_stub '{"script":[{"answer":"looking"},{"tool":"schedule","state":"ACTIVE"},{"hold":true}]}'
gls_call sc "$RUN" "$S/p.md" "$REPO" high open neon
D3=$(gls_key sc GEMINI_DIR)
gls_t "schedule: exit 1, unavailable (tool) with its tokens, RESPONSE_FILE= empty" sh -c '[ "$0" = 1 ] && [ "$(head -n 1 "$1")" = "GEMINI: unavailable (tool in=1000 out=10 cached=500)" ] && grep -qx "RESPONSE_FILE=" "$1" && [ -n "$2" ]' "$(gls_rc sc)" "$S/sc.out" "$(gls_rec "$D3")"
gls_stub "$ANSWER"
setsid flock "$D3/lock" sh -c ': > "$0"; read -r _ < "$1"' "$S/held" "$S/release" & HOLDER=$!
for _ in $(seq 50); do [ -e "$S/held" ] && break; sleep 0.1; done
("$RESUME" "" "$S/p2.md" "$D3" < /dev/null > "$S/lk.out" 2> "$S/lk.err"; echo "$?" > "$S/lk.rc") & LK=$!
for _ in $(seq 30); do [ -e "$S/lk.rc" ] || [ -e "$D3/prompt.2.md" ] && break; sleep 0.1; done
gls_t "lock: a resume started while the dir's lock is held waits, nothing sent" sh -c '[ -e "$0" ] && [ ! -e "$1" ] && [ ! -e "$2/prompt.2.md" ]' "$S/held" "$S/lk.rc" "$D3"
if [ -e "$S/held" ]; then echo go > "$S/release"; else kill -- "-$HOLDER" 2> /dev/null; fi
wait "$HOLDER"
HOLDER=""
wait "$LK"
gls_t "lock: ...then runs; a resume after a tool end is allowed and answers" sh -c '[ "$(cat "$0")" = 0 ] && head -n 1 "$1" | grep -q "^GEMINI: answered " && [ -f "$2/result.2.json" ] && [ "$(find "$2/home" -path "*/stub/*[0-9].json" | wc -l)" = 2 ]' "$S/lk.rc" "$S/lk.out" "$D3"
# Resumes $D3 as <name> with session id $2 the way a first turn still running would meet it: a holder keeps the lock
# with session_id gone, and puts it back before letting go, once the resume has the lock file open.
gls_held() {
  rm -f "$S/held" && mv "$D3/session_id" "$S/sid" || return 1
  setsid flock "$D3/lock" sh -c ': > "$0"; read -r _ < "$1"; mv "$2" "$3"' "$S/held" "$S/release" "$S/sid" "$D3/session_id" & HOLDER=$!
  for _ in $(seq 100); do [ -e "$S/held" ] && break; sleep 0.1; done
  "$RESUME" "$2" "$S/p2.md" "$D3" < /dev/null > "$S/$1.out" 2> "$S/$1.err" & local p=$!
  for _ in $(seq 300); do { [ "$(readlink "/proc/$p/fd/9" 2> /dev/null)" = "$D3/lock" ] || [ ! -e "/proc/$p/fd/0" ]; } && break; sleep 0.1; done
  if [ -e "$S/held" ]; then echo go > "$S/release"; else kill -- "-$HOLDER" 2> /dev/null; fi
  wait "$HOLDER"
  HOLDER=""
  wait "$p"
  echo "$?" > "$S/$1.rc"
}
before=$(gls_snap "$D3")
gls_held w1 00000000-0000-4000-8000-000000000000
gls_t "lock: a wrong session id given while the first turn holds the lock waits, then exits 2 against the id written meanwhile, the dir unchanged" sh -c '[ "$0" = 2 ] && grep -q "is not the one" "$1" && [ "$2" = "$3" ]' "$(gls_rc w1)" "$S/w1.err" "$before" "$(gls_snap "$D3")"
gls_held w2 ""
gls_t "lock: \"\" given then waits too, and resumes the id written meanwhile" sh -c '[ "$0" = 0 ] && head -n 1 "$1" | grep -q "^GEMINI: answered " && jq -e "(.args | index(\"--conversation\")) as \$i | .args[\$i + 1] == \"$3\"" "$2"' "$(gls_rc w2)" "$S/w2.out" "$(gls_rec "$D3")" "$(cat "$D3/session_id")"

# --- refusals -------------------------------------------------------------------------------------------------------------
n=$(gls_runs)
gls_call k1 "$RUN" "$S/kp.md" "$REPO" high open neon
gls_t "refuse: a prompt holding the stub key: exit 2, the stop line alone on stderr, nothing on stdout, no run dir" sh -c '[ "$0" = 2 ] && [ ! -s "$1" ] && [ "$(wc -l < "$2")" = 1 ] && grep -q "^ERROR: the prompt holds the Gemini key" "$2" && [ "$3" = "$4" ]' "$(gls_rc k1)" "$S/k1.out" "$S/k1.err" "$n" "$(gls_runs)"
gls_call k2 "$RUN" "$HOME/.config/gemini/.env" "$REPO" high open neon
gls_t "refuse: the key file as the prompt: exit 2, one stderr line, no run dir" sh -c '[ "$0" = 2 ] && [ ! -s "$1" ] && [ "$(wc -l < "$2")" = 1 ] && [ "$3" = "$4" ]' "$(gls_rc k2)" "$S/k2.out" "$S/k2.err" "$n" "$(gls_runs)"
printf 'a\0b\n' > "$S/np.md"
gls_call k3 "$RUN" "$S/np.md" "$REPO" high open neon
gls_t "refuse: a prompt not read whole (a NUL byte): exit 2, one stderr line, no run dir" sh -c '[ "$0" = 2 ] && [ ! -s "$1" ] && [ "$(wc -l < "$2")" = 1 ] && [ "$3" = "$4" ]' "$(gls_rc k3)" "$S/k3.out" "$S/k3.err" "$n" "$(gls_runs)"
printf 'path=%s\nsha256=%064d\nversion=1.5.15-stub\n' "$HOME/bin/agy" 0 > "$HOME/.agents/gemini-agy"
gls_call e4 "$RUN" "$S/p.md" "$REPO" high open neon
gls_t "refuse: an engine setup refusal on a fresh run: exit 4 off-setup, no trailer, no run dir" sh -c '[ "$0" = 4 ] && [ "$(cat "$1")" = "GEMINI: unavailable (off-setup)" ] && [ "$2" = "$3" ]' "$(gls_rc e4)" "$S/e4.out" "$n" "$(gls_runs)"
cp "$S/pin" "$HOME/.agents/gemini-agy"
gls_stub '{"init":{"mode":"request-review"},"script":[{"answer":"x"},{"result":"SUCCESS","response":"x"}]}'
gls_call md "$RUN" "$S/p.md" "$REPO" high open neon
DM=$(gls_key md GEMINI_DIR)
gls_t "fixture: a run whose init reports another permission mode ends unavailable (mode)" sh -c '[ "$0" = 1 ] && head -n 1 "$1" | grep -q "^GEMINI: unavailable (mode "' "$(gls_rc md)" "$S/md.out"
gls_stub "$ANSWER"
cp -a "$D1" "$HOME/.cache/elsewhere" && ln -s "$D1" "$S/link" || echo "FAIL  fixture: a copied and a linked run dir"
mkdir -p "$D1/home/.gemini/config"
# label|the run dir|the dir argument|expected exit|its stdout|the session id|a change before the call|its undo after it.
# Each change and undo is an sh -c body: $0 the first run dir, $1 the saved pin, $2 the home, $3 the repo.
while IFS='|' read -r label dir arg want out sid change undo; do
  sh -c "$change" "$D1" "$S/pin" "$HOME" "$REPO"
  before=$(gls_snap "$dir")
  gls_call rf "$RESUME" "$sid" "$S/p2.md" "$arg"
  after=$(gls_snap "$dir")
  sh -c "$undo" "$D1" "$S/pin" "$HOME" "$REPO"
  gls_t "refuse resume: $label: exit $want, every entry's type, mode, size and checksum unchanged" sh -c '[ "$0" = "$1" ] && [ "$(cat "$2")" = "$3" ] && [ "$4" = "$5" ]' "$(gls_rc rf)" "$want" "$S/rf.out" "$out" "$before" "$after"
done << EOF
a mismatched session id|$D1|$D1|2||00000000-0000-4000-8000-000000000000|:|:
a linked dir|$D1|$S/link|2|||:|:
a dir of mode 750|$D1|$D1|2|||chmod 750 "\$0"|chmod 700 "\$0"
a dir outside ~/.cache/gemini-leg/|$HOME/.cache/elsewhere|$HOME/.cache/elsewhere|2|||:|:
a last turn that ended on the mode tripwire|$DM|$DM|2|||:|:
a last result that is a link|$D1|$D1|2|||mv "\$0/result.2.json" "\$2/r2.json" && touch -c -a -d @$OLD "\$2/r2.json" && ln -s "\$2/r2.json" "\$0/result.2.json"|stat -c %X "\$2/r2.json" > "\$2/r2.atime"; rm "\$0/result.2.json" && mv "\$2/r2.json" "\$0/result.2.json"
a marker that appeared since the run|$D1|$D1|4|GEMINI: unavailable (off-marker)||printf '%s\n' '$OFF' >> "\$3/AGENTS.md"|git -C "\$3" checkout -q -- AGENTS.md
an engine refusal (hooks.json in the private home)|$D1|$D1|2|||echo '{}' > "\$0/home/.gemini/config/hooks.json"|rm "\$0/home/.gemini/config/hooks.json"
an engine setup refusal (the pin's hash)|$D1|$D1|4|GEMINI: unavailable (off-setup)||sed -i 's/^sha256=.*/sha256=$(printf '%064d' 0)/' "\$2/.agents/gemini-agy"|cp "\$1" "\$2/.agents/gemini-agy"
EOF
# The engine refuses that link too, without following it, so only the target's access time shows the resume's own
# check: a read of the target, a result with no tripwire, would have moved it.
if [ -n "$READS" ]; then
  gls_t "refuse resume: the linked result's target was never opened (its access time stays)" test "$(cat "$HOME/r2.atime")" = "$OLD"
else
  echo "skip  refuse resume: the linked result's target was never opened (this filesystem does not record reads)"
fi

exit "$FAIL"
