# run-isolation

Retrofit a repo so **many agents can run its local services and tests concurrently on one machine** without clashing — the recurring pain when several worktrees each start anvil, the Aztec sandbox, a PXE, or a dev server and assume they own the box.

> This README explains the idea. The procedure the agent follows is in [`SKILL.md`](SKILL.md); the canonical code templates live in the [`my-stack`](../my-stack/) skill.

## The principle

**Isolate by ownership, not by technology.** A *run* owns a namespace — ports, a process group, a data dir, optionally a compose project — keyed off one `RUN_ID`, and tears down exactly what it owns. The expensive bug isn't a port clash; it's cleanup that kills processes you don't own (`pkill -f anvil`), which makes another agent think its network crashed.

## What it installs

1. **`~/.agents` registry** — a host-level, atomically-locked, self-healing table (`ports.md`) that every agent consults: the shared source-of-truth for who is running what and where, and a race-free port allocator (closes the TOCTOU hole in bind-and-release).
2. **Process-group ownership** — services spawned `detached`, torn down by `kill(-pgid)`. Surgical, never by name.
3. **Per-run data dirs** — no shared `~/.aztec` / `~/.foundry` collisions.
4. **Compose-project-per-run** — for any *containerized* dependency (the Aztec sandbox is native as of v5, so it's a plain host process).

Plus COOP/COEP + `crossOriginIsolated` assertion for browser E2E (Barretenberg WASM).

## Invocation

`/run-isolation`, or phrases like "make this repo parallel-safe", "port-aware this repo", "agents keep killing each other's processes". Audits the repo, then applies the four primitives and verifies two runs coexist.
