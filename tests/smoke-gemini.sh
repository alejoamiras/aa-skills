#!/usr/bin/env bash
# Smoke test for the gemini skill's scripts: skills/gemini/scripts beside a stub engine, a temp HOME and TMPDIR. The real
# launcher is staged only beside a synthetic api.ts.
# shellcheck disable=SC2016 # literal $… in sh -c bodies
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$(mktemp -d)" && S="$(cd "$S" && pwd -P)" || { echo "FAIL  fixture setup: a temp dir"; exit 1; }
trap '[ -n "${KEEP:-}" ] && echo "kept $S" || rm -rf "$S"' EXIT
# The stub copies the caller's stderr file at entry, so a trailer printed after the engine starts cannot pass.
export HOME="$S/home" TMPDIR="$S/tmp" GM_CALLS="$S/calls" GM_ERR="$S/e" GM_SNAP="$S/snap"
RUN="$HOME/.claude/skills/gemini/scripts/run-gemini.sh"
RES="$HOME/.claude/skills/gemini/scripts/resume-gemini.sh"
FET="$HOME/.claude/skills/gemini/scripts/fetch-gemini.sh"
ENG="$S/skill/engines/api"
P="$S/prompt.md"
{ mkdir -p "$HOME/.agents" "$HOME/.claude/skills" "$TMPDIR" "$S/caller/rel" "$S/other" "$S/skill/engines" &&
  cp -R "$ROOT/skills/gemini/scripts" "$S/skill/scripts" && ln -s "$S/skill" "$HOME/.claude/skills/gemini" &&
  printf 'Review this.\nSecond line.\n' > "$P"; } || { echo "FAIL  fixture setup: the scripts tree, HOME and the prompt"; exit 1; }
FAIL=0

gm_t() { local label="$1"; shift; if "$@" > /dev/null 2>&1; then echo "ok    $label"; else echo "FAIL  $label"; FAIL=1; fi; }
gm_tn() { local label="$1"; shift; if "$@" > /dev/null 2>&1; then echo "FAIL  $label (expected failure)"; FAIL=1; else echo "ok    $label"; fi; }
gm_key() { sed -n "s/^$1=//p" "$2"; }

cat > "$ENG" << 'STUB' || { echo "FAIL  fixture setup: write the stub"; exit 1; }
#!/usr/bin/env bash
cat "$GM_ERR" > "$GM_SNAP" 2> /dev/null
{ pwd -P; printf '%s\n' "$@"; } > "$GM_CALLS"
printf 'abc' > "$1/id.txt"
printf 'stub answer\n' > "$1/response.md"
echo "OK: gemini-4-carbon in=1 cached=0 thought=0 out=1 total=2"
STUB
chmod 755 "$ENG" || { echo "FAIL  fixture setup: make the stub executable"; exit 1; }

