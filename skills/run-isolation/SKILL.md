---
name: run-isolation
description: Retrofit a repo's local services, test runners, and E2E so MANY agents can run them concurrently on one machine without clashing. Fixes hardcoded ports, broad `pkill`/`killall` cleanup that murders other agents' processes, fixed data dirs, and sole-machine-ownership assumptions. Installs a host-level run registry (~/.agents) as a shared source-of-truth + race-free port allocator, process-group ownership for surgical teardown, per-run data dirs, and compose-project-per-run for any containerized dependency. Trigger phrases include "/run-isolation", "make this repo parallel-safe", "port-aware this repo", "isolate runs", "multiple agents clashing ports", "tests fight over ports", "agents killing each other's processes", "make the e2e parallel-safe". Use when a repo assumes it owns the machine. Pairs with the my-stack skill (canonical code templates). NOT a performance or security pass.
---

# Run isolation

**The problem.** Multiple agents run on one machine (often separate git worktrees of the same repo). Each spins up local services for tests/E2E — anvil (default 8545), the Aztec sandbox, a PXE, a playground, dev servers — and they step on each other: ports clash, one run's cleanup kills another run's processes, and the victim agent concludes "the network is broken" and burns time chasing a phantom.

**The principle: isolate by ownership, not by technology.** A *run* owns a namespace of resources — ports, a process group, a data dir, optionally a compose project — keyed off one `RUN_ID`, and tears down **exactly** what it owns. Never by name. Never "kill all anvils."

This skill is the **audit-and-apply procedure** for any repo (owned or not). The canonical code templates live in the `my-stack` skill; reference them rather than reinventing.

## When to apply

Auto-applies on the symptoms above ("agents killing each other's processes", "tests fight over ports", "make this parallel-safe"). Also worth applying proactively to any repo that starts external services in tests or dev.

## Step 1 — Audit (find the sole-ownership assumptions)

Grep the run path (test setup, CI, dev scripts, docker-compose, `.env`, Playwright/vitest config) for:

- **Hardcoded ports**: `8545`, `:3000`, fixed PXE / sandbox / playground / app ports.
- **Broad process cleanup** (the worst offender — this is what kills other agents): `pkill -f anvil`, `pkill node`, `killall`, `lsof -ti:8545 | xargs kill`. Anything that matches by name or by a port you don't own.
- **Fixed data dirs**: `~/.aztec`, `~/.foundry`, fixed `/tmp/...`, sqlite/LevelDB at fixed paths.
- **Sole-ownership assumptions**: "port in use → assume a crashed run, kill it"; health checks that probe a fixed port the run doesn't own and infer global breakage.
- **Browser E2E**: missing COOP/COEP headers; reliance on "localhost auto-enables SharedArrayBuffer".

List what you find before changing anything.

## Step 2 — Apply the four primitives

### 1. Ports — the `~/.agents` registry (shared source-of-truth + race-free allocator)

Don't let each repo reinvent allocation. Use one host-level registry every agent on the machine consults:

- **`~/.agents/ports.md`** — a readable table any agent can consult: `runId | service | host:port | pid | worktree | started`. This is the "who is running what, and where" source-of-truth.
- **All mutations under an atomic lock** (`~/.agents/ports.lock` via `mkdir` — dependency-free, atomic on POSIX).
- **`claim(service)`**: lock → reap rows whose owner `pid` is dead (`kill -0` fails) → pick a free port (per-worktree base range, skipping ports already in the table) → reserve the row → unlock → start the service → health-check (re-claim if a residual race lost the bind).
- **`release(runId)`**: lock → drop this run's rows. Called on teardown.
- **Self-healing**: every read reaps dead-owner rows, so a crashed agent's entries never leak and block ports forever.

This closes the TOCTOU hole in the naive `bind(0) → close → start-later` pattern, and gives cross-agent **visibility** a per-worktree lockfile can't. `--port 0` self-binding is a fine optimization where a service supports it (anvil takes `--port`, but not every tool treats `0` as ephemeral), so the registry is the baseline, not `--port 0`.

### 2. Process ownership — groups, not names

Spawn each service in its own **process group** (`detached: true` in Node/Bun → the child's pid *is* the new pgid). Record `{ pid, pgid, cwd, cmd, startedAt, runId }` in run-local state. Tear down with `process.kill(-pgid, 'SIGTERM')`, then `SIGKILL` after a grace window — this kills the run's whole process tree and **nothing else**. Validate the record before killing (guards against PID reuse). Raw `pkill -f "<unique-marker>"` is **orphan-recovery fallback only**, never the normal teardown path.

### 3. Data dirs — per-run, isolated

Each service gets a per-run data dir (`$RUNTIME/<run-id>/<service>`). Override `HOME` / `XDG_*` / `--datadir` / tool-specific env so global state (`~/.aztec`, `~/.foundry`) can't collide across runs.

### 4. Containerized dependencies — compose project per run

For any service that *is* containerized (note: the **Aztec sandbox runs natively as of v5 — it is NOT a container**, so it's a host process handled by primitives 1–3): use `docker compose -p $RUN_ID`, no hardcoded `container_name`, project-scoped volumes/labels, teardown `docker compose -p $RUN_ID down -v --remove-orphans`. Don't nest an already-containerized service inside another container. Host networking is not an escape hatch — it shares the host network and reintroduces the clash.

## Step 3 — Browser E2E (if applicable)

Bake `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` (or `credentialless`) into the dev/test server, and assert `await page.evaluate(() => crossOriginIsolated)` as a test precondition. Do **not** rely on "localhost auto-enables SharedArrayBuffer" — it is a secure context but SAB sharing still depends on cross-origin isolation, and the localhost behavior is not guaranteed across browsers/versions. (This matters for Barretenberg WASM in Aztec dApps.)

## Step 4 — Verify it actually parallelizes

- Start two runs at once (two worktrees, or the same repo twice). Both must come up on **distinct** ports, both must appear as rows in `~/.agents/ports.md`, and neither may kill the other.
- Kill one run mid-flight (`kill -9` its supervisor). The other must be unaffected; the dead run's rows must be reaped on the next registry read.
- Grep confirms **zero** hardcoded ports and **zero** by-name/by-port kills remain on the run path.

## Discipline (the bans — enforce these)

- **NO hardcoded ports** anywhere on the run path.
- **NO by-name / by-port kills** as normal teardown (`pkill -f anvil`, `killall node`, `lsof -ti:PORT | xargs kill`). Kill by process group you own.
- **NO fixed data dirs** shared across runs.
- A service being unreachable is **NOT** evidence it's broken — check whether THIS run owns it (registry + pgid) before diagnosing or restarting anything.

## NOT this skill

- Canonical code templates (registry module, `agent.sh`, `global-setup.ts`) → `my-stack`.
- Not a performance pass, not a security audit (`/harden`), not a diff review (`/code-review`).
