# my-stack

Opinionated project scaffolding and conventions: **Bun** (PM + runtime + scripts), **Biome** (lint + format), React + Vite + TypeScript `strict`, Tailwind v4 + shadcn/ui, `bun:test` / Vitest / Playwright, OpenTofu, monorepo workspace layout.

Includes the supply-chain hardening defaults (7-day npm minimum release age via `bunfig.toml`, frozen lockfiles in CI, OIDC + npm trusted publisher with provenance instead of static tokens), per-package CI workflow conventions with path filtering, and parallel-safe E2E patterns (ephemeral ports, worktree-scoped cleanup).

Templates and the full scaffolding sequence live in [`SKILL.md`](SKILL.md).
