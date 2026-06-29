---
name: my-stack
description: "Use when scaffolding a new repository, configuring development tooling, setting up CI/CD pipelines, or when working on owned repositories. Covers the preferred stack: bun, biome, husky, commitlint, lint-staged, shellcheck, actionlint, sort-package-json, playwright, vitest, OpenTofu, monorepo structure, trusted publisher for npm, OIDC, React + Vite frontend defaults, supply-chain hardening (7-day min-age, frozen lockfile), and parallel-safe E2E patterns."
---

# My Preferred Development Stack

Tooling, conventions, scaffolding, and CI/CD for repositories I own. Use when scaffolding new repos or configuring existing ones. Pair with `~/.claude/CLAUDE.md` for the operating principles (workflow, plan protocol, code organization, security mindset).

## Core Tooling

| Tool | Purpose | Replaces |
|------|---------|----------|
| **bun** | Package manager, runtime, test runner, workspaces | npm/yarn/pnpm, jest |
| **biome** | Linting + formatting (single tool) | eslint + prettier |
| **vitest** | React component test runner (when Vite is in play) | jest |
| **husky** | Git hooks | n/a |
| **lint-staged** | Run linters on staged files only | n/a |
| **commitlint** | Enforce conventional commits | n/a |
| **shellcheck** | Shell script linting | n/a |
| **actionlint** | GitHub Actions workflow linting | n/a |
| **sort-package-json** | Consistent package.json key ordering | n/a |
| **playwright** | E2E testing (browser) | cypress, puppeteer |
| **storybook** | Component catalog / visual docs (frontend) | n/a |
| **ncu** (npm-check-updates) | Dependency update checking | npm outdated |
| **OpenTofu** | Infrastructure as Code | Terraform |

## Frontend defaults (when project has UI)

- **Framework**: React (current stable) + TypeScript `strict`
- **Bundler / dev**: Vite (current stable), run via `bunx --bun vite`
- **Aztec wallet**: `@aztec/wallet-sdk` directly (framework-agnostic)
- **Server state**: TanStack Query — handles API fetch/cache/refetch/invalidate/mutations. *Note:* TanStack ecosystem was hit by a May 11, 2026 npm supply-chain attack; `@tanstack/query` itself was clean, and the 7-day min-age below catches such attacks regardless. Smaller-surface alternative: SWR (Vercel).
- **Client state (global)**: Jotai — atomic state, fine-grained subscriptions
- **Client state (medium scope)**: Context + Reducer with a `createReducerHook` factory
- **Visual catalog**: Storybook
- **CSS / styling**: Tailwind v4 + `@tailwindcss/vite` + `tailwind-variants` + `tailwind-merge` + `clsx`; **shadcn/ui** for accessible primitives (Dialog, DropdownMenu, Command, Sonner, Form, Sheet, Popover). Panda CSS + Park UI was considered as the type-safety-purist alternative but rejected pragmatically for ecosystem reasons.
- **Add only when needed**: wagmi v2 + viem (L1 work), Next.js (real SSR needs)

## Dependency Management

- Run **ncu** periodically (when starting a new project, or as a dedicated dependency-update task) — NOT per feature branch
- `bunx npm-check-updates -u` to update, then `bun install`, then run full test suite to catch breakage
- Dependency updates should be their own PRs, separate from feature work

## Project Structure (Monorepo)

```
├── packages/
│   ├── <package-a>/
│   │   ├── src/
│   │   │   ├── *.ts
│   │   │   └── *.test.ts            # Unit tests colocated
│   │   ├── e2e/                      # E2E tests
│   │   └── package.json
│   └── <package-b>/
├── infra/tofu/                       # OpenTofu IaC (when needed)
├── implementations-plan/             # Committed plan artifacts
│   ├── index.md                      # Plans + lessons index (kept up to date)
│   └── <plan-name>/
│       ├── plan.md
│       └── lessons/
│           └── phase-N.md
├── docs/
│   ├── roadmap.md                    # Phases, decisions, backlog
│   └── ci-pipeline.md                # CI/CD reference
├── scripts/run/                      # Run isolation (parallel-safe local services)
│   ├── registry.ts                   # Shared ~/.agents port registry + allocator
│   ├── resolve-ports.ts              # Claims ports per service from the registry
│   └── agent.sh                      # Per-worktree runner
├── .github/workflows/
├── CLAUDE.md                         # Project instructions
├── biome.json
├── bunfig.toml                       # Supply-chain settings (min-age etc.)
├── commitlint.config.ts
├── .husky/
└── package.json                      # Root workspace config
```

