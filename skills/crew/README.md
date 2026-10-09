# crew

Live Claude Code workers on your other [`claude-usage`](../../bin/claude-usage) accounts. A director session runs `scripts/crew.sh spawn`. Each worker gets its own session on a private tmux server (`tmux -L crew`), and the two talk both ways with Claude Code's `SendMessage` at `uds:<socket>` addresses. You can attach to any worker to watch or steer it.

How it stays safe to run next to everything else:

- **Clean environment.** The worker's env is rebuilt from a short allowlist inside the pane's exec chain. The director's messaging token, and anything a tmux server carries globally, never reach it.
- **Trust is copied, never granted.** `claude-usage prepare` trusts a folder for the worker's account only where the director already trusts it or a parent.
- **No config races.** `.claude.json` changes go through a fail-closed per-account lock. They are refused while a session or a pending launch lives on the account.
- **Ownership.** Every worker is tagged with its director's pid and start time. `stop` checks the worker's identity before any signal, and never acts by name.

For one-shot, read-only work on another account, the [`claude`](../claude/) skill's headless worker role is lighter. The director's playbook lives in [`SKILL.md`](SKILL.md).
