---
name: blueprint
description: Plan-creation protocol with FOUR tiers (lowest to highest ceremony) — `/blueprint light` (bounded feature, single codex audit) | `/blueprint mid` (contained feature, codex + fable dual audit; DEFAULT if unsure) | `/blueprint deep` (architectural / cross-cutting, three parallel plans main+codex+fable + double audit + contradiction-check) | `/blueprint mega-deep` (novel surface, planning agents spawn research subagents to map modules before drafting, plus split Round 2 audit). Every tier asks clarifying questions, runs a cheap codebase recon phase before planning (1–3 agents by default: a batched repo-wide reuse/dedup sweep whose capability list stays complete on every tier, plus subsystem mappers only where needed), keeps agent fan-out under explicit low-by-default Cost controls and runs `/code-review` ONLY when the user opts in at Phase 0 (off by default — the codex fix loop is the review), homes the session into a task-named git worktree before drafting (workspace homing via EnterWorktree + the ~/.agents/workspaces.md manifest), requires a validation gate on every implementation phase (real project commands + pass criteria), embeds a self-contained post-implementation protocol in every plan.md (an iterative codex fix loop with explicit no-over-engineering + comment-quality rules, preceded by `/code-review` only if opted in — run per arc on stacked plans before the next arc begins, plus a final cross-arc pass — then arc-stacked PR delivery via `gh stack`, PRs opened only after all loops converge), and produces an ELI5 deliverable (a shareable Claude Artifact, with a standalone-HTML fallback) embedding `/goal` + `/loop` seed strings. Trigger phrases: "ultraplan", "ultrathink plan", "deep plan", "give me a plan", "blueprint this", "plan this carefully", "plan properly", "use the plan protocol", "full ceremony". Auto-fire (invoke without being asked) when the work involves cross-package BEHAVIORAL changes, infra / IaC with rollout or privilege impact, schema or protocol changes, UI-flow redesign, external-system integration, auth or permissions changes, billing logic, data migrations or backfills, concurrency or cache invalidation, or public API changes.
---

# Blueprint

Structured plan-creation protocol for non-trivial work. Four tiers scaled to size and risk. Every tier asks clarifying questions first and ends with a pasteable approval gate.

## Tier selector

| Tier | When to use | What you get |
|------|-------------|--------------|
| `/blueprint light` | Bounded feature, single-package, low-risk | Clarifying Qs → one plan → single codex audit → ELI5 (with /goal+/loop) |
| `/blueprint mid` | Contained feature, may span 2 packages, moderate risk | Clarifying Qs → one plan + competing outline → dual audit (codex + fable subagent) → final codex pass on ledger → ELI5 |
| `/blueprint deep` | Architectural, cross-cutting, high risk | Clarifying Qs → 3 parallel plans (main + codex + fable subagent) → consolidate + contradiction-check → double audit → final codex pass → ELI5 |
| `/blueprint mega-deep` | Novel surface, first-of-its-kind, planning agents would otherwise be guessing | Clarifying Qs → each planning agent spawns persisted research subagents → then `deep` flow with split Round 2 (resumed self-critique + fresh hostile audit) |

**Default to `mid`** when scope is unclear. BUT: if two or more of the following are HIGH, recommend `deep` regardless of package count — **novelty, blast radius, irreversibility, migration cost, external coupling, security sensitivity**. Single-package can still be `deep` for auth, billing, concurrency, migrations, irreversible state changes. Escalate to `mega-deep` only when the team has no prior experience with the surface area (subagent fan-out is expensive).

## Cost controls (read before fanning out anything)

Blueprint's ceremony is the plan's rigor, NOT agent headcount. Subagent fan-out and `/code-review` are the two things that actually burn tokens, and neither scales quality linearly — a well-briefed single agent beats six vague ones, and the codex fix loop already reviews every diff. Defaults are deliberately low; the user raises them explicitly, per run.

| Knob | Default | Raise only when |
|---|---|---|
| Recon agents (0.4) | **1–3 total** (1 batched reuse sweep + 0–2 subsystem mappers) | User says "wide recon" / the repo is a large unfamiliar monorepo |
| `/code-review` | **OFF** — not run; the codex fix loop is the review (see Post-implementation) | User opts in at the Phase 0 question (then `low`/`medium` sized to the diff; `high`/`max` only on an explicit ask) |
| Codex effort (every `/codex` call in this skill) | **`high`** on GPT-6 Astra | User asks for `xhigh`/`max` for the run — `xhigh` roughly doubles wall-clock per round on Astra for marginal review gain |
| Codex fix-loop rounds | Until clean, hard stop at 3 | Never — 3 rounds is a scope smell, surface instead |
| Recon cross-model check | Off | User asks; then ONE codex pass at `gpt-5.6-terra` (cheap tier) re-testing the absence claims |

**Announce the budget shape** with the tier recommendation (0.5): "recon: 2 agents; code-review: off (per your Phase 0 answer)" — so the user can dial it before spend happens, not after. If the user gives a budget instruction ("keep it cheap", "go wide"), it overrides these defaults for the whole run; record it in `plan.md` next to `eli5_mode`.

**Model note — the two review legs (current 2026-09-04).** The "fable" subagent is the top-tier Claude planning/audit leg that runs in parallel with Codex in every tier. Run it on **Fable 5.1** when available (`Agent` tool: `model: 'fable'`); **while Fable is deactivated, run it on Opus 5 (1M context)** (`model: 'opus'`). "fable" names the *role* — the independent top-tier Claude reviewer alongside Codex — not a hard model requirement, so `audit-fable.md` and the "codex + fable" terminology stay as-is regardless of which model fills the role. The **Codex leg runs on GPT-6 Astra** — the codex skill's default model — at **`high`**, not `xhigh`: on Astra, `xhigh` adds minutes per round for marginal gain on plan and diff review, and a blueprint runs many rounds. Every `/codex high` in this skill (plan audits, the post-implementation fix loop, the cross-arc pass) means Astra at `high` unless the user names another model or asks for `xhigh`/`max` for the run.

---

## Phase 0: Clarifying questions (ALL tiers)

**The plan is the most important step. Don't draft against a fuzzy target.** Before any drafting, ask the user:

- **Success criterion**: what does "done" look like? Measurable signals?
- **Scope trade-offs**: what's in, what's out, where can scope be cut?
- **Constraints**: time, infra, external deps, capacity
- **Quality bar**: PoC, staging, or production? Calibrates testing rigor and audit depth.
- **Validation layers**: which validation layers should gate each phase? **Inspect the repo FIRST** (package scripts, CI workflows, Makefile, test dirs) so the options offered are REAL, then ask via `AskUserQuestion` with what actually exists: typecheck/lint, unit, integration, e2e, e2e against live networks (sandbox / anvil / testnet). Flag any requested layer the project doesn't have yet — building it becomes a plan phase of its own.
- **Decisions to surface vs delegate**: which trade-offs come back to the user, which the agent resolves
- **`/code-review` in the post-implementation loop — ASK, default OFF**: the codex fix loop reviews every diff already; `/code-review` on top of it is the single biggest token sink in the protocol. Ask explicitly (via `AskUserQuestion`): "Run `/code-review` before the codex fix loop? Default: no. If yes: `low` (small/contained diff) or `medium` (typical feature arc)." Never assume yes; never pick `high`/`max` unless the user names it. Record the answer in plan.md's front matter as `code_review: off | low | medium | high | max` — the Post-implementation section, the Delivery section (per arc) and the `/goal` + `/loop` seeds are all generated from that one value.
- **Post-implementation hardening**: will this work eventually need `/harden security` or `/harden quality`? Recommended (but not auto-scheduled) if the plan touches trust boundaries, auth, secrets, CI/CD, publishing, or repo-wide security posture. Note: `/harden` is thorough/expensive — usually scheduled for pre-release of a library or app, NOT after every plan. Surface this so the user can decide upfront.

Wait for answers before proceeding.

---

## Phase 0.4: Codebase recon (ALL tiers)

**Plan against the code that exists, not a blank slate.** After clarifying questions, before drafting (and before the tier call, which recon can revise), fan out cheap-but-clever read-only subagents to map the terrain the work will touch. This is the "research first" principle made structural: it surfaces what to reuse, what to adapt, and the conventions to match — so the plan extends the codebase instead of duplicating it, and audits critique against reality.

