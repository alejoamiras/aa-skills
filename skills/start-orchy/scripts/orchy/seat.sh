# shellcheck shell=bash
# The orchestrator seat: one session per repo, owned by pid and start time.
seat_held() { # only the session in the seat spawns, so a session that handed it over, or never took it, cannot
  local me p st; me=$(session_pid)
  read -r p st _ < "$H/orchestrator.lock" 2>/dev/null || { echo "refused: no session holds the seat of $REPO; ORCHY lock first" >&2; return 1; }
  [ "$p" = "$me" ] && [ -n "$st" ] && [ "$st" = "$(pid_start "$me")" ] || { echo "refused: this session (pid $me) does not hold the seat of $REPO (pid $p does)" >&2; return 1; }
}
drop_main_ban() { # an earlier bootstrap banned the slot label main with the roster, which refuses every mention of a main branch
  local b n t; [ -f "$LOCAL" ] && b=$(jq -r '.prompt_ban // empty' "$LOCAL" 2>/dev/null) && [ -n "$b" ] || return 0
  n=$(sed -E 's/\(main\|/(/g; s/\|main\)/)/g; s/\|main\|/|/g' <<<"$b"); [ "$n" != "$b" ] || return 0
  if t=$(mktemp "$H/.local.XXXXXX") && jq --arg b "$n" '.prompt_ban = $b' "$LOCAL" > "$t" && mv -f "$t" "$LOCAL"; then echo "prompt_ban no longer bans the slot label main"
  else rm -f "${t:-}"; echo "warning: could not drop main from prompt_ban" >&2; fi
}
orchy_lock() {
  f="$H/orchestrator.lock"; me=$(session_pid)
  # The seat names the session and its messaging address so a coordinator can find it; pid and start time stay the only
  # ownership test, and the messaging token is never read.
  sess=${CLAUDE_CODE_SESSION_ID:-${ORCHY_SESSION:--}}; addr=-; [ -n "${CLAUDE_CODE_MESSAGING_SOCKET:-}" ] && addr="uds:$CLAUDE_CODE_MESSAGING_SOCKET"
  for _ in 1 2 3; do
    if ( set -o noclobber; echo "$me $(pid_start "$me") $(utc_now) $sess $addr" > "$f" ) 2>/dev/null; then echo "locked $REPO for session pid $me ($sess)"; ev seat.lock session="$sess"; drop_main_ban; exit 0; fi
    read -r p st t hs _ < "$f" 2>/dev/null || { sleep 1; continue; }
    [ "$p" = "$me" ] && [ "$st" = "$(pid_start "$me")" ] && { echo "already locked by this session (pid $me)"; drop_main_ban; exit 0; }
    if [ -d "/proc/$p" ] && [ "$(pid_start "$p")" = "$st" ]; then echo "refused: another orchestrator holds $REPO (pid $p, session ${hs:--}, since $t)"; exit 2; fi
    # a stale holder: one contender at a time replaces it (the flock dies with its holder), so two contenders cannot unlink each other's fresh lock
    ( flock -w 5 9 || exit 1; read -r p2 st2 _ < "$f" 2>/dev/null; [ "$p2" = "$p" ] && [ "$st2" = "$st" ] && rm -f "$f"; exit 0 ) 9>"$f.takeover" || sleep 1
  done; echo "lock: could not claim $f"; exit 2
}
orchy_unlock() {
  # Under the takeover lock, so the seat read is the seat removed: never a live other session's, never a contender's fresh one.
  need flock; f="$H/orchestrator.lock"; me=$(session_pid)
  ( flock -w 5 9 || { echo "refused: the seat's takeover lock is busy"; exit 2; }
    [ -f "$f" ] || { echo "unlocked (no seat was held)"; exit 0; }
    read -r p st _ hs _ < "$f" 2>/dev/null; mine=0; gone=1
    [ "$p" = "$me" ] && [ "$st" = "$(pid_start "$me")" ] && mine=1
    [ -n "$p" ] && [ -d "/proc/$p" ] && [ "$(pid_start "$p")" = "$st" ] && gone=0
    if [ $mine = 1 ] || [ $gone = 1 ]; then rm -f "$f"; echo "unlocked"; ev seat.unlock session="${hs:--}"; exit 0; fi
    echo "refused: pid $p holds the seat and is alive; it is not this session"; exit 2 ) 9>"$f.takeover"
}
