---
name: handoff
description: Continues this Claude Code conversation on another claude-usage account with its full context, for when this account runs low. Prints the one line to run after /exit; `clu` then copies the session into that account and resumes it there. Use when the owner asks to switch or move accounts, to continue on another account, or says this one is nearly out ("/handoff", "switch accounts", "move this session to another account"). Claude Code only.
---

# handoff

1. Run `claude-usage handoff [account]`. With no account it picks the best one other than this session's. It prints that account's headroom and the line to run.
2. Before relaying it, name in one line what stops at /exit: background agents or shells still running, Monitors, cron jobs, artifact watches. If work is in flight, ask whether to wait for it first.
3. In a start-orchy orchestrator, use `/pause-orchy handoff to <account>` instead: it releases the seat first and prints the same line; `/start-orchy` in the carried session re-arms the loop and the Monitor.
4. Relay the output verbatim in a code block. Never run the printed line yourself: it must run after this session exits, or the two copies of the conversation drift apart.
