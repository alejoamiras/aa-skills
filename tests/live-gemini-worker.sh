#!/usr/bin/env bash
# A live Gemini worker on the real pinned agy and the paid API: two short turns, whether the key reaches a command, and
# whether stop ends a command agy left running. It spends tokens, so it runs only with GEMINI_WORKER_LIVE=spend, from a
# Claude Code director started with --dangerously-skip-permissions; no workflow runs it. It never reads the key file or
# the pin: the pump does, and the facts it prints come from the pump's log, which the pump has already redacted.
set -uo pipefail
# An inherited GIT_DIR beats -C and would aim the scratch setup at another repository.
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_NAMESPACE GIT_PREFIX
export LC_ALL=C

if [[ ${GEMINI_WORKER_LIVE:-} != spend ]]; then
  echo "skip: the live Gemini worker test spends API tokens; set GEMINI_WORKER_LIVE=spend to run it"
  exit 0
fi
[[ $(uname -s) == Linux ]] || { echo "live: Linux only" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
CLI="$ROOT/skills/gemini/scripts/worker-gemini.sh"
CAP=400000
STAMP=$(date -u +%Y%m%dt%H%M%Sz)
RUN="$HOME/.cache/gemini-worker-live/$STAMP"
REPO="$RUN/repo" WT="$RUN/repo/.claude/worktrees/live"
SLUG="live-$STAMP"
STATE="$HOME/.cache/gemini-worker/$SLUG"
LOG="$STATE/log.ndjson"
FAIL=0 T0=$SECONDS

mkdir -p "${RUN%/*}" && mkdir -m 700 "$RUN" || { echo "live: cannot create $RUN" >&2; exit 1; }
# A failed assertion must not leave the worker or what agy started running; stop is idempotent, and the dirs stay for a
# post-mortem.
trap 'if [[ -d $STATE ]]; then "$CLI" stop "$SLUG" > /dev/null 2>&1 || echo "live: stop $SLUG failed: run it by hand" >&2; fi
  printf "live: scratch %s\nlive: state %s\n" "$RUN" "$STATE"' EXIT

# --- the scratch repo, its worktree and the probe ---------------------------------------------------------------------
# Without the owner's global and system git config, none of its hooks, templates or signing run in the scratch setup.
# The worker CLI keeps the full environment.
BARE=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
GIT=("${BARE[@]}" git -c user.name=live -c user.email=live@example.invalid)
{ "${GIT[@]}" init -q "$REPO" && echo live > "$REPO/README" && "${GIT[@]}" -C "$REPO" add README &&
  "${GIT[@]}" -C "$REPO" commit -qm init &&
  (cd "$REPO" && "${BARE[@]}" AGENTS_DIR="$RUN" "$ROOT/bin/agent-worktree" new live --no-start > "$RUN/worktree.out" 2>&1); } ||
  { echo "live: cannot make the scratch repo and its worktree; see $RUN/worktree.out" >&2; exit 1; }
cat > "$WT/probe.sh" << 'EOF'
#!/bin/sh
# Whether the key reached this command, never its value.
if [ -n "${GEMINI_API_KEY+set}" ]; then echo present; else echo absent; fi > "$(dirname "$0")/probe.out"
EOF
chmod +x "$WT/probe.sh" || exit 1

A=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
B=$(od -An -N10 -tu1 /dev/urandom | awk '{ for (i = 1; i <= NF; i++) printf "%c", 97 + $i % 26 }')
[[ ${#A} == 16 && ${#B} == 10 ]] || { echo "live: cannot draw the nonces" >&2; exit 1; }
# A finished command's leftovers are ended by agy, so the sleep must outlive the tool call inside a running command.
printf '%s\n' \
  "A short test of this worker. Do exactly these steps in this worktree, then answer." \
  "1. Write $A to the file nonce.txt, and nothing else." \
  "2. Run the command \`sleep 600 & wait\` so that your tool call returns at once while the command keeps running. Do not wait for it to finish and do not stop it. Do not use nohup or a bare \`&\` instead: what a finished command leaves behind is ended." \
  "3. Run ./probe.sh once. Do not open probe.out." \
  "4. Answer with the single word $B and nothing else. Say nothing about environment variables." > "$RUN/m1"
echo "What single word did my previous message ask you to answer with? Answer with that word only." > "$RUN/m2"

# --- start, two messages at once, every turn ----------------------------------------------------------------------------
"$CLI" start "$WT" --name "$SLUG" --effort low --cap "$CAP" > "$RUN/start.out"
rc=$?
cat "$RUN/start.out"
if ((rc)); then
  echo "live: start exited $rc" >&2
  exit "$rc"
fi
{ "$CLI" send "$SLUG" "$RUN/m1" > "$RUN/send1.out" && "$CLI" send "$SLUG" "$RUN/m2" > "$RUN/send2.out"; } ||
  { echo "live: send failed" >&2; exit 1; }
# Message 1's SEEN: a later one could already be past turn 1.
SEEN=$(sed -n 's/^GEMINI_WORKER_SEEN=//p' "$RUN/send1.out")
: > "$RUN/wait.out"
for ((i = 0; i < 4; i++)); do
  [[ $SEEN =~ ^[0-9]+$ ]] || { echo "live: no GEMINI_WORKER_SEEN to wait from" >&2; exit 1; }
  ((SEEN < 2)) || break
  "$CLI" wait "$SLUG" "$SEEN" --timeout 300 > "$RUN/wait.$i"
  rc=$?
  cat "$RUN/wait.$i" >> "$RUN/wait.out"
  if ((rc)); then
    echo "live: wait exited $rc. agy's stderr lines from the log, then the wait output:" >&2
    jq -rR 'fromjson? | select(.src == "err") | .ev | tostring' "$LOG" >&2
    cat "$RUN/wait.$i" >&2
    "$CLI" stop "$SLUG"
    exit 1
  fi
  SEEN=$(sed -n 's/^GEMINI_WORKER_SEEN=//p' "$RUN/wait.$i")
done

# --- what the worker did and the director saw ---------------------------------------------------------------------------
# The worker wrote these files: a FIFO would block the read, and a symlink would read whatever it names.
N="" W="not a regular file"
[[ -f $WT/nonce.txt && ! -L $WT/nonce.txt ]] && N=$(head -c 64 "$WT/nonce.txt" | tr -d '[:space:]')
if [[ -f $WT/probe.out && ! -L $WT/probe.out ]]; then
  W=$(head -c 64 "$WT/probe.out" | tr -d '[:space:]')
  [[ $W == present || $W == absent ]] || W="neither present nor absent"
fi
if [[ $N == "$A" ]]; then echo "ok    nonce.txt holds A"; else echo "FAIL  nonce.txt holds A"; FAIL=1; fi
if [[ $W == present || $W == absent ]]; then
  echo "ok    the worker ran probe.sh"
else
  echo "FAIL  the worker ran probe.sh (probe.out: $W)"
  FAIL=1
fi
for n in 1 2; do
  if jq -enR --argjson n "$n" --arg b "$B" 'first(inputs | fromjson? | objects | select(.src == "gw" and .type == "turn" and .n == $n))
      | .from == "director" and .status == "SUCCESS" and (.tokens | type) == "number" and (.answer | type) == "string" and (.answer | contains($b))' "$LOG" > /dev/null; then
    echo "ok    turn $n: from the director, SUCCESS, a token count, and an answer holding B"
  else
    echo "FAIL  turn $n: from the director, SUCCESS, a token count, and an answer holding B"
    FAIL=1
  fi
done
if grep -q '^turn 1: from=director status=SUCCESS ' "$RUN/wait.out" && grep -q '^turn 2: from=director status=SUCCESS ' "$RUN/wait.out"; then
  echo "ok    wait showed both turn lines with status=SUCCESS"
else
  echo "FAIL  wait showed both turn lines with status=SUCCESS"
  FAIL=1
fi
TOKENS=$(sed -n 's/^GEMINI_WORKER_TOKENS=//p' "$RUN/wait.out" | tail -n 1)
if [[ $TOKENS =~ ^([0-9]+)/$CAP$ ]] && ((BASH_REMATCH[1] < CAP)); then
  echo "ok    the worker's total, $TOKENS, is under the cap"
else
  echo "FAIL  the worker's total, $TOKENS, is under the cap"
  FAIL=1
fi

# --- the sleep agy left running, found by the worker's marker, then stop -------------------------------------------------
MARKER=$(jq -rR 'fromjson? | select(.src == "gw" and .type == "ready") | .marker' "$LOG" | tail -n 1)
SP="" SSID="" SSTART=""
if [[ $MARKER =~ ^[a-z0-9_-]+\.[0-9a-f]{32}$ ]]; then
  while IFS= read -r f; do
    p="${f#/proc/}"
    p="${p%/environ}"
    [[ $(tr '\0' ' ' < "/proc/$p/cmdline" 2> /dev/null) =~ (^|/)sleep\ 600\ $ ]] || continue
    read -r s 2> /dev/null < "/proc/$p/stat" || continue
    # From the third field on: the command name before it may hold spaces; session is index 3, start time 19.
    read -r -a st <<< "${s##*) }"
    SP="$p" SSID="${st[3]}" SSTART="${st[19]}"
    break
  done < <(grep -lzxF -- "GEMINI_WORKER_ID=$MARKER" /proc/[0-9]*/environ 2> /dev/null)
fi
if [[ -n $SP ]] && grep -qzxF -- "GEMINI_WORKER_ID=$MARKER" "/proc/$SP/environ" 2> /dev/null; then
  echo "ok    the sleep 600 is alive with the worker's marker (pid $SP, session $SSID, start $SSTART)"
else
  echo "FAIL  the sleep 600 is alive with the worker's marker"
  FAIL=1
fi
"$CLI" stop "$SLUG"
rc=$?
if ((rc == 0)); then echo "ok    stop exits 0"; else echo "FAIL  stop exits 0 (it exited $rc)"; FAIL=1; fi
s=""
[[ -n $SP ]] && read -r s 2> /dev/null < "/proc/$SP/stat"
read -r -a st <<< "${s##*) }"
# pgrep exits 1 for no match only; any other failure must not pass for an empty session.
prc=2
[[ -n $SSID ]] && { pgrep -s "$SSID" > /dev/null; prc=$?; }
if [[ -n $SP && ${st[19]:-} != "$SSTART" ]] && ((prc == 1)); then
  echo "ok    the sleep and its session are gone"
else
  echo "FAIL  the sleep and its session are gone"
  FAIL=1
fi
if [[ -n $MARKER && -z $(grep -lzxF -- "GEMINI_WORKER_ID=$MARKER" /proc/[0-9]*/environ 2> /dev/null) ]]; then
  echo "ok    no process holds the marker"
else
  echo "FAIL  no process holds the marker"
  FAIL=1
fi

# --- facts for the lessons file: field names and counts, no answer text --------------------------------------------------
echo "== facts =="
echo "events: $(jq -rR 'fromjson? | select(.src == "agy") | .ev | objects | .event' "$LOG" | sort | uniq -c | awk '{ printf "%s%s=%s", s, $2, $1; s = " " }')"
echo "step types: $(jq -rR 'fromjson? | select(.src == "agy") | .ev | objects | .step_update | objects | .step_type' "$LOG" | sort | uniq -c | awk '{ printf "%s%s=%s", s, $2, $1; s = " " }')"
jq -nrR '[inputs | fromjson? | objects] as $e
  | range($e | length) | select($e[.].src == "in" and $e[.].refused == null) as $i
  | ([$e[($i + 1):][] | select(.src == "agy" and (.ev | type) == "object")] | first) as $n
  | "turn start after message \($e[$i].name): \($n.ev.event // "none")"
    + (if ($n.ev.step_update | type) == "object" then " step_type=\($n.ev.step_update.step_type) state=\($n.ev.step_update.state)" else "" end)' "$LOG"
jq -rR 'fromjson? | select(.src == "agy") | .ev | objects | .result | objects | "result: num_turns=\(.num_turns) status=\(.status)"' "$LOG"
echo "result fields: $(jq -rR 'fromjson? | select(.src == "agy") | .ev | objects | .result | objects | keys[]' "$LOG" | sort -u | paste -sd' ' -)"
echo "usage fields: $(jq -rR 'fromjson? | select(.src == "agy") | .ev | objects | .result | objects | .usage | objects | keys[]' "$LOG" | sort -u | paste -sd' ' -)"
echo "probe.out: $W"
jq -rR 'fromjson? | select(.src == "gw" and .type == "turn") | "turn \(.n): from=\(.from) tokens=\(.tokens) total=\(.total)"' "$LOG"
echo "total: $TOKENS"
jq -rR 'fromjson? | select(.src == "gw" and .type == "ready") | "pin: agy \(.version) sha256 \(.sha256), model \(.model), effort \(.effort)"' "$LOG"
echo "sleep: pid ${SP:-none}, session ${SSID:-none}, start ${SSTART:-none}"
echo "wall-clock: $((SECONDS - T0)) s"
exit "$FAIL"