For single-package repos, flatten (no `packages/` dir) but keep all other conventions.

---

## Scaffolding a New Repo

### 1. Initialize

```bash
mkdir <project-name> && cd <project-name>
git init
bun init -y
bunx npm-check-updates -u           # land on current latest deps
bun install
```

### 2. Monorepo structure (if multi-package)

```bash
mkdir -p packages/<pkg>/src
```

Root `package.json`:

```json
{
  "workspaces": ["packages/*"]
}
```

### 3. Supply-chain hardening (do this BEFORE installing prod deps)

Create `bunfig.toml`:

```toml
[install]
minimumReleaseAge = 604800        # 7 days — blocks fresh npm publishes (supply-chain protection)
# minimumReleaseAgeExcludes = ["@org/internal-pkg"]  # CVE bypass: add here, install, follow-up PR removes

[install.lockfile]
frozen = false                    # local dev allows lockfile updates
```

In CI workflows, use `bun install --frozen-lockfile` (or `bun ci`) so any un-committed dependency change fails the pipeline.

Commit `bun.lock`.

### 4. Biome (lint + format — replaces ESLint + Prettier)

```bash
bun add -d @biomejs/biome
bunx biome init
```

In `biome.json`, enable `noExplicitAny` as error:

```json
{
  "linter": {
    "rules": {
      "suspicious": {
        "noExplicitAny": "error"
      }
    }
  }
}
```

### 5. Commit hygiene

```bash
bun add -d husky lint-staged @commitlint/cli @commitlint/config-conventional
bunx husky init
```

`package.json`:

```json
{
  "lint-staged": {
    "*.{ts,tsx,js,jsx}": ["biome check --write"],
    "*.sh": ["shellcheck"],
    ".github/workflows/*.yml": ["actionlint"],
    "**/package.json": ["sort-package-json"],
    "infra/tofu/*.tf": ["tofu fmt"]
  }
}
```

`commitlint.config.ts`:

```ts
export default { extends: ['@commitlint/config-conventional'] };
```

Hooks:

```bash
echo "bunx commitlint --edit \$1" > .husky/commit-msg
echo "bunx lint-staged" > .husky/pre-commit
```

### 6. Shell & workflow linting

```bash
brew install shellcheck actionlint     # macOS; use apt/dnf/etc. otherwise
bun add -d sort-package-json
```

### 7. Testing

**Backend / SDK / pure TS — `bun:test`** (built-in, zero config):

```bash
# Tests run via `bun test`. Colocate as *.test.ts next to source.
```

**React component tests — Vitest** (when Vite is the bundler):

```bash
bun add -d vitest @vitest/ui jsdom @testing-library/react @testing-library/jest-dom @testing-library/user-event
```

`vitest.config.ts`:

```ts
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    setupFiles: ['./tests/setup.ts'],
  },
});
```

`tests/setup.ts`:

```ts
import '@testing-library/jest-dom/vitest';
```

**Pure-Bun React alternative — `bun:test` + happy-dom + RTL** (for intentionally Bun-pure projects):

```bash
bun add -d happy-dom @happy-dom/global-registrator @testing-library/react
```

`tests/dom-setup.ts`:

```ts
import { GlobalRegistrator } from "@happy-dom/global-registrator";
GlobalRegistrator.register();
```

`bunfig.toml`:

```toml
[test]
preload = "./tests/dom-setup.ts"
```

