# claude

Second-opinion consults from the Anthropic model family via the headless [Claude Code CLI](https://code.claude.com/docs/en/headless) (`claude -p`). This is the **foreign-reviewer leg for Codex-driven sessions** — the mirror of [`codex`](../codex/), which is the foreign-reviewer leg when Claude Code drives. [`blueprint`](../blueprint/) names the two legs by role, so that protocol runs from either harness; [`harden`](../harden/) still assumes a Claude Code driver (mapping it is a follow-up).

Ships two helper scripts with the same positional contract and trailer as their codex counterparts: `scripts/run-claude.sh` (fresh session — prompt file in, response + session ID out) and `scripts/resume-claude.sh` (continue a captured session for follow-ups and rebuttals). The reviewer is read-only and isolated by construction — `--safe-mode` (no user CLAUDE.md, hooks, MCP, plugins; OAuth still works, unlike `--bare`), `--restricted --strict-mcp-config`, `--tools Read,Grep,Glob` confined to the cwd — never hangs on a permission prompt (`--permission-prompts none`), rejects malformed or error results with a non-zero exit, and resumes sessions by explicit ID only — never `--continue`, never fixed shared paths. There is deliberately no writing mode.

One constraint worth knowing up front: from inside Codex the scripts must run **escalated** — Claude Code needs the network and writes to `~/.claude`, both of which Codex's sandbox blocks — and when escalation cannot be granted (`approval_policy = never`), the foreign review is blocked rather than faked.

Invocation and effort conventions live in [`SKILL.md`](SKILL.md).
