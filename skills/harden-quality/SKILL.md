---
name: harden-quality
description: Whole-codebase MAINTAINABILITY audit — finds concrete code smells (Fowler catalog + named analogs) that make working code expensive to change: duplication, coupling, divergent change, shotgun surgery, feature envy, dead code, temporal coupling, config sprawl. Five effort levels (low / medium / high / max / ultra). Map-reduce protocol with parallel Claude + Codex agents per cluster, coordinator-of-specialists shape. Produces impact-bucketed reports under `audit/quality/<date-run-id>/`. Single audit dimension by design (no other focuses' prompts loaded), so it runs on any model, Fable included. Use when finishing a vibecoded project that needs a cleanup pass before shipping, or any time the user wants a whole-codebase maintainability scan rather than a diff review. Trigger phrases include "/harden-quality", "maintainability audit", "code smell scan", "find refactor opportunities", "tech debt scan", "quality pass", "scan this repo for smells". Auto-fire ONLY on explicit audit verbs (maintainability audit / code smell scan / tech debt scan / quality pass), NOT on generic "shipping prep" or "implementation help" language. NOT for diff-only review (use /code-review). NOT for correctness bugs (use /harden-bugs).
---

# Harden Quality

Whole-codebase **maintainability** audit. One focus (quality), five effort levels, map-reduce protocol with parallel Claude + Codex agents and a coordinator-of-specialists shape.

This is a dedicated single-dimension sibling of `/harden`, carrying **only maintainability content** — no other audit focus's prompt is loaded — so it runs clean on any session model. Use it whenever you want a maintainability pass without pulling in the combined skill.

## Invocation

```
/harden-quality [effort]
```

- `[effort]` (default `high`): `low` | `medium` | `high` | `max` | `ultra`

Examples:
- `/harden-quality` runs a maintainability pass at default `high` effort.
- `/harden-quality max` runs a deeper pass.
- `/harden-quality ultra` runs the most thorough (and slowest) scan.

## What counts as a finding

A finding qualifies ONLY if the code **currently works** and the issue is about **future-change cost** — a concrete smell with a NAMED catalog mapping (Fowler's Refactoring catalog or a named close analog with the mapping explained).

- Correctness bugs are out of scope — use `/harden-bugs`.
- Style / formatting is out of scope — the linter handles it.

## Protocol

### Phase 0: Scope confirm

Before any scanning, briefly confirm with the user (use `AskUserQuestion` for clean input):

- What is in scope? Whole repo, a specific package, or a subset?
- Anything to exclude (third-party, generated code, vendor dirs)?
- Known concerns to flag early?
- What is the project type (web app, CLI, library, backend service)?

**Unattended fallback** (CI, scheduled runs, AFK mode, or any non-interactive context): if no answer arrives within a reasonable wait, default to the whole repo minus generated/vendor/`node_modules`/`dist`/`build` directories. State the assumptions explicitly in the report's Methodology section so the user knows what was scanned.

### Phase 1: Repo map (with monorepo hierarchical option)

Build a structured repo map. Module-by-module audits without a map waste tokens and produce inconsistent findings.

**For single-codebase or small repos**: spawn ONE `Explore` subagent with the mapping task below.

**For monorepos** (detected via root `package.json` `workspaces` field, `lerna.json`, `nx.json`, `pnpm-workspace.yaml`, or `packages/` directory): spawn a TWO-LEVEL hierarchical mapping:

1. **Outer mapper** inventories the workspace packages: one-sentence purpose per package, key public exports, dependency direction between packages.
2. **Per-package mappers** (parallel `Explore` subagents, one per package) execute the full mapping task below for their assigned package.

This prevents one bad map from poisoning all downstream phases on large repos.

**Mapping task** (used by single mapper or per-package mappers):

> Map this [repo | workspace package]. Output:
> 1. **Module/package inventory**: name, path, purpose (one sentence), language, rough LOC.
> 2. **Entrypoints**: HTTP routes, CLI commands, event handlers, background jobs, public exports.
> 3. **Coupling surfaces**: modules that import many others, shared utility grab-bags, cross-package dependencies.
> 4. **Dependency graph**: which modules import which (one level deep); flag any cycles.
> 5. **Frameworks in use**: web frameworks, ORMs, validation libs, DI containers, event buses.
> 6. **Test surfaces**: where tests live, what coverage looks like (rough).
> 7. **Generated / vendored / fixture code**: paths that should be excluded from finding-eligibility unless production-wired.
> 8. **Apparent duplication**: modules that look like they might duplicate each other.

Save to `audit/quality/<run-id>/raw/repo-map.md` (flat) or `audit/quality/<run-id>/raw/repo-map/<package>.md` (hierarchical, per package).

Effort scales which model is used (Haiku at `low`, Sonnet at `medium`+, Fable at `max`+) — see the Model note under Effort knob.

### Phase 2: Map (parallel agents per cluster)

Cluster the repo into bounded units. Do NOT run agents on raw files at random. The main agent (you) decides clusters from the Phase 1 output.

Cluster route for maintainability: by **package boundary** and by **similarity** (modules that look like they might duplicate each other based on the repo map).

For each cluster, spawn TWO agents in parallel (always, regardless of effort level):

- **Claude agent** (model per effort level, see Effort knob below).
- **Codex agent** via `/codex` at matching codex effort level (read-only sandbox). At `low` effort, codex runs at minimal effort but still runs. Codex is never skipped: keeping cross-model coverage constant across all tiers is non-negotiable (different model families catch different blind spots).

Each agent receives:
- The cluster's source code.
- Repo-map summaries of the dependencies the cluster imports (NOT full source code of dependencies).
- The quality prompt (see Scan prompt below).
- The negative list (what NOT to flag), included in the prompt.

**Context cap with handoff-edge escalation**: in-cluster traces are capped at ~4 functions of inter-procedural context (RepoAudit guidance; beyond that, hallucination rates spike). However, the cap **escalates across cluster boundaries** when the trace would cross a **handoff edge**:
- Event emit → listener
- DI inject site → consumer
- RPC / message-queue produce → consume
- Framework hook → handler (e.g., middleware → route)

For each handoff edge, the agent can request the handoff target's signature plus its immediate handler (one function) without violating the cap. This catches cross-module coupling that the hard cap would miss.

Output per agent goes to:
- `audit/quality/<run-id>/raw/<cluster>-claude.md`
- `audit/quality/<run-id>/raw/<cluster>-codex.md`

### Phase 2.5: Cross-rebuttal (only at `high` effort and above)

This phase exists only at `high`, `max`, and `ultra` effort levels. It widens the methodological gap with `medium` (where the two agents stay blind to each other).

After Phase 2 raw findings are saved, spawn a brief cross-rebuttal pass per cluster:

- Claude agent reads Codex's raw findings AND its own, then adds: "what did Codex miss? What looks overconfident in Codex's claims?"
- Codex agent reads Claude's raw findings AND its own, then adds the same challenge.

Each agent appends to its own raw file with a `## Cross-rebuttal` section. At `max`, this is a full rebuttal pass (substantive challenge per finding). At `ultra`, it runs twice (Round 2 push-back as well; see Effort knob).

### Phase 3: Reduce (coordinator/judge)

Spawn ONE coordinator agent (top-tier model per effort level). Inputs: all raw findings from Phase 2 + 2.5.

Coordinator tasks:

1. **Deduplicate by root cause + smell type + affected boundary**. Same root cause appearing in N places is ONE finding, not N. BUT: each finding must include an `instances` list of ALL N locations so remediation scope is accurate. One duplicated helper copied across 5 files is one finding with `instances: [file1, file2, ...]`.
2. **Resolve cross-model disagreements**. When Claude flagged and Codex did not (or vice versa), keep the finding but mark `cross-model disagreement` as a confidence signal. Convergence is the strongest evidence available.
3. **Drop speculative findings**. No named smell (Fowler or mapped analog) = drop. "Could be cleaner" without a named smell is noise.
4. **Weight maintenance impact by blast radius + change frequency** (see Severity framework). Assign priority HERE at the reduce stage.
5. **Surface cross-cutting findings** that span multiple clusters (duplication across packages, cyclic dependencies, config sprawl, inconsistent error-handling shape).
6. **Sanity check finding density**: aim for ~1.2 findings per cluster on average (Cloudflare's production target). Higher counts suggest the negative list is failing; rerun with stricter filters if needed.

Why the coordinator model changes between effort levels (Fable at `high`, Codex xhigh at `max`+): at `max` effort, the map phase is Claude-heavy. A Codex coordinator introduces deliberate cross-family judgment at the reduce stage, catching what Anthropic-family models share as blind spots. At `high`, the Fable coordinator is sufficient since the map phase is more balanced.

Save to `audit/quality/<run-id>/findings/consolidated.md`.

### Phase 4: Verifier pass (by impact bucket, not top-N rank)

For findings flagged by Phase 3, run a verifier pass prioritized BY IMPACT BUCKET (NOT by top-N rank). This prevents a rare architectural smell from being crowded out by many local ones.

Order: ALL architectural → ALL structural → ALL local (up to the effort-level cap) → cosmetic (if budget remains).

For each verified finding:

1. Re-read the finding's claimed evidence against the actual source.
2. Confirm or refute the smell.
3. Strengthen the evidence: exact `file:line(s)`, all duplicated/coupled locations, the named refactoring that resolves it, and what disappears afterward.
4. Refine the recommendation: smallest safe refactoring, references to existing patterns in the codebase.
5. Final confidence: `high` (smell verified by both models), `moderate` (one confirmed, other unsure), `low` (kept but flagged).

**Verifier anchoring guard**: the verifier MUST re-read the source independently AND state its own conclusion BEFORE reading the prior claim. For dead-code claims specifically, confirm no DI / reflective registration covers the symbol before agreeing.

Save to `audit/quality/<run-id>/findings/verified.md`.

### Phase 5: Report

Two artifacts: a structured `report.md` (always), and an optional standalone `report.html` companion for stakeholders.

#### Markdown report — `audit/quality/<run-id>/report.md`

```markdown
# Harden Quality Report
**Repo:** <path/name>
**Date:** YYYY-MM-DD
**Effort:** <level>
**Run ID:** <id>
**Models:** <models used per phase>
**Scope:** <what was audited, what was excluded>

## Executive summary
2-3 paragraphs: what was audited, headline findings, recommended priorities.

## Methodology
Map-reduce shape, agent count per cluster, models per phase, cap on inter-procedural context, handoff-edge escalation policy, negative list applied. State any unattended-fallback assumptions explicitly. Document deviations from the formal effort spec explicitly. Honest deviation notes are more useful than pretending the spec was followed.

## Findings

### [<IMPACT>] <Finding ID>: <Title>
**Impact:** architectural | structural | local | cosmetic (+ blast radius, change frequency)
**Confidence:** high | moderate | low
**Smell:** <Fowler smell or named analog with mapping>
**Found by:** claude | codex | both

**Instances** (all locations sharing this root cause):
- `file1:line(s)`
- `file2:line(s)`

**Description**: what the smell is, in plain language.

**Evidence**: concrete locations + the duplicated/coupled logic or dead-code proof.

**Why it harms future change**: the concrete scenario that gets harder, with blast-radius and change-frequency notes.

**Recommended refactoring**: named from Fowler's catalog (Extract Method / Move Function / etc.) or a named analog. What disappears afterward.

**Effort estimate**: hours / days / weeks.

---

## Findings NOT pursued (with reasoning)
One line each. Things the agents flagged that were dropped during reduce or verifier.

## Cross-cutting observations
Patterns that span multiple clusters and are worth tracking even if not actionable per-finding.
```

#### HTML companion — `audit/quality/<run-id>/report.html` (optional)

Write it when the user wants a stakeholder-facing view. Standalone single-file HTML (no external CSS/JS, no build step). Same shape as any good findings page:

1. **Per-finding ELI5 block** (3 short paragraphs, before the technical trace):
   - **What it is** — plain-language explanation of the smell with enough context that a non-engineer understands what's wrong. Define any unavoidable jargon inline.
   - **What gets harder to change** — the concrete next feature or fix that becomes slower, riskier, or touches more files than it should because this smell exists. Use a realistic example.
   - **The fix** — the refactoring, in plain language. Mention if a cleaner pattern already exists elsewhere in the codebase to mirror.
2. **Technical trace** behind a `<details>` collapsible — instances, evidence, named refactoring, what disappears. Default-collapsed.
3. **Top-of-page stat strip** — total / architectural / structural / local / cosmetic counts as chips.
4. **"Cheapest wins first" callout** — green-bordered, the 2-3 refactorings that are hours of work with high payoff.
5. **Footer** with **relative links** to the markdown report and raw outputs — never absolute filesystem paths.

Design constraints: system font stack, generous whitespace, max-width ~820px; auto dark-mode via `@media (prefers-color-scheme: dark)` with CSS custom properties; impact chips red for architectural, amber for structural, gray for local/cosmetic; code references as inline `<code>`, repo-relative only; no JavaScript (`<details>` is the only interactive element); ~30-50KB for ~10-15 findings.

**Reporting back at end-of-task**: give the absolute path to `report.md` (and `report.html` if written) so the user can click-to-open from the terminal.

**Remote viewing (headless boxes)**: if `BLUEPRINT_VIEW_CMD` is set, additionally run `$BLUEPRINT_VIEW_CMD <absolute path to audit/quality/<run-id>>` and print the returned URL + `/report.html` (when written; else `/report.md`) on its own standalone line — the full contract (stdout validation, failure notice, `--down`) is defined once in the blueprint skill's "Remote viewing" section; same rules apply here. **Teardown discipline is strict**: serve only while the user is actually reading — run `$BLUEPRINT_VIEW_CMD --down <same dir>` as soon as the user acknowledges the report (their next instruction counts) or at session end, whichever comes first, and confirm the teardown in chat. The mount covers the repo's whole `audit/` tree (all runs).

## Scan prompt (Phase 2 agents; reused by the Phase 4 verifier)

```
You are auditing a code cluster for QUALITY (maintainability, not correctness). Mindset: future-change cost.

Find ONLY concrete code smells with NAMED catalog mappings. The code currently works; your job is to surface what makes it expensive to change.

For each finding, you MUST provide:

1. Title: concise.
2. Smell name - must come from Fowler's Refactoring catalog OR a named close analog with the mapping explained. Examples:

   Fowler classics:
   - Bloaters: Long Method, Large Class, Primitive Obsession, Long Parameter List, Data Clumps
   - OO-Abusers (or language equivalents): Switch Statements, Temporary Field, Refused Bequest, Alternative Classes with Different Interfaces
   - Change Preventers: Divergent Change, Shotgun Surgery, Parallel Inheritance Hierarchies
   - Dispensables: Comments-as-deodorant, Duplicate Code, Dead Code, Lazy Class, Data Class, Speculative Generality
   - Couplers: Feature Envy, Inappropriate Intimacy, Message Chains, Middle Man

   Named close analogs (cite the source / community canon):
   - Cyclic dependencies (boundary erosion)
   - Temporal coupling (operations that must happen in a specific order without enforcement)
   - Config sprawl (the same config knob duplicated across N files)
   - Test brittleness (tests that fail on unrelated refactors)
   - React-specific: Rules-of-Hooks violations, missing useEffect dependencies, fire-and-forget effects, over-coupled prop drilling, custom-hook extraction opportunity
   - Async-specific: callback chains where promises/async would do, missing error boundary in async flows, sync-over-async (blocking calls in async handlers)
   - Error-handling: try/catch nesting, exception swallowing, error-as-success-path

   For analogs, EXPLAIN the mapping: "This is a form of Shotgun Surgery because changing X requires touching N unrelated files".

3. Maintenance impact. Use the four buckets BUT also weight by blast radius and change frequency:
   - architectural: wrong abstraction at module/package level
   - structural: wrong shape within a module
   - local: within a single function or file
   - cosmetic: minor

   PLUS: blast radius (how many files/modules touched), change frequency (how often this code is modified, inferred from git history if available). A `local` smell touched weekly may matter more than a dormant `architectural` smell.

4. Concrete evidence: cite specific instances. For duplication: cite ALL N locations and the duplicated logic. For Feature Envy: name the data the function envies and where it lives. For dead code: cite the absence of inbound references with grep-style evidence AND confirm no DI / reflective registration covers it.

5. Why it harms future change: be concrete. What scenario gets harder?

6. Smallest safe refactoring: from Fowler's refactoring catalog (Extract Method / Move Function / Replace Conditional with Polymorphism / Inline Function / etc.) OR a named analog refactoring. Name it.

7. What disappears: what duplication / coupling / complexity goes away after the refactoring.

8. Instances: ALL file:line locations sharing this root cause.

If you cannot name a smell (Fowler or close analog with mapping), mark as a NON-FINDING.

DO NOT FLAG:
- Style or formatting (Biome / ESLint / Prettier handle).
- Naming preferences without a concrete duplication or coupling consequence.
- "Could be cleaner" / "more idiomatic" without naming a smell.
- Speculative future flexibility ("what if you need to support X later?").
- Performance optimizations (separate concern).
- Correctness or behavioral bugs (use /harden-bugs).
- Pre-existing patterns the codebase consistently uses UNLESS they create measurable duplication, coupling, or change amplification. (Conventions are not smells unless they cost something.)
- Issues in test, demo, fixture, or migration code UNLESS that code is production-wired.
- Dead-code claims in reflective / DI / framework-registration contexts UNLESS you can confirm no registration covers it.
- Framework defaults you would override with no clear gain.
```

## Effort knob

The effort knob scales agent intelligence and depth, NOT phase composition. All phases run at every level (Codex is never skipped, even at `low`).

**Model note.** This ladder names **Fable** as the top-tier Claude model (Phase 1 map and Phase 2 cluster agents at `max`/`ultra`; the Phase 3 coordinator at `high`). Run it on Fable when available (`Agent` tool: `model: 'fable'`); fall back to Opus 4.8 (1M context) (`model: 'opus'`) only when Fable is unavailable. This skill loads a single audit dimension (maintainability only), so Fable runs every leg without falling back — that is the whole reason it exists as a separate skill. The Codex legs are unaffected either way.

| Effort | Phase 1 model | Phase 2 agents per cluster | Phase 2.5 cross-rebuttal | Phase 3 coordinator | Phase 4 verifier depth | Wall-clock (rough, 10 clusters) |
|--------|---------------|----------------------------|--------------------------|---------------------|-------------------------|----------------------------------|
| `low` | Haiku | 2: Claude Haiku + Codex (minimal effort) | NO | Sonnet | top 3 (impact-bucket prioritized) | ~10-15 min |
| `medium` | Sonnet | 2: Claude Sonnet + Codex (medium effort) | NO | Sonnet | top 5 (impact-bucket prioritized) | ~25-35 min |
| `high` (default) | Sonnet | 2: Claude Sonnet + Codex (xhigh) | YES (light pass) | Fable | top 10 (impact-bucket prioritized) | ~50-70 min |
| `max` | Fable | 2: Claude Fable + Codex (xhigh) | YES (full rebuttal) | Codex xhigh ¹ | all structural+ (impact-bucket prioritized) | ~80-100 min |
| `ultra` | Fable | 4: 2 Claude Fable + 2 Codex (xhigh, independent passes) | YES + Round 2 push-back (resume sessions) | Codex xhigh ¹ | all findings (impact-bucket prioritized) | ~130-200 min |

¹ Coordinator switches from Fable (`high`) to Codex xhigh (`max`+) DELIBERATELY: at `max`, the map phase is Claude-heavy. A Codex coordinator introduces cross-family judgment at the reduce stage, catching what Anthropic-family models share as blind spots. At `high`, Fable is sufficient because the map phase is more balanced. This is intentional heterogeneity, not arbitrary model selection.

`ultra` Round 2 push-back: resume the Phase 2 / 2.5 sessions with the prompt *"Look at your prior findings. What did you miss? What did you over-assert? Which conventions did you mislabel as smells, and which real smells did you excuse as conventions? Where were you anchored on the cluster's framing?"* (Same pattern as `/blueprint mega-deep`.)

Wall-clock estimates assume ~10 clusters; scales roughly linearly with cluster count.

## Severity framework (maintenance impact + weighting)

Four scope buckets:
- architectural: wrong abstraction at module/package level
- structural: wrong shape within a module
- local: within a single function/file
- cosmetic: minor

Plus weighting by **blast radius** (how many files/modules touched by this smell) and **change frequency** (how often the affected code is modified, from git history if available). Priority = scope × blast radius × change frequency.

A `local` duplication touched weekly may rank higher than a dormant `architectural` smell. The report's Findings table sorts by computed priority, not just scope.

## Output directory layout

```
audit/quality/<YYYY-MM-DD>-<run-id>/
├── raw/
│   ├── repo-map.md                   # flat (single-codebase) OR
│   ├── repo-map/<package>.md         # hierarchical (monorepo)
│   ├── <cluster-1>-claude.md         # Phase 2 raw + Phase 2.5 cross-rebuttal appended
│   ├── <cluster-1>-codex.md
│   └── ...
├── findings/
│   ├── consolidated.md               # after Phase 3 reduce
│   └── verified.md                   # after Phase 4 verifier
├── report.md                         # Phase 5 markdown report (always)
└── report.html                       # Phase 5 HTML companion (optional)
```

Multiple runs on the same codebase get separate dated directories; they do not overwrite each other. Compare runs by reading multiple `report.md` files side by side.

## Known failure modes (avoid these)

From the multi-agent LLM auditing literature plus failure modes specific to this harness:

- **Monolithic single-agent on whole repo**: hallucinations spike on graphs with millions of edges. The phase structure exists for this reason. Do not skip it.
- **Ungrounded agent debate**: agents arguing without a named smell produce confidently wrong findings. Always demand a Fowler smell or a mapped analog.
- **Self-consensus with one model**: two Claude agents agreeing means nothing. Cross-model (Claude + Codex) disagreement is the actual signal.
- **Smell without evidence**: an "architectural" label without cited instances is wrong-priority. Reject during reduce.
- **Reducers that merge by file:line**: dedupe by `root cause + smell type + affected boundary`, not by location. The same duplicated helper in 5 places is ONE finding (but list all 5 instances).
- **Free-form chain-of-thought in agent prompts**: does not outperform structured prompts. Use the structured finding shape required above.
- **Unbounded inter-procedural exploration**: cap at ~4 functions of context, with handoff-edge escalation. Beyond that, hallucinations dominate.
- **Skipping the negative list**: the negative list cuts false positives more than any prompt-engineering trick. Conventions are not smells unless they cost something.
- **Poisoned repo-map anchoring**: a wrong or partial Phase 1 map silently corrupts every downstream cluster. Hierarchical mapping for monorepos + cross-checking the map against the actual directory tree mitigates this.
- **Cluster-boundary blindness**: coupling that crosses clusters can disappear at the cap unless the handoff-edge escalation rule is applied.
- **Over-merging distinct findings during dedupe**: aggressive dedupe can collapse two different smells that share a location. Dedupe by root cause + smell type + boundary.
- **Dead-code false positives**: claiming dead code without checking DI / reflective / framework registration. Always confirm no registration covers the symbol.
- **Verifier confirmation bias**: the verifier sees the prior claim and anchors. Mitigation: the verifier MUST re-read the source independently AND state its own conclusion before reading the prior claim.
- **Non-deterministic cluster naming**: if cluster names drift between runs, runs become hard to compare. Use stable, hash-of-cluster-content-or-path-based names.

## What `/harden-quality` is NOT

- NOT for diff-only review (use `/code-review max --fix`).
- NOT a correctness pass (use `/harden-bugs`).
- NOT a performance pass (separate concern).
- NOT idempotent: rerunning on the same codebase gives slightly different results (different model rollouts, agent contexts). Cross-run agreement is signal.
- NOT composed with `/blueprint`. The report is the deliverable. The user decides what to refactor.