**Important:** the setup file MUST NOT import `@testing-library/react` — preload files run sequentially; DOM globals need to be on `globalThis` before RTL evaluates.

**E2E — Playwright**:

```bash
bun add -d @playwright/test
bunx playwright install
```

**Test structure convention** — group by subject, nest by variant:

```ts
describe("ProverClient", () => {
  describe("Local", () => { /* ... */ });
  describe("Remote", () => { /* ... */ });
  describe.skipIf(!process.env.AZTEC_NETWORK)("Network", () => { /* ... */ });
});
```

Extract shared logic (e.g. `deploySchnorrAccount()`) into in-file helpers. Promote to a shared file only when reused across files.

### 8. Run isolation (parallel-safe local services & tests)

Any local service an agent starts — anvil, the Aztec sandbox (native as of v5, not a container), PXE, playground, dev servers — MUST run safely when MANY agents share one machine (often separate worktrees). Principle: **isolate by ownership, not technology** — a run owns its ports, process group, and data dir, and tears down exactly what it owns. The `/run-isolation` skill retrofits any repo to this; the canonical implementation is below.

Two non-negotiable bans: **no hardcoded ports** on the run path, and **no by-name kills** (`pkill -f anvil`, `killall node`) — those murder other agents' processes and are the real reason a healthy run "looks broken".

**`scripts/run/registry.ts`** — host-level run registry under `~/.agents`: a shared source-of-truth (`ports.md`, consultable by every agent) and a race-free allocator (atomic `mkdir` lock; dead-owner rows self-heal on every read):

```ts
import { mkdirSync, rmdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const DIR = join(homedir(), '.agents');
const FILE = join(DIR, 'ports.md');           // the shared, human-readable source-of-truth
const LOCK = join(DIR, 'ports.lock');          // atomic mkdir lock serializes all mutations
const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

async function withLock<T>(fn: () => T): Promise<T> {
  mkdirSync(DIR, { recursive: true });
  for (let i = 0; i < 400; i++) {
    try { mkdirSync(LOCK); } catch { await new Promise((r) => setTimeout(r, 25)); continue; }
    try { return fn(); } finally { rmdirSync(LOCK); }
  }
  throw new Error('run-registry: lock timeout (stale ~/.agents/ports.lock? remove it)');
}

type Row = { runId: string; service: string; port: number; pid: number; worktree: string; started: string };

function read(): Row[] {
  if (!existsSync(FILE)) return [];
  return readFileSync(FILE, 'utf8').split('\n')
    .map((l) => l.split('|').map((c) => c.trim()))
    .filter((c) => c.length >= 8 && /^\d+$/.test(c[3]))      // data rows only (skip header/separator)
    .map((c) => ({ runId: c[1], service: c[2], port: Number(c[3]), pid: Number(c[4]), worktree: c[5], started: c[6] }));
}

function write(rows: Row[]): void {
  const head = '| runId | service | port | pid | worktree | started |\n|---|---|---|---|---|---|\n';
  writeFileSync(FILE, head + rows.map((r) => `| ${r.runId} | ${r.service} | ${r.port} | ${r.pid} | ${r.worktree} | ${r.started} |`).join('\n') + '\n');
}

// Reserve a free port for one service and record the owning run. ownerPid MUST be a long-lived
// process (the agent.sh shell), not this short script — that's what liveness-reaping keys off.
export const claim = (o: { runId: string; service: string; ownerPid: number; worktree: string; base: number; span: number }) =>
  withLock(() => {
    const rows = read().filter((r) => alive(r.pid));        // reap dead owners → ports free up
    const taken = new Set(rows.map((r) => r.port));
    let port = o.base;
    while (taken.has(port)) if (++port >= o.base + o.span) throw new Error('run-registry: no free port in range');
    rows.push({ runId: o.runId, service: o.service, port, pid: o.ownerPid, worktree: o.worktree, started: new Date().toISOString() });
    write(rows);
    return port;
  });

export const release = (runId: string) =>
  withLock(() => write(read().filter((r) => r.runId !== runId && alive(r.pid))));
```

