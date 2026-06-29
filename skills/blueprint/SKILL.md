---
name: blueprint
description: Plan-creation protocol with FOUR tiers (lowest to highest ceremony) — `/blueprint light` (bounded feature, single codex audit) | `/blueprint mid` (contained feature, codex + fable dual audit; DEFAULT if unsure) | `/blueprint deep` (architectural / cross-cutting, three parallel plans main+codex+fable + double audit + contradiction-check) | `/blueprint mega-deep` (novel surface, planning agents spawn research subagents to map modules before drafting, plus split Round 2 audit). Every tier asks clarifying questions, requires a validation gate on every implementation phase (real project commands + pass criteria), and produces an ELI5 HTML deliverable embedding `/goal` + `/loop` seed strings. Trigger phrases: "ultraplan", "ultrathink plan", "deep plan", "give me a plan", "blueprint this", "plan this carefully", "plan properly", "use the plan protocol", "full ceremony". Auto-fire (invoke without being asked) when the work involves cross-package BEHAVIORAL changes, infra / IaC with rollout or privilege impact, schema or protocol changes, UI-flow redesign, external-system integration, auth or permissions changes, billing logic, data migrations or backfills, concurrency or cache invalidation, or public API changes.
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

## Phase 0.5: Tier recommendation (ALL tiers)

Once the user has answered the clarifying questions, the main agent recommends a tier based on the answers and current task understanding.

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

Once the tier is set, proceed to the per-tier protocol below.

---

## Per-tier protocols

### `/blueprint light`

1. Clarifying questions.
2. Draft `plan.md` (single agent).
3. Send the plan to codex (`/codex xhigh`) for a critical pass with explicit adversarial / security ask + assumption-attack ask.
4. Address findings inline; document adopted vs rejected.
5. Generate `eli5.html` (see below) with DRAFT `/goal` + `/loop` embedded.
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
6. Generate `eli5.html` with DRAFT `/goal` + `/loop` embedded.
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
7. Generate `eli5.html` with DRAFT `/goal` + `/loop` embedded.
8. Approval gate.
9. **Post-approval seeds**: finalize `/goal` + `/loop` against the approved scope; deliver paste-ready in chat (see seeds section).
10. Implement + lesson tracking + pre-codex `/code-review max --fix` + post-impl codex audit + fix loop.

### `/blueprint mega-deep`

Same shape as `/blueprint deep`, but with an upfront research phase AND a split Round 2 audit. Use only when novelty of the surface area means the planning agents would otherwise be guessing at module shapes, AND the implementation cost (days+) justifies the heaviest ceremony.

1. Clarifying questions.
2. **Research phase** (mandatory persisted artifacts): each of the three planning agents (main + codex + fable) first spawns research subagents to map modules they expect to touch. Each agent decides what to explore based on the task + clarifying answers.
   - Main: spawn read-only research subagents specialized for codebase exploration (today via `subagent_type: 'Explore'`) for each relevant module / surface.
   - Codex: invoked with explicit instruction to research relevant files via its read-only sandbox before drafting.
   - Fable subagent: instructed to spawn its own research subagents before drafting.
   - **Each research subagent persists its findings to `implementations-plan/<plan>/research/<module>.md` as a mandatory artifact** (NOT just a verbal summary into the planner). Includes: module purpose, public surface, key invariants, current pain points, relevant tests.
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
11. Generate `eli5.html` with DRAFT `/goal` + `/loop` embedded.
12. Approval gate.
13. **Post-approval seeds**: finalize `/goal` + `/loop` against the approved scope; deliver paste-ready in chat (see seeds section).
14. Implement + lesson tracking + pre-codex `/code-review max --fix` + post-impl codex audit + fix loop.

**Cost note**: subagent fan-out is expensive; mega-deep persists multiple research artifacts AND runs a split Round 2 with a fresh subagent. Reserve `mega-deep` for first-of-its-kind work where the implementation cost (days+) dwarfs the audit overhead. Most non-trivial tasks land at `mid` or `deep`.

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

## Required: ELI5 HTML companion (ALL tiers)

**Hard prerequisite for the approval gate.** Generate `implementations-plan/<plan>/eli5.html`: standalone HTML, no external deps, no build, opens in a browser (mobile or desktop).

Contents:

