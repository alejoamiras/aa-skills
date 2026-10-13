---
name: blueprint
description: Plan-creation protocol for non-trivial work, in FOUR tiers (lowest to highest ceremony) — `/blueprint light` (bounded feature, one foreign-reviewer audit) | `/blueprint mid` (contained feature, codex + fable dual audit; DEFAULT if unsure) | `/blueprint deep` (architectural / cross-cutting: three parallel plans, contradiction-check, double audit) | `/blueprint mega-deep` (novel surface: research subagents map the modules before drafting). Every tier asks clarifying questions, runs a cheap reuse recon, homes into a task-named git worktree, writes a plan.md with a validation gate per phase and a self-contained post-implementation protocol (codex fix loop, stacked PRs via `gh stack`, close-out, worktree teardown), and produces an ELI5 Artifact with `/goal` + `/loop` seeds. Runs from Claude Code or Codex. Trigger phrases: "ultraplan", "ultrathink plan", "deep plan", "give me a plan", "blueprint this", "plan this carefully", "plan properly", "use the plan protocol", "full ceremony". Auto-fire (invoke without being asked) when the work involves cross-package BEHAVIORAL changes, infra / IaC with rollout or privilege impact, schema or protocol changes, UI-flow redesign, external-system integration, auth or permissions changes, billing logic, data migrations or backfills, concurrency or cache invalidation, or public API changes.
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
| Foreign-reviewer effort (every `/codex` — or `/claude` — call in this skill) | **`high`** (the Phase 0 `codex_model` via `/codex`; the Phase 0 `claude_model` via `/claude`) | User asks for `xhigh`/`max` for the run — `xhigh` roughly doubles wall-clock per round on Astra for marginal review gain |
| Parallel lanes | **Off**; the plan only assesses them | The owner approves the plan's lanes at the approval gate; at most 3 |
| Codex fix-loop rounds | Until clean, hard stop at 3 | Never — 3 rounds is a scope smell, surface instead |
| Recon cross-model check | Off | User asks; then ONE codex pass at `gpt-5.6-terra` (cheap tier) re-testing the absence claims |
| Explainer (`explainer` skill) | **Off** — when on: one background worker, a foreign-reviewer script loop (≤ 3 rounds at `high` on the Phase 0 model), one TTS request (≤ 6,000 characters, cached) | The owner says yes to the Phase 0 question in their own message; never on a subagent's or loop's run |

**Announce the budget shape** with the tier recommendation (0.5): "recon: 2 agents; code-review: off (per your Phase 0 answer)" — so the user can dial it before spend happens, not after. If the user gives a budget instruction ("keep it cheap", "go wide"), it overrides these defaults for the whole run; record it in `plan.md` next to `eli5_mode`.

**Model note — the two review legs (current 2026-10-02).** Both legs' models are the user's call at Phase 0, recorded in plan.md's front matter:

