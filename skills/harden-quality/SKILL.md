---
name: harden-quality
description: Quality-only whole-codebase audit (test extraction of `/harden quality` with no security/bugs content). Finds named code smells (Fowler catalog + analogs) that make code expensive to change — behavior-preserving maintainability only. Five effort levels (low / medium / high / max / ultra). Map-reduce protocol with parallel Claude + Codex agents per cluster. Produces impact-bucketed reports under `audit/quality/<date-run-id>/`. Trigger phrases: "/harden-quality", "quality audit", "maintainability audit", "smell hunt", "refactoring audit". NOT for diff-only review (use /code-review) and NOT for vulnerability or correctness hunting (use /harden).
---

# Harden-Quality

Test extraction of `/harden quality` into a standalone skill, for evaluating how well Fable finds quality improvements in isolation. Same protocol bones as `/harden`, quality focus only. **If this skill and `/harden` ever drift, `/harden` is canonical.** Delete this skill when the test is done.

## Invocation

```
/harden-quality [effort]
```

- `[effort]` (default `high`): `low` | `medium` | `high` | `max` | `ultra`
- To test Fable specifically, run `max` or `ultra` — those are the levels where Fable does the mapping and cluster passes.

## Scope rule

A finding qualifies ONLY if behavior is currently correct and the finding is about maintainability or change cost. Anything about wrong behavior, crashes, data integrity, or trust boundaries is out of scope for this skill — note it in one line under "Out-of-scope observations" in the report and move on.

## Protocol

### Phase 0: Scope confirm

Briefly confirm with the user (use `AskUserQuestion` for clean input): what's in scope (whole repo / package / subset), what to exclude (generated, vendor, third-party), known pain points, project type.

**Unattended fallback**: no answer → whole repo minus generated/vendor/`node_modules`/`dist`/`build`; state the assumption in the report's Methodology section.

### Phase 1: Repo map

Spawn ONE `Explore` subagent (monorepos: two-level — outer package inventory, then parallel per-package mappers). Mapping task:

> Map this [repo | workspace package]. Output:
> 1. **Module/package inventory**: name, path, purpose (one sentence), language, rough LOC.
> 2. **Public surface**: exports, routes, CLI commands.
> 3. **Dependency graph**: which modules import which (one level deep).
> 4. **Similarity candidates**: modules that look like they might duplicate each other.
> 5. **Frameworks in use** and house conventions you can infer.
> 6. **Test surfaces**: where tests live, rough coverage shape.
> 7. **Generated / vendored / fixture code**: paths excluded from finding-eligibility unless production-wired.
> 8. **Change hotspots**: most-frequently-modified paths from `git log` if available.

Save to `audit/quality/<run-id>/raw/repo-map.md` (or `raw/repo-map/<package>.md` for monorepos).

### Phase 2: Map (parallel agents per cluster)

Main agent clusters the repo from the Phase 1 output — by **package boundary** and by **similarity** (likely-duplicate modules share a cluster). For each cluster, spawn TWO agents in parallel regardless of effort:

- **Claude agent** (model per effort table).
- **Codex agent** via `/codex` at matching effort (read-only sandbox). Codex is never skipped — cross-model coverage is the signal.

Each agent gets: the cluster source, repo-map summaries of imported dependencies (not their source), the quality prompt below, and its DO-NOT-FLAG list. In-cluster traces cap at ~4 functions of inter-procedural context; the cap escalates one function across handoff edges (event emit→listener, DI inject→consumer, framework hook→handler).

Output: `audit/quality/<run-id>/raw/<cluster>-claude.md` and `<cluster>-codex.md`.

### Phase 2.5: Cross-rebuttal (`high`+ only)

Each agent reads the other's raw findings plus its own and appends a `## Cross-rebuttal` section: what did the other miss, what looks overconfident. Light pass at `high`, full rebuttal at `max`, twice at `ultra` (Round 2 push-back: resume sessions with "What did you miss? What did you over-assert? Where were you anchored on the cluster's framing instead of attacking it?").

### Phase 3: Reduce (coordinator)

ONE coordinator agent (model per effort table) over all raw findings:

1. **Dedupe by root cause**, not location — same smell in N places is ONE finding with an `instances` list of all N locations.
2. **Cross-model disagreements**: keep, mark `cross-model disagreement` as a confidence signal. Convergence is the strongest evidence.
3. **Drop anything without concrete evidence** (cited instances, named smell). No exceptions.
4. **Compute priority** = scope bucket × blast radius × change frequency (see Impact framework).
5. **Surface cross-cutting smells** spanning clusters (duplication across packages, inconsistent error handling).
6. Sanity-check density: ~1.2 findings per cluster on average; much higher means the DO-NOT-FLAG list is failing.

Save to `audit/quality/<run-id>/findings/consolidated.md`.

### Phase 4: Verifier pass

Verify findings in priority order: ALL architectural → ALL structural → local (to the effort cap) → cosmetic if budget remains. Verifier MUST re-read the source independently and state its own conclusion BEFORE reading the prior claim (anchoring guard). Confirm/refute, strengthen instance lists, name the smallest safe refactoring, final confidence high/moderate/low.

Save to `audit/quality/<run-id>/findings/verified.md`.

### Phase 5: Report

