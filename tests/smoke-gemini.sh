#!/usr/bin/env bash
# Smoke test for the gemini skill's scripts: a copy of skills/gemini whose engine is a stub, a temp HOME and TMPDIR.
# No key file, network or real engine is touched.
# shellcheck disable=SC2016 # literal $… in sh -c bodies
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$(cd "$(mktemp -d)" && pwd -P)"
trap '[ -n "${KEEP:-}" ] && echo "kept $S" || rm -rf "$S"' EXIT
export HOME="$S/home" TMPDIR="$S/tmp" GM_CALLS="$S/calls"
mkdir -p "$HOME/.agents" "$HOME/.claude/skills" "$TMPDIR" "$S/caller/rel" "$S/other"
cp -R "$ROOT/skills/gemini" "$S/skill"
mkdir -p "$S/skill/engines"
ln -s "$S/skill" "$HOME/.claude/skills/gemini"
RUN="$HOME/.claude/skills/gemini/scripts/run-gemini.sh"
ENG="$S/skill/engines/api"
P="$S/prompt.md"
printf 'Review this.\nSecond line.\n' > "$P"
FAIL=0

gm_t() { local label="$1"; shift; if "$@" > /dev/null 2>&1; then echo "ok    $label"; else echo "FAIL  $label"; FAIL=1; fi; }
gm_tn() { local label="$1"; shift; if "$@" > /dev/null 2>&1; then echo "FAIL  $label (expected failure)"; FAIL=1; else echo "ok    $label"; fi; }
gm_key() { sed -n "s/^$1=//p" "$2"; }

rm -f "$ENG"
cat > "$ENG" << 'STUB'
#!/usr/bin/env bash
{ pwd -P; printf '%s\n' "$@"; } > "$GM_CALLS"
printf 'abc' > "$1/id.txt"
printf 'stub answer\n' > "$1/response.md"
echo "OK: gemini-4-carbon in=1 cached=0 thought=0 out=1 total=2"
STUB
chmod 755 "$ENG"