- **Claude leg** (`claude_model`), the "fable" role: the top-tier Claude planner and auditor beside Codex in every tier. **Opus 5.5** (`Agent` tool: `model: 'opus'`; the default) or, on an explicit opt-in, **Fable 5.1** (`model: 'fable'`), which is slower and more expensive. If Fable is unavailable mid-run, fall back to Opus 5.5 and log it in lessons. "fable" names the *role*, not a hard model requirement, so `audit-fable.md` and the "codex + fable" terminology stay as-is whichever model fills it.
- **Codex leg** (`codex_model`): **GPT-6.1 Sol** (`gpt-6.1-sol`; the default — near-Astra quality, much faster and cheaper, which compounds over a plan's many review rounds) or, on an explicit opt-in, **GPT-6 Astra** (`gpt-6-astra`), the strongest reviewer, slower and more expensive. Pass the slug as the fifth argument of every `run-codex.sh` call: the script's own default is Astra, so an omitted argument silently ignores the answer. A `resume-codex.sh` against the same codex-dir stays on the session's model by itself. Sol needs **Codex CLI ≥ 0.159.1**; an older CLI is refused by `run-codex.sh` (called directly, it gets a 400 that reads like an entitlement problem) — run on Astra instead and log it in lessons.
- **Effort**: either model runs at **`high`**, not `xhigh`, which adds minutes per round for marginal gain on plan and diff review. Every `/codex high` in this skill (plan audits, the post-implementation fix loop, the cross-arc pass) means the `codex_model` at `high` unless the user asks for `xhigh`/`max` for the run.
- Recon explorers use the `sonnet` alias, which always resolves to the newest Sonnet, so they need no pin.
- **On a Codex driver the legs swap mechanics, not names**: the foreign reviewer is Claude — `/claude high` on the `claude_model` — and the same-family leg is a Codex subagent on the `codex_model`; see Harness capabilities.

**Subagent preamble.** Every prompt this skill hands to a subagent, a reviewer or a worker starts with the line `You are a subagent. Don't run memo.` The codex, claude and kimi spawn scripts prepend it themselves; an `Agent` tool prompt carries it by hand. Only the driving session reads and writes the shared memory.

---

## Harness capabilities (driver-agnostic protocol)

This skill is one `SKILL.md` installed for both **Claude Code** and **Codex**. The protocol is written in terms of two roles, and the tool names in the phases below are the Claude Code spelling of each capability:

- **Driver** — the harness running this session.
- **Foreign reviewer** — the other model family, reached through its CLI via the sibling skill: `/codex` when Claude Code drives, `/claude` when Codex drives. Every `/codex high` in this skill means "the foreign reviewer at `high`"; a review by the driver's own family does not satisfy it.
- **Same-family leg** — the top-tier reviewer/planner from the driver's own family, run as a native subagent (`mid` and above).

**On a Codex driver, read `references/harness.md` before Phase 0** and substitute per its table rather than skipping a step. It maps each capability to its Codex form: the foreign reviewer and the case where it is blocked, the same-family leg, recon explorers, worktree homing and teardown, clarifying questions, the task list, the ELI5, the opt-in diff review, the seeds, and deep-tier research.

**Artifact names are by family, not role**: `audit-codex.md` holds the OpenAI-family review and `audit-fable.md` the Anthropic-family review whichever harness drives, so a plan's audit trail reads the same from either side.

**Record the driver in `plan.md`** front matter (`driver: claude-code | codex`, next to `eli5_mode`, `code_review`, `claude_model`, `codex_model` and `explainer`), and generate the Post-implementation section, the Delivery section and the seeds with the **concrete** skill names and model slugs for that driver (`/codex` or `/claude`, the reviewer's model as its script argument, `/code-review` or `codex review`, `/goal` with or without `/loop`). A fresh implementing session reads plan.md, not this table; it must not have to re-derive the mapping.

---

## Phase 0: Clarifying questions (ALL tiers)

**The plan is the most important step. Don't draft against a fuzzy target.** Before any drafting, ask the user:

- **Success criterion**: what does "done" look like? Measurable signals?
- **Who it is for, and what excellent looks like to them**: the user or consumer of the change (end user on a phone, a dApp integrating the SDK, an operator reading logs, a future maintainer) and the two to four qualities they would notice in a top implementation versus a merely working one. Feeds the Outcome & Quality Bar section.
- **Scope trade-offs**: what's in, what's out, where can scope be cut?
- **Constraints**: time, infra, external deps, capacity
- **Quality bar**: PoC, staging, or production? Calibrates testing rigor and audit depth.
- **Validation layers**: which validation layers should gate each phase? **Inspect the repo FIRST** (package scripts, CI workflows, Makefile, test dirs) so the options offered are REAL, then ask via `AskUserQuestion` with what actually exists: typecheck/lint, unit, integration, e2e, e2e against live networks (sandbox / anvil / testnet). Flag any requested layer the project doesn't have yet — building it becomes a plan phase of its own.
- **Decisions to surface vs delegate**: which trade-offs come back to the user, which the agent resolves
- **`/code-review` in the post-implementation loop — ASK, default OFF**: the codex fix loop reviews every diff already; `/code-review` on top of it is the single biggest token sink in the protocol. Ask explicitly (via `AskUserQuestion`): "Run `/code-review` before the codex fix loop? Default: no. If yes: `low` (small/contained diff) or `medium` (typical feature arc)." Never assume yes; never pick `high`/`max` unless the user names it. Record the answer in plan.md's front matter as `code_review: off | low | medium | high | max` — the Post-implementation section, the Delivery section (per arc) and the `/goal` + `/loop` seeds are all generated from that one value.
- **The Claude leg's model — ASK (`mid` and above; every tier on a Codex driver)**: the "fable" role, or the `/claude` foreign reviewer when Codex drives. Ask via `AskUserQuestion` with Opus 5.5 first as the recommended default and Fable 5.1 as the opt-in for plans where the strongest reviewer is worth it; say it is slower and more expensive. Record `claude_model: opus | fable` in plan.md's front matter: every fable-leg spawn, `/claude` call and seed in the run uses it. `light` on Claude Code has no Claude leg, so skip it there.
- **The Codex leg's model — ASK (every tier on Claude Code; `mid` and above on a Codex driver)**: the `/codex` foreign reviewer when Claude Code drives, the same-family subagent when Codex does. Ask via `AskUserQuestion` with GPT-6.1 Sol first as the recommended default and GPT-6 Astra as the opt-in; say it is slower and more expensive. `light` on a Codex driver has no Codex leg (its one audit is Claude's), so skip it there; the answer never changes the model the driver itself runs on. Record `codex_model: sol | astra` in plan.md's front matter: every `/codex` call, Codex subagent and seed in the run uses it (`gpt-6.1-sol` / `gpt-6-astra`). With no user to ask, use Sol, or Astra when the Codex CLI is below Sol's floor (Model note); either way, record which model ran and why.
- **Narrated explainer — ASK only when the owner started this run with their own message** (never in a subagent, never from a `/goal` or `/loop` brief; there it is `off` without asking): "Make a narrated explainer for this plan? It is a 2–5 minute animated section inside the ELI5. The foreign reviewer polishes the script from the plan and ELI5, the narration text goes to ElevenLabs, you pick a look from four previews on a private page, and the page and audio are published with the ELI5." Options: `narrated` (offer only when the `explainer` skill's preflight passes), `captions` (animated, no voice; the script review and style board still apply), `off`. Record `explainer: off | narrated | captions` in plan.md's front matter. The front matter records the answer; only the owner's answer authorizes the job (see the `explainer` skill's Authorization).
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
- **Open work**: the parent reads the tracker before drafting: `gh issue list --state open --limit 200`, narrowed with `--label <domain>`, `--label owner-decision`, `--label blocked:external` or `--search "<words>"`. An open issue the plan resolves joins its scope, and the PR that resolves it says `Closes #N`; one the plan collides with is named in `recon.md`. Draft security advisories are not in that list: read them under the repository's Security tab if you have access, and keep their findings out of `recon.md`, which is committed.
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
   - Otherwise call `EnterWorktree` with `name: <slug>`. This skill instruction is the standing authorization the tool requires. The native default base (`fresh`, from origin's default branch) is correct — plans start from a clean tree; set `worktree.baseRef: "head"` in settings only when the plan must build on unpushed local work. On a Codex driver: `agent-worktree new <slug> --no-start` creates the identical worktree + manifest row; work from the path it prints (there is no session-level cwd switch — every subsequent command runs there).
3. **Set up + register**: run `bun install` if a `package.json` exists, then `agent-worktree register <slug> --status "phase 0.75: homed, drafting"` (derives path/branch/repo from cwd; plan defaults to `implementations-plan/<slug>`). If `agent-worktree` is not on PATH, note it and continue — homing works without the manifest.
3b. **Ensure the plan-folder hygiene files carry the required rules.** Do not test for the files' existence and skip — a pre-existing `.gitignore` missing these lines is exactly the case that silently stays wrong. Append what is absent, never overwrite what is there, and never append a line twice:
   - `implementations-plan/.gitignore` → `audit-*.md`, `plan-*.md`, `_*.md`, `eli5.html`, `narration.mp3`, `narration.mp4`, then `!**/lessons/**` so a scratch pattern can never swallow a debugging log. Unanchored on purpose: nested sub-plans (`<plan>/<sub-plan>/`) and `research/` drafts must be caught too. `plan-*.md` does NOT match `plan.md`.
   - `implementations-plan/.ignore` → `/archive/`, with the leading slash so it anchors to that one directory rather than every descendant named `archive`.
   - `implementations-plan/` also needs `index.md`, `lessons.md` and `archive/index.md` to exist, plus in the repo's `.gitattributes`:
     ```gitattributes
     implementations-plan/** linguist-generated=true
     implementations-plan/lessons.md -linguist-generated
     ```
     The blanket rule collapses plan diffs in GitHub review; the exemption keeps the curated layer reviewable, which is the part that most needs a human eye.
   - **Open work gets no file here.** It lives in GitHub issues and private draft security advisories (see Where open work lives). The one fallback is a repository with issues disabled (`gh repo view --json hasIssuesEnabled -q .hasIssuesEnabled` prints `false`): there, keep `implementations-plan/follow-ups.md` with its own `-linguist-generated` exemption, and read every "issue" in this skill as an entry in it. On a repository with issues, an existing `follow-ups.md` is a migration: the plan's close-out opens an issue for each live entry (dedupe first) and `git rm`s the file.
   - **On an existing repo this is a migration, not scaffolding.** `.gitignore` does not untrack anything already committed, so inventory what is now ignored-but-tracked with `git ls-files -ci --exclude-standard -- implementations-plan`, review the list, `git rm --cached` the intended artifact classes, and re-run until it comes back empty. Skipping this leaves a half-state where searches look clean while every future commit still publishes transcripts.
4. **Status discipline**: keep the manifest's one-line status current at every gate — after approval (`agent-worktree status <slug> "approved: implementing phase 1"`), at each phase-gate pass (`"phase N green: <next>"`), and at wrap-up (`"delivered: PR #N, awaiting merge"`). That line is what `agent-worktree list` shows a human scanning "what was this one doing?" — it is the discovery layer, not decoration.
5. **Teardown ends the run**: once the close-out is on trunk, run `agent-worktree done <slug> --merged` without asking — see After the merge: teardown. An **abandoned** plan is the opposite case: nothing proves its work is safe to drop, so suggest `agent-worktree done <slug> --force` and leave the call to the user.

---

## Per-tier protocols

**Every tier runs the same preamble and the same tail; only the drafting and audit steps between them differ.** The preamble is Phase 0 (clarify) → 0.4 (recon) → 0.5 (tier) → 0.75 (homing). The tail:

1. Generate the ELI5 companion (Artifact primary; `eli5.html` fallback) with DRAFT `/goal` + `/loop` embedded.
2. Approval gate.
3. **Post-approval seeds**: finalize `/goal` + `/loop` against the approved scope; deliver them paste-ready in chat (see seeds section).
4. Implement + lesson tracking, then the post-implementation protocol embedded in plan.md: iterative codex fix loop (per arc on stacked plans, plus a final cross-arc pass; preceded by `/code-review <level> --fix` ONLY if the user opted in at Phase 0) → arc-stacked PR delivery, closed by the plan's close-out (the PR's final commits, or the stack's top layer) → teardown of the worktree and its branches once that merges.

Every audit step sends the full Standard audit packet. Tool names are the Claude Code spelling — on a Codex driver, `/codex` reads as `/claude` and the fable `Agent` leg as a Codex subagent, per Harness capabilities.

### `/blueprint light`

1. Draft `plan.md` (single agent).
2. Send the plan to codex (`/codex high`) for a critical pass with explicit adversarial / security ask + assumption-attack ask.
3. Address findings inline; document adopted vs rejected.
4. The shared tail.

**Light floor** (epistemic minimum for the lightest tier): at least 5 verified Facts in the Assumptions section AND no silent Asks in any implementation phase. Every implementation phase must list its assumptions explicitly. If you can't meet this floor, the task is too underspecified for `/blueprint light` — escalate to `mid`.

### `/blueprint mid`

1. Draft `plan.md` (main agent). **Then generate one competing outline as an alternative approach** (main agent, different angle: cheapest-first vs safest-first, monolithic vs split, etc.). This forces actual plan-space search, not just one author + reviews. Both go into the audit.
2. **Dual audit in parallel**:
   - Codex via `/codex high` with explicit adversarial / security / assumption-attack asks. Codex sees BOTH outlines.
   - Fable subagent via the `Agent` tool, configured as a top-tier Claude subagent specialized for architectural planning (`subagent_type: 'Plan'`, `model:` the Phase 0 `claude_model` — `'opus'` for Opus 5.5 or `'fable'` for Fable 5.1). Same asks. Sees both outlines.
3. Iterate on feedback; produce a **decision ledger**: which outline was chosen, what alternatives were rejected and why, what's still disputed.
4. **Final fresh-context codex pass**: open a NEW codex session (not a resume). Provide the **consolidated plan, the decision ledger (rejected alternatives + unresolved disagreements)**, and the adversarial + assumption-attack asks. Fresh codex now has the full decision trail and can genuinely re-evaluate, not just review the surface again.
5. The shared tail.

### `/blueprint deep` and `/blueprint mega-deep`

`deep` drafts three independent plans in parallel (main, codex, fable), consolidates them into a decision ledger, sends the ledger back to both reviewers for a contradiction-check, runs a double audit, then a final fresh-context codex pass. `mega-deep` adds a persisted research phase before drafting and splits its second audit round into a resumed self-critique and a fresh hostile audit. **On either tier, read `references/deep-tiers.md` before drafting**: it holds their numbered steps, which this summary does not replace.

---

## Required: Outcome & Quality Bar section (ALL tiers)

Every plan must include an "Outcome & Quality Bar" section, placed before Architecture & Implementation. It states who the change is for and what an excellent result looks like **to them**, in terms the implementing session can act on. This is the answer to "why does the quality of this matter", and it is what makes a top-quality implementation different from a working one.

- **For whom**: the concrete user or consumer, and the situation they are in when they meet the change.
- **What excellent looks like**: two to four criteria, each observable in the delivered work (behaviour, copy, latency, failure handling, API ergonomics, readability of the code a maintainer inherits). "Every async step shows pending, failed and recovered states, and error copy says what to do next" is a criterion; "polished UX" is not.
- **What good enough looks like**: where the bar deliberately stops, so quality effort goes where it is felt and not everywhere.

No motivational or emotional language ("deliver something to be proud of", "think how satisfied users will be"): evidence that such framing improves model output is weak on current models, and it gives the implementer nothing to check. Concrete criteria do both jobs. Validation gates should reference these criteria where a command or test can prove one, and audit prompts may cite them when judging whether the plan serves its user. The section goes in the ELI5 companion too, in plain language: it is the human decision layer's view of the same thing.

For `light` plans two criteria suffice.

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

---

## Required: Assumptions section (ALL tiers)

Every plan must include an "Assumptions" section. **This is NOT a generic risk register** (those belong in Security & Adversarial). This section addresses epistemic surface only: what is this plan resting on, and how confident are we?

Separate into three buckets:

- **Facts** (verified against the codebase, docs, or user): cite file paths, line numbers, or sources
- **Inferences** (deduced but unverified, may be wrong): label clearly so audits can attack them surgically
- **Asks** (decisions the user must make): surface to the user, do not silently assume

This complements the Security & Adversarial Considerations section: that one looks at threat surface; this one looks at epistemic surface (what we're trusting that we shouldn't).

---

## Standard audit packet (ALL tiers, EVERY audit invocation)

Every audit prompt (codex + fable, every tier) sends ONE packet: the plan, the recon reuse map as context, and all four asks below. Where a per-tier step abbreviates them (e.g. "adversarial / assumption-attack asks"), that shorthand still means the FULL packet — never silently drop the implementation critique or the recon check.

1. **Adversarial / security** (the Security & Adversarial section): *"What could go wrong? What would an attacker target? What are we trusting that we shouldn't? Where are the supply-chain / crypto / least-privilege weaknesses?"*
2. **Assumption-attack**, in addition to the first (the Assumptions section): *"Attack the Assumptions section. Which Facts are misstated? Which Inferences are unsafe? Which Asks need surfacing instead of being silently assumed? Return findings under Facts / Inferences / Asks buckets, matching the section being attacked."*
3. **Implementation critique** (the Architecture & Implementation section): *"Critique the Architecture & Implementation. Is this the right structure, or is there a simpler / more idiomatic pattern? Wrong abstraction or boundary? Do the interfaces leak? Does any of it duplicate or ignore what `recon.md` found reusable? What would you build differently, and why?"*
4. **Proportion** (Required: Proportion): *"For every finding, write its path (initial conditions, actions or events, order, the invariant broken, the consequence) with a trace or reproducer, label it demonstrated / plausible but unverified / needs unsupported conditions, and give the smallest fix. If the fix adds persistent state, a lifecycle, a coordination protocol, a recovery policy or a public contract, say what obligations it creates and whether a known limit is the better answer."*

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
- Phase steps and pass criteria follow the Plain-language standard below: they are procedures, and the implementing session must not be able to read a step two ways.

---

## Required: Plain-language standard (ALL tiers)

Write human-facing prose **80% of the way to ASD-STE100** (Simplified Technical English, the controlled language of aerospace maintenance manuals). Name the spec and aim at it. Models know it well, and the name sets the tone better than a paraphrase. The rules below are the checkable floor. Break a rule only when the compliant version would lose meaning or change an exact name. First, try to split the sentence.

**Applies to**:
- the ELI5 companion's prose
- `plan.md` phase steps, Validation gate pass criteria, and Asks
- harden's stakeholder report, except its technical trace

**Exempt**:
- Architecture & Implementation, trade-offs, and the reasoning in Assumptions. They need nuance and long "because" chains.
- Code comments. The value-per-character rule governs them.
- Seeds, commands, paths and identifiers.

**Rules**:
- **Length**: a procedural sentence has at most 20 words. A descriptive sentence has at most 25. A paragraph has at most 6 sentences and one topic.
- **One instruction per sentence**, in the imperative: "Add the check", not "The check should be added".
- **Active voice, actor named**: "the worker rejects the request", not "the request is rejected".
- **Noun stacks of at most 3 words**: "the policy for rotating the wallet's session keys", not "wallet session key rotation policy". An exact project name is exempt.
- **Warnings come before the step** they apply to.
- **Dictionary discipline**: use STE's approved general words in their approved sense and part of speech, where they say the meaning exactly. Prefer the plainest word: "use", not "utilize"; "start", not "initiate". Project terms are allowed, as STE allows technical names and technical verbs. When only an unapproved word is exact, use it.
- **One name per thing**: each word keeps one meaning for the whole document, and each thing keeps one name. Once "worker" means the Cloudflare Worker, it never means a background job. That job is then never also a "task".
- **Define unfamiliar terms** where they first appear. In the ELI5, when more than two project terms appear, also list them in a terms box.

Reread every in-scope sentence against these rules before you publish the ELI5 or send `plan.md` to an audit. Apply the same check when you edit this section.

---

## Required: Proportion (ALL tiers)

Review pressure grows software the wrong way: a reviewer finds a race, the fix adds a mechanism, the mechanism has a residual, the residual becomes an open issue. These rules cap that loop. They bind the planning audits, the post-implementation fix loop and the close-out.

- **A finding is a change only once its path is written.** For every finding the planner records the initial conditions, the actions or events, the execution order, the invariant it breaks and the consequence, backed by a reproducer or a concrete code trace, and labels it **demonstrated**, **plausible but unverified**, or **needs conditions the system does not support**. A path alone does not justify work: the consequence must matter (lost data or funds, a wrong screen, a stuck flow, a boundary crossed). A security finding names the attacker's capability and the boundary crossed; never write "not exploitable", only "exploitability unknown" or the traced path, and a suspected serious weakness goes to a private advisory. A reviewer's "could" with no trace is plausible-but-unverified: fixed when the fix is local (a bug fix with its test), otherwise a known limit. A finding that needs unsupported conditions, or whose consequence does not matter, is a known limit.
- **Known limits are closed issues, never lost lines.** A known limit is filed as an issue labelled `known-limit` and closed as not planned in the same breath. Its body states the failure hypothesis, the consequence, the missing prerequisite or the unverified step, the disposition, and the precise reopening condition (a user report, new code evidence, a changed assumption). The plan's Outcome lists it as `Known limits: #N`. Before planning an area, search its closed limits (`gh issue list --state closed --label known-limit --search "<words>"`). These records count in no throughput figure. This is the one exception to "every issue has a demonstrated path".
- **A fix-loop round does not grow the design.** A round fixes bugs, adds tests and makes local changes inside the approved behaviour (a missing cleanup, a promise that awaits what already runs, a helper that removes a copy). A fix that introduces or materially expands persistent state, an independent lifecycle (a background task, a timer, a watcher), a coordination protocol (a lock, a queue, a handshake, a registration), a recovery policy (a retry, a reconciliation, a fallback) or a public contract or configuration is a plan change: write what it adds, the obligations it creates, what can now go wrong and the simpler alternative (a known limit included), then stop for the user's approval. The user may predelegate bounded, reversible changes to the panel in writing; persistence, permissions, public contracts, background work and scope expansion stay the user's. Judge the resulting complexity, removals included: making an existing state machine materially more complex counts the same as adding one. In the planning audits the same holds: such a finding is accepted only with its path written and the known-limit alternative rejected in writing.
- **Later rounds verify; they do not reopen.** A resumed review verifies the accepted fixes and looks for regressions; reopening a settled disposition needs new evidence; a newly found material defect is still reported.
- **Plans have a size target**: `light` 150 lines, `mid` 350, `deep` 600, `mega-deep` 900, every line counted, audit tables included. Over target means cutting duplication and restatement, never packing paragraphs or dropping evidence; a plan still over after that says so in one line with the reason. Where the repository's `implementations-plan/README.md` carries a Post-implementation standard, the execution contract is the plan plus that standard read at the revision the plan names: the plan keeps inline only what is specific to it (commands, parameters, loop placement, slug, trunk, deviations, approval boundaries). Citing this skill never counts: the implementing session may never load it.
- **E2E has a runtime budget, not a file quota.** Each added e2e scenario names the distinct failure mode it proves, why a cheaper layer (unit, component, composition) cannot establish it, and its estimated then measured runtime; the PR body states the per-browser suite wall-clock before and after. File count is diagnostic only: merging files to hit a number saves nothing. A timeout stays visible in the numbers.
- **Enhancements are not work until the user says so.** An `enhancement` issue enters a plan only on a recorded product decision, and a plan is not started while a product decision it depends on is open.

---

## Required: Post-implementation section IN plan.md (ALL tiers)

The post-implementation steps are executed by the IMPLEMENTING session — often a fresh `/goal` or `/loop` session that never loaded this skill. plan.md is the only instruction surface it is guaranteed to read. So every plan.md MUST end with a "Post-implementation" section the implementing session can execute without this skill: the steps written out with the run's concrete values, or the shared ones cited from the repository's own `implementations-plan/README.md` § Post-implementation standard at a recorded revision with the plan-specific parts inline (Required: Proportion). "See the blueprint skill" fails the approval gate. This section is the one canonical statement of those steps.

**While implementing** (plan.md says this too):

- Write comments to the comment-quality bar AS you code, not as post-hoc cleanup: value per character, invariants and non-obvious whys only, never references to the plan or its phases (plans are ephemeral; code outlives them) — the codex loop audits this.
- Log meaningful attempts in `implementations-plan/<plan>/lessons/phase-N.md`. At each phase-gate pass, refresh the workspace manifest: `agent-worktree status <slug> "phase N green: <next>"` (see Phase 0.75 status discipline).
- **Failure-retry policy**: a human-driven implementation stops and reassesses after **3 failures** on the same step, since the human can re-scope quickly; a `/loop` autonomous run stops after **5**, since it operates without immediate human escalation and the extra two attempts let it try alternate framings first. Both are hard stops, not advisory.

The steps, in order:

1. **`/code-review <level> --fix` — ONLY if plan.md says `code_review` is not `off`** (the user's Phase 0 answer). `off`, the default, means this step is absent from the plan, not "skipped": never add it to such a plan, never "helpfully" run it, and never ask again mid-implementation. When on: run it on the diff under review (placement below) → skim the applied fixes for unintended changes → commit them separately from implementation commits, so they stay identifiable as code-review work. Level is the one recorded in plan.md, sized to the diff — small/contained → `low`; typical feature arc → `medium`; `high`/`max` ONLY when the user named them. Higher levels fan out many more agents for broader-but-shakier findings, and the codex loop already covers depth — paying twice for it is what burns a budget.
2. **Codex audit** (`/codex high`), sent as one package:
   - the diff under review (placement below);
   - only when step 1 ran: a separate summary of its commits, what changed and why, so codex audits the original implementation and the cleanup as distinct changes rather than a silently cleaned final state;
   - plan.md and the decision ledger; on multi-arc plans, also the arc map ("this is arc N of M; later arcs will build X on it"), so seams reserved for later arcs aren't flagged as dead code;
   - the adversarial / security ask (the final cross-arc pass asks instead for cross-arc issues: seams between arcs, duplication across arcs, drift from the plan);
   - the no-over-engineering and comment-quality rules below, verbatim.
3. **Iterative fix loop**: triage the findings (verify codex's factual claims against the repo first — it can misread code), apply the accepted fixes, commit, log the round (consult + verdict) in lessons/, then RESUME the same codex session with the fix diff and ask it to re-review under the same rules. Repeat until a round yields no new material findings — rejected nitpicks don't count as churn. A round fixes bugs, adds tests and makes local changes inside the approved behaviour; a fix that adds persistent state, an independent lifecycle, a coordination protocol, a recovery policy or a public contract is a plan change: write it into the plan with the obligations it creates and the known-limit alternative, and stop for the user. A resumed round verifies the accepted fixes and reopens a settled disposition only on new evidence (Required: Proportion). Still producing material findings after 3 rounds? Stop and surface to the user: that's a scope smell (the implementation diverged from the plan, or the plan under-specified), not a polish loop.
4. **Delivery** per the plan's Delivery section — the FIRST time any PR is opened (see PR timing). Single-arc: `gh pr create`. Multi-arc: `gh stack sync` first if trunk moved, then `gh stack submit --auto` and `gh pr edit` for each body.
5. **Close-out** per Closing the plan below, written out in plan.md or cited from the repository standard as above, never from this skill: the Outcome block with its `Open items:` line, lessons promotion with its pruning pass, every open item filed as an issue or a private draft advisory (copy the Where open work lives table in), the `git mv` into `archive/` in its own commit with link repair, and the index line moved to `archive/index.md` — as the single PR's final commits, or as the stack's docs-only top layer (`gh stack add <slug>-close-out`, its commits, `gh stack submit --auto`). Then watch checks on every PR (`gh pr checks --watch`). Then report and wait: merging is the user's call, and the merge completes the plan.
6. **Teardown after the merge** per After the merge below, written out in plan.md with the real slug, plan path and trunk. The plan.md text must also say who notices the merge: a `/loop` session checks on every firing; a `/goal` session arms its one background wait right after its wrap-up report, and otherwise runs the step at the start of its next turn.

**Loop placement (the plan.md section spells out the one that applies):**

- **Single-arc plan**: steps 1–3 run once, over the whole implementation diff (the net diff from plan baseline), after the last phase goes green; then steps 4 and 5, and step 6 once the PR merges.
- **Multi-arc plan**: steps 1–3 run **per arc, at each arc boundary** — after the arc's phases go green and BEFORE `gh stack add` opens the next arc — scoped to that arc's diff while the arc is still the stack tip (fixes land on their own branch; no later arc's review or PR ever rests on an unreviewed base). Only a boundary the Delivery section marks `pipelined` lets implementation run ahead (`references/multi-arc.md`). After ALL arcs are green and looped, run one **final cross-arc integration pass**: a FRESH codex session over the net diff from plan baseline with the cross-arc ask — same iterative loop; it should converge in a round or two since every arc was already cleaned. `/code-review` (when opted in) runs per arc only — don't repeat it over the net diff. Then steps 4 and 5, and step 6 once the close-out merges.

**The no-over-engineering rule** (include verbatim in every post-impl codex prompt, initial and resumed): *"Report bugs and small, targeted improvements only. Do not propose speculative abstractions, extra configuration surface, new layers, or rewrites — the smallest change that fixes each real problem. If code works and is clear, leave it alone."*

**The comment-quality rule** (same treatment — verbatim in every post-impl codex prompt): *"Audit the comments for value per character. Flag any comment that narrates what the code visibly does, restates its line, references implementation plans / phases / reviews, or spends a paragraph where a sentence works — and flag places where a non-obvious invariant or constraint deserves a comment it doesn't have. Comments are permanent context every future reader, human or LLM, pays to re-read: they must be few, dense, and exact."*

### Closing the plan

**All five steps ship inside the delivery, so no docs PR trails the plan.** Single-arc: they are the PR's final commits, made after `gh pr create` so the Outcome can cite the PR number. Multi-arc: they are the stack's docs-only top layer, the close-out PR, made after the arc PRs exist for the same reason. **Steps 2 and 3 are how lessons and open work survive; never skip them.**

1. Write an `## Outcome` block in `plan.md`, directly **after** the YAML front matter, never above it. It carries: date, final status (`completed` / `superseded by <plan>` / `abandoned — <reason>`), what shipped with PR numbers, what was dropped, rejected or superseded and why (a disposition line each, never an open item), a `Known limits:` line (the closed `known-limit` issues this plan filed, `#N` each; `none` otherwise), an `Open items:` line, and one explicit line retiring the plan's `/goal` and `/loop` seeds so a later reader cannot mistake them for live instructions.
2. **Promote the generalizable gotchas** into `implementations-plan/lessons.md` — one line each, linking to the archived detail. Promote what would bite a future run on a *different* task: a tool's real behaviour, an ordering requirement, a dead end and why it was dead. Leave run-specific noise behind. **Promotion is also a pruning pass**: that file is read at the start of every task, so it holds a budget of roughly 8 KiB. Deduplicate against what is there, retire whatever your entry supersedes, and date-stamp anything tied to a tool version. A stale workaround in that file is worse than an empty file — it gets injected into every future run. The raw `lessons/phase-N.md` logs travel into the archive intact; promotion never deletes them. Then `memo note` each promoted line with its scope tag, so sessions in other repos learn it too; the file stays the repo-local record.
3. **File every open item in its home**, per Where open work lives below: a GitHub issue, a private draft security advisory, or a step in the repository's launch checklist. The Outcome's `Open items:` line lists their numbers (`#N`, `GHSA-…`) and names the checklist section of a launch step, or reads `none`. A plan never closes while it owns an item that is anything else. The Outcome names numbers, never their status: the tracker holds that.
4. **Archive the folder**, from the repo root: create `implementations-plan/archive/` if absent, `git mv implementations-plan/<plan-name> implementations-plan/archive/<plan-name>`, then repair what the extra directory level broke. Inventory first with `git grep -n '<plan-name>'` and check for `../../` targets that now resolve one level short, links to sibling plans that did not move in the same commit, and any reference from CI, scripts or docs. An `index.md` entry of the form `<plan-name>/plan.md` moves into `archive/index.md` unchanged. Keep this move in its own commit: mixing it with rewrites makes history traversal useless, and `git log --follow` tracks single files, not directories.
5. Move its `index.md` line into `archive/index.md`, marked completed.

**Delivered is not closed until the close-out merges.** The Outcome is written before the merge, so keep it true until then: an arc dropped or reshaped in review means editing the Outcome on the close-out first. Meanwhile a running `/loop` finds the live path gone and, because trunk does not have the archived plan yet, babysits delivery instead of stopping (see its reality check).

`implementations-plan/.ignore` keeps the archive out of **default recursive searches** while it stays fully committed. That is a default, not a guarantee: a lesson link, an explicit path, `git grep`, or a resumed conversation can all still surface a closed plan — which is exactly why step 1's Outcome block exists. Treat anything under `archive/` as evidence of what was decided and why, never as a task list to execute. `implementations-plan/lessons.md` is never archived and never ignored: it is the durable layer.

**Parallel worktrees share `index.md` and `lessons.md`.** Keep edits to them in the close-out wherever possible, so their conflicts stay inside one docs-only change. Reconcile it against trunk immediately before submitting it and again after any `gh stack sync`, keep stable topical sections, and never re-sort or reformat wholesale. A clean line-level merge can still leave two contradictory lessons, or resurrect a lesson another branch just retired, so read what the other side added instead of trusting the merge. Do not configure a union merge driver for these files.

### Where open work lives

Open work lives in GitHub issues. A suspected exploitable weakness lives in a private draft security advisory, never in a public issue. Copy this table into every plan's close-out:

| Situation | Home |
|---|---|
| Work inside the implementation you are on | the active `plan.md` and the PR |
| Actionable work that outlives the plan: a bug, a gap, a missing test, a deferred refactor | a GitHub issue, with a domain label and a `Record` link to the archived plan |
| Needs a product call, or waits on something outside the repo | an issue labelled `owner-decision` or `blocked:external` (the body names the trigger) |
| A suspected exploitable weakness | a private draft security advisory; `plan.md` records only "tracked privately: GHSA-…" until it is published |
| Rejected, superseded or already done | a disposition line in the plan's Outcome block; no open item anywhere |
| A finding whose path needs unsupported conditions, or whose consequence does not matter | an issue labelled `known-limit`, closed as not planned in the same breath (hypothesis, consequence, missing prerequisite, disposition, reopening condition); the Outcome lists it as `Known limits: #N` |
| Knowledge that prevents a repeat | `implementations-plan/lessons.md` (8 KiB budget) |
| A legal or store blank with a release deadline | the repo's launch checklist (`BEFORE-LAUNCH.md` in Nulo) |
| Accepted code work that blocks launch | a milestone, pointed at once from that checklist |

- **Dedupe before opening one**: `gh issue list --state all --search "<words>"`. Extend the issue that already owns the work instead of opening a twin.
- **An issue body has five sections**: `## What happens`, `## Where`, `## Impact`, `## Possible fix`, `## Record`. `## What happens` writes the path (initial conditions, actions, order, the invariant broken, the consequence) and labels it demonstrated or plausible but unverified; a path that needs unsupported conditions is a closed `known-limit` issue.
- **`Closes #N` means integrated, not released.** The PR that resolves an issue says it, and GitHub closes the issue when that PR merges into the default branch. The release that ships it comes later.
- **An advisory is published when its fix ships in a tagged release**, or closed with a written disposition. Until then its finding appears in no committed plan, PR body or test name. The fix may land first: its PR and tests describe the change, not the weakness.
- **Finding open work**: `gh issue list --state open --limit 200`, narrowed by `--label <domain>`, `--label owner-decision`, `--label blocked:external` or `--milestone <name>`. Draft advisories are under the repository's Security tab, for those with advisory access.

### After the merge: teardown

**The run ends with the worktree gone, not with a suggestion to remove it.** The trigger is the close-out on trunk: `git fetch -q origin <trunk> && git cat-file -e FETCH_HEAD:implementations-plan/archive/<plan>/plan.md` (`FETCH_HEAD`, not `origin/<trunk>`: it is what origin has now, whatever refspecs the clone is configured with). A session reaches that check three ways:

- **It performed the merge** on the user's explicit call (`gh pr merge --squash` / `gh stack merge --squash`): teardown follows in the same turn.
- **A running `/loop`** finds it in its reality check.
- **The user comes back to a delivered plan**: every turn after delivery starts with this check. A `/goal` session has no loop to notice the merge, so on Claude Code it arms ONE background wait right after the wrap-up report — `Bash` with `run_in_background` at the maximum timeout: `until git fetch -q origin <trunk> && git cat-file -e FETCH_HEAD:implementations-plan/archive/<plan>/plan.md; do sleep 300; done`. Waiting costs no tokens; a merge inside the window wakes the session into the teardown, and an expired wait is not re-armed.

Then, without asking — this section is the standing authorization:

1. **Leave the worktree.** `ExitWorktree` with `action: "keep"` when this session entered through `EnterWorktree`; never `remove`, which reads a squash-merged branch as unmerged and knows nothing of stack branches. A session that was resumed inside the worktree has nothing to exit: the helper is then its last command, because its working directory disappears with the worktree.
2. **`agent-worktree done <slug> --merged`** (`--trunk <trunk>` when trunk is not origin's default branch). It re-proves the merge itself — the worktree's HEAD fully contained in trunk, squash merges included — then removes the worktree, every local branch of the stack, their landed remote branches and the manifest row.
3. **Report its output**: each deleted branch with its last SHA, and anything it kept with the reason.

It refuses rather than forces: uncommitted or untracked files, a HEAD carrying changes trunk lacks (commits made after the merge, or trunk has since rewritten the same lines), a failed fetch, or a worktree holding initialized submodules (git will not remove one unforced, and their repositories would die with it). Relay the refusal and stop — never reach for `--force` or `git branch -D` to get past it. Gitignored transcripts and drafts go with the worktree by design (see Outputs). If `agent-worktree` is not on PATH, say so and leave the removal to the user.

---

## Required: Delivery section — arcs → stacked PRs (ALL tiers)

Phases are the unit of validation; **arcs** are the unit of review — a contiguous group of phases that ships as one PR. Every plan.md MUST include a "Delivery" section declaring the mapping: arc name → phases included → what it stacks on → the `/code-review` setting for that arc (`off` unless the user opted in at Phase 0; then `low` / `medium`; higher only if the user asked).

- **Single-arc plan** (typical `light`, many `mid`): one branch, one PR, plain `gh pr create`; the plan's close-out lands as that PR's final commits. Say so explicitly; no stack ceremony.
- **Multi-arc plan**: one branch per arc, stacked via the `gh stack` extension (`gh extension list` to confirm; `gh extension install github/gh-stack` if missing) so each PR stays a reviewable slice while later arcs build on earlier ones. The top layer is always a docs-only **close-out** PR (branch `<slug>-close-out`) — the mapping's last row. **Read `references/multi-arc.md` before writing this section for a multi-arc plan, or for one that recommends lanes**: it holds review pipelining, parallel lanes and the agent-safe `gh stack` commands.

**The close-out ships with the delivery, never as a follow-up PR.** It writes the Outcome, promotes lessons, files open items as issues or advisories and archives the plan folder (see Closing the plan), so the merge that lands the work is the merge that completes the plan. On a stack, `gh stack merge` on the close-out lands every arc below it with it.

Sizing rule: an arc must be independently revertable and reviewable in one sitting — if its diff wouldn't be, split it.

**PR timing — no PR before the quality loops.** PRs (drafts included) are opened ONLY in the post-implementation Delivery step, after EVERY quality loop the plan requires has converged (single-arc: the one loop; multi-arc: each arc's boundary loop AND the final cross-arc pass). An open PR re-runs CI on every push, burning CI minutes on code the loops will still change. During implementation the per-phase validation gates are the feedback loop; branches still get pushed (checkpointing, `gh stack push`) — under the PR-gate CI convention a branch push without a PR triggers nothing.

**Parallelism assessment** (every multi-phase plan, one short paragraph in Delivery):

- name the phases that are truly independent: disjoint files, and no semantic coupling (migration numbering, shared fixtures or identifiers, generated outputs);
- estimate the critical path serial and with lanes;
- recommend lanes only when they cut it by about 30% or more.

Pipelined arc boundaries and parallel lanes exist only as plan.md's Delivery section states them, audited and approved with the rest of the plan; lanes also need the owner's explicit approval at the gate. Nothing is improvised mid-run.

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

**File mode (fallback):** the standalone `eli5.html`: no external deps, no build, opens in any browser. Use it when the Artifact tool is absent or the plan must stay on your infrastructure. **Read `references/eli5-file-mode.md` before writing it**: it holds the scaffold, how to present the file at the approval gate, and the `BLUEPRINT_VIEW_CMD` remote-viewing contract.

**Excluded from the ELI5 (both modes): the Architecture & Implementation detail** (interfaces, schemas, file maps, algorithms) — that lives in `plan.md` for the audits. A simplified diagram of the mechanism and defined terms are allowed. (The command-heavy `/goal` + `/loop` seeds DO belong in the ELI5 — "no jargon" is about prose, not the pasteable seeds.)

Either way, the CONTENTS are the same:

All prose follows the **Plain-language standard** (80% of the way to ASD-STE100, see above).

- **Title + one-paragraph summary** in plain language
- **Why this tier was chosen** (Phase 0.5 rubric outcome, with the rubric scores)
- **Who it is for and what excellent looks like** (the Outcome & Quality Bar, in plain language)
- **Terms** (when more than two project terms appear): each with a one-line meaning
- **Diagrams**: one to three inline SVGs, each next to the section it explains.
  - Draw only a real mechanism: how a request or data moves, the order of phases and arcs, or the system before and after.
  - Show the simplified mechanism. Interfaces, schemas and file paths stay in `plan.md`.
  - Label the boxes with the prose's names. Give each diagram a one-sentence caption that says what to notice.
  - Keep the prose complete without the diagram. Draw top to bottom in a viewBox about 320 units wide, so labels stay readable on a phone.
  - Draw no decorative diagrams. A plan with nothing to draw gets none.
  - Artifact mode: load the `artifact-diagramming` skill first. File mode: write the SVG by hand, as in the file-mode scaffold. Do not use Mermaid, because it needs a script.
- **Explainer** (only when `explainer` is not `off`): the animated, narrated section built by the `explainer` skill, near the top. The ELI5 is published first with empty `<!-- explainer:start --><!-- explainer:end -->` markers; the driver fills them when the background worker finishes.
- **Phases**: ELI5 of each (what + why, no jargon) + its validation gate in one plain-language line ("proves itself by: unit tests for the new parser + lint")
- **Human context**: simplified background needed to understand decisions
- **Open questions**: with their human-context framing
- **Approval decision needed from you**: explicit list of what the user must approve (scope, tier, deliverables, /harden scheduling decision if relevant)
- **Implementation seeds**: `/goal` and `/loop` shown as code blocks (DRAFT until the approval gate; finalized post-approval), with ONE marked as "Recommended for this plan" based on whether completion is transcript-observable; explicit warning "Use exactly one per session — they don't compose"
- **(File fallback only) Footer links**: relative links to `plan.md` and `./lessons/`

UI/UX: simple, clean, uncluttered. Plain typography, generous whitespace, no flashy CSS. Mobile-readable.

---

## Required: `/goal` and `/loop` seed strings (ALL tiers)

These live IN the ELI5 companion (the Artifact, or the fallback `eli5.html`) as copy-paste code blocks (DRAFT until the approval gate), and also at the bottom of `plan.md` under a "Seeds" section for terminal grep-ability.

**Seeds are finalized AFTER the approval gate** (Approval gate, "Immediately after approval"). Approval can change scope — conditions attached, phases dropped, constraints added — and that invalidates pre-approval seeds: the drafts exist so the user can evaluate the plan, and the post-approval versions are canonical. **The implementation session must run INSIDE the plan's worktree** (this session already is, post-homing; a fresh session gets there via `agent-worktree resume <slug>`) — seeds pasted into a session sitting in the root clone drive work in the wrong tree.

**Within a single Claude Code session, only one is active. Setting one replaces the other. The ELI5 picks ONE as the recommended seed for this plan; the other is shown as a fallback.** `/goal` is the official primitive for "keep working until a condition holds" (per docs: *"To keep the session working turn after turn until a condition is met rather than on an interval, see `/goal`"*) and survives `claude --resume` — prefer it whenever completion is transcript-observable. `/loop` is interval-based; recurring tasks fire until they expire after 7 days. Use `/loop` with a FIXED interval as the fallback when signals aren't transcript-visible or cron-style reliability is wanted. Avoid self-paced (interval-less) loops for plan execution: the model can end them early when it judges work "done enough" — the classic under-drive stall.

**Permission-stall warning**: a loop silently stalls on permission prompts. Start the implementation session in the permission mode you intend (plus AFK authorization where applicable) so the loop isn't blocked waiting for an approval nobody is present to give.

### `/goal` template

`/goal` sets a completion condition. A Haiku-class evaluator checks after each turn whether it holds. The evaluator only sees what the agent surfaces in the conversation, so the condition must reference observable signals. Frame as: (1) one measurable end state, (2) how to prove it, (3) constraints that matter.

Replace `<trunk>` with the stack's base branch, and `<test>` and `<lint>` with the project's actual commands (e.g. `bun run test` / `bun run lint:actions`, `pnpm test` / `pnpm lint`, `cargo test` / `cargo clippy`, `go test ./...` / `golangci-lint run`):

```
/goal All phases marked ✓ in plan.md (the per-phase headers in the file — not the chat, not the task list), each ✓ backed by its phase's validation gate (as defined in plan.md) reported passing in the transcript; for each phase the agent has printed `LESSONS_FILE=implementations-plan/<plan>/lessons/phase-N.md` in the transcript; if plan.md's `code_review` is not `off`: `/code-review` complete at that level with findings applied and committed (once per arc on multi-arc plans) — if it is `off`, `/code-review` was NOT run; the codex fix loop converged for EVERY reviewed diff — each arc at its boundary plus the final cross-arc pass on multi-arc plans, the whole diff on single-arc — each convergence evidenced by a resumed codex pass reporting no new material findings, quoted in the transcript; the Delivery section's PR topology exists on GitHub, created only AFTER all loops converged (`gh stack view` or `gh pr view` output in the transcript), including the close-out that archived the plan — the single PR's final commits or the stack's docs-only top layer (`git show --stat` of the archive-move commit in the transcript); `<test>` and `<lint>` both report exit 0 in the transcript.
```

### `/loop` template

`/loop` re-fires the prompt on its interval until cleared or expired (7 days). Default to **`/loop 15m`** for implementation cadence: firings land between turns (never mid-response, no overlap), and jitter can delay a firing by up to half the interval — treat 15m as "roughly every 15-22 minutes". The prompt must DRIVE work, not restate the goal: encode dispositions explicitly — never idle, always have a task, decide with codex instead of waiting for the user.

```
/loop 15m Drive implementations-plan/<plan> forward. Never idle waiting for my input. Each firing:
1. **Reality check**: read implementations-plan/<plan>/plan.md and lessons/ (authoritative state — not the chat), including its Outcome & Quality Bar section: every step is judged against those criteria, not just against "it runs". On a stack, read them from the TOP layer (`gh stack view` names it; `git show <top-branch>:<path>`), never from a lower arc's checkout — its plan.md predates later phases. If that path is gone, the close-out has run: `git fetch -q origin <trunk> && git cat-file -e FETCH_HEAD:implementations-plan/archive/<plan>/plan.md` succeeds → it merged and the plan is completely done: run the teardown now, without asking — `ExitWorktree` (`keep`) if this session entered the worktree through `EnterWorktree`, then `agent-worktree done <slug> --merged` (plus `--trunk <trunk>` when `<trunk>` is not origin's default branch) — report what it removed or, if it refused, its output verbatim (never force past a refusal), clear this loop and STOP. Fails → delivered and awaiting my merge: babysit only (CI per step 2, fixes on the arc they belong to then `gh stack sync`, keep the Outcome true), never resume a phase or read the archived plan as a task list; once every PR is green, report that once and STOP — later firings repeat only this merge check. A live plan.md that already carries an `## Outcome` block means a close-out was interrupted: finish it. Otherwise, native task list empty (fresh session)? rebuild it from plan.md, one task per remaining step; run `git status` and `git log --oneline -5`. If a PR exists, `gh pr view --json statusCheckRollup` (no --watch; multi-arc plans: `gh stack view` for the whole stack). Without a PR but with CI configured, `gh run list --branch $(git branch --show-current) --limit 1 --json status,databaseId`.
2. **Waiting on CI is fine** — confirm it's actually progressing (`gh run watch <run-id>` up to 10 minutes; queued or stuck past that → inspect logs, log it as blocked in lessons). Use the wait productively: review the diff, prep the next phase, strengthen tests. Don't start work that would conflict with the in-flight change.
3. **No task in hand?** Pick the next pending step from plan.md and start it. After each meaningful edit, run the fast validation layers (`<lint>` + `<test>` for the touched packages) — catch mistakes in-step, not phases later. Then commit → push (multi-arc plans: `gh stack push`; `gh stack sync` if trunk or a lower arc moved, except during a pipelined review: one sync when it converges).
4. **Stuck, or facing a decision you'd normally bring to me?** Don't wait. Call `/codex high` (on plan.md's `codex_model`) with full context and go back and forth until you two reach a defensible decision, then act on it. Log every consult + verdict in lessons/phase-N.md. Exception — hard limits stay hard: never merge to main or release branches, never publish or deploy, never expand scope beyond plan.md; if the decision requires crossing one, surface it and hold.
5. **Same step failed 5 times?** Stop retrying; reassess the approach with codex, then continue down the agreed path.
6. **Phase green?** "Green" means THE PHASE'S VALIDATION GATE as written in plan.md passes (commands + pass criteria — not generic vibes). Run the full gate, paste the result, mark ✓ in plan.md, file the lessons entry, print `LESSONS_FILE=implementations-plan/<plan>/lessons/phase-N.md` in the transcript, advance to the next phase. Arc boundary crossed (per plan.md's Delivery section)? Run the arc's quality loop FIRST, as plan.md's Post-implementation section places it, until a round yields nothing material — THEN `gh stack add <next-arc-branch>` before the next arc's work. A boundary plan.md marks pipelined, or a lanes table, follows plan.md's Delivery section instead.
7. **All phases ✓ in plan.md?** Run plan.md's Post-implementation section from where it stands. The remaining quality loop first: single-arc, the whole loop over the net diff from plan baseline; multi-arc, only the final cross-arc integration pass, in a FRESH codex session (every arc already looped at its boundary). Still churning after 3 rounds → surface and stop. Then Delivery per plan.md — the FIRST time any PR is opened — then the close-out per plan.md, then `gh pr checks --watch`. Then write the wrap-up report: what shipped, every contentious decision codex and I debated — each with ELI5 context (what the question was, the options, why we picked ours) — and open items by issue or advisory number. Surface and stop — merging the close-out completes the plan, and that is my call; the firing after my merge tears the worktree down (step 1).

Keep the native task list current (`TaskUpdate` as steps start/finish; plan.md stays the source of truth). No task tools in this session → print the step checklist only when a step changes state.
```

Adjust both templates to match the specific plan (phase names, quality calibration) and project (concrete lint/test commands).

---

## Status visibility (throughout)

Track protocol progress in the **native task list** (`TaskCreate` / `TaskUpdate`), not a checklist re-typed into every response: the harness renders it, nothing is re-printed per turn, and it survives compaction and `claude --continue`.

- Create the tasks once the tier is set (0.5): one per step below, adjusted to the tier, with 0 / 0.4 / 0.5 backfilled as completed. At approval add one per implementation phase; on multi-arc plans also one per arc quality loop, one for the cross-arc pass, one for Delivery. Chain them with `blockedBy` so `TaskList` answers "what's next".
- `in_progress` on entry; `completed` only when the step's exit condition holds — a phase's task completes when its validation gate passes and plan.md carries the ✓, never before.
- **plan.md stays authoritative.** The list is per session: a fresh implementing session rebuilds it from plan.md's phase headers (the `/loop` template does this in its reality check). The `/goal` evaluator checks plan.md, never the task list.
- No task tools in the session (on Claude Code, `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` restores them)? Don't emulate them in prose every turn: print the step list below only when a step changes state.

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
[ ] 9. Delivery: PRs created (only now), close-out committed on top, checks green
[ ] 10. Teardown after the merge: worktree, stack branches and manifest row removed
```

---

## Approval gate (ALL tiers)

**Do not ask for approval until ALL of the following are true. The gate BLOCKS otherwise.**

Required deliverables present:

1. `plan.md` (with Architecture & Implementation, Security & Adversarial Considerations, and Assumptions sections, a validation gate on every implementation phase, a Post-implementation section executable without this skill (written out, or citing the repository's own standard), AND a Delivery section mapping phases → arcs/PRs) + `recon.md` from Phase 0.4
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
- **Post-implementation section missing or not executable without this skill** (references the skill instead of spelling out the steps or citing the repository's own standard), or lacks the post-merge teardown step, or **Delivery section missing the arc → phase mapping or the close-out**.

**ELI5 visibility (mandatory when asking for approval)**: the user must never have to hunt for the plan.

- **Artifact (primary):** give its URL on its own standalone line, labeled as the plan's ELI5. That's the whole step — it's already hosted and shareable; no file paths, no serving, no teardown.
- **File fallback (`eli5.html`):** present it as `references/eli5-file-mode.md` says: both path forms on their own lines, `open` on macOS, and the `BLUEPRINT_VIEW_CMD` hook when it is set. Serving exists only inside the approval window: after the verdict, run the hook's `--down` for every attempted UP, as that file says.

**Explainer (when plan.md's `explainer` is not `off`)**: right after presenting the ELI5 and the approval ask, launch the `explainer` skill's job as a background worker. Say in one line that it is building and that approval need not wait for it. When it returns its four-look style board, publish it (private), show it to the owner and relay the pick to the worker (the owner may answer after approving). When it reports, merge its fragment into the current ELI5 and republish (same source path, same URL) per the `explainer` skill's step 7, then post one line: ready, mode, length. The explainer is never a gate deliverable, and a failed explainer never blocks approval.

Present everything together. User approves explicitly using one of the three verdict formats.

**Immediately after approval** (especially conditional approvals): finalize the `/goal` + `/loop` seeds against the approved scope — fold in conditions, dropped phases, new constraints — deliver them in chat as paste-ready blocks, and sync the ELI5 companion (redeploy the Artifact, or update `eli5.html`) + plan.md's Seeds section. Pre-gate seeds are drafts; post-approval seeds are canonical.

---

## Composition with other skills

Blueprint sits in a specific phase of the development cycle. Other skills cover other phases:

- **`/code-review` and Blueprint cover different phases.** Plan-time audits (codex + fable) gate plan APPROVAL; the codex fix loop in plan.md's Post-implementation section gates IMPLEMENTATION. Inside Blueprint, `/code-review` precedes that loop only on the Phase 0 opt-in; outside it, it stays useful on any diff the user points it at.
- **`explainer` is opt-in and owner-only.** Blueprint asks at Phase 0 and launches it at the approval gate; the skill owns the narration, the animation contract, the key exception and QA.
- **`/harden` is NOT auto-scheduled by Blueprint.** It's an expensive whole-codebase audit, typically run before a release/library publish, not after every plan. Blueprint surfaces the question during Phase 0 (clarifying questions) so the user can decide whether the plan's surface (auth / secrets / CI/CD / publishing / repo-wide security posture) warrants a `/harden` pass at release-time. The user decides; Blueprint records the decision in the plan's "Post-implementation hardening" note.

---

## Frontend addendum

When the plan touches UI, **copywriting is part of the design surface**. Clear, simple, no jargon, no clutter. Bad copy makes a good product feel rough. Treat copy review with the same rigor as code review.

---

## Outputs always land here

```
implementations-plan/<plan-name>/
├── plan.md           # COMMITTED. The plan: Architecture & Implementation + Security & Adversarial + Assumptions sections, per-phase validation gates, Post-implementation section (codex fix loop; `/code-review` first only if `code_review` ≠ off), Delivery section (arcs → PRs), audit verdicts inline (mid/deep/mega-deep), decision ledger (mid+), Seeds at bottom
├── recon.md          # COMMITTED. Phase 0.4 codebase-recon findings (reuse / adapt / dedup-risk map) — feeds the draft + every audit
├── research/         # COMMITTED. Persisted research subagent findings (mega-deep only; deepest rung of the recon ladder)
│   └── <module>.md
├── lessons/
│   └── phase-N.md    # COMMITTED. Per-phase debugging logs (filled during implementation)
├── audit-codex.md    # local only — Codex audit transcript(s)
├── audit-fable.md    # local only — Fable audit transcript (mid/deep/mega-deep only)
├── plan-<family>.md  # local only — competing drafts (deep/mega-deep); superseded by plan.md
├── _*.md             # local only — scratch briefs and reviewer prompts
└── eli5.html         # local only — ELI5 FALLBACK; primary is a Claude Artifact (hosted off-repo); /goal + /loop embedded, one marked Recommended
```

**Transcripts and drafts are written, then left uncommitted** (`implementations-plan/.gitignore`, seeded at Phase 0.75). They are real working files during the run — write them, read them, resume against them — they just never enter history: the verdicts already live inline in `plan.md`, the drafts are superseded by it, and reviewer transcripts are the single worst source of absolute local paths, which must never reach a public repo.

**Uncommitted means disposable, and `agent-worktree done` deletes them** along with the worktree — its clean-status check does not protect ignored files. So the committed record has to stand alone BEFORE close-out: `plan.md` carries each audit's accepted findings, the rejected ones with reasons, and any unresolved concern. "Audit passed" is not a record. No committed file may link to `audit-*.md`, `eli5.html` or a draft, because those links will dangle. If a transcript must survive, copy it somewhere outside the worktree — never rely on the worktree keeping it.

Update `implementations-plan/index.md` with `- [<plan-name>](<plan-name>/plan.md) — <status> — <one-line hook>` when the plan is created. The index lists ACTIVE plans only; closing moves the line to `archive/index.md` (see Closing the plan).

The committed artifacts land INSIDE the plan's worktree (Phase 0.75) and merge to the canonical clone with the PR. A published Artifact is hosted off-repo on claude.ai, so only its URL, recorded in `plan.md`, survives. Once the close-out merges, the session removes the worktree itself with `agent-worktree done <plan-name> --merged` (see After the merge).