- **Title + one-paragraph summary** in plain language
- **Why this tier was chosen** (Phase 0.5 rubric outcome, with the rubric scores)
- **Phases**: ELI5 of each (what + why, no jargon) + its validation gate in one plain-language line ("proves itself by: unit tests for the new parser + lint")
- **Human context**: simplified background needed to understand decisions
- **Open questions**: with their human-context framing
- **Approval decision needed from you**: explicit list of what the user must approve (scope, tier, deliverables, /harden scheduling decision if relevant)
- **Implementation seeds**: `/goal` and `/loop` shown as code blocks (DRAFT until the approval gate; finalized post-approval), with ONE marked as "Recommended for this plan" based on whether completion is transcript-observable; explicit warning "Use exactly one per session — they don't compose"
- **Footer links**: relative links to `plan.md` and `./lessons/`

UI/UX: simple, clean, uncluttered. Plain typography, generous whitespace, no flashy CSS. Mobile-readable (viewport meta tag).

### ELI5 HTML scaffold

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

These live IN `eli5.html` as copy-paste code blocks (DRAFT until the approval gate), and also at the bottom of `plan.md` under a "Seeds" section for terminal grep-ability.

**Seeds are finalized AFTER the approval gate.** Approval can change scope — conditions attached, phases dropped, constraints added — and that invalidates pre-approval seeds. The drafts exist so the user can evaluate the plan; the post-approval versions are canonical. After approval, deliver the final seeds in chat as paste-ready blocks and sync `eli5.html` + plan.md to match.

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
[✓] 1. <Tier-specific drafting step>
[▶] 2. <Tier-specific audit step>
[ ] 3. <Tier-specific final-pass step>
[ ] 4. ELI5 generation
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

1. `plan.md` (with Security & Adversarial Considerations section, Assumptions section, AND a validation gate on every implementation phase)
2. Codex's final verdict in **explicit format**: `approve` | `conditional approve (with conditions: ...)` | `reject (with blocking findings: ...)`. Freeform / vague verdicts do NOT count as approval.
3. `eli5.html` (embedding the `/goal` + `/loop` seed strings, with one marked Recommended)
4. For `/blueprint mid`, `/blueprint deep`, `/blueprint mega-deep`: fable audit verdicts inline in `plan.md`
5. For `/blueprint mid`+, the **decision ledger** (rejected alternatives + unresolved disagreements) is part of `plan.md`

**Block conditions** (gate refuses to ask for approval if any are true):

- **Unresolved Asks** in the Assumptions section (silent assumptions are blockers; either resolve with user input or convert to explicit ask in approval).
- **Unaddressed high-severity audit findings** (codex or fable flagged High/Critical; not adopted, not explicitly rejected with reason).
- **Missing adopted-vs-rejected logs** from any audit cycle.
- **Any implementation phase missing a concrete validation gate** (commands + pass criteria from the project's real tooling).

**ELI5 visibility (mandatory when asking for approval)**: the user must never have to hunt for the plan. When presenting the gate, output BOTH of these on their own standalone lines (terminals linkify them differently — one of the two will be clickable), then open it:

```
<absolute path to eli5.html>
file://<absolute path to eli5.html>
```

On macOS, also run `open <absolute path to eli5.html>` so the browser pops without hunting. (Absolute paths are fine in CHAT — the no-absolute-paths rule applies to committed files only.)

Present everything together. User approves explicitly using one of the three verdict formats.

**Immediately after approval** (especially conditional approvals): finalize the `/goal` + `/loop` seeds against the approved scope — fold in conditions, dropped phases, new constraints — deliver them in chat as paste-ready blocks, and sync `eli5.html` + plan.md's Seeds section. Pre-gate seeds are drafts; post-approval seeds are canonical.

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

Implement per the plan. Log meaningful attempts in `implementations-plan/<plan>/lessons/phase-N.md`.

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
├── plan.md           # The plan, with Security & Adversarial + Assumptions sections, per-phase validation gates, audit verdicts inline (mid/deep/mega-deep), decision ledger (mid+), Seeds section at bottom
├── audit-codex.md    # Codex audit transcript(s)
├── audit-fable.md    # Fable audit transcript (mid/deep/mega-deep only)
├── eli5.html         # ELI5 with /goal + /loop embedded, one marked Recommended
├── research/         # Persisted research subagent findings (mega-deep only)
│   └── <module>.md
└── lessons/
    └── phase-N.md    # Per-phase debugging logs (filled during implementation)
```

Update `implementations-plan/index.md` with `- [<plan-name>](<plan-name>/plan.md) — <status> — <one-line hook>` when the plan is created and again when it closes.