**`scripts/run/resolve-ports.ts`** — claim one port per service from the registry (RUN_ID + OWNER_PID come from `agent.sh`); still writes a run-local `ports.json` for the run's own processes to read:

```ts
import { mkdirSync, writeFileSync } from 'node:fs';
import { claim } from './registry';

const RUN_ID = process.env.RUN_ID!;             // stable per worktree (set by agent.sh)
const OWNER_PID = Number(process.env.OWNER_PID); // the long-lived agent.sh shell ($$)
const services = ['anvil', 'aztec', 'aztecAdmin', 'aztecP2p', 'playground'];

// Per-worktree base range so independent worktrees barely contend; the registry resolves the rest.
const seed = Number(BigInt('0x' + Buffer.from(RUN_ID).toString('hex').slice(0, 6)) % 380n);
const ports: Record<string, number> = {};
for (let i = 0; i < services.length; i++) {
  ports[services[i]] = await claim({
    runId: RUN_ID, service: services[i], ownerPid: OWNER_PID, worktree: process.cwd(),
    base: 20000 + seed * 100 + i * 20, span: 20,
  });
}
mkdirSync('.run-state', { recursive: true });
writeFileSync('.run-state/ports.json', JSON.stringify(ports, null, 2));
console.log(JSON.stringify(ports));
```

**`scripts/run/agent.sh`** — per-worktree runner:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Stable per-worktree run id + the long-lived owner pid (this shell) for the registry
export RUN_ID="${RUN_ID:-$(printf '%s' "$PWD" | shasum | cut -c1-8)}"
export OWNER_PID=$$

# Allocate ports from the shared ~/.agents registry
PORTS=$(bun scripts/run/resolve-ports.ts)
ANVIL_PORT=$(echo "$PORTS" | jq -r .anvil)
AZTEC_PORT=$(echo "$PORTS" | jq -r .aztec)
# ... extract the rest

# Build with the per-run URL baked in
VITE_LOCAL_NETWORK_RPC_URL="http://localhost:$AZTEC_PORT" bun run build

# Sanity check: bundle must contain the URL
grep -q "http://localhost:$AZTEC_PORT" dist/*.js || {
  echo "FATAL: built bundle does not contain http://localhost:$AZTEC_PORT" >&2
  exit 1
}

# Run tests with ports in env
ANVIL_PORT="$ANVIL_PORT" AZTEC_PORT="$AZTEC_PORT" \
  bun vitest run --config vitest.e2e.network.config.ts "$@"
```

**`tests/e2e/global-setup.ts`** — owns lifecycle, tracks PIDs:

```ts
import { spawn } from 'node:child_process';
import { writeFileSync, readFileSync, existsSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { release } from '../../scripts/run/registry';

const PORTS = JSON.parse(readFileSync('.run-state/ports.json', 'utf-8'));
const RUN_ID = process.env.RUN_ID!;
const owned: Record<string, number> = {}; // service -> pgid (=== child.pid when detached)

function spawnService(name: string, cmd: string, args: string[]): void {
  const dataDir = join(tmpdir(), `myproject-${RUN_ID}-${name}`);   // per-run, isolated
  const child = spawn(cmd, args, {
    detached: true,                                                // new process group: pgid === child.pid
    stdio: 'inherit',
    env: { ...process.env, DATA_DIR: dataDir, HOME: dataDir },     // isolate global state (~/.aztec, ~/.foundry)
  });
  owned[name] = child.pid!;
}

function killGroup(pgid: number): void {
  try { process.kill(-pgid, 'SIGTERM'); } catch { /* already gone */ }   // negative pid = whole process group
}

export async function setup(): Promise<void> {
  if (existsSync('.run-state/owned.json')) {                       // reap only THIS worktree's prior run
    const prior = JSON.parse(readFileSync('.run-state/owned.json', 'utf-8'));
    for (const pgid of Object.values(prior) as number[]) killGroup(pgid);
  }
  spawnService('anvil', 'anvil', ['--port', String(PORTS.anvil)]);
  // ... aztec sandbox, playground, etc. — each on its PORTS.* port, each detached
  mkdirSync('.run-state', { recursive: true });
  writeFileSync('.run-state/owned.json', JSON.stringify(owned));
}

