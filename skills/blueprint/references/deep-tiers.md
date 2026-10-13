# Blueprint: `deep` and `mega-deep` protocols

Read this file before drafting on a `deep` or `mega-deep` run. Both tiers start after the shared preamble (Phase 0 → 0.4 → 0.5 → 0.75) and end with the shared tail, both defined in `SKILL.md` under Per-tier protocols. Every audit below sends the full Standard audit packet (`SKILL.md`). On a Codex driver, `/codex` reads as `/claude` and the fable `Agent` leg as a Codex subagent, per Harness capabilities.

## `/blueprint deep`

1. **Three independent plans in parallel** (different perspectives, separate context):
   - **Main agent**: drafts against the clarifying answers.
   - **Codex**: invoked via `/codex high` with clarifying answers + task statement + explicit adversarial / security / assumption-attack asks.
   - **Fable subagent** (top-tier Claude subagent specialized for architectural planning; `subagent_type: 'Plan'`, `model:` the Phase 0 `claude_model`): given clarifying answers + adversarial / security / assumption-attack asks.
2. **Consolidate** (by main): take the strongest pieces, verify factual claims against the repo, produce a **decision ledger** documenting which decisions came from which source, which were rejected and why, what's still disputed.
3. **Contradiction-check**: send the consolidated plan + the decision ledger back to BOTH codex and the fable subagent for one round of contradiction-checking. They look for: choices that contradict each other across phases, rejected alternatives that should have been kept, disputed items that were silently resolved. This catches main's consolidation blind spots before the gate.
4. **Double audit** on the contradiction-checked plan:
   - Codex again, with adversarial / security / assumption-attack asks.
   - Fresh fable subagent (different context), with same asks.
5. **Final fresh-context codex pass**: open a NEW codex session (not a resume). Provide the audited plan + the full decision ledger + the adversarial + assumption-attack asks.
6. The shared tail: ELI5, approval gate, post-approval seeds, implementation and the post-implementation protocol.

## `/blueprint mega-deep`

Same shape as `/blueprint deep`, but with an upfront research phase AND a split Round 2 audit. Use only when novelty of the surface area means the planning agents would otherwise be guessing at module shapes, AND the implementation cost (days+) justifies the heaviest ceremony.

1. **Research phase** (mandatory persisted artifacts) — the heaviest rung of the Phase 0.4 recon ladder: same idea (map prior art before planning), scaled up to per-module persisted artifacts and run independently by each planning agent. Each of the three planning agents (main + codex + fable) first spawns research subagents to map modules they expect to touch. Each agent decides what to explore based on the task + clarifying answers.
   - Main: spawn read-only research subagents specialized for codebase exploration (today via `subagent_type: 'Explore'`) for each relevant module / surface.
   - Codex: invoked with explicit instruction to research relevant files via its read-only sandbox before drafting.
   - Fable subagent: instructed to spawn its own research subagents before drafting.
   - **Each research subagent's findings are persisted to `implementations-plan/<plan>/research/<module>.md` as a mandatory artifact** — the spawning planner writes them (read-only explorers return reports, they don't write files), NOT just a verbal summary. Includes: module purpose, public surface, key invariants, current pain points, relevant tests.
   - On a Codex driver neither foreign leg can spawn agents or write files: the driver runs the research and persists what the foreign leg returns (Harness capabilities).
2. **Three independent plans in parallel**, now informed by persisted research artifacts.
3. **Consolidate** (by main): produce decision ledger as in `deep`.
4. **Contradiction-check** (codex + fable on consolidated plan + ledger), as in `deep`.
5. **Audit Round 1**: codex + fable subagent in parallel, both with adversarial / security / assumption-attack asks.
6. Iterate on Round 1 findings; document adopted vs rejected.
7. **Audit Round 2 (split)** — instead of resuming both sessions (which compounds anchoring):
   - **Resumed self-critique** (codex resume): *"Look at your prior findings. What did you miss? What did you over-assert? What second-order risks did your initial review not surface? Where were you anchored on the plan's framing instead of attacking it?"*
   - **Fresh hostile audit** (NEW fable subagent, no prior context): "You're seeing this plan for the first time. Attack it. Find what the prior reviewers missed because they were already inside the plan's framing."
8. Iterate on Round 2 findings.
9. **Final fresh-context codex pass**: open a NEW codex session with just the iterated plan + full decision ledger + adversarial + assumption-attack asks.
10. The shared tail: ELI5, approval gate, post-approval seeds, implementation and the post-implementation protocol.

**Cost note**: subagent fan-out is expensive; mega-deep persists multiple research artifacts AND runs a split Round 2 with a fresh subagent. Reserve `mega-deep` for first-of-its-kind work where the implementation cost (days+) dwarfs the audit overhead. Most non-trivial tasks land at `mid` or `deep`.
