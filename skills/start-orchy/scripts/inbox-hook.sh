#!/usr/bin/env bash
# PostToolUse hook of an orchy lead: offers the orchestrator's queued notes (`orchy.sh say`) to the lead's own thread.
# Usage, from the lead's --settings file: inbox-hook.sh <inbox.jsonl>. The cursor file beside it counts the bytes delivered.
# It runs after every tool call, so the common case (nothing new) must exit before reading stdin, locking or calling jq.
# Hooks of parallel tool calls run concurrently: everything past the fast path holds a flock on the inbox itself.
set -u
export LC_ALL=C   # byte lengths, not characters: the cursor is a byte offset
f=${1:?usage: inbox-hook.sh <inbox.jsonl>}; c="${f%.jsonl}.cursor"
size=$(stat -c %s "$f" 2>/dev/null) || exit 0
cur=$(cat "$c" 2>/dev/null); [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
[ "$size" -gt "$cur" ] || exit 0
# a subagent's tool call fires this hook too; a note it consumed would never reach the lead
[ -z "$(jq -r '.agent_id // empty' 2>/dev/null)" ] || exit 0
exec 8>>"$f"; flock -w 5 8 || exit 0
cur=$(cat "$c" 2>/dev/null); [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
rest=$(tail -c +"$((cur + 1))" "$f" | head -c 65536; echo .); rest=${rest%.}
# Whole lines only, at most 4 KiB, never fewer than one (say caps a line at 3 KiB); a line without its newline is still being written.
take=""
while [[ "$rest" == *$'\n'* ]]; do
  line=${rest%%$'\n'*}
  [ -n "$take" ] && [ $(( ${#take} + ${#line} + 1 )) -gt 4096 ] && break
  take+="$line"$'\n'; rest=${rest#*$'\n'}
done
[ -n "$take" ] || exit 0
msg=$(printf '%s' "$take" | jq -Rrs 'split("\n") | map(select(length > 0) | fromjson? | "ORCHY-STEER: " + .text) | join("\n\n")') || exit 0
# Advance only after the output is written: a failed write leaves the notes for the next tool call.
if [ -n "$msg" ]; then jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}' || exit 0; fi
printf '%s\n' "$((cur + ${#take}))" > "$c.tmp.$$" && mv "$c.tmp.$$" "$c"