export async function teardown(): Promise<void> {
  for (const pgid of Object.values(owned)) killGroup(pgid);        // kill ONLY groups we own — never `pkill -f`
  await release(RUN_ID);                                           // drop our rows from the ~/.agents registry
  rmSync('.run-state', { recursive: true, force: true });
}
```

**Required principles (recap):**
- **Ports**: claimed from the shared `~/.agents` registry (race-free, cross-agent visible) — never hardcoded.
- **Ownership**: each service in its own process group; teardown is `kill(-pgid)` for groups you own. `pkill -f "<marker>"` is orphan-recovery fallback ONLY, never normal teardown.
- **Data dirs**: per-run, with `HOME`/`--datadir` overridden so global state (`~/.aztec`, `~/.foundry`) can't collide.
- **Containerized deps** (if any — the Aztec sandbox is native as of v5, so it's just a host process): one compose project per run (`docker compose -p $RUN_ID … down -v --remove-orphans`).
- **Browser E2E**: set COOP/COEP headers and assert `await page.evaluate(() => crossOriginIsolated)` — don't rely on localhost auto-enabling SharedArrayBuffer.
- A run that can't reach a service is NOT proof it's broken — check whether THIS run owns it (registry + pgid) before restarting anything.

Useful pattern for single-worktree fast iteration: fingerprint the sandbox by its deployed L1 contract addresses and compare against the last known set on startup — a mismatch means the sandbox was restarted and cached state is stale, so the run should reset rather than trust it.

### 9. Frontend (when project has UI)

```bash
bun create vite@latest .              # pick React + TypeScript
bun add @aztec/wallet-sdk @tanstack/react-query jotai
bun add -d @vitejs/plugin-react vitest @testing-library/react @testing-library/jest-dom @testing-library/user-event jsdom
```

#### CSS / styling — Tailwind v4 + shadcn/ui

```bash
# Tailwind v4 (Oxide engine, CSS-first config)
bun add -d tailwindcss @tailwindcss/vite
bun add tailwind-variants tailwind-merge clsx
```

`src/index.css` (CSS-first config — no `tailwind.config.js`):

```css
@import "tailwindcss";

@theme {
  --color-brand-500: oklch(0.72 0.18 250);
  --color-brand-600: oklch(0.62 0.20 250);
  /* design tokens go here as CSS variables */
}
```

`vite.config.ts`:

```ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
});
```

**shadcn/ui** (copy-paste accessible primitives):

```bash
bunx shadcn@latest init                # one-time setup; picks Base UI or Radix
bunx shadcn@latest add button dialog dropdown-menu command sonner form input
```

**Typed component variants** with `tailwind-variants`:

```ts
import { tv, type VariantProps } from 'tailwind-variants';

const button = tv({
  base: 'inline-flex items-center justify-center rounded-md text-sm font-medium',
  variants: {
    variant: {
      primary: 'bg-brand-500 text-white hover:bg-brand-600',
      ghost: 'hover:bg-neutral-100',
    },
    size: { sm: 'h-8 px-3', md: 'h-10 px-4' },
  },
  defaultVariants: { variant: 'primary', size: 'md' },
});

