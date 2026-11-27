# Blueprint: `deep` and `mega-deep` protocols

Read this file before drafting on a `deep` or `mega-deep` run. Both tiers start after the shared preamble (Phase 0 → 0.4 → 0.5 → 0.75) and end with the shared tail, both defined in `SKILL.md` under Per-tier protocols. Every audit below sends the full Standard audit packet (`SKILL.md`). On a Codex driver, `/codex` reads as `/claude` and the fable `Agent` leg as a Codex subagent, per Harness capabilities.

## `/blueprint deep`

1. **Four independent plans in parallel** (different perspectives, separate context):
   - **Main agent**: drafts against the clarifying answers.
   - **Codex**: invoked via `/codex high` with clarifying answers + task statement + explicit adversarial / security / assumption-attack asks.
   - **Fable subagent** (top-tier Claude subagent specialized for architectural planning; `subagent_type: 'Plan'`, `model:` the Phase 0 `claude_model`): given clarifying answers + adversarial / security / assumption-attack asks.
   - **Gemini**: a new run (`SKILL.md`, Model note, Gemini leg) on Codex's prompt file. The driver copies its answer into `plan-gemini.md`; an unavailable Gemini leaves its record line in the decision ledger.
2. **Consolidate** (by main): take the strongest pieces, verify factual claims against the repo, produce a **decision ledger** documenting which decisions came from which source, which were rejected and why, what's still disputed.
3. **Contradiction-check**: send the consolidated plan + the decision ledger back to codex, the fable subagent and Gemini for one round of contradiction-checking. They look for: choices that contradict each other across phases, rejected alternatives that should have been kept, disputed items that were silently resolved. This catches main's consolidation blind spots before the gate.
4. **Triple audit** on the contradiction-checked plan:
   - Codex again, with adversarial / security / assumption-attack asks.
   - Fresh fable subagent (different context), with same asks.
   - Gemini again, on Codex's prompt file.
5. **Final fresh-context codex and gemini passes**: open a NEW codex session and a NEW Gemini run (not resumes). Provide each the audited plan + the full decision ledger + the adversarial + assumption-attack asks, in one prompt file.
6. The shared tail: ELI5, approval gate, post-approval seeds, implementation and the post-implementation protocol.

## `/blueprint mega-deep`

Same shape as `/blueprint deep`, but with an upfront research phase AND a split Round 2 audit. Use only when novelty of the surface area means the planning agents would otherwise be guessing at module shapes, AND the implementation cost (days+) justifies the heaviest ceremony.

1. **Research phase** (mandatory persisted artifacts) — the heaviest rung of the Phase 0.4 recon ladder: same idea (map prior art before planning), scaled up to per-module persisted artifacts and run independently by each planning agent. Each of the four planning agents (main + codex + fable + gemini) first spawns research subagents to map modules they expect to touch. Each agent decides what to explore based on the task + clarifying answers.
   - Main: spawn read-only research subagents specialized for codebase exploration (today via `subagent_type: 'Explore'`) for each relevant module / surface.
   - Codex: invoked with explicit instruction to research relevant files via its read-only sandbox before drafting.
   - Fable subagent: instructed to spawn its own research subagents before drafting.
   - Gemini: told to research the relevant files in place before drafting; its run in `open` reads the worktree with commands. It is told not to write files, so the driver persists its report.
   - **Each research subagent's findings are persisted to `implementations-plan/<plan>/research/<module>.md` as a mandatory artifact** — the spawning planner writes them (read-only explorers return reports, they don't write files), NOT just a verbal summary. Includes: module purpose, public surface, key invariants, current pain points, relevant tests.
   - On a Codex driver neither foreign leg can spawn agents or write files: the driver runs the research and persists what the foreign leg returns (Harness capabilities).
2. **Four independent plans in parallel**, now informed by persisted research artifacts.
3. **Consolidate** (by main): produce decision ledger as in `deep`.
4. **Contradiction-check** (codex + fable + gemini on consolidated plan + ledger), as in `deep`.
5. **Audit Round 1**: codex + fable subagent + gemini in parallel, each with adversarial / security / assumption-attack asks.
6. Iterate on Round 1 findings; document adopted vs rejected.
7. **Audit Round 2 (split)** — instead of resuming every session (which compounds anchoring):
   - **Resumed self-critique** (codex resume, and Gemini resumed beside it with `resume-agy.sh` on the same follow-up file): *"Look at your prior findings. What did you miss? What did you over-assert? What second-order risks did your initial review not surface? Where were you anchored on the plan's framing instead of attacking it?"*
   - **Fresh hostile audit** (NEW fable subagent, no prior context): "You're seeing this plan for the first time. Attack it. Find what the prior reviewers missed because they were already inside the plan's framing."
8. Iterate on Round 2 findings.
9. **Final fresh-context codex and gemini passes**: open a NEW codex session and a NEW Gemini run, each with just the iterated plan + full decision ledger + adversarial + assumption-attack asks, in one prompt file.
10. The shared tail: ELI5, approval gate, post-approval seeds, implementation and the post-implementation protocol.

**Cost note**: subagent fan-out is expensive; mega-deep persists multiple research artifacts AND runs a split Round 2 with a fresh subagent. Reserve `mega-deep` for first-of-its-kind work where the implementation cost (days+) dwarfs the audit overhead. Most non-trivial tasks land at `mid` or `deep`.
