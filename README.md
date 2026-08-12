# aa-skills

Personal [Claude Code](https://claude.com/claude-code) skills, versioned and symlinked into `~/.claude` so they survive dead laptops and install in one command on new machines.

The real files live **here**; `~/.claude/skills/<name>` are symlinks. Editing a skill in place is editing this repo — backup is just `git commit && git push`.

## Skills

| Skill | What it does |
|---|---|
| [`blueprint`](skills/blueprint/) | Plan-creation protocol with four ceremony tiers (light / mid / deep / mega-deep), dual-model audits, ELI5 HTML deliverables |
| [`harden`](skills/harden/) | Whole-codebase audit, all three focuses (security / bugs / quality) — map-reduce over parallel Claude + Codex agents, five effort levels |
| [`harden-bugs`](skills/harden-bugs/) | Correctness-only clone of the harden harness with zero security language, so it runs clean on any model (Fable included) |
| [`harden-quality`](skills/harden-quality/) | Maintainability-only clone of the harden harness with zero security language, so it runs clean on any model (Fable included) |
| [`codex`](skills/codex/) | Second-opinion consults via the Codex CLI (cross-model review) |
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

`install.sh` symlinks each `skills/<name>` into `~/.claude/skills/<name>`, backs up anything it replaces to `~/.claude/backups/`, and wires the repo's pre-commit hook. Rerunning is safe.

> **Note:** `claude/` is a **private submodule** (the owner's global `CLAUDE.md` + personal `statusline.sh`). Cloning it will fail for everyone else — that's expected, and `install.sh` skips it gracefully. Everything under `skills/` works standalone.

## Adding a skill

Create `skills/<name>/SKILL.md` in this repo, rerun `./install.sh`, commit + push.

## Secret hygiene

- `hooks/pre-commit` runs `gitleaks` on staged changes (wired by `install.sh`).
- CI runs gitleaks over full history on every push/PR.
- GitHub secret scanning + push protection enabled on the remote.
- No transcripts, history, `settings.local.json`, or credentials are ever tracked here.