type ButtonProps = VariantProps<typeof button> & React.ButtonHTMLAttributes<HTMLButtonElement>;
```

**Storybook (component catalog)**:

```bash
bunx storybook@latest init
```

**Discipline**: define design tokens in one `@theme` block — `bg-brand-500`, not raw hex. If you write the same 3+ utility classes twice, promote to a `tv()` variant in `src/components/ui/`.

### 10. Root scripts

`package.json`:

```json
{
  "scripts": {
    "lint": "biome check . && sort-package-json --check **/package.json",
    "lint:fix": "biome check --write . && sort-package-json **/package.json",
    "lint:shell": "shellcheck **/*.sh",
    "lint:actions": "actionlint",
    "test": "bun run lint && bun test",
    "test:components": "vitest run",
    "test:e2e": "playwright test",
    "e2e:agent": "scripts/run/agent.sh"
  }
}
```

Add `lint:tofu` if using OpenTofu:

```json
{ "lint:tofu": "cd infra/tofu && tofu fmt -check -diff && tofu validate" }
```

### 11. Project docs

```bash
mkdir -p docs implementations-plan
touch implementations-plan/index.md   # Keep this updated as plans land
```

Create `CLAUDE.md` at repo root describing:
- Current state (packages, architecture)
- Quick start commands
- Project-specific conventions (deviations from personal CLAUDE.md)
- Validation commands

Create `docs/roadmap.md` for tracking phases, decisions, and backlog.

### 12. OpenTofu (if infrastructure needed)

```bash
mkdir -p infra/tofu
```

- Remote state in S3
- `tofu fmt` + `tofu validate` in lint-staged + CI
- OIDC for AWS credentials in CI (see CI section)

---

## CI/CD Conventions

### GitHub Actions

- **Per-package workflows** with gate jobs (one workflow per package in a monorepo)
- **Reusable workflows** prefixed with `_` (e.g., `_build-base.yml`, `_publish.yml`)
- **Always lint workflows** with actionlint locally before pushing
- **Change detection**: only run package workflows when relevant files change
- **`bun audit`** as a CI step. Default behavior fails on vulnerabilities; if blocking is too noisy, use `continue-on-error: true` and surface findings in the step summary:

```yaml
- name: bun audit
  run: bun audit
  continue-on-error: true            # advisory; remove to make blocking
```

### Workflow file naming

| Type | Pattern | Examples |
|---|---|---|
| Per-package PR gate | `<package>.yml` | `accelerator.yml`, `sdk.yml`, `app.yml` |
| Reusable workflows | `_<thing>.yml` | `_e2e.yml`, `_publish-sdk.yml`, `_aztec-update.yml` |
| Deploy | `deploy-*.yml` | `deploy-landing.yml` |
| Publish | `publish-*.yml` | `publish-testnet.yml`, `publish-nightlies.yml` |
| Release | `release-*.yml` | `release-accelerator.yml` |
| Backport | `backport-*.yml` | `backport-nightlies.yml` |
| Automation (upstream-tracking) | `<upstream>-*.yml` | `aztec-nightlies.yml`, `aztec-stable.yml` |
| Standalone lint | `actionlint.yml` | `actionlint.yml` |

Reusable composite actions live in `.github/actions/<name>/action.yml`.

### Per-package PR gate template

Every per-package workflow starts with a `changes` job that gates the rest of the pipeline on path-filtered file changes. Manual `workflow_dispatch` always bypasses the filter so you can force-run from the Actions UI.

```yaml
name: <Package>

on:
  workflow_dispatch:
  pull_request:
    branches: [main]

jobs:
  changes:
    name: Detect changes
    runs-on: ubuntu-latest
    timeout-minutes: 2
    outputs:
      relevant: ${{ steps.override.outputs.relevant || steps.filter.outputs.relevant }}
    steps:
      - uses: actions/checkout@v6
      - uses: dorny/paths-filter@v4
        id: filter
        with:
          filters: |
            relevant:
              - 'packages/<package>/**'
              - '!packages/<package>/**/*.md'
              - 'packages/<dependent-package>/src/**'
              - 'biome.json'
              - 'package.json'
              - 'bun.lock'
              - '.github/workflows/<package>.yml'
              - '.github/workflows/_<reusable>.yml'
              - '.github/actions/**'
      - name: Override for manual dispatch
        if: github.event_name == 'workflow_dispatch'
        id: override
        run: echo "relevant=true" >> "$GITHUB_OUTPUT"

  test:
    name: Test
    needs: changes
    if: needs.changes.outputs.relevant == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: ./.github/actions/setup-<package>
      - run: bun run --cwd packages/<package> test