- **Agents**: read-only `Explore` subagents on `model: 'sonnet'` (cheap but clever), fanned out in parallel on two axes:
  - **Reuse sweep — breadth, tier-INDEPENDENT, never skipped**: decompose the task into the capabilities it needs (parsing, caching, API client, validation, UI primitives, …), then **batch ALL of them into ONE agent** whose prompt lists each capability explicitly and asks for a per-capability verdict. Breadth comes from the capability list and the search angles, NOT from agent count — one agent given six named capabilities covers the same ground as six agents, at a fraction of the cost. That agent scans the whole repo/workspace per capability — "what here already does, or half-does, this?" — from several angles: by name (greps for likely terms), by structure (package/module trees), by consumer (imports and wiring of similar features), by tests (fixtures and helpers reveal prior art). Split into a second sweep agent only when the capability list genuinely exceeds one agent's reach (many capabilities, or a large monorepo); the ceiling is **2 unless the user asks for wider** (see Cost controls). Candidates include existing helpers, similar features, shared packages (every workspace package in a monorepo, not just the touched one), test utilities, prior attempts. Duplication risk does NOT shrink with task size — small `light` features are where copy-paste sneaks in precisely because nobody looked — so the sweep's capability list stays complete on every tier, `light` included.
  - **Subsystem mappers — depth, scales with tier**: 0–2 by default, only for subsystems the reuse sweep flags as genuinely load-bearing (`light`/`mid` often need none — the sweep already covered them). `deep`/`mega-deep` may widen or add rounds; mega-deep's heavier per-module **Research phase** is the deepest rung of this same ladder (recon and mega-deep research are one concept scaled, not two).
  - **Total default: 1–3 agents.** Recon is a cheap pre-pass, not a survey. Widen only on the user's explicit say-so.