Markdown only (`audit/quality/<run-id>/report.md`) — no HTML companion for quality yet (per `/harden`, the ELI5 phrasing needs quality-specific language first).

```markdown
# Harden-Quality Report
**Repo / Date / Effort / Run ID / Models / Scope**

## Executive summary
2-3 paragraphs: what was audited, headline smells, recommended order of attack.

## Methodology
Cluster count, agents per cluster, models per phase, deviations from the effort spec (state them honestly), unattended-fallback assumptions.

## Findings (sorted by computed priority, not scope alone)

### [<IMPACT>] <ID>: <Title>
**Impact:** <architectural | structural | local | cosmetic> · blast radius: <N files/modules> · change frequency: <hot | warm | cold>
**Confidence:** <high | moderate | low> · **Smell:** <Fowler name or named analog + mapping> · **Found by:** <claude | codex | both>
**Instances:** all file:line locations sharing this root cause
**Evidence:** concrete citations (duplicated logic, coupling chain, dead-code grep evidence)
**Why it harms future change:** the concrete scenario that gets harder
**Smallest safe refactoring:** named from Fowler's catalog or analog
**What disappears:** the duplication/coupling/complexity removed
**Effort estimate:** hours / days / weeks

## Findings NOT pursued (one line each, with reasoning)
## Out-of-scope observations (one line each — anything that isn't a maintainability finding)
## Cross-cutting observations
```

Report the absolute path to `report.md` in chat at end-of-task.

## The quality prompt (sent verbatim to Phase 2 agents, reused for Phase 4)

```
You are auditing a code cluster for QUALITY (maintainability, not correctness). Mindset: future-change cost.

Find ONLY concrete code smells with NAMED catalog mappings. The code currently works; your job is to surface what makes it expensive to change.

For each finding, you MUST provide:

1. Title: concise.
2. Smell name — must come from Fowler's Refactoring catalog OR a named close analog with the mapping explained. Examples:

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

3. Maintenance impact bucket: architectural (wrong abstraction at module/package level) / structural (wrong shape within a module) / local (within a single function or file) / cosmetic (minor). PLUS blast radius (how many files/modules touched) and change frequency (how often this code is modified, inferred from git history if available). A local smell touched weekly may matter more than a dormant architectural smell.

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
- Anything about wrong behavior, crashes, data integrity, or trust boundaries — out of scope for this skill; note in one line and move on.
- Pre-existing patterns the codebase consistently uses UNLESS they create measurable duplication, coupling, or change amplification. (Conventions are not smells unless they cost something.)
- Issues in test, demo, fixture, or migration code UNLESS that code is production-wired.
- Dead-code claims in reflective / DI / framework-registration contexts UNLESS you can confirm no registration covers it.
- Framework defaults you would override with no clear gain.
```

## Effort knob

Effort scales intelligence and depth, NOT phase composition. Codex is never skipped.

| Effort | Phase 1 model | Phase 2 agents per cluster | Phase 2.5 rebuttal | Phase 3 coordinator | Phase 4 verifier depth |
|--------|---------------|----------------------------|--------------------|---------------------|------------------------|
| `low` | Haiku | Claude Haiku + Codex (minimal) | no | Sonnet | top 3 by priority |
| `medium` | Sonnet | Claude Sonnet + Codex (medium) | no | Sonnet | top 5 by priority |
| `high` (default) | Sonnet | Claude Sonnet + Codex (xhigh) | light | Fable | top 10 by priority |
| `max` | Fable | Claude Fable + Codex (xhigh) | full | Codex xhigh | all structural+ |
| `ultra` | Fable | 2 Claude Fable + 2 Codex (xhigh, independent) | full + Round 2 | Codex xhigh | all findings |

Coordinator switches to Codex xhigh at `max`+ deliberately: the map phase is Claude-heavy there, so a cross-family judge at reduce catches Anthropic-family shared blind spots.

## Impact framework

Priority = **scope bucket × blast radius × change frequency**. The Findings section sorts by computed priority, not scope alone. Low-confidence architectural findings get relabeled `Potential architectural`, not silently kept.

## Output layout

```
audit/quality/<YYYY-MM-DD>-<run-id>/
├── raw/            # repo-map + per-cluster claude/codex outputs (+ rebuttals)
├── findings/       # consolidated.md, verified.md
└── report.md
```

Runs never overwrite each other; cross-run agreement is signal.

## Known failure modes

- **Ungrounded debate**: findings without cited instances are noise — demand the named smell + evidence.
- **Self-consensus with one model**: two Claude agents agreeing means nothing; Claude+Codex convergence is the signal.
- **Over-merging during dedupe**: dedupe by root cause, not by shared file — two different smells in one file stay two findings.
- **Verifier confirmation bias**: verifier states its own conclusion before reading the prior claim.
- **Convention-blindness vs convention-suppression**: don't flag house conventions, but DO flag them when they measurably amplify change cost.

## What `/harden-quality` is NOT

- NOT for diff-only review (`/code-review max --fix`).
- NOT for vulnerability or correctness hunting (that's `/harden`).
- NOT composed with `/blueprint` — the report is the deliverable; the user decides what to refactor.
- NOT permanent: this is a test extraction. `/harden` is canonical; delete this skill when the Fable evaluation is done.