# --- refusals before the per-call dir exists ------------------------------------
N0=$(ls -A "$TMPDIR" | wc -l)
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "config: none gives exit 2, no stdout, no dir, 'no engine configured'" sh -c '[ "$0" -eq 2 ] && [ ! -s "$1" ] && [ "$(ls -A "$2" | wc -l)" -eq "$3" ] && grep -qx "ERROR: no engine configured" "$4"' "$rc" "$S/o" "$TMPDIR" "$N0" "$S/e"
echo stub > "$HOME/.agents/gemini-engine" || { echo "FAIL  fixture setup: the stub config"; exit 1; }
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "config: 'stub' gives exit 2, no stdout, no dir, and names the file" sh -c '[ "$0" -eq 2 ] && [ ! -s "$1" ] && [ "$(ls -A "$2" | wc -l)" -eq "$3" ] && grep -qF "$4" "$5"' "$rc" "$S/o" "$TMPDIR" "$N0" "$HOME/.agents/gemini-engine" "$S/e"
echo api > "$HOME/.agents/gemini-engine" || { echo "FAIL  fixture setup: the api config"; exit 1; }
# label:the one stderr line's first word or reason:arguments
for c in "zero arguments:usage:" "five arguments:usage:$P . high gemini-x extra" "a shifted call (p.md low):cwd:$P low" \
  "effort max:effort:$P . max" "model A/b:model:$P . high A/b"; do
  args="${c#*:}"
  # shellcheck disable=SC2086 # the case's words are its arguments
  (cd "$S/caller" && "$RUN" ${args#*:}) > "$S/o" 2> "$S/e"; rc=$?
  gm_t "usage: ${c%%:*} gives exit 2, one line naming its reason, no stdout, no dir" sh -c '[ "$0" -eq 2 ] && [ ! -s "$1" ] && [ "$(ls -A "$2" | wc -l)" -eq "$3" ] && [ "$(wc -l < "$4")" -eq 1 ] && grep -qw "$5" "$4"' "$rc" "$S/o" "$TMPDIR" "$N0" "$S/e" "${args%%:*}"
done
{ mv "$ENG" "$S/real-stub" && ln -s "$S/real-stub" "$ENG"; } || { echo "FAIL  fixture setup: link the stub"; exit 1; }
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "engine: a symlinked engines/api gives exit 2, no stdout, no dir" sh -c '[ "$0" -eq 2 ] && [ ! -s "$1" ] && [ "$(ls -A "$2" | wc -l)" -eq "$3" ]' "$rc" "$S/o" "$TMPDIR" "$N0"
{ rm "$ENG" && mv "$S/real-stub" "$ENG"; } || { echo "FAIL  fixture setup: unlink the stub"; exit 1; }
gm_t "refusals: the engine never ran" test ! -e "$GM_CALLS"

# --- an answered turn -------------------------------------------------------------
rm -f "$GM_SNAP"
(cd "$S/caller" && "$RUN" "$P" "$S/other") > "$S/o" 2> "$S/e"; rc=$?
D=$(gm_key GEMINI_DIR "$S/o")
gm_t "run: an answered turn exits 0" test "$rc" -eq 0
gm_t "run: stdout is exactly the four keys, ENGINE=api" sh -c '[ "$(sed "s/=.*//" "$0" | paste -sd, -)" = GEMINI_DIR,RESPONSE_FILE,LOG_FILE,ENGINE ] && grep -qx ENGINE=api "$0"' "$S/o"
gm_t "run: RESPONSE_FILE holds the stub's answer" sh -c '[ "$(cat "$0")" = "stub answer" ]' "$(gm_key RESPONSE_FILE "$S/o")"
gm_t "run: the same four lines are on stderr when the engine starts" cmp -s "$S/o" "$GM_SNAP"
gm_t "run: the OK: line is copied to stderr" grep -qx "OK: gemini-4-carbon in=1 cached=0 thought=0 out=1 total=2" "$S/e"
gm_t "run: the engine got <absolute dir> 0 submit" sh -c 'case $1 in /*) ;; *) exit 1 ;; esac; [ "$(sed -n 2,4p "$0" | paste -sd" " -)" = "$1 0 submit" ]' "$GM_CALLS" "$D"
gm_t "run: the engine ran in the caller's cwd, not [cwd]" sh -c '[ "$(sed -n 1p "$0")" = "$1" ]' "$GM_CALLS" "$S/caller"
{ printf '%s\n%s\n\n' "You are a subagent. Don't run memo." "You are consulted as an independent reviewer. You cannot read files or run commands: judge only the material below, and say what is missing instead of guessing." > "$S/want" &&
  cat "$P" >> "$S/want"; } || { echo "FAIL  fixture setup: the expected prompt"; exit 1; }
gm_t "run: prompt.md is the preamble, the reviewer line, a blank line, then the prompt" cmp -s "$S/want" "$D/prompt.md"
gm_t "run: the only records are effort (high by default) and model (empty by default)" sh -c '[ "$(ls -A "$0" | paste -sd" " -)" = "effort id.txt log.txt model prompt.md response.md" ] && [ "$(cat "$0/effort")" = high ] && [ ! -s "$0/model" ]' "$D"
(cd "$S/caller" && TMPDIR=rel "$RUN" "$P" "" low gemini-4-carbon) > "$S/o" 2> "$S/e"; rc=$?
D=$(gm_key GEMINI_DIR "$S/o")
gm_t "run: a relative TMPDIR still gives an absolute dir and argv" sh -c '[ "$0" -eq 0 ] && case $1 in "$2"/gemini-*) ;; *) exit 1 ;; esac && [ "$(sed -n 2p "$3")" = "$1" ]' "$rc" "$D" "$S/caller/rel" "$GM_CALLS"
gm_t "run: explicit effort and model are recorded" sh -c '[ "$(cat "$0/effort")" = low ] && [ "$(cat "$0/model")" = gemini-4-carbon ]' "$D"

# --- turns that end without an answer ------------------------------------------------
cat > "$ENG" << 'STUB' || { echo "FAIL  fixture setup: write the stub"; exit 1; }
#!/usr/bin/env bash
printf 'abc' > "$1/id.txt"
echo "poll 1: in_progress"
STUB
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
D=$(gm_key GEMINI_DIR "$S/o")
gm_t "pending: exit 3 with the trailer" sh -c '[ "$0" -eq 3 ] && [ "$(wc -l < "$1")" -eq 4 ] && [ -n "$2" ]' "$rc" "$S/o" "$D"
gm_t "pending: PENDING: leads the report after the early trailer" sh -c '[ "$(sed -n 5p "$0")" = "PENDING: run fetch-gemini.sh $1" ]' "$S/e" "$D"
gm_t "pending: the log tail follows" grep -qx "poll 1: in_progress" "$S/e"
cat > "$ENG" << 'STUB' || { echo "FAIL  fixture setup: write the stub"; exit 1; }
#!/usr/bin/env bash
printf 'abc' > "$1/id.txt"
printf 'failed' > "$1/ended.txt"
STUB
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "ended: exit 1 with the trailer and the marker's word" sh -c '[ "$0" -eq 1 ] && [ "$(wc -l < "$1")" -eq 4 ] && grep -qw failed "$2"' "$rc" "$S/o" "$S/e"
gm_tn "ended: the shell adds no resend advice" grep -qiE 'resend|again|billed' "$S/e"
cat > "$ENG" << 'STUB' || { echo "FAIL  fixture setup: write the stub"; exit 1; }
#!/usr/bin/env bash
echo "ERROR: x"
exit 5
STUB
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "no outcome: exit 1, the engine's ERROR: line and the no-outcome line" sh -c '[ "$0" -eq 1 ] && grep -qx "ERROR: x" "$1" && grep -q "turn 0 has no recorded outcome" "$1" && [ "$(wc -l < "$2")" -eq 4 ]' "$rc" "$S/e" "$S/o"
cat > "$ENG" << 'STUB' || { echo "FAIL  fixture setup: write the stub"; exit 1; }
#!/usr/bin/env bash
exit 0
STUB
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "no outcome: an engine that writes nothing and exits 0 still gives exit 1" test "$rc" -eq 1

# --- resume and fetch ----------------------------------------------------------------
# A refusal: exit 2, no trailer, one stderr line holding the expected words.
REFUSED='[ "$0" -eq 2 ] && [ ! -s "$1" ] && [ "$(wc -l < "$2")" -eq 1 ] && grep -qF "$3" "$2"'
cat > "$ENG" << 'STUB' || { echo "FAIL  fixture setup: write the stub"; exit 1; }
#!/usr/bin/env bash
cat "$GM_ERR" > "$GM_SNAP" 2> /dev/null
s=""; [ "$2" = 0 ] || s="-$2"
{ pwd -P; printf '%s\n' "$@"; } > "$GM_CALLS"
printf 'abc' > "$1/id$s.txt"
printf 'answer %s\n' "$2" > "$1/response$s.md"
echo "OK: turn $2"
STUB
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> /dev/null
D=$(gm_key GEMINI_DIR "$S/o")
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> /dev/null
D2=$(gm_key GEMINI_DIR "$S/o")
(cd "$S/caller" && "$RES" "$D" "$P") > /dev/null 2>&1
rm -f "$GM_SNAP"
(cd "$S/caller" && "$RES" "$D/" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "resume: two resumes leave turn files 1 and 2" sh -c 'for n in 1 2; do for f in followup-$n.md id-$n.txt response-$n.md log-$n.txt; do [ -f "$0/$f" ] || exit 1; done; done' "$D"
gm_t "resume: the second exits 0 and the engine got <dir> 2 submit" sh -c '[ "$0" -eq 0 ] && [ "$(sed -n 2,4p "$1" | paste -sd" " -)" = "$2 2 submit" ]' "$rc" "$GM_CALLS" "$D"
printf 'GEMINI_DIR=%s\nRESPONSE_FILE=%s\nLOG_FILE=%s\nENGINE=api\n' "$D" "$D/response-2.md" "$D/log-2.txt" > "$S/want-t"
gm_t "resume: the turn-2 trailer on stdout, and on stderr when the engine starts" sh -c 'cmp -s "$0" "$1" && cmp -s "$0" "$2"' "$S/want-t" "$S/o" "$GM_SNAP"
gm_t "resume: followup-2.md is the preamble, the reviewer line, a blank line, then the prompt" cmp -s "$S/want" "$D/followup-2.md"
printf 'dash prompt\n' > "$S/caller/-" || { echo "FAIL  fixture setup: a prompt file named -"; exit 1; }
(cd "$S/caller" && "$RUN" - < /dev/null) > "$S/o" 2> /dev/null; rc=$?
DD=$(gm_key GEMINI_DIR "$S/o")
(cd "$S/caller" && "$RES" "$DD" - < /dev/null) > /dev/null 2>&1; rc2=$?
gm_t "run, resume: a prompt file named - is read as a file, not as stdin" sh -c '[ "$0" -eq 0 ] && [ "$1" -eq 0 ] && [ "$(tail -n 1 "$2/prompt.md")" = "dash prompt" ] && [ "$(tail -n 1 "$2/followup-1.md")" = "dash prompt" ]' "$rc" "$rc2" "$DD"

{ echo keep > "$S/sentinel" && ln -s "$S/sentinel" "$D/log-3.txt" && ln -s "$S/nowhere" "$D/response-4.md" && echo x > "$D/.response-5.md.x"; } ||
  { echo "FAIL  fixture setup: links in turns 3 and 4"; exit 1; }
(cd "$S/caller" && "$RES" "$D" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "resume: a symlinked log-3, a dangling response-4 take their slots, a temp name does not" test "$rc" -eq 0 -a "$(gm_key LOG_FILE "$S/o")" = "$D/log-5.txt"
gm_t "resume: the sentinel behind log-3.txt is unchanged" sh -c '[ "$(cat "$0")" = keep ]' "$S/sentinel"

cat > "$ENG" << 'STUB' || { echo "FAIL  fixture setup: write the stub"; exit 1; }
#!/usr/bin/env bash
cat "$GM_ERR" > "$GM_SNAP" 2> /dev/null
s=""; [ "$2" = 0 ] || s="-$2"
{ pwd -P; printf '%s\n' "$@"; } > "$GM_CALLS"
if [ "$3" = submit ]; then printf 'abc' > "$1/id$s.txt"; echo "poll 1: in_progress"; exit 0; fi
printf 'answer %s\n' "$2" > "$1/response$s.md"
echo "OK: turn $2 collected"
STUB
(cd "$S/caller" && "$RUN" "$P") > "$S/o" 2> /dev/null
D3=$(gm_key GEMINI_DIR "$S/o")
(cd "$S/caller" && "$RES" "$D" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "resume: turn 6 left pending exits 3" test "$rc" -eq 3 -a "$(gm_key LOG_FILE "$S/o")" = "$D/log-6.txt"
(cd "$S/caller" && "$RES" "$D" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "resume: refused while turn 6 is pending, with the fetch line, claiming nothing" sh -c "$REFUSED"' && [ ! -e "$4/followup-7.md" ]' "$rc" "$S/o" "$S/e" "run fetch-gemini.sh $D" "$D"
rm -f "$GM_CALLS" "$GM_SNAP"
(cd "$S/caller" && "$FET" "$D") > "$S/o" 2> "$S/e"; rc=$?
printf 'GEMINI_DIR=%s\nRESPONSE_FILE=%s\nLOG_FILE=%s\nENGINE=api\n' "$D" "$D/response-6.md" "$D/log-6.txt" > "$S/want-t"
gm_t "fetch: collects turn 6: <dir> 6 collect, exit 0, the turn-6 trailer" sh -c '[ "$0" -eq 0 ] && [ "$(sed -n 2,4p "$1" | paste -sd" " -)" = "$2 6 collect" ] && cmp -s "$3" "$4"' "$rc" "$GM_CALLS" "$D" "$S/want-t" "$S/o"
gm_t "fetch: the turn-6 trailer is on stderr when the engine starts" cmp -s "$S/want-t" "$GM_SNAP"
rm -f "$GM_CALLS"
(cd "$S/caller" && "$FET" "$D") > "$S/o" 2> "$S/e"; rc=$?
gm_t "fetch: again on the answered turn: exit 0, same trailer, its OK: line, no engine" sh -c '[ "$0" -eq 0 ] && cmp -s "$1" "$2" && grep -qx "OK: turn 6 collected" "$3" && [ ! -e "$4" ]' "$rc" "$S/want-t" "$S/o" "$S/e" "$GM_CALLS"
{ grep -v '^OK: ' "$D/log-6.txt" > "$S/cut" && cat "$S/cut" > "$D/log-6.txt"; } || { echo "FAIL  fixture setup: cut the OK: line"; exit 1; }
(cd "$S/caller" && "$FET" "$D") > "$S/o" 2> "$S/e"; rc=$?
gm_t "fetch: still exit 0 with the OK: line cut from the log" sh -c '[ "$0" -eq 0 ] && cmp -s "$1" "$2" && [ ! -e "$3" ]' "$rc" "$S/want-t" "$S/o" "$GM_CALLS"

cat > "$ENG" << 'STUB' || { echo "FAIL  fixture setup: write the stub"; exit 1; }
#!/usr/bin/env bash
s=""; [ "$2" = 0 ] || s="-$2"
printf 'abc' > "$1/id$s.txt"
printf 'failed' > "$1/ended$s.txt"
STUB
(cd "$S/caller" && "$RES" "$D" "$P") > /dev/null 2>&1; rc=$?
(cd "$S/caller" && "$FET" "$D") > "$S/o" 2> "$S/e"; rc2=$?
gm_t "fetch: turn 7 ended exits 1 with its word and the turn-7 trailer" sh -c '[ "$0" -eq 1 ] && [ "$1" -eq 1 ] && grep -qw failed "$2" && grep -qx "RESPONSE_FILE=$4/response-7.md" "$3"' "$rc" "$rc2" "$S/e" "$S/o" "$D"
cat > "$ENG" << 'STUB' || { echo "FAIL  fixture setup: write the stub"; exit 1; }
#!/usr/bin/env bash
exit 0
STUB
(cd "$S/caller" && "$RES" "$D" "$P") > /dev/null 2>&1; rc=$?
gm_t "resume: turn 8 left as a prompt only exits 1" test "$rc" -eq 1 -a -f "$D/followup-8.md"
(cd "$S/caller" && "$RES" "$D" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "resume: refused on turn 8 with the no-outcome line, claiming nothing" sh -c "$REFUSED"' && [ ! -e "$4/followup-9.md" ]' "$rc" "$S/o" "$S/e" "turn 8 has no recorded outcome" "$D"
(cd "$S/caller" && "$FET" "$D") > "$S/o" 2> "$S/e"; rc=$?
gm_t "fetch: refused on turn 8 with the no-outcome line" sh -c "$REFUSED" "$rc" "$S/o" "$S/e" "turn 8 has no recorded outcome"

rm -f "$GM_CALLS"
(cd "$S/caller" && "$RES" "$D2") > "$S/o" 2> "$S/e"; rc=$?
gm_t "resume: one argument is a usage error" sh -c "$REFUSED" "$rc" "$S/o" "$S/e" "usage:"
(cd "$S/caller" && "$RES" "" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "resume: an empty dir argument is a usage error" sh -c "$REFUSED" "$rc" "$S/o" "$S/e" "usage:"
# label|reason|setup|undo: each runs resume, then fetch, on the otherwise answerable D2.
while IFS='|' read -r label reason setup undo; do
  sh -c "$setup" "$D2" "$S" || { echo "FAIL  fixture setup: $label"; exit 1; }
  (cd "$S/caller" && "$RES" "$(cat "$S/target")" "$P") > "$S/o" 2> "$S/e"; rc=$?
  gm_t "resume: refuses $label" sh -c "$REFUSED" "$rc" "$S/o" "$S/e" "$reason"
  (cd "$S/caller" && "$FET" "$(cat "$S/target")") > "$S/o" 2> "$S/e"; rc=$?
  gm_t "fetch: refuses $label" sh -c "$REFUSED" "$rc" "$S/o" "$S/e" "$reason"
  sh -c "$undo" "$D2" "$S" || { echo "FAIL  fixture setup: undo $label"; exit 1; }
done << 'CASES'
a symlinked dir|not a conversation dir|ln -s "$0" "$1/dlink" && echo "$1/dlink" > "$1/target"|rm "$1/dlink"
a symlinked dir given with a trailing slash|not a conversation dir|ln -s "$0" "$1/dlink" && echo "$1/dlink/" > "$1/target"|rm "$1/dlink"
a dir with mode 750|not a conversation dir|chmod 750 "$0" && echo "$0" > "$1/target"|chmod 700 "$0"
a symlinked effort record|effort must be a regular file|mv "$0/effort" "$0/effort.real" && ln -s effort.real "$0/effort" && echo "$0" > "$1/target"|rm "$0/effort" && mv "$0/effort.real" "$0/effort"
CASES
gm_t "refusals: no engine ran and no turn was claimed" sh -c '[ ! -e "$0" ] && [ ! -e "$1/followup-1.md" ]' "$GM_CALLS" "$D2"
(cd "$S/caller" && "$RES" "$D3" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "turn 0 pending: resume gives the fetch line" sh -c "$REFUSED" "$rc" "$S/o" "$S/e" "run fetch-gemini.sh $D3"
rm "$D3/id.txt" || { echo "FAIL  fixture setup: drop turn 0's id"; exit 1; }
(cd "$S/caller" && "$RES" "$D3" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "turn 0 prompt only: resume gives the no-outcome line" sh -c "$REFUSED" "$rc" "$S/o" "$S/e" "turn 0 has no recorded outcome"
echo failed > "$D3/ended.txt" || { echo "FAIL  fixture setup: end turn 0"; exit 1; }
(cd "$S/caller" && "$RES" "$D3" "$P") > "$S/o" 2> "$S/e"; rc=$?
gm_t "turn 0 ended: resume gives the turn-0 line, claiming nothing" sh -c "$REFUSED"' && [ ! -e "$4/followup-1.md" ]' "$rc" "$S/o" "$S/e" "turn 0 has no answer: see its log's NEXT line, then start again with run-gemini.sh" "$D3"

# --- fetch refuses turn files that are links or not regular files ----------------------------
cat > "$ENG" << 'STUB' || { echo "FAIL  fixture setup: write the stub"; exit 1; }
#!/usr/bin/env bash
{ pwd -P; printf '%s\n' "$@"; } > "$GM_CALLS"
echo "engine output"
STUB
C="$S/conv"
{ mkdir -m 700 "$C" && printf high > "$C/effort" && : > "$C/model" && printf 'p\n' > "$C/prompt.md" && printf abc > "$C/id.txt" &&
  printf failed > "$C/ended.txt" && echo FAKE-SECRET-TEXT > "$S/secret" && ln -s "$S/secret" "$C/log.txt" && rm -f "$GM_CALLS"; } ||
  { echo "FAIL  fixture setup: an ended turn whose log is a link"; exit 1; }
(cd "$S/caller" && "$FET" "$C") > "$S/o" 2> "$S/e"; rc=$?
gm_t "fetch: refuses an ended turn whose log links to a secret, printing it nowhere" sh -c "$REFUSED"' && ! grep -q FAKE-SECRET "$1" "$2"' "$rc" "$S/o" "$S/e" "$C/log.txt must be a regular file"
{ rm "$C/ended.txt" "$C/log.txt" && ln -s "$S/sentinel" "$C/log.txt"; } || { echo "FAIL  fixture setup: a pending turn whose log is a link"; exit 1; }
(cd "$S/caller" && "$FET" "$C") > "$S/o" 2> "$S/e"; rc=$?
gm_t "fetch: refuses a pending turn whose log is a link, leaving its target alone and running no engine" sh -c "$REFUSED"' && [ "$(cat "$4")" = keep ] && [ ! -e "$5" ]' "$rc" "$S/o" "$S/e" "$C/log.txt must be a regular file" "$S/sentinel" "$GM_CALLS"
{ rm "$C/log.txt" && mkdir "$C/response.md"; } || { echo "FAIL  fixture setup: a directory named response.md"; exit 1; }
(cd "$S/caller" && "$FET" "$C") > "$S/o" 2> "$S/e"; rc=$?
gm_t "fetch: refuses a directory named response.md" sh -c "$REFUSED" "$rc" "$S/o" "$S/e" "$C/response.md must be a regular file"

# --- the launcher ------------------------------------------------------------------------
# Only the real launcher beside a probe: no real api.ts is ever staged.
{ mkdir -p "$S/probe/engines" "$S/pcaller" && cp "$ROOT/skills/gemini/engines/api" "$S/probe/engines/api" && chmod 755 "$S/probe/engines/api"; } ||
  { echo "FAIL  fixture setup: the launcher"; exit 1; }
cat > "$S/probe/engines/api.ts" << 'PROBE' || { echo "FAIL  fixture setup: the probe"; exit 1; }
import { readdirSync } from "node:fs";
console.log(Object.keys(process.env).sort().join(" "));
console.log(process.cwd());
console.log(readdirSync(".").length);
PROBE
{ printf '#!/bin/sh\ntouch "%s/fake-bun-ran"\n' "$S" > "$S/pcaller/bun" && chmod 755 "$S/pcaller/bun" &&
  printf 'require("node:fs").writeFileSync("%s/preload-ran", "")\n' "$S" > "$S/evil.ts" && printf 'GM_DOTENV=1\n' > "$S/pcaller/.env" &&
  printf 'preload = ["%s/evil.ts"]\n' "$S" > "$S/pcaller/bunfig.toml"; } || { echo "FAIL  fixture setup: the planted bun, preload, .env and bunfig.toml"; exit 1; }
(cd "$S/pcaller" && PATH=".:$PATH" BUN_OPTIONS="--preload $S/evil.ts" BUN_CONFIG_VERBOSE_FETCH=curl TMPDIR=rel ../probe/engines/api /x 0 submit) > "$S/po" 2>&1; rc=$?
gm_t "launcher: a call by relative path runs the probe and exits with bun's status" test "$rc" -eq 0
gm_t "launcher: the bun planted in the caller's cwd never ran" test ! -e "$S/fake-bun-ran"
gm_t "launcher: no inherited or cwd preload ran" test ! -e "$S/preload-ran"
gm_t "launcher: only PATH and XDG_CONFIG_HOME reach api.ts" sh -c '[ "$(sed -n 1p "$0")" = "PATH XDG_CONFIG_HOME" ]' "$S/po"
gm_t "launcher: the probe ran in an empty dir that is gone afterwards" sh -c 'd=$(sed -n 2p "$0"); [ "$(sed -n 3p "$0")" = 0 ] && case $d in /*/gemini-api.*) [ ! -e "$d" ] ;; *) exit 1 ;; esac' "$S/po"

exit "$FAIL"
