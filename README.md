# aa-skills

Personal agent skills in the [Agent Skills](https://agentskills.io) format, versioned here and installed for **both** [Claude Code](https://claude.com/claude-code) and [Codex](https://github.com/openai/codex) so they survive dead laptops and install in one command on new machines.

The real files live **here**; `~/.claude/skills/<name>` and `~/.agents/skills/<name>` are symlinks to the same directories. Editing a skill in place is editing this repo — backup is just `git commit && git push`.

`blueprint` is written in terms of a **driver** (the harness running the session) and a **foreign reviewer** (the other model family's CLI): `/codex` when Claude Code drives, `/claude` when Codex drives. The `harden*` skills still assume a Claude Code driver.

## Skills

| Skill | What it does |
|---|---|
| [`blueprint`](skills/blueprint/) | Plan-creation protocol with four ceremony tiers (light / mid / deep / mega-deep), cross-model audits from either harness (driver + foreign reviewer), ELI5 Artifact / HTML deliverables |
| [`harden`](skills/harden/) | Whole-codebase audit, all three focuses (security / bugs / quality) — map-reduce over parallel Claude + Codex agents, five effort levels |
| [`harden-bugs`](skills/harden-bugs/) | Correctness-only clone of the harden harness with zero security language, so it runs clean on any model (Fable included) |
| [`harden-quality`](skills/harden-quality/) | Maintainability-only clone of the harden harness with zero security language, so it runs clean on any model (Fable included) |
| [`claude`](skills/claude/) | Second-opinion consults via the headless Claude Code CLI (Fable 5.1 by default) — the foreign-reviewer leg for Codex-driven sessions; mirror of `codex` with the same script contract |
| [`codex`](skills/codex/) | Second-opinion consults via the Codex CLI (GPT-6 Astra by default) — the foreign-reviewer leg for Claude Code-driven sessions; plus raster image generation/editing through Codex's built-in `image_gen` (gpt-image-2, ChatGPT plan, no API key) |
| [`kimi`](skills/kimi/) | Second-opinion consults via the Kimi Code CLI (Moonshot K3/K2.x) — codex-style harness with a worktree-change tripwire (kimi has no read-only sandbox) |
| [`my-stack`](skills/my-stack/) | Project scaffolding: Bun, Biome, CI/CD conventions, supply-chain hardening |
| [`run-isolation`](skills/run-isolation/) | Make a repo's local services/tests parallel-safe across many agents — shared `~/.agents` port registry, process-group teardown |
| [`wallet-sdk`](skills/wallet-sdk/) | `@aztec/wallet-sdk` integration patterns for dApp frontends + wallet extensions |

Each skill directory has a `README.md` explaining the concepts (blueprint and harden include pipeline diagrams) and a `SKILL.md` with the exact protocol the agent follows. The README is the explainer; SKILL.md is the source of truth.

## Helper CLIs

| Tool | What it does |
|---|---|
| [`bin/agent-worktree`](bin/agent-worktree) | Task-named git worktrees off one canonical clone + the `~/.agents/workspaces.md` manifest (who is working on what, where). `new` / `list` / `resume` / `status` / `done` / `register`. Blueprint's workspace homing registers through it. |

`install.sh` symlinks `bin/*` into `~/.local/bin`.

## Install

```sh
git clone --recurse-submodules git@github.com:alejoamiras/aa-skills.git ~/Projects/aa-skills
cd ~/Projects/aa-skills && ./install.sh
```

`install.sh` symlinks each `skills/<name>` into `~/.claude/skills/<name>` (Claude Code) **and** `~/.agents/skills/<name>` (Codex — retiring any older link under `~/.codex/skills` that points here), backs up anything it replaces to `~/.claude/backups/`, and wires the repo's pre-commit hook. Rerunning is safe.

> **Note:** `claude/` is a **private submodule** (the owner's harness-neutral `AGENTS.md`, the thin `CLAUDE.md` that imports it, personal `statusline.sh`, managed `settings.json` keys). Cloning it will fail for everyone else — that's expected, and `install.sh` skips it gracefully. Everything under `skills/` works standalone.

### Instructions file: one `AGENTS.md`, two readers

Codex reads `~/.codex/AGENTS.md`; Claude Code reads only `~/.claude/CLAUDE.md` but supports `@path` imports. So the generic instructions live once in `AGENTS.md`, `CLAUDE.md` is `@AGENTS.md` plus a short Claude Code-only tail, and `install.sh` links `AGENTS.md` into both `~/.claude/` (so the relative import resolves next to the link) and `~/.codex/`. Codex caps combined instructions at 32 KiB by default (`project_doc_max_bytes` in `~/.codex/config.toml`) — raise it if a large global file leaves no room for project-level `AGENTS.md`.

## Adding a skill

Create `skills/<name>/SKILL.md` in this repo, rerun `./install.sh`, commit + push. Both harnesses read the same `name` + `description` frontmatter and tolerate the other's optional fields (Claude Code's `allowed-tools` / `effort` / `context`, Codex's optional `agents/openai.yaml`).

## Secret hygiene

- `hooks/pre-commit` runs `gitleaks` on staged changes (wired by `install.sh`).
- CI runs gitleaks over full history on every push/PR.
- GitHub secret scanning + push protection enabled on the remote.
- No transcripts, history, `settings.local.json`, or credentials are ever tracked here.
