# my-stack

Opinionated project scaffolding and conventions: **Bun 1.4+** (PM + runtime + scripts, native-first), **Biome** (lint + format), React + Vite + TypeScript `strict`, Tailwind v4 + shadcn/ui, `bun:test` / Vitest / Playwright, monorepo workspace layout.

Two standing biases worth knowing before you scaffold:

- **Check Bun before adding a dependency.** 1.4 absorbed a lot of small packages — `Bun.cron`, `Bun.Image`, `node:sqlite`, `Bun.Archive`, the JSON5/JSONC/XML/TOML parsers, `CompressionStream` — plus an isolated-linker install mode and a test runner with `--parallel`, `--shard`, and `--changed`. SKILL.md carries the swap table.
- **Infrastructure is tiered, and IaC is the top tier.** A web thing ships on Cloudflare Workers/Pages with `wrangler.jsonc` as its whole infra definition; a managed platform is next; OpenTofu appears only when there's real cloud infrastructure (EC2/VPC/IAM) whose untracked state is itself the risk.

Includes the supply-chain hardening defaults (7-day npm minimum release age via `bunfig.toml`, frozen lockfiles in CI, OIDC + npm trusted publisher with provenance instead of static tokens), per-package CI workflow conventions with path filtering, and parallel-safe E2E patterns (ephemeral ports, worktree-scoped cleanup).

Templates and the full scaffolding sequence live in [`SKILL.md`](SKILL.md).