# --- refusals before the per-call dir exists ------------------------------------
N0=$(ls -A "$TMPDIR" | wc -l)
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "config: none gives exit 2, no stdout, no dir, 'no engine configured'" sh -c '[ "$0" -eq 2 ] && [ ! -s "$1" ] && [ "$(ls -A "$2" | wc -l)" -eq "$3" ] && grep -qx "ERROR: no engine configured" "$4"' "$rc" "$S/o" "$TMPDIR" "$N0" "$S/e"
echo stub > "$HOME/.agents/gemini-engine"
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "config: 'stub' gives exit 2, no stdout, no dir, and names the file" sh -c '[ "$0" -eq 2 ] && [ ! -s "$1" ] && [ "$(ls -A "$2" | wc -l)" -eq "$3" ] && grep -qF "$4" "$5"' "$rc" "$S/o" "$TMPDIR" "$N0" "$HOME/.agents/gemini-engine" "$S/e"
echo api > "$HOME/.agents/gemini-engine"
# label:the one stderr line's first word or reason:arguments
for c in "zero arguments:usage:" "five arguments:usage:$P . high gemini-x extra" "a shifted call (p.md low):cwd:$P low" \
  "effort max:effort:$P . max" "model A/b:model:$P . high A/b"; do
  args="${c#*:}"
  # shellcheck disable=SC2086 # the case's words are its arguments
  (cd "$S/caller" && "$RUN" ${args#*:}) > "$S/o" 2> "$S/e"; rc=$?
  gm_t "usage: ${c%%:*} gives exit 2, one line naming its reason, no stdout, no dir" sh -c '[ "$0" -eq 2 ] && [ ! -s "$1" ] && [ "$(ls -A "$2" | wc -l)" -eq "$3" ] && [ "$(wc -l < "$4")" -eq 1 ] && grep -qw "$5" "$4"' "$rc" "$S/o" "$TMPDIR" "$N0" "$S/e" "${args%%:*}"
done
mv "$ENG" "$S/real-stub" && ln -s "$S/real-stub" "$ENG"
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "engine: a symlinked engines/api gives exit 2, no stdout, no dir" sh -c '[ "$0" -eq 2 ] && [ ! -s "$1" ] && [ "$(ls -A "$2" | wc -l)" -eq "$3" ]' "$rc" "$S/o" "$TMPDIR" "$N0"
rm "$ENG" && mv "$S/real-stub" "$ENG"
gm_t "refusals: the engine never ran" test ! -e "$GM_CALLS"

# --- an answered turn -------------------------------------------------------------
(cd "$S/caller" && "$RUN" "$P" "$S/other") > "$S/o" 2> "$S/e"; rc=$?
D=$(gm_key GEMINI_DIR "$S/o")
gm_t "run: an answered turn exits 0" test "$rc" -eq 0
gm_t "run: stdout is exactly the four keys, ENGINE=api" sh -c '[ "$(sed "s/=.*//" "$0" | paste -sd, -)" = GEMINI_DIR,RESPONSE_FILE,LOG_FILE,ENGINE ] && grep -qx ENGINE=api "$0"' "$S/o"
gm_t "run: RESPONSE_FILE holds the stub's answer" sh -c '[ "$(cat "$0")" = "stub answer" ]' "$(gm_key RESPONSE_FILE "$S/o")"
gm_t "run: the same four lines lead stderr, before the engine starts" sh -c 'head -n 4 "$1" | cmp -s - "$0"' "$S/o" "$S/e"
gm_t "run: the OK: line is copied to stderr" grep -qx "OK: gemini-4-carbon in=1 cached=0 thought=0 out=1 total=2" "$S/e"
gm_t "run: the engine got <absolute dir> 0 submit" sh -c 'case $1 in /*) ;; *) exit 1 ;; esac; [ "$(sed -n 2,4p "$0" | paste -sd" " -)" = "$1 0 submit" ]' "$GM_CALLS" "$D"
gm_t "run: the engine ran in the caller's cwd, not [cwd]" sh -c '[ "$(sed -n 1p "$0")" = "$1" ]' "$GM_CALLS" "$S/caller"
printf '%s\n%s\n\n' "You are a subagent. Don't run memo." "You are consulted as an independent reviewer. You cannot read files or run commands: judge only the material below, and say what is missing instead of guessing." > "$S/want"
cat "$P" >> "$S/want"
gm_t "run: prompt.md is the preamble, the reviewer line, a blank line, then the prompt" cmp -s "$S/want" "$D/prompt.md"
gm_t "run: the only records are effort (high by default) and model (empty by default)" sh -c '[ "$(ls -A "$0" | paste -sd" " -)" = "effort id.txt log.txt model prompt.md response.md" ] && [ "$(cat "$0/effort")" = high ] && [ ! -s "$0/model" ]' "$D"
(cd "$S/caller" && TMPDIR=rel "$RUN" "$P" "" low gemini-4-carbon) > "$S/o" 2> "$S/e"; rc=$?
D=$(gm_key GEMINI_DIR "$S/o")
gm_t "run: a relative TMPDIR still gives an absolute dir and argv" sh -c '[ "$0" -eq 0 ] && case $1 in "$2"/gemini-*) ;; *) exit 1 ;; esac && [ "$(sed -n 2p "$3")" = "$1" ]' "$rc" "$D" "$S/caller/rel" "$GM_CALLS"
gm_t "run: explicit effort and model are recorded" sh -c '[ "$(cat "$0/effort")" = low ] && [ "$(cat "$0/model")" = gemini-4-carbon ]' "$D"

# --- turns that end without an answer ------------------------------------------------
cat > "$ENG" << 'STUB'
#!/usr/bin/env bash
printf 'abc' > "$1/id.txt"
echo "poll 1: in_progress"
STUB
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
D=$(gm_key GEMINI_DIR "$S/o")
gm_t "pending: exit 3 with the trailer" sh -c '[ "$0" -eq 3 ] && [ "$(wc -l < "$1")" -eq 4 ] && [ -n "$2" ]' "$rc" "$S/o" "$D"
gm_t "pending: PENDING: leads the report after the early trailer" sh -c '[ "$(sed -n 5p "$0")" = "PENDING: run fetch-gemini.sh $1" ]' "$S/e" "$D"
gm_t "pending: the log tail follows" grep -qx "poll 1: in_progress" "$S/e"
cat > "$ENG" << 'STUB'
#!/usr/bin/env bash
printf 'abc' > "$1/id.txt"
printf 'failed' > "$1/ended.txt"
STUB
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "ended: exit 1 with the trailer and the marker's word" sh -c '[ "$0" -eq 1 ] && [ "$(wc -l < "$1")" -eq 4 ] && grep -qw failed "$2"' "$rc" "$S/o" "$S/e"
gm_tn "ended: the shell adds no resend advice" grep -qiE 'resend|again|billed' "$S/e"
cat > "$ENG" << 'STUB'
#!/usr/bin/env bash
echo "ERROR: x"
exit 5
STUB
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "no outcome: exit 1, the engine's ERROR: line and the no-outcome line" sh -c '[ "$0" -eq 1 ] && grep -qx "ERROR: x" "$1" && grep -q "turn 0 has no recorded outcome" "$1" && [ "$(wc -l < "$2")" -eq 4 ]' "$rc" "$S/e" "$S/o"
cat > "$ENG" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "no outcome: an engine that writes nothing and exits 0 still gives exit 1" test "$rc" -eq 1

exit "$FAIL"