```

### Reusable workflow template

```yaml
name: _<Thing> (reusable)

on:
  workflow_call:
    inputs:
      ref:
        description: Git ref to checkout
        required: false
        type: string
        default: ""
      target_url:
        description: Target service URL (e.g. an Aztec node)
        required: false
        type: string
        default: "http://localhost:8080"
      build_extras:
        description: Optional flag to build supplementary artifacts
        required: false
        type: boolean
        default: false
    secrets:
      SOME_SECRET:
        required: false

jobs:
  do-the-thing:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v6
        with:
          ref: ${{ inputs.ref || github.ref }}
      - uses: ./.github/actions/setup-<thing>
      - name: Run
        env:
          TARGET_URL: ${{ inputs.target_url }}
          SOME_SECRET: ${{ secrets.SOME_SECRET }}
        run: bun run e2e:<thing>
```

Call from a per-package workflow:

```yaml
e2e:
  needs: changes
  if: needs.changes.outputs.relevant == 'true'
  uses: ./.github/workflows/_<thing>.yml
  with:
    target_url: http://localhost:8080
    build_extras: true
  secrets: inherit
```

### Path-filter discipline

A per-package workflow's `paths-filter` block should include:

- **Own source tree**: `packages/<pkg>/**`
- **Doc exclusions**: `!packages/<pkg>/**/*.md` so doc-only changes don't trigger the gate
- **Upstream-dep source paths**: `packages/<dep>/src/**` so a change in a dependency re-runs this gate
- **Shared lint/format config**: `biome.json`, `package.json`, `bun.lock`
- **The workflow file itself**: `.github/workflows/<package>.yml` (so workflow tweaks trigger validation)
- **Any reusable workflows it calls**: `.github/workflows/_<reusable>.yml`
- **Shared composite actions**: `.github/actions/**`

If a path filter starts gating things you don't expect (over- or under-triggering), check this list before adjusting the job logic.

### NPM Publishing: Trusted Publisher

Use GitHub Actions OIDC with npm trusted publisher — **no npm tokens stored as secrets** wherever the package is eligible.

1. Configure trusted publisher in npm registry settings (link GitHub repo + workflow)
2. Use `provenance: true` in the publish step
3. No `NPM_TOKEN` secret needed

```yaml
- uses: actions/setup-node@v4
  with:
    registry-url: 'https://registry.npmjs.org'
- run: npm publish --provenance --access public
  # OIDC handles auth — no NODE_AUTH_TOKEN needed
```

If the package isn't eligible for trusted publishing, fall back to `NPM_TOKEN` — that's the documented escape hatch. The publish job may still need npm/Node tooling even in a Bun-first repo; trusted publishing is npm-side.

### OIDC Everywhere

**Always use OIDC when available** instead of long-lived credentials:

- **AWS**: `aws-actions/configure-aws-credentials` with OIDC role
- **npm**: Trusted publisher (OIDC-based)
- **Vercel / cloud providers**: OIDC where supported
- Never store long-lived access keys, tokens, or credentials as GitHub secrets when OIDC is an option

### Least-privilege for GitHub Actions tokens

Default workflow `permissions:` to `contents: read`. Grant write scopes only on the specific job that needs it (and only the specific scope — e.g. `id-token: write` for OIDC, not blanket `write-all`).

### OpenTofu in CI

- `tofu plan` in CI for PRs (read-only preview)
- `tofu apply` on merge to main (or manual trigger)
- State stored remotely in S3
- OIDC for AWS credentials

---

## Adversarial / safety considerations

For non-trivial work, the `blueprint` skill requires a "Security & Adversarial Considerations" section in every plan, drawing from the personal CLAUDE.md "Security & Adversarial mindset" checklist (threat model, least privilege, cryptography, input validation, supply chain, domain-specific risks).

This skill's scaffolding already enforces part of that checklist: 7-day npm min-age, frozen lockfile, trusted publisher + provenance, OIDC, least-privilege Actions tokens, scoped IAM. Apply the rest per-plan.
