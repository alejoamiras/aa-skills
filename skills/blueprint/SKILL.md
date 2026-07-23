---
name: blueprint
description: Plan-creation protocol with FOUR tiers (lowest to highest ceremony) — `/blueprint light` (bounded feature, single codex audit) | `/blueprint mid` (contained feature, codex + fable dual audit; DEFAULT if unsure) | `/blueprint deep` (architectural / cross-cutting, three parallel plans main+codex+fable + double audit + contradiction-check) | `/blueprint mega-deep` (novel surface, planning agents spawn research subagents to map modules before drafting, plus split Round 2 audit). Every tier asks clarifying questions, runs a cheap-but-clever codebase recon phase to surface reusable/adaptable prior art before planning, homes the session into a task-named git worktree before drafting (workspace homing via EnterWorktree + the ~/.agents/workspaces.md manifest), requires a validation gate on every implementation phase (real project commands + pass criteria), and produces an ELI5 deliverable (a shareable Claude Artifact, with a standalone-HTML fallback) embedding `/goal` + `/loop` seed strings. Trigger phrases: "ultraplan", "ultrathink plan", "deep plan", "give me a plan", "blueprint this", "plan this carefully", "plan properly", "use the plan protocol", "full ceremony". Auto-fire (invoke without being asked) when the work involves cross-package BEHAVIORAL changes, infra / IaC with rollout or privilege impact, schema or protocol changes, UI-flow redesign, external-system integration, auth or permissions changes, billing logic, data migrations or backfills, concurrency or cache invalidation, or public API changes.
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

**Model note — Fable → Opus fallback.** The "fable" subagent is the top-tier Claude planning/audit leg that runs in parallel with Codex in every tier. Run it on **Fable** when available; **while Fable is deactivated, run it on Opus 4.8 (1M context)** (`Agent` tool: `model: 'opus'`). "fable" names the *role* — the independent top-tier Claude reviewer alongside Codex — not a hard model requirement, so `audit-fable.md` and the "codex + fable" terminology stay as-is regardless of which model fills the role.

---

## Phase 0: Clarifying questions (ALL tiers)

**The plan is the most important step. Don't draft against a fuzzy target.** Before any drafting, ask the user:

- **Success criterion**: what does "done" look like? Measurable signals?
- **Scope trade-offs**: what's in, what's out, where can scope be cut?
- **Constraints**: time, infra, external deps, capacity
- **Quality bar**: PoC, staging, or production? Calibrates testing rigor and audit depth.
- **Validation layers**: which validation layers should gate each phase? **Inspect the repo FIRST** (package scripts, CI workflows, Makefile, test dirs) so the options offered are REAL, then ask via `AskUserQuestion` with what actually exists: typecheck/lint, unit, integration, e2e, e2e against live networks (sandbox / anvil / testnet). Flag any requested layer the project doesn't have yet — building it becomes a plan phase of its own.
- **Decisions to surface vs delegate**: which trade-offs come back to the user, which the agent resolves
- **Post-implementation hardening**: will this work eventually need `/harden security` or `/harden quality`? Recommended (but not auto-scheduled) if the plan touches trust boundaries, auth, secrets, CI/CD, publishing, or repo-wide security posture. Note: `/harden` is thorough/expensive — usually scheduled for pre-release of a library or app, NOT after every plan. Surface this so the user can decide upfront.

Wait for answers before proceeding.

---

## Phase 0.4: Codebase recon (ALL tiers)

**Plan against the code that exists, not a blank slate.** After clarifying questions, before drafting (and before the tier call, which recon can revise), fan out cheap-but-clever read-only subagents to map the terrain the work will touch. This is the "research first" principle made structural: it surfaces what to reuse, what to adapt, and the conventions to match — so the plan extends the codebase instead of duplicating it, and audits critique against reality.