- **Snapshot fidelity**: recon must read the SAME base the worktree will be created from (origin's default branch, per 0.75's `fresh` base) — NOT a dirty local working tree or an unrelated checked-out branch. If the canonical clone diverges, recon against the intended base ref explicitly, or run recon after homing (0.75) on the worktree's actual base.
- **Each agent returns, structured** (read-only explorers don't write files — the PARENT persists their returned reports): what already exists here (files/modules + one-line purpose); **reuse-as-is** candidates; **adapt-with-changes** candidates (and what changes); the conventions, patterns, and test shapes to match; **collision / dedup risks** (existing code the naive plan would duplicate or fight); and **the search trail for every absence claim** ("no existing X — searched <terms/globs/paths>") so audits can challenge what wasn't found, not just what was — a bare "nothing to reuse" is the classic silent dedup failure.
- **Persist the consolidated findings to `implementations-plan/<plan>/recon.md` once the worktree exists (Phase 0.75)** — writing artifacts before homing is exactly what 0.75 forbids; the parent holds recon findings in context until then. recon.md leads with an explicit **Reuse map** table: capability needed → existing code found (or absence + search trail) → verdict `reuse-as-is | adapt | build new` — and every `build new` carries a one-line justification the audits can attack.
- **`recon.md` feeds both the draft and every audit**: planners build on the reuse map; codex/fable are explicitly told to check the design against it ("does this duplicate or ignore what recon found?").

If recon reveals the change is materially larger or more coupled than the clarifying answers implied, say so and revise the tier recommendation (0.5) before drafting.

---

## Phase 0.5: Tier recommendation (ALL tiers)

Once the user has answered the clarifying questions and the Phase 0.4 recon has returned, the main agent recommends a tier based on the answers, the recon findings, and current task understanding.

**Rubric**: count how many of these are HIGH for this task:
1. **Novelty** (no prior team experience with this surface)
2. **Blast radius** (failure affects many users / many subsystems)
3. **Irreversibility** (mistakes are hard to undo: prod data, releases, schema)
4. **Migration cost** (state, data, or contract migrations)
5. **External coupling** (depends on third-party APIs / services)
6. **Security sensitivity** (auth, secrets, payments, privacy)

- 0 high → `light` (if also bounded and single-package) or `mid`
- 1 high → `mid` (default if unsure)
- 2+ high → `deep` regardless of package count
- 2+ high AND novelty is HIGH → `mega-deep`

Example outputs:

> "Based on your answers, this looks like a `mid` task: contained feature, no novel surface area, only 1 high-risk dimension (external coupling). Confirm `/blueprint mid`, or override with `/blueprint light|deep|mega-deep`?"

> "Based on your answers, this looks like a `deep` task even though it's single-package: it's an auth refactor with high blast radius AND high irreversibility. Single-package does NOT downgrade to `mid` here. Confirm `/blueprint deep`, or override with `/blueprint mid|mega-deep`?"

The recommendation is advisory. The user always has the final call.

Once the tier is set, proceed to workspace homing, then the per-tier protocol below.

---

## Phase 0.75: Workspace homing (ALL tiers)

Blueprint work lives in its own git worktree, named after the plan. Home the session BEFORE writing any artifact (`plan.md`, `recon.md`, research files, the fallback `eli5.html`) — artifacts written pre-homing land in the root clone's tree, which is exactly the collision worktrees exist to prevent. (Phase 0.4 recon EXPLORES read-only before homing; its `recon.md` is persisted here, as the first artifact written into the fresh worktree.)

1. **Derive the slug** from the task: kebab-case, == the plan name (e.g. `escrow-refund`). Announce it alongside the tier recommendation ("Homing into worktree `escrow-refund`").
2. **Skip-or-create**:
   - Already inside a worktree (`git rev-parse --git-dir` ≠ `--git-common-dir`)? Skip creation and ADOPT: derive the slug from the worktree path itself (`.claude/worktrees/<slug>`) and align the plan name to THAT slug — never register a task-derived slug into a worktree named something else. If the path doesn't match the native layout (custom `WorktreeCreate` hook, manual layout), skip manifest registration and just note it.
   - Not a git repository? Skip homing entirely, say so, and proceed in place.
   - Otherwise call `EnterWorktree` with `name: <slug>`. This skill instruction is the standing authorization the tool requires. The native default base (`fresh`, from origin's default branch) is correct — plans start from a clean tree; set `worktree.baseRef: "head"` in settings only when the plan must build on unpushed local work.
3. **Set up + register**: run `bun install` if a `package.json` exists, then `agent-worktree register <slug> --status "phase 0.75: homed, drafting"` (derives path/branch/repo from cwd; plan defaults to `implementations-plan/<slug>`). If `agent-worktree` is not on PATH, note it and continue — homing works without the manifest.
4. **Status discipline**: keep the manifest's one-line status current at every gate — after approval (`agent-worktree status <slug> "approved: implementing phase 1"`), at each phase-gate pass (`"phase N green: <next>"`), and at wrap-up (`"done: PR #N"`). That line is what `agent-worktree list` shows a human scanning "what was this one doing?" — it is the discovery layer, not decoration.
5. **Close-out**: after the PR merges (or the plan is abandoned), suggest `agent-worktree done <slug>` (removes worktree + branch + manifest row). Never run it unprompted while the branch is unmerged.

---

## Per-tier protocols

**All tiers first run the shared preamble** — Phase 0 (clarify) → 0.4 (recon) → 0.5 (tier) → 0.75 (homing). The numbered steps below cover drafting through implementation; the "Clarifying questions" step in each is a recap of that preamble, not a claim that recon/homing are skipped.

### `/blueprint light`

1. Clarifying questions.
2. Draft `plan.md` (single agent).
3. Send the plan to codex (`/codex high`) for a critical pass with explicit adversarial / security ask + assumption-attack ask.
4. Address findings inline; document adopted vs rejected.
5. Generate the ELI5 companion (Artifact primary; `eli5.html` fallback, see below) with DRAFT `/goal` + `/loop` embedded.
6. Approval gate.
7. **Post-approval seeds**: finalize `/goal` + `/loop` against the approved scope; deliver paste-ready in chat (see seeds section).
8. Implement + lesson tracking, then the post-implementation protocol embedded in plan.md: iterative codex fix loop (per arc on stacked plans, plus a final cross-arc pass; preceded by `/code-review <level> --fix` ONLY if the user opted in at Phase 0) → arc-stacked PR delivery.

**Light floor** (epistemic minimum for the lightest tier): at least 5 verified Facts in the Assumptions section AND no silent Asks in any implementation phase. Every implementation phase must list its assumptions explicitly. If you can't meet this floor, the task is too underspecified for `/blueprint light` — escalate to `mid`.

### `/blueprint mid`

1. Clarifying questions.
2. Draft `plan.md` (main agent). **Then generate one competing outline as an alternative approach** (main agent, different angle: cheapest-first vs safest-first, monolithic vs split, etc.). This forces actual plan-space search, not just one author + reviews. Both go into the audit.
3. **Dual audit in parallel**:
   - Codex via `/codex high` with explicit adversarial / security / assumption-attack asks. Codex sees BOTH outlines.
   - Fable subagent via the `Agent` tool, configured as a top-tier Claude subagent specialized for architectural planning (today: `subagent_type: 'Plan'`, `model: 'fable'`, fallback `model: 'opus'` (Opus 5, 1M) while Fable is unavailable; capability matters more than the literal name). Same asks. Sees both outlines.
4. Iterate on feedback; produce a **decision ledger**: which outline was chosen, what alternatives were rejected and why, what's still disputed.
5. **Final fresh-context codex pass**: open a NEW codex session (not a resume). Provide the **consolidated plan, the decision ledger (rejected alternatives + unresolved disagreements)**, and the adversarial + assumption-attack asks. Fresh codex now has the full decision trail and can genuinely re-evaluate, not just review the surface again.
6. Generate the ELI5 companion — Artifact (primary) or `eli5.html` fallback — with DRAFT `/goal` + `/loop` embedded.
7. Approval gate.
8. **Post-approval seeds**: finalize `/goal` + `/loop` against the approved scope; deliver paste-ready in chat (see seeds section).
9. Implement + lesson tracking, then the post-implementation protocol embedded in plan.md: iterative codex fix loop (per arc on stacked plans, plus a final cross-arc pass; preceded by `/code-review <level> --fix` ONLY if the user opted in at Phase 0) → arc-stacked PR delivery.

### `/blueprint deep`

1. Clarifying questions.
2. **Three independent plans in parallel** (different perspectives, separate context):
   - **Main agent**: drafts against the clarifying answers.
   - **Codex**: invoked via `/codex high` with clarifying answers + task statement + explicit adversarial / security / assumption-attack asks.
   - **Fable subagent** (top-tier Claude subagent specialized for architectural planning; today via `subagent_type: 'Plan'`, `model: 'fable'`, fallback `model: 'opus'` (Opus 5, 1M) while Fable is unavailable): given clarifying answers + adversarial / security / assumption-attack asks.
3. **Consolidate** (by main): take the strongest pieces, verify factual claims against the repo, produce a **decision ledger** documenting which decisions came from which source, which were rejected and why, what's still disputed.
4. **Contradiction-check** (NEW): send the consolidated plan + the decision ledger back to BOTH codex and the fable subagent for one round of contradiction-checking. They look for: choices that contradict each other across phases, rejected alternatives that should have been kept, disputed items that were silently resolved. This catches main's consolidation blind spots before the gate.
5. **Double audit** on the contradiction-checked plan:
   - Codex again, with adversarial / security / assumption-attack asks.
   - Fresh fable subagent (different context), with same asks.
6. **Final fresh-context codex pass**: open a NEW codex session (not a resume). Provide the audited plan + the full decision ledger + the adversarial + assumption-attack asks.
7. Generate the ELI5 companion — Artifact (primary) or `eli5.html` fallback — with DRAFT `/goal` + `/loop` embedded.
8. Approval gate.
9. **Post-approval seeds**: finalize `/goal` + `/loop` against the approved scope; deliver paste-ready in chat (see seeds section).
10. Implement + lesson tracking, then the post-implementation protocol embedded in plan.md: iterative codex fix loop (per arc on stacked plans, plus a final cross-arc pass; preceded by `/code-review <level> --fix` ONLY if the user opted in at Phase 0) → arc-stacked PR delivery.

### `/blueprint mega-deep`

Same shape as `/blueprint deep`, but with an upfront research phase AND a split Round 2 audit. Use only when novelty of the surface area means the planning agents would otherwise be guessing at module shapes, AND the implementation cost (days+) justifies the heaviest ceremony.

1. Clarifying questions.
2. **Research phase** (mandatory persisted artifacts) — the heaviest rung of the Phase 0.4 recon ladder: same idea (map prior art before planning), scaled up to per-module persisted artifacts and run independently by each planning agent. Each of the three planning agents (main + codex + fable) first spawns research subagents to map modules they expect to touch. Each agent decides what to explore based on the task + clarifying answers.
   - Main: spawn read-only research subagents specialized for codebase exploration (today via `subagent_type: 'Explore'`) for each relevant module / surface.
   - Codex: invoked with explicit instruction to research relevant files via its read-only sandbox before drafting.
   - Fable subagent: instructed to spawn its own research subagents before drafting.
   - **Each research subagent's findings are persisted to `implementations-plan/<plan>/research/<module>.md` as a mandatory artifact** — the spawning planner writes them (read-only explorers return reports, they don't write files), NOT just a verbal summary. Includes: module purpose, public surface, key invariants, current pain points, relevant tests.
3. **Three independent plans in parallel**, now informed by persisted research artifacts.
4. **Consolidate** (by main): produce decision ledger as in `deep`.
5. **Contradiction-check** (codex + fable on consolidated plan + ledger), as in `deep`.
6. **Audit Round 1**: codex + fable subagent in parallel, both with adversarial / security / assumption-attack asks.
7. Iterate on Round 1 findings; document adopted vs rejected.
8. **Audit Round 2 (split)** — instead of resuming both sessions (which compounds anchoring):
   - **Resumed self-critique** (codex resume): *"Look at your prior findings. What did you miss? What did you over-assert? What second-order risks did your initial review not surface? Where were you anchored on the plan's framing instead of attacking it?"*
   - **Fresh hostile audit** (NEW fable subagent, no prior context): "You're seeing this plan for the first time. Attack it. Find what the prior reviewers missed because they were already inside the plan's framing."
9. Iterate on Round 2 findings.
10. **Final fresh-context codex pass**: open a NEW codex session with just the iterated plan + full decision ledger + adversarial + assumption-attack asks.
11. Generate the ELI5 companion — Artifact (primary) or `eli5.html` fallback — with DRAFT `/goal` + `/loop` embedded.
12. Approval gate.
13. **Post-approval seeds**: finalize `/goal` + `/loop` against the approved scope; deliver paste-ready in chat (see seeds section).
14. Implement + lesson tracking, then the post-implementation protocol embedded in plan.md: iterative codex fix loop (per arc on stacked plans, plus a final cross-arc pass; preceded by `/code-review <level> --fix` ONLY if the user opted in at Phase 0) → arc-stacked PR delivery.

**Cost note**: subagent fan-out is expensive; mega-deep persists multiple research artifacts AND runs a split Round 2 with a fresh subagent. Reserve `mega-deep` for first-of-its-kind work where the implementation cost (days+) dwarfs the audit overhead. Most non-trivial tasks land at `mid` or `deep`.

---

## Required: Architecture & Implementation section

Every plan must include an "Architecture & Implementation" section — the engineering layer. Blueprint audits must argue about *how to build it*, not only *whether the idea is right*; this section is what they argue over. It stays in `plan.md` ONLY — it does NOT go in the ELI5 companion (that's the human decision layer; keep the jargon out of it).

Cover:

- **Proposed architecture**: the shape of the solution — components, boundaries, where new code lives, how it fits existing structure (grounded in `recon.md`: what's reused vs newly added).
- **Key interfaces / types / schemas**: the contracts at package and module boundaries (precise types for cross-workspace / published surfaces; looser internal helpers are fine).
- **Data & control flow**: how data moves through the change; the sequence for the critical path.
- **File-level change map**: which files/modules are added, modified, deleted — cross-checked against recon's reuse candidates so the plan extends rather than duplicates.
- **Algorithms / non-obvious mechanics**: anything with real complexity, spelled out.
- **Trade-offs & alternatives not taken**: the design forks considered and why the chosen one won — this is what the audits pressure-test.

For `light` plans a **compact** treatment is fine — reuse/location, touched files, the critical flow, and the one simpler alternative considered; mark genuinely-N/A bullets N/A rather than padding. Heavier tiers fill all six.

**Every audit prompt (codex + fable, every tier) MUST also request an implementation critique**, alongside the adversarial and assumption-attack asks: *"Critique the Architecture & Implementation. Is this the right structure, or is there a simpler / more idiomatic pattern? Wrong abstraction or boundary? Do the interfaces leak? Does any of it duplicate or ignore what `recon.md` found reusable? What would you build differently, and why?"*

**Standard audit packet (ALL tiers, EVERY audit invocation).** The three asks — adversarial/security (Security section), assumption-attack (Assumptions section), and implementation-critique (this section) — are ONE packet, sent together with the recon reuse-map as context. Where a per-tier step is abbreviated (e.g. "adversarial / assumption-attack asks"), that shorthand still means the FULL packet — never silently drop the implementation-critique or the recon check.

---

## Required: Security & Adversarial Considerations section

Every plan must include a "Security & Adversarial Considerations" section. **This is NOT where uncertain facts go** (those belong in Assumptions). This section addresses threat surface only.

Cover:

- **Threat model**: who could attack, what's the attack surface
- **Least privilege**: minimal credentials, scoped GitHub Actions tokens (`contents: read` default), OIDC, narrow IAM
- **Cryptography**: battle-tested libraries only, never roll your own. Cite the library + version constraint.
- **Input validation / sanitization** at every trust boundary
- **Supply chain**: 7-day npm min-age, frozen lockfile, trusted publisher + provenance
- **Domain-specific risks**:
  - Frontend: XSS, CSRF, clickjacking, prompt injection of LLM flows, dep provenance
  - Smart contracts (Aztec / Noir / Solidity): reorg, replay, front-running, censorship, oracle manipulation, reentrancy
  - npm publishing: trusted publisher + provenance; no static token
  - Backend / API: authn / authz, rate limiting, secret rotation, log redaction

**Every audit prompt (codex + fable, every tier) MUST explicitly request adversarial review**: *"What could go wrong? What would an attacker target? What are we trusting that we shouldn't? Where are the supply-chain / crypto / least-privilege weaknesses?"*

---

## Required: Assumptions section (ALL tiers)

Every plan must include an "Assumptions" section. **This is NOT a generic risk register** (those belong in Security & Adversarial). This section addresses epistemic surface only: what is this plan resting on, and how confident are we?

Separate into three buckets:

- **Facts** (verified against the codebase, docs, or user): cite file paths, line numbers, or sources
- **Inferences** (deduced but unverified, may be wrong): label clearly so audits can attack them surgically
- **Asks** (decisions the user must make): surface to the user, do not silently assume

Audit prompts (codex + fable, every tier) MUST explicitly include an assumption-attack ask **in addition to** the Security & Adversarial ask: *"Attack the Assumptions section. Which Facts are misstated? Which Inferences are unsafe? Which Asks need surfacing instead of being silently assumed? Return findings under Facts / Inferences / Asks buckets, matching the section being attacked."*

This complements the Security & Adversarial Considerations section: that one looks at threat surface; this one looks at epistemic surface (what we're trusting that we shouldn't).

---

## Required: Per-phase validation gates (ALL tiers)

**This is what makes solo/autonomous implementation possible.** Every implementation phase in `plan.md` MUST end with an explicit **Validation gate** block:

- **Commands**: the exact commands to run, taken from the project's REAL tooling (package scripts, CI workflow steps, Makefile — never invented). E.g. `bun run lint && bun run test packages/sdk`, `bun run test:e2e`.
- **Pass criteria**: what output counts as passing (exit 0, specific test file green, app boots and serves the route, migration applies + rolls back).
- **Layers exercised**: which of typecheck/lint · unit · integration · e2e · e2e-live-network this gate covers, per the Phase 0 validation-layers answer.

Rules:

- **Gates are cumulative-cheap**: every gate includes the fast layers (lint, typecheck, unit for the touched packages). Heavier layers (e2e, networked e2e) appear at the phases that warrant them — not on every phase, per the Phase 0 answer.
- **Validate within the phase too, not just at the end**: after each meaningful step inside a phase, run at least the fast layers. Catching a mistake two steps later is cheap; catching it two phases later is a rollback.
- **A phase cannot be marked ✓ until its gate passes.** The gate definition in plan.md is THE meaning of "phase green" — the `/loop` and `/goal` templates reference it instead of guessing.
- **Missing infrastructure is a phase, not a wish**: if the user asked for a layer the project lacks (no e2e harness, no CI), building it becomes an early plan phase, sequenced BEFORE the phases that depend on it.
- New tests added by a phase belong INSIDE that phase's gate (test added → gate runs it), keeping tests inline with the change per the testing philosophy.

---

## Required: Post-implementation section IN plan.md (ALL tiers)

The post-impl steps (Phase 5+ below) are executed by the IMPLEMENTING session — often a fresh `/goal` or `/loop` session that never loaded this skill. plan.md is the only instruction surface it is guaranteed to read. So every plan.md MUST end with a self-contained "Post-implementation" section — the steps written out, not referenced ("see the blueprint skill" fails the approval gate) — specifying, in order:

1. **`/code-review <level> --fix` — ONLY if plan.md says `code_review` is not `off`** (the user's Phase 0 answer; off is the default and means this step is absent from the plan, not "skipped"). When on: run it on the diff under review (single-arc: the whole implementation; multi-arc: the arc's diff) → skim the applied fixes → commit them separately from implementation commits. Level is the one recorded in plan.md, sized to the diff — small/contained → `low`; typical feature arc → `medium`; `high`/`max` ONLY when the user named them. Higher levels fan out many more agents for broader-but-shakier findings, and the codex loop already covers depth — paying twice for it is what burns a budget. Never add `/code-review` to a plan whose `code_review` is `off`.
2. **Codex audit** (`/codex high`): the diff under review + (if `/code-review` ran) a summary of the code-review commits + plan.md + decision ledger + the adversarial/security ask + the no-over-engineering and comment-quality rules below.
3. **Iterative fix loop**: triage findings (verify codex's factual claims against the repo first — it can misread code), apply the accepted fixes, commit, log the round (consult + verdict) in lessons/, then RESUME the same codex session with the fix diff and ask it to re-review. Repeat until a round yields no new material findings — rejected nitpicks don't count as churn. Still producing material findings after 3 rounds? Stop and surface to the user: that's a scope smell, not a polish loop.
4. **Delivery** per the plan's Delivery section (below): create the PRs — the FIRST time any PR is opened. Never open PRs (even drafts) during implementation: they burn CI minutes on code the loops above will still change.

**Loop placement (the plan.md section spells out the one that applies):**

- **Single-arc plan**: steps 1–3 run once, over the whole implementation diff, after the last phase goes green; then step 4.
- **Multi-arc plan**: steps 1–3 run **per arc, at each arc boundary** — after the arc's phases go green and BEFORE `gh stack add` opens the next arc — scoped to that arc's diff while the arc is still the stack tip (fixes land on their own branch; nothing cascades; no later arc ever builds on unreviewed code). Brief codex with the arc map ("this is arc N of M; later arcs will build X on it") so seams reserved for later arcs aren't flagged as dead code. After ALL arcs are green and looped, run one **final cross-arc integration pass**: a FRESH codex session over the net diff from plan baseline, asking explicitly for cross-arc issues (seams between arcs, duplication across arcs, drift from the plan) — same iterative loop; it should converge in a round or two since every arc was already cleaned. `/code-review` (when opted in) runs per arc only — don't repeat it over the net diff. Then step 4.

**The no-over-engineering rule** (include verbatim in every post-impl codex prompt, initial and resumed): *"Report bugs and small, targeted improvements only. Do not propose speculative abstractions, extra configuration surface, new layers, or rewrites — the smallest change that fixes each real problem. If code works and is clear, leave it alone."*

**The comment-quality rule** (same treatment — verbatim in every post-impl codex prompt): *"Audit the comments for value per character. Flag any comment that narrates what the code visibly does, restates its line, references implementation plans / phases / reviews, or spends a paragraph where a sentence works — and flag places where a non-obvious invariant or constraint deserves a comment it doesn't have. Comments are permanent context every future reader, human or LLM, pays to re-read: they must be few, dense, and exact."*

---

## Required: Delivery section — arcs → stacked PRs (ALL tiers)

Phases are the unit of validation; **arcs** are the unit of review — a contiguous group of phases that ships as one PR. Every plan.md MUST include a "Delivery" section declaring the mapping: arc name → phases included → what it stacks on → the `/code-review` setting for that arc (`off` unless the user opted in at Phase 0; then `low` / `medium`; higher only if the user asked).

- **Single-arc plan** (typical `light`, many `mid`): one branch, one PR, plain `gh pr create`. Say so explicitly; no stack ceremony.
- **Multi-arc plan**: one branch per arc, stacked via the `gh stack` extension (`gh extension list` to confirm; `gh extension install github/gh-stack` if missing) so each PR stays a reviewable slice while later arcs build on earlier ones.

Sizing rule: an arc must be independently revertable and reviewable in one sitting — if its diff wouldn't be, split it.

**PR timing — no PR before the quality loops.** PRs (drafts included) are opened ONLY in the post-implementation Delivery step, after EVERY quality loop the plan requires has converged (single-arc: the one loop; multi-arc: each arc's boundary loop AND the final cross-arc pass). An open PR re-runs CI on every push, burning CI minutes on code the loops will still change. During implementation the per-phase validation gates are the feedback loop; branches still get pushed (checkpointing, `gh stack push`) — under the PR-gate CI convention a branch push without a PR triggers nothing.

### `gh stack` mechanics (agent-safe forms)

`gh stack` prompts interactively when underspecified — always pass branches and flags explicitly:

- **Start** (arc 1): `gh stack init --adopt <current-branch>` to make the worktree branch layer 1, or `gh stack init <arc-1-branch>`; add `--base <trunk>` if trunk isn't the repo's default branch.
- **Arc boundary** (previous arc's phases all green AND its quality loop converged — see the Post-implementation section): `gh stack add <arc-N-branch>` — subsequent commits land on the new layer.
- **Publish — only in the Delivery step, after the quality loops converge** (see PR timing above): `gh stack submit --auto` (titles auto-generate from commits; conventional commits make them right), then `gh pr edit` each PR with a proper body, then watch checks. Never submit during implementation, not even as drafts.
- **Stay current**: `gh stack sync` after trunk moves or fixes land on a lower arc — it cascade-rebases and pushes `--force-with-lease --atomic`. On conflict: `gh stack rebase`, resolve, `--continue`.
- Per-arc loop fixes land on their own arc automatically (the arc is the tip while its loop runs). Final-integration-pass fixes go on the top arc unless they squarely belong to a lower one and moving them is cheap (`gh stack down`/`up`, then `gh stack sync` to cascade).
- **`gh stack merge` merges the named PR AND every PR below it** — a land-to-trunk action: the user's call, never autonomous/AFK.

Caution: sync/rebase rewrite arc-branch history. Fine while the agent owns every arc branch; the moment another human pushes to one, stop syncing autonomously and surface it.

---

## Required: ELI5 companion (ALL tiers)

**Hard prerequisite for the approval gate.** The ELI5 is the plain-language, human decision layer — what the user reads to approve. It is authored as ONE source file in the plan dir (`implementations-plan/<plan>/eli5.html`) and delivered in one of two modes.

**Mode preflight (decide ONCE, early — record `eli5_mode` in `plan.md`):** use **Artifact** mode when the `Artifact` tool is available in the session AND the plan may be published to claude.ai (default yes; Phase 0 surfaces "must this plan stay on your infrastructure?" when the surface looks sensitive). Otherwise use **file** mode. This one decision governs the generation step, the approval-gate presentation, and post-approval seed sync — don't re-decide it ad hoc.

**Artifact mode (primary):** publish the source file via the `Artifact` tool → a shareable claude.ai URL (default-private; the user shares when they choose).
- **Load the `artifact-design` skill BEFORE building it** — a hard requirement of the Artifact tool, and it calibrates the design effort.
- **Self-contained**: an Artifact is a single hosted page — it CANNOT relatively link to `plan.md` / `lessons/` (those aren't published). Inline what the reader needs; naming `plan.md`'s repo-relative path as plain text is fine.
- **Record the Artifact URL + its source file path in `plan.md`** (Seeds/approval area). Redeploying the SAME source file → the SAME URL; without the recorded URL+path a resumed session or post-approval seed sync can't update the live Artifact.
- **Keep it current on any material change** — not only post-approval seed finalization, but also a redraft after rejection or a re-audit. A stale shared Artifact is worse than none.
- **Privacy**: publishing sends plan content to claude.ai. For plans that must stay on-infra, use file mode — a legitimate reason to switch, not only tool availability.

**File mode (fallback):** the standalone `eli5.html` (scaffold below): no external deps, no build, opens in any browser. It's what the `BLUEPRINT_VIEW_CMD` remote-viewing hook serves (see the approval gate). Use it when the Artifact tool is absent or the plan must stay on your infrastructure.

**Excluded from the ELI5 (both modes): the Architecture & Implementation / technical detail** — that lives in `plan.md` for the audits. (The command-heavy `/goal` + `/loop` seeds DO belong in the ELI5 — "no jargon" is about prose, not the pasteable seeds.)

Either way, the CONTENTS are the same:

- **Title + one-paragraph summary** in plain language
- **Why this tier was chosen** (Phase 0.5 rubric outcome, with the rubric scores)
- **Phases**: ELI5 of each (what + why, no jargon) + its validation gate in one plain-language line ("proves itself by: unit tests for the new parser + lint")
- **Human context**: simplified background needed to understand decisions
- **Open questions**: with their human-context framing
- **Approval decision needed from you**: explicit list of what the user must approve (scope, tier, deliverables, /harden scheduling decision if relevant)
- **Implementation seeds**: `/goal` and `/loop` shown as code blocks (DRAFT until the approval gate; finalized post-approval), with ONE marked as "Recommended for this plan" based on whether completion is transcript-observable; explicit warning "Use exactly one per session — they don't compose"
- **(File fallback only) Footer links**: relative links to `plan.md` and `./lessons/`

Explicitly EXCLUDED from the ELI5 (both forms): the Architecture & Implementation / technical detail — that lives in `plan.md` for the audits, not the human approval view.

UI/UX: simple, clean, uncluttered. Plain typography, generous whitespace, no flashy CSS. Mobile-readable.

### ELI5 fallback: standalone HTML scaffold

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Blueprint ELI5 — <plan-name></title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 720px; margin: 2rem auto; padding: 0 1rem; color: #222; line-height: 1.6; }
    h1, h2, h3 { font-weight: 600; }
    h1 { font-size: 1.8rem; margin-bottom: 1.5rem; }
    h2 { font-size: 1.3rem; margin-top: 2.5rem; }
    h3 { font-size: 1.05rem; margin-top: 1.5rem; color: #444; }
    code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.9rem; }
    pre { background: #f6f6f6; padding: 1rem; border-radius: 4px; overflow-x: auto; white-space: pre-wrap; }
    .phase { margin: 1.5rem 0; padding: 1rem 1.25rem; border-left: 3px solid #ccc; background: #fafafa; }
    .seeds { margin-top: 3rem; padding-top: 2rem; border-top: 1px solid #eee; }
    .recommended { background: #fff8e1; border-left-color: #f0a020; }
    .warning { color: #b45309; font-weight: 600; margin: 1rem 0; }
    .approval { background: #eef6ff; padding: 1rem 1.25rem; border-left: 3px solid #0366d6; margin: 1.5rem 0; }
    a { color: #0366d6; }
    .muted { color: #666; font-size: 0.9rem; }
  </style>
</head>
<body>
  <h1><plan-name></h1>
  <p><one-paragraph summary, plain language></p>

  <h2>Why this tier was chosen</h2>
  <p><tier picked, rubric scores, justification in 2-3 sentences></p>

  <h2>Phases</h2>
  <div class="phase">
    <h3>Phase 1: <name></h3>
    <p><what + why, plain language></p>
    <p class="muted">Proves itself by: <validation gate, plain language — e.g. "unit tests for the new parser + lint, all green"></p>
  </div>
  <!-- repeat for each phase -->

  <h2>Human context</h2>
  <p><background needed to understand decisions, no jargon></p>

  <h2>Open questions</h2>
  <ul>
    <li><question + human context></li>
  </ul>

  <div class="approval">
    <h2>Approval decision needed from you</h2>
    <ul>
      <li>Confirm scope and exclusions.</li>
      <li>Confirm tier (`mid` / `deep` / etc.) based on the rubric above.</li>
      <li>Confirm the validation plan: which layers gate which phases (unit / integration / e2e / live-network e2e).</li>
      <li>Confirm the delivery topology: which phases group into which arcs / stacked PRs (or the single-PR call).</li>
      <li>Decide whether to schedule `/harden security` or `/harden quality` post-implementation (if applicable).</li>
      <li>Approve, conditionally approve (with conditions), or reject (with blocking findings).</li>
    </ul>
  </div>

  <section class="seeds">
    <h2>Implementation seeds (draft — finalized after approval)</h2>
    <p>Two options for the autonomous implementation session. `/goal` survives <code>claude --resume</code> and is the official primitive for "work until the condition holds"; recurring `/loop` tasks fire on their interval until they expire after 7 days. Pick the one matching whether the completion condition is observable in the transcript.</p>
    <p class="warning">Use exactly ONE per session. They don't compose — setting one replaces the other.</p>

    <div class="phase recommended">
      <h3>Recommended for this plan: /<goal or loop></h3>
      <pre><code>/<recommended seed> ...</code></pre>
    </div>

    <h3>Alternative: /<the other one></h3>
    <pre><code>/<alternative seed> ...</code></pre>
  </section>

  <p class="muted"><a href="plan.md">Full plan.md</a> · <a href="./lessons/">Lessons logs</a></p>
</body>
</html>
```

Use relative links (`plan.md`, `./lessons/`), never absolute filesystem paths.

---

## Required: `/goal` and `/loop` seed strings (ALL tiers)

These live IN the ELI5 companion (the Artifact, or the fallback `eli5.html`) as copy-paste code blocks (DRAFT until the approval gate), and also at the bottom of `plan.md` under a "Seeds" section for terminal grep-ability.

**Seeds are finalized AFTER the approval gate.** Approval can change scope — conditions attached, phases dropped, constraints added — and that invalidates pre-approval seeds. The drafts exist so the user can evaluate the plan; the post-approval versions are canonical. After approval, deliver the final seeds in chat as paste-ready blocks and sync the ELI5 companion (redeploy the Artifact, or update `eli5.html`) + plan.md to match. **The implementation session must run INSIDE the plan's worktree** (this session already is, post-homing; a fresh session gets there via `agent-worktree resume <slug>`) — seeds pasted into a session sitting in the root clone drive work in the wrong tree.

**Within a single Claude Code session, only one is active. Setting one replaces the other. The ELI5 picks ONE as the recommended seed for this plan; the other is shown as a fallback.** `/goal` is the official primitive for "keep working until a condition holds" (per docs: *"To keep the session working turn after turn until a condition is met rather than on an interval, see `/goal`"*) and survives `claude --resume` — prefer it whenever completion is transcript-observable. `/loop` is interval-based; recurring tasks fire until they expire after 7 days. Use `/loop` with a FIXED interval as the fallback when signals aren't transcript-visible or cron-style reliability is wanted. Avoid self-paced (interval-less) loops for plan execution: the model can end them early when it judges work "done enough" — the classic under-drive stall.

**Permission-stall warning**: a loop silently stalls on permission prompts. Start the implementation session in the permission mode you intend (plus AFK authorization where applicable) so the loop isn't blocked waiting for an approval nobody is present to give.

### `/goal` template

`/goal` sets a completion condition. A Haiku-class evaluator checks after each turn whether it holds. The evaluator only sees what the agent surfaces in the conversation, so the condition must reference observable signals. Frame as: (1) one measurable end state, (2) how to prove it, (3) constraints that matter.

Replace `<test>` and `<lint>` with the project's actual commands (e.g. `bun run test` / `bun run lint:actions`, `pnpm test` / `pnpm lint`, `cargo test` / `cargo clippy`, `go test ./...` / `golangci-lint run`):

```
/goal All phases marked ✓ in plan.md (the per-phase headers in the file — not the chat, not the task list), each ✓ backed by its phase's validation gate (as defined in plan.md) reported passing in the transcript; for each phase the agent has printed `LESSONS_FILE=implementations-plan/<plan>/lessons/phase-N.md` in the transcript; if plan.md's `code_review` is not `off`: `/code-review` complete at that level with findings applied and committed (once per arc on multi-arc plans) — if it is `off`, `/code-review` was NOT run; the codex fix loop converged for EVERY reviewed diff — each arc at its boundary plus the final cross-arc pass on multi-arc plans, the whole diff on single-arc — each convergence evidenced by a resumed codex pass reporting no new material findings, quoted in the transcript; the Delivery section's PR topology exists on GitHub, created only AFTER all loops converged (`gh stack view` or `gh pr view` output in the transcript); `<test>` and `<lint>` both report exit 0 in the transcript.
```

### `/loop` template

`/loop` re-fires the prompt on its interval until cleared or expired (7 days). Default to **`/loop 15m`** for implementation cadence: firings land between turns (never mid-response, no overlap), and jitter can delay a firing by up to half the interval — treat 15m as "roughly every 15-22 minutes". The prompt must DRIVE work, not restate the goal: encode dispositions explicitly — never idle, always have a task, decide with codex instead of waiting for the user.

```
/loop 15m Drive implementations-plan/<plan> forward. Never idle waiting for my input. Each firing:
1. **Reality check**: read implementations-plan/<plan>/plan.md and lessons/ (authoritative state — not the chat); native task list empty (fresh session)? rebuild it from plan.md, one task per remaining step; run `git status` and `git log --oneline -5`. If a PR exists, `gh pr view --json statusCheckRollup` (no --watch; multi-arc plans: `gh stack view` for the whole stack). Without a PR but with CI configured, `gh run list --branch $(git branch --show-current) --limit 1 --json status,databaseId`.
2. **Waiting on CI is fine** — confirm it's actually progressing (`gh run watch <run-id>` up to 10 minutes; queued or stuck past that → inspect logs, log it as blocked in lessons). Use the wait productively: review the diff, prep the next phase, strengthen tests. Don't start work that would conflict with the in-flight change.
3. **No task in hand?** Pick the next pending step from plan.md and start it. After each meaningful edit, run the fast validation layers (`<lint>` + `<test>` for the touched packages) — catch mistakes in-step, not phases later. Then commit → push (multi-arc plans: `gh stack push`; `gh stack sync` if trunk or a lower arc moved).
4. **Stuck, or facing a decision you'd normally bring to me?** Don't wait. Call `/codex high` with full context and go back and forth until you two reach a defensible decision, then act on it. Log every consult + verdict in lessons/phase-N.md. Exception — hard limits stay hard: never merge to main or release branches, never publish or deploy, never expand scope beyond plan.md; if the decision requires crossing one, surface it and hold.
5. **Same step failed 5 times?** Stop retrying; reassess the approach with codex, then continue down the agreed path.
6. **Phase green?** "Green" means THE PHASE'S VALIDATION GATE as written in plan.md passes (commands + pass criteria — not generic vibes). Run the full gate, paste the result, mark ✓ in plan.md, file the lessons entry, print `LESSONS_FILE=implementations-plan/<plan>/lessons/phase-N.md` in the transcript, advance to the next phase. Arc boundary crossed (per plan.md's Delivery section)? Run the arc's quality loop FIRST — only if plan.md's `code_review` is not `off`: `/code-review <level> --fix` on the arc diff (level per plan.md; never `max` unless I asked) → commit separately; then, always, the codex loop with the arc map and the plan's no-over-engineering + comment-quality rules until a round yields nothing material — THEN `gh stack add <next-arc-branch>` before the next arc's work.
7. **All phases ✓ in plan.md?** Close out per plan.md's Post-implementation section. Single-arc: run the full quality loop now — only if plan.md's `code_review` is not `off`: `/code-review <level> --fix` (level per plan.md; never `max` unless I asked) → skim applied fixes → commit separately (so code-review changes stay first-class); then, always, the codex audit (`/codex high`, net diff from plan baseline + summary of code-review commits if any + adversarial / security ask + the plan's no-over-engineering + comment-quality rules) → apply accepted fixes, commit, then RESUME the same codex session with the fix diff for a re-review — loop until a round yields no new material findings (still churning after 3 rounds → surface and stop). Multi-arc: every arc already looped at its boundary (step 6) — run only the final cross-arc integration pass: FRESH codex session over the net diff + code-review commit summaries (if any) + cross-arc ask (seams between arcs, duplication across arcs, plan drift) + the no-over-engineering + comment-quality rules, same loop-until-clean. Then Delivery per plan.md — the FIRST time any PR is opened: `gh pr create` (single-arc) or `gh stack sync` then `gh stack submit --auto` + `gh pr edit` bodies (multi-arc), then `gh pr checks --watch`. Then write the wrap-up report: what shipped, every contentious decision codex and I debated — each with ELI5 context (what the question was, the options, why we picked ours) — and open items. Surface and stop.

Keep the native task list current (`TaskUpdate` as steps start/finish; plan.md stays the source of truth). No task tools in this session → print the step checklist only when a step changes state.
```

Adjust both templates to match the specific plan (phase names, quality calibration) and project (concrete lint/test commands).

---

## Status visibility (throughout)

Track protocol progress in the **native task list** (`TaskCreate` / `TaskUpdate`), not a checklist re-typed into every response: the harness renders it (spinner text + `ctrl+t` panel), nothing is re-printed per turn, and it survives compaction and `claude --continue` (stored per session under `~/.claude/tasks/<session-id>/`).

- Create the tasks once the tier is set (0.5): one per step below, adjusted to the tier, with 0 / 0.4 / 0.5 backfilled as completed. At approval add one per implementation phase; on multi-arc plans also one per arc quality loop, one for the cross-arc pass, one for Delivery. Chain them with `blockedBy` so `TaskList` answers "what's next".
- `in_progress` on entry; `completed` only when the step's exit condition holds — a phase's task completes when its validation gate passes and plan.md carries the ✓, never before.
- **plan.md stays authoritative.** The list is per session: a fresh implementing session rebuilds it from plan.md's phase headers (the `/loop` template does this in its reality check). The `/goal` evaluator checks plan.md, never the task list.
- No task tools in the session? They're off by default on Opus 4.8+, Sonnet 5, Fable 5/5.1 and newer since Claude Code 2.1.233 (`CLAUDE_CODE_ENABLE_TODO_TOOLS=1`, e.g. in `settings.json` → `env`, restores them). Don't emulate them in prose every turn: print the step list below only when a step changes state.

Canonical steps (adjust per tier):

```
[✓] 0. Clarifying questions
[✓] 0.4 Codebase recon (findings returned)
[✓] 0.5 Tier recommendation
[✓] 0.75 Workspace homing (worktree: <slug>) + recon.md persisted
[✓] 1. <Tier-specific drafting step>
[▶] 2. <Tier-specific audit step>
[ ] 3. <Tier-specific final-pass step>
[ ] 4. ELI5 companion (Artifact / file fallback)
[ ] 5. Approval gate
[ ] 6. Implementation
[ ] 7. Quality loops: codex fix loop (per arc on stacks, at each boundary) — /code-review first ONLY if code_review ≠ off in plan.md
[ ] 8. Final cross-arc integration pass (multi-arc only)
[ ] 9. Delivery: PRs created (only now), checks green
```

---

## Approval gate (ALL tiers)

**Do not ask for approval until ALL of the following are true. The gate BLOCKS otherwise.**

Required deliverables present:

1. `plan.md` (with Architecture & Implementation, Security & Adversarial Considerations, and Assumptions sections, a validation gate on every implementation phase, a self-contained Post-implementation section, AND a Delivery section mapping phases → arcs/PRs) + `recon.md` from Phase 0.4
2. Codex's final verdict in **explicit format**: `approve` | `conditional approve (with conditions: ...)` | `reject (with blocking findings: ...)`. Freeform / vague verdicts do NOT count as approval.
3. ELI5 companion — a published Artifact (primary) or `eli5.html` (fallback) — embedding the `/goal` + `/loop` seed strings, with one marked Recommended
4. For `/blueprint mid`, `/blueprint deep`, `/blueprint mega-deep`: fable audit verdicts inline in `plan.md`
5. For `/blueprint mid`+, the **decision ledger** (rejected alternatives + unresolved disagreements) is part of `plan.md`

**Block conditions** (gate refuses to ask for approval if any are true):

- **Unresolved Asks** in the Assumptions section (silent assumptions are blockers; either resolve with user input or convert to explicit ask in approval).
- **Unaddressed high-severity audit findings** (codex or fable flagged High/Critical; not adopted, not explicitly rejected with reason).
- **Missing adopted-vs-rejected logs** from any audit cycle.
- **Any implementation phase missing a concrete validation gate** (commands + pass criteria from the project's real tooling).
- **Missing `recon.md` (Phase 0.4) or the Architecture & Implementation section in `plan.md`.**
- **Post-implementation section missing or not self-contained** (references the skill instead of spelling out the steps), or **Delivery section missing the arc → phase mapping**.

**ELI5 visibility (mandatory when asking for approval)**: the user must never have to hunt for the plan. How you present it depends on which ELI5 form you produced:

**If you published an Artifact (primary):** give its URL on its own standalone line, labeled as the plan's ELI5. That's the whole step — it's already hosted and shareable; no file paths, no serving, no teardown.

**If you used the file fallback (`eli5.html`):** output BOTH of these on their own standalone lines (terminals linkify them differently — one of the two will be clickable):

```
<absolute path to eli5.html>
file://<absolute path to eli5.html>
```

Then run EVERY applicable step — additive, not first-match-wins (a macOS box with a hook configured does both 1 and 2):

1. **Remote-viewing hook** — if `BLUEPRINT_VIEW_CMD` is set, run `$BLUEPRINT_VIEW_CMD <absolute plan dir>` and VALIDATE its stdout before trusting it: success means exit 0 AND exactly one line AND it matches `^https?://` AND it has no trailing slash. On success print the returned URL + `/eli5.html` on its own standalone line, labeled as the remote-viewing URL. Anything else — non-zero exit, empty/multi-line stdout, non-URL line, trailing slash — is a hook failure: print `remote view unavailable (hook failed); using file paths` — never fail silently when the hook is configured.
2. **macOS** — run `open <absolute path to eli5.html>` so the browser pops without hunting.
3. **Neither applied** — the printed paths above are the fallback.

(Absolute paths are fine in CHAT — the no-absolute-paths rule applies to committed files only.)

**After the verdict is recorded** (file-fallback path only; approve / conditional approve / reject alike): if `BLUEPRINT_VIEW_CMD` was invoked for UP at this gate — **even if that UP failed validation or errored, since it may have partially published** — run `$BLUEPRINT_VIEW_CMD --down <absolute plan dir>` and confirm the teardown in chat. Serving exists only inside the approval window. A DOWN failure is non-blocking but must be reported. (The Artifact path has no teardown — being persistently shareable is the point.)

### Remote viewing (headless boxes): the `BLUEPRINT_VIEW_CMD` contract

When blueprint runs on a machine with no browser (e.g. a remote dev server), the machine may export `BLUEPRINT_VIEW_CMD` naming a hook that maps a plan directory to a temporary browsable URL. The skill never learns the mechanism — the hook owns it.

```
$BLUEPRINT_VIEW_CMD <absolute-path-to-plan-dir>          # UP: publish, print URL
$BLUEPRINT_VIEW_CMD --down <absolute-path-to-plan-dir>   # DOWN: unpublish
```

- **UP** stdout: exactly one line — the base URL at which the plan dir is browsable. Must start `http://` or `https://`, NO trailing slash. The skill appends `/eli5.html`. Exit 0 = live; non-zero or empty stdout = fall through the cascade with the visible notice. Repeat UP for the same dir returns the same URL (idempotent).
- **DOWN**: removes whatever UP published for that dir; exit 0 also when nothing was published (idempotent). The skill calls DOWN immediately after the approval verdict — after every ATTEMPTED UP, successful or not.
- `BLUEPRINT_VIEW_CMD` is the path to an executable; the skill invokes it directly (quoted) with the plan dir as a single argument — the value is never shell-split.
- The hook owns its security policy (what it serves, to whom).

Reference implementation for Tailscale machines: `examples/blueprint-view-tailscale.sh` (serves ONLY allowlisted doc trees — default `implementations-plan` + `audit`, the latter for `/harden` reports, override via `BLUEPRINT_VIEW_TREES` — tailnet-only, refuses any symlink, `--off` backstop). This contract section is the single source of truth; other skills (e.g. `/harden`'s report step) reference it rather than redefining it. Policy notes for ANY implementation: served doc trees must never contain secrets (gitleaks guards commits, not live files), and served HTML shares one browser origin across repos — never place untrusted HTML under a served tree.

Present everything together. User approves explicitly using one of the three verdict formats.

**Immediately after approval** (especially conditional approvals): finalize the `/goal` + `/loop` seeds against the approved scope — fold in conditions, dropped phases, new constraints — deliver them in chat as paste-ready blocks, and sync the ELI5 companion (redeploy the Artifact, or update `eli5.html`) + plan.md's Seeds section. Pre-gate seeds are drafts; post-approval seeds are canonical.

---

## Composition with other skills

Blueprint sits in a specific phase of the development cycle. Other skills cover other phases:

- **`/code-review` is NOT replaced by Blueprint, and Blueprint is NOT replaced by `/code-review`.** They cover different phases:
  - Plan-time audits (codex + fable during Blueprint) gate plan APPROVAL.
  - The iterative codex fix loop gates IMPLEMENTATION (it runs from plan.md's embedded Post-implementation section). `/code-review <low|medium> --fix` precedes it ONLY when the user opted in at Phase 0 — it is off by default inside Blueprint, though the same `/code-review` stays independently useful on any diff when the user invokes it.
- **`/harden` is NOT auto-scheduled by Blueprint.** It's an expensive whole-codebase audit, typically run before a release/library publish, not after every plan. Blueprint surfaces the question during Phase 0 (clarifying questions) so the user can decide whether the plan's surface (auth / secrets / CI/CD / publishing / repo-wide security posture) warrants a `/harden` pass at release-time. The user decides; Blueprint records the decision in the plan's "Post-implementation hardening" note.

---

## Phase 5+: Implementation, lessons, post-impl review loop, delivery

These steps are duplicated INTO every plan.md as its required Post-implementation + Delivery sections — the implementing session executes them from there, not from this skill.

### Implementation + lesson tracking

Implement per the plan. Write comments to the comment-quality bar AS you code, not as post-hoc cleanup: value per character, invariants and non-obvious whys only, never references to the plan or its phases (plans are ephemeral; code outlives them) — the codex loop audits this. Log meaningful attempts in `implementations-plan/<plan>/lessons/phase-N.md`. At each phase-gate pass, refresh the workspace manifest: `agent-worktree status <slug> "phase N green: <next>"` (see Phase 0.75 status discipline). At arc boundaries (per the plan's Delivery section), run the arc's quality loop FIRST (see the Required Post-implementation section's loop placement), then `gh stack add <next-arc-branch>` before starting the next arc's work.

**Failure-retry policy** (explicit, not parenthetical):
- **Human-driven implementation**: after **3 failures** on the same step, stop and reassess. The human is in the loop and can re-scope quickly.
- **`/loop` autonomous mode**: after **5 failures** on the same step, stop and reassess. The autonomous loop has higher tolerance because it operates without immediate human escalation; the extra two attempts let it try alternate framings before stopping.

Why the difference: humans escalate fast, agents need a wider window to self-correct before the loop should yield. Both are hard stops, not advisory.

### Pre-codex code-review pass (opt-in only)

**Default: not run.** `/code-review` runs before the codex audit ONLY when plan.md's `code_review` is not `off` — the user's answer to the Phase 0 question. If the plan has no such setting or it says `off`, go straight to the codex post-impl audit; do not "helpfully" add a review pass, and do not ask again mid-implementation.

When opted in, run `/code-review <level> --fix` on the diff under review (the whole implementation on single-arc plans; the arc's diff at each arc boundary on multi-arc plans — see the Required Post-implementation section's loop placement). This catches correctness bugs AND quality cleanups (simplification, reuse, efficiency) via the Anthropic model family, applies fixes to the working tree. After it finishes:
1. Skim the applied fixes for sanity (look for unintended changes).
2. **Commit them separately from implementation commits** (so they're identifiable as code-review-applied vs implementation work).
3. Proceed to the codex post-impl audit.

**Never default to `max`.** Level is the one recorded in plan.md — `low` for small/contained, `medium` for a typical feature arc — and `high`/`max` run only when the user named them. `max` fans out many more agents for broader-but-lower-confidence findings, and the codex loop that follows already supplies the depth; paying for both is how a token budget disappears. See Cost controls.

### Post-implementation codex review

After the phases go green (and, only if opted in, after `/code-review` has been applied and committed in separate commits), send codex (`/codex high`) the following package:

1. **The diff under review** (the arc's diff at an arc boundary; the net diff from plan baseline for single-arc plans and for the final cross-arc integration pass).
2. **A separate summary of code-review-applied commits** — only when `/code-review` ran — listing what it changed and why. This lets codex audit BOTH the original implementation AND the cleanup as distinct artifacts. Omit the item entirely when `code_review` is `off`.
3. The original plan.md + decision ledger for reference — on multi-arc plans, plus the arc map ("this is arc N of M; later arcs will build X on it") so seams reserved for later arcs aren't flagged as dead code.
4. Explicit adversarial / security ask (the final integration pass asks for cross-arc issues instead: seams between arcs, duplication across arcs, drift from the plan).
5. **The no-over-engineering rule**, verbatim from the plan's Post-implementation section — the ask is bugs and small targeted improvements, not redesigns.
6. **The comment-quality rule**, verbatim from the same section — comments audited for value per character: no code-narration, no plan/phase references, flag missing comments where an invariant deserves one.

When `/code-review` did run, this preserves provenance: codex can see what was originally implemented vs what was tweaked by `/code-review`, and can audit structural changes from `/code-review` as first-class changes rather than as a silently-cleaned final state.

### Iterative fix loop

Triage codex's findings — verify factual claims against the repo before acting (codex can misread code). Apply the accepted fixes, commit, log the round (consult + verdict) in lessons/, then **resume the same codex session** with the fix diff and ask for a re-review under the same no-over-engineering rule. Loop until a round yields no new material findings — rejected nitpicks don't count as churn. Still producing material findings after 3 rounds? Stop and surface to the user: that's a scope smell (the implementation diverged from the plan, or the plan under-specified), not a polish problem.

**Placement**: single-arc plans run this loop once, over the whole diff. Multi-arc plans run it per arc at each arc boundary (before `gh stack add`), then one final cross-arc integration pass over the net diff — see the Required Post-implementation section's loop placement.

### Delivery

Ship per plan.md's Delivery section — PRs are created ONLY here, after every required quality loop has converged (per-arc loops + the final cross-arc pass on multi-arc plans; opening PRs earlier burns CI on every push while the loops are still changing the code). Single-arc → plain `gh pr create`; multi-arc → `gh stack sync` first if trunk moved, then `gh stack submit --auto` + `gh pr edit` bodies. Watch checks (`gh pr checks --watch`). `gh stack merge` (lands the named PR and everything below it) stays the user's call. Then maintain `implementations-plan/index.md` with the completed marker.

---

## Frontend addendum

When the plan touches UI, **copywriting is part of the design surface**. Clear, simple, no jargon, no clutter. Bad copy makes a good product feel rough. Treat copy review with the same rigor as code review.

---

## Outputs always land here

```
implementations-plan/<plan-name>/
├── plan.md           # The plan: Architecture & Implementation + Security & Adversarial + Assumptions sections, per-phase validation gates, Post-implementation section (codex fix loop; `/code-review` first only if `code_review` ≠ off), Delivery section (arcs → PRs), audit verdicts inline (mid/deep/mega-deep), decision ledger (mid+), Seeds at bottom
├── recon.md          # Phase 0.4 codebase-recon findings (reuse / adapt / dedup-risk map) — feeds the draft + every audit
├── audit-codex.md    # Codex audit transcript(s)
├── audit-fable.md    # Fable audit transcript (mid/deep/mega-deep only)
├── eli5.html         # ELI5 FALLBACK only — primary is a Claude Artifact (hosted off-repo); /goal + /loop embedded, one marked Recommended
├── research/         # Persisted research subagent findings (mega-deep only; deepest rung of the recon ladder)
│   └── <module>.md
└── lessons/
    └── phase-N.md    # Per-phase debugging logs (filled during implementation)
```

Update `implementations-plan/index.md` with `- [<plan-name>](<plan-name>/plan.md) — <status> — <one-line hook>` when the plan is created and again when it closes.

All of this lands INSIDE the plan's worktree (Phase 0.75) and merges to the canonical clone with the PR — EXCEPT a published Artifact, which is hosted off-repo on claude.ai (only its source `eli5.html` + the URL recorded in `plan.md` live in the worktree). At close-out, suggest `agent-worktree done <plan-name>`.
