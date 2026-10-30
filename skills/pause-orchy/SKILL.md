---
name: pause-orchy
description: Hands a running start-orchy program's orchestrator seat over before the owner moves the orchestrator to another claude-usage account. In the orchestrator's session it takes a last snapshot, stops the tick loop and the event Monitor, writes a handover line to notes.md and releases the seat; leads and merge watchers keep running, and /start-orchy from a session on the other account resumes and adopts them. With "handoff to <account>" it also prints the line that continues this same conversation, full context included, on that account. Use ONLY when the owner asks for it ("/pause-orchy", "pause orchy", "move orchy to another account", "/pause-orchy handoff to <account>"). Claude Code only; never from inside a lead or a crew worker.
---

# pause-orchy

Run it in the orchestrator's session, from the repository's root. `ORCHY` is `~/.claude/skills/start-orchy/scripts/orchy.sh`.

1. `ORCHY snapshot`: the live leads, the armed watchers and the waiting record as they stand.
2. Stop the loop (`CronList`, then `CronDelete` the job whose prompt starts `Program status tick for`) and the event Monitor (`TaskStop` on the `ORCHY wait` task). Stop no lead and disarm no watcher: they finish their work and write their reports, which the next session reads.
3. Append one dated line to `$ORCHY_HOME/notes.md` (`ORCHY home` prints the path): `<date> paused for an account move: leads <keys>; watchers <names>; waiting <refs>`. Keys, names and refs only, never an account name.
4. `ORCHY unlock`. From here this session launches nothing: `launch` and `resume` refuse a session that does not hold the seat.
5. Tell the owner, in two lines, that the program is paused with N leads and M watchers still running, and that the next step is `/start-orchy` from the repository's root in a session on the other account (`claude-usage run <account>`). That session takes the seat, adopts what is running, records its own session URL, and keeps leads off the account it runs on.
6. With `handoff to <account>` (or a bare `handoff`: the best account other than this one), run `claude-usage handoff <account>` and relay its output verbatim in a code block instead of step 5's second line, then one line: once the carried session opens, type `/start-orchy` there; it takes the seat again and re-arms the loop and the Monitor, with this conversation's context intact. Never run the printed line yourself: it must run after this session exits.

While no session holds the seat, the program shows as stopped and nothing new is spawned or armed. To end a program instead, use start-orchy's Stop (Phase 4).