- **Agents**: read-only `Explore` subagents on `model: 'sonnet'` (cheap but clever), fanned out in parallel — one per subsystem / concern the task plausibly touches. **Sizing**: the tier isn't chosen yet, so start with a modest default fan-out (≈2–4 agents sized to the apparent surface); the tier call (0.5) and deeper tiers may widen it — `deep`/`mega-deep` add rounds, and mega-deep's heavier per-module **Research phase** is the deepest rung of this same ladder (recon and mega-deep research are one concept scaled, not two).
- **Snapshot fidelity**: recon must read the SAME base the worktree will be created from (origin's default branch, per 0.75's `fresh` base) — NOT a dirty local working tree or an unrelated checked-out branch. If the canonical clone diverges, recon against the intended base ref explicitly, or run recon after homing (0.75) on the worktree's actual base.
- **Each agent returns, structured** (read-only explorers don't write files — the PARENT persists their returned reports): what already exists here (files/modules + one-line purpose); **reuse-as-is** candidates; **adapt-with-changes** candidates (and what changes); the conventions, patterns, and test shapes to match; and **collision / dedup risks** (existing code the naive plan would duplicate or fight).
- **Persist the consolidated findings to `implementations-plan/<plan>/recon.md` once the worktree exists (Phase 0.75)** — writing artifacts before homing is exactly what 0.75 forbids; the parent holds recon findings in context until then.
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
3. Send the plan to codex (`/codex xhigh`) for a critical pass with explicit adversarial / security ask + assumption-attack ask.
4. Address findings inline; document adopted vs rejected.
5. Generate the ELI5 companion (Artifact primary; `eli5.html` fallback, see below) with DRAFT `/goal` + `/loop` embedded.
6. Approval gate.
7. **Post-approval seeds**: finalize `/goal` + `/loop` against the approved scope; deliver paste-ready in chat (see seeds section).
8. Implement + lesson tracking + pre-codex `/code-review max --fix` + post-impl codex audit + fix loop.

**Light floor** (epistemic minimum for the lightest tier): at least 5 verified Facts in the Assumptions section AND no silent Asks in any implementation phase. Every implementation phase must list its assumptions explicitly. If you can't meet this floor, the task is too underspecified for `/blueprint light` — escalate to `mid`.

### `/blueprint mid`

1. Clarifying questions.
2. Draft `plan.md` (main agent). **Then generate one competing outline as an alternative approach** (main agent, different angle: cheapest-first vs safest-first, monolithic vs split, etc.). This forces actual plan-space search, not just one author + reviews. Both go into the audit.
3. **Dual audit in parallel**:
   - Codex via `/codex xhigh` with explicit adversarial / security / assumption-attack asks. Codex sees BOTH outlines.
   - Fable subagent via the `Agent` tool, configured as a top-tier Claude subagent specialized for architectural planning (today: `subagent_type: 'Plan'`, `model: 'fable'`, fallback `model: 'opus'` (Opus 4.8 1M) while Fable is unavailable; capability matters more than the literal name). Same asks. Sees both outlines.
4. Iterate on feedback; produce a **decision ledger**: which outline was chosen, what alternatives were rejected and why, what's still disputed.
5. **Final fresh-context codex pass**: open a NEW codex session (not a resume). Provide the **consolidated plan, the decision ledger (rejected alternatives + unresolved disagreements)**, and the adversarial + assumption-attack asks. Fresh codex now has the full decision trail and can genuinely re-evaluate, not just review the surface again.
6. Generate the ELI5 companion — Artifact (primary) or `eli5.html` fallback — with DRAFT `/goal` + `/loop` embedded.
7. Approval gate.
8. **Post-approval seeds**: finalize `/goal` + `/loop` against the approved scope; deliver paste-ready in chat (see seeds section).
9. Implement + lesson tracking + pre-codex `/code-review max --fix` + post-impl codex audit + fix loop.

### `/blueprint deep`

1. Clarifying questions.
2. **Three independent plans in parallel** (different perspectives, separate context):
   - **Main agent**: drafts against the clarifying answers.
   - **Codex**: invoked via `/codex xhigh` with clarifying answers + task statement + explicit adversarial / security / assumption-attack asks.
   - **Fable subagent** (top-tier Claude subagent specialized for architectural planning; today via `subagent_type: 'Plan'`, `model: 'fable'`, fallback `model: 'opus'` (Opus 4.8 1M) while Fable is unavailable): given clarifying answers + adversarial / security / assumption-attack asks.
3. **Consolidate** (by main): take the strongest pieces, verify factual claims against the repo, produce a **decision ledger** documenting which decisions came from which source, which were rejected and why, what's still disputed.
4. **Contradiction-check** (NEW): send the consolidated plan + the decision ledger back to BOTH codex and the fable subagent for one round of contradiction-checking. They look for: choices that contradict each other across phases, rejected alternatives that should have been kept, disputed items that were silently resolved. This catches main's consolidation blind spots before the gate.
5. **Double audit** on the contradiction-checked plan:
   - Codex again, with adversarial / security / assumption-attack asks.
   - Fresh fable subagent (different context), with same asks.
6. **Final fresh-context codex pass**: open a NEW codex session (not a resume). Provide the audited plan + the full decision ledger + the adversarial + assumption-attack asks.
7. Generate the ELI5 companion — Artifact (primary) or `eli5.html` fallback — with DRAFT `/goal` + `/loop` embedded.
8. Approval gate.
9. **Post-approval seeds**: finalize `/goal` + `/loop` against the approved scope; deliver paste-ready in chat (see seeds section).
10. Implement + lesson tracking + pre-codex `/code-review max --fix` + post-impl codex audit + fix loop.

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
14. Implement + lesson tracking + pre-codex `/code-review max --fix` + post-impl codex audit + fix loop.

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
/goal All phases marked ✓ in plan.md (the per-phase headers in the file, not just the chat), each ✓ backed by its phase's validation gate (as defined in plan.md) reported passing in the transcript; for each phase the agent has printed `LESSONS_FILE=implementations-plan/<plan>/lessons/phase-N.md` in the transcript; `/code-review max --fix` complete with findings applied and committed; codex post-impl audit complete with high/critical findings addressed (including modularity / architecture concerns); `<test>` and `<lint>` both report exit 0 in the transcript.
```

### `/loop` template

`/loop` re-fires the prompt on its interval until cleared or expired (7 days). Default to **`/loop 15m`** for implementation cadence: firings land between turns (never mid-response, no overlap), and jitter can delay a firing by up to half the interval — treat 15m as "roughly every 15-22 minutes". The prompt must DRIVE work, not restate the goal: encode dispositions explicitly — never idle, always have a task, decide with codex instead of waiting for the user.

```
/loop 15m Drive implementations-plan/<plan> forward. Never idle waiting for my input. Each firing:
1. **Reality check**: read implementations-plan/<plan>/plan.md and lessons/ (authoritative state — not the chat); run `git status` and `git log --oneline -5`. If a PR exists, `gh pr view --json statusCheckRollup` (no --watch). Without a PR but with CI configured, `gh run list --branch $(git branch --show-current) --limit 1 --json status,databaseId`.
2. **Waiting on CI is fine** — confirm it's actually progressing (`gh run watch <run-id>` up to 10 minutes; queued or stuck past that → inspect logs, log it as blocked in lessons). Use the wait productively: review the diff, prep the next phase, strengthen tests. Don't start work that would conflict with the in-flight change.
3. **No task in hand?** Pick the next pending step from plan.md and start it. After each meaningful edit, run the fast validation layers (`<lint>` + `<test>` for the touched packages) — catch mistakes in-step, not phases later. Then commit → push.
4. **Stuck, or facing a decision you'd normally bring to me?** Don't wait. Call `/codex xhigh` with full context and go back and forth until you two reach a defensible decision, then act on it. Log every consult + verdict in lessons/phase-N.md. Exception — hard limits stay hard: never merge to main or release branches, never publish or deploy, never expand scope beyond plan.md; if the decision requires crossing one, surface it and hold.
5. **Same step failed 5 times?** Stop retrying; reassess the approach with codex, then continue down the agreed path.
6. **Phase green?** "Green" means THE PHASE'S VALIDATION GATE as written in plan.md passes (commands + pass criteria — not generic vibes). Run the full gate, paste the result, mark ✓ in plan.md, file the lessons entry, print `LESSONS_FILE=implementations-plan/<plan>/lessons/phase-N.md` in the transcript, advance to the next phase.
7. **All phases ✓ in plan.md?** Run the post-impl sequence: `/code-review max --fix` → skim applied fixes → commit separately (so code-review changes stay first-class) → codex post-impl audit (`/codex xhigh`, net diff from plan baseline + summary of code-review commits + adversarial / security ask) → address high/critical findings. Then write the wrap-up report: what shipped, every contentious decision codex and I debated — each with ELI5 context (what the question was, the options, why we picked ours) — and open items. Surface and stop.

Keep the ASCII checklist visible each firing (human readability only; plan.md is the source of truth).
```

Adjust both templates to match the specific plan (phase names, quality calibration) and project (concrete lint/test commands).

---

## Status visibility (throughout)

Maintain an ASCII to-do list in your responses showing current phase, done / pending. The ASCII checklist is for HUMAN readability only; it is NOT authoritative state (repo artifacts are). The `/goal` evaluator should check plan.md, not the chat checklist.

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
[ ] 7. Post-impl codex audit
[ ] 8. Fix loop
```

Adjust steps per the tier you're running.

---

## Approval gate (ALL tiers)

**Do not ask for approval until ALL of the following are true. The gate BLOCKS otherwise.**

Required deliverables present:

1. `plan.md` (with Architecture & Implementation, Security & Adversarial Considerations, and Assumptions sections, AND a validation gate on every implementation phase) + `recon.md` from Phase 0.4
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
  - `/code-review max --fix` then codex post-impl audit gate IMPLEMENTATION (these run inside Blueprint's post-impl steps, but the same `/code-review` is independently useful on any diff).
- **`/harden` is NOT auto-scheduled by Blueprint.** It's an expensive whole-codebase audit, typically run before a release/library publish, not after every plan. Blueprint surfaces the question during Phase 0 (clarifying questions) so the user can decide whether the plan's surface (auth / secrets / CI/CD / publishing / repo-wide security posture) warrants a `/harden` pass at release-time. The user decides; Blueprint records the decision in the plan's "Post-implementation hardening" note.

---

## Phase 5+: Implementation, lessons, post-impl audit, fix loop

### Implementation + lesson tracking

Implement per the plan. Log meaningful attempts in `implementations-plan/<plan>/lessons/phase-N.md`. At each phase-gate pass, refresh the workspace manifest: `agent-worktree status <slug> "phase N green: <next>"` (see Phase 0.75 status discipline).

**Failure-retry policy** (explicit, not parenthetical):
- **Human-driven implementation**: after **3 failures** on the same step, stop and reassess. The human is in the loop and can re-scope quickly.
- **`/loop` autonomous mode**: after **5 failures** on the same step, stop and reassess. The autonomous loop has higher tolerance because it operates without immediate human escalation; the extra two attempts let it try alternate framings before stopping.

Why the difference: humans escalate fast, agents need a wider window to self-correct before the loop should yield. Both are hard stops, not advisory.

### Pre-codex code-review pass

Before the codex post-impl audit, run `/code-review max --fix` on the implementation diff. This catches correctness bugs AND quality cleanups (simplification, reuse, efficiency) via the Anthropic model family, applies fixes to the working tree.

After `/code-review` finishes:
1. Skim the applied fixes for sanity (look for unintended changes).
2. **Commit them separately from implementation commits** (so they're identifiable as code-review-applied vs implementation work).
3. Proceed to the codex post-impl audit.

Always run at `max` effort regardless of tier. The implementation work is already done; the marginal cost of a thorough code review is small relative to catching issues before codex.

### Post-implementation codex review

After `/code-review max --fix` has been applied and committed in separate commits, send codex (`/codex xhigh`) the following package:

1. **The net diff from the plan baseline** (everything that changed during implementation, before code-review cleanups).
2. **A separate summary of code-review-applied commits** listing what `/code-review` changed and why. This lets codex audit BOTH the original implementation AND the cleanup as distinct artifacts.
3. The original plan.md + decision ledger for reference.
4. Explicit adversarial / security ask.

This preserves provenance: codex can see what was originally implemented vs what was tweaked by `/code-review`, and can audit structural changes from `/code-review` as first-class changes rather than as a silently-cleaned final state.

### Evaluate + fix loop

Triage codex's review feedback. Implement real fixes. Close the loop. Maintain `implementations-plan/index.md` with the completed marker.

---

## Frontend addendum

When the plan touches UI, **copywriting is part of the design surface**. Clear, simple, no jargon, no clutter. Bad copy makes a good product feel rough. Treat copy review with the same rigor as code review.

---

## Outputs always land here

```
implementations-plan/<plan-name>/
├── plan.md           # The plan: Architecture & Implementation + Security & Adversarial + Assumptions sections, per-phase validation gates, audit verdicts inline (mid/deep/mega-deep), decision ledger (mid+), Seeds section at bottom
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
