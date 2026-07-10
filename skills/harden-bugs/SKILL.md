---
name: harden-bugs
description: Whole-codebase CORRECTNESS audit — finds wrong results, crashes, data corruption, lost updates, race conditions, and invariant violations that show up during normal use. Five effort levels (low / medium / high / max / ultra). Map-reduce protocol with parallel Claude + Codex agents per cluster, coordinator-of-specialists shape. Produces impact-bucketed reports under `audit/bugs/<date-run-id>/`. Single audit dimension by design (no other focuses' prompts loaded), so it runs on any model, Fable included. Use when finishing a vibecoded project that needs a correctness pass before shipping, or any time the user wants a whole-codebase bug hunt rather than a diff review. Trigger phrases include "/harden-bugs", "bug hunt", "find bugs", "correctness audit", "whole repo bug scan", "hunt for correctness issues", "scan this repo for bugs". Auto-fire ONLY on explicit audit verbs (bug hunt / correctness audit / whole repo bug scan / scan for bugs), NOT on generic "shipping prep" or "implementation help" language. NOT for diff-only review (use /code-review). NOT for maintainability (use /harden-quality).
---

# Harden Bugs

Whole-codebase **correctness** audit. One focus (bugs), five effort levels, map-reduce protocol with parallel Claude + Codex agents and a coordinator-of-specialists shape.

This is a dedicated single-dimension sibling of `/harden`, carrying **only correctness content** — no other audit focus's prompt is loaded — so it runs clean on any session model. Use it whenever you want a correctness pass without pulling in the combined skill.

## Invocation

```
/harden-bugs [effort]
```

- `[effort]` (default `high`): `low` | `medium` | `high` | `max` | `ultra`

Examples:
- `/harden-bugs` runs a bug hunt at default `high` effort.
- `/harden-bugs max` runs a deeper pass.
- `/harden-bugs ultra` runs the most thorough (and slowest) bug hunt.

## What counts as a finding

A finding qualifies ONLY if normal operation triggers a **wrong result, crash, data corruption, lost update, or invariant violation** — and a confused-but-ordinary user, or a non-hostile environmental condition (timing, concurrency, missing data, latency), can trigger it.

- Maintainability or change-cost concerns are out of scope — use `/harden-quality`.
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
> 3. **State owners**: modules that own mutable state, shared caches, connection pools, in-flight queues.
> 4. **Dependency graph**: which modules import which (one level deep).
> 5. **Frameworks in use**: web frameworks, ORMs, validation libs, concurrency primitives, DI containers, event buses.
> 6. **Test surfaces**: where tests live, what coverage looks like (rough).
> 7. **Generated / vendored / fixture code**: paths that should be excluded from finding-eligibility unless production-wired.

Save to `audit/bugs/<run-id>/raw/repo-map.md` (flat) or `audit/bugs/<run-id>/raw/repo-map/<package>.md` (hierarchical, per package).

Effort scales which model is used (Haiku at `low`, Sonnet at `medium`+, Fable at `max`+) — see the Model note under Effort knob.

### Phase 2: Map (parallel agents per cluster)

Cluster the repo into bounded units. Do NOT run agents on raw files at random. The main agent (you) decides clusters from the Phase 1 output.

Cluster route for correctness: by **state owner** (modules that own mutable state) and by **call graph** (functions that share callers or callees). Error-path-heavy modules get their own cluster.

For each cluster, spawn TWO agents in parallel (always, regardless of effort level):

- **Claude agent** (model per effort level, see Effort knob below).
- **Codex agent** via `/codex` at matching codex effort level (read-only sandbox). At `low` effort, codex runs at minimal effort but still runs. Codex is never skipped: keeping cross-model coverage constant across all tiers is non-negotiable (different model families catch different blind spots).

Each agent receives:
- The cluster's source code.
- Repo-map summaries of the dependencies the cluster imports (NOT full source code of dependencies).
- The bugs prompt (see Scan prompt below).
- The negative list (what NOT to flag), included in the prompt.

**Context cap with handoff-edge escalation**: in-cluster traces are capped at ~4 functions of inter-procedural context (RepoAudit guidance; beyond that, hallucination rates spike). However, the cap **escalates across cluster boundaries** when the trace would cross a **handoff edge**:
- Event emit → listener
- DI inject site → consumer
- RPC / message-queue produce → consume
- Framework hook → handler (e.g., middleware → route)

For each handoff edge, the agent can request the handoff target's signature plus its immediate handler (one function) without violating the cap. This catches event-driven, DI-heavy, and cross-service flows that the hard cap would miss.

Output per agent goes to:
- `audit/bugs/<run-id>/raw/<cluster>-claude.md`
- `audit/bugs/<run-id>/raw/<cluster>-codex.md`

### Phase 2.5: Cross-rebuttal (only at `high` effort and above)

This phase exists only at `high`, `max`, and `ultra` effort levels. It widens the methodological gap with `medium` (where the two agents stay blind to each other).

After Phase 2 raw findings are saved, spawn a brief cross-rebuttal pass per cluster:

- Claude agent reads Codex's raw findings AND its own, then adds: "what did Codex miss? What looks overconfident in Codex's claims?"
- Codex agent reads Claude's raw findings AND its own, then adds the same challenge.

Each agent appends to its own raw file with a `## Cross-rebuttal` section. At `max`, this is a full rebuttal pass (substantive challenge per finding). At `ultra`, it runs twice (Round 2 push-back as well; see Effort knob).

### Phase 3: Reduce (coordinator/judge)

Spawn ONE coordinator agent (top-tier model per effort level). Inputs: all raw findings from Phase 2 + 2.5.

Coordinator tasks:

1. **Deduplicate by root cause + failing operation + affected state**. Same root cause appearing in N places is ONE finding, not N. BUT: each finding must include an `instances` list of ALL N locations so remediation scope is accurate.
2. **Resolve cross-model disagreements**. When Claude flagged and Codex did not (or vice versa), keep the finding but mark `cross-model disagreement` as a confidence signal. Convergence is the strongest evidence available.
3. **Drop speculative findings**. No concrete counter-example = drop. No exception. "Could break" without a reproducing input or interleaving is noise.
4. **Apply the anchored severity ladder** (see Severity framework). Assign the band HERE at the reduce stage (not at Phase 2, where bands drift).
5. **Surface cross-cutting findings** that span multiple clusters (shared invariant broken in several places, inconsistent error handling, the same bad retry pattern repeated).
6. **Sanity check finding density**: aim for ~1.2 findings per cluster on average (Cloudflare's production target). Higher counts suggest the negative list is failing; rerun with stricter filters if needed.

Why the coordinator model changes between effort levels (Fable at `high`, Codex xhigh at `max`+): at `max` effort, the map phase is Claude-heavy. A Codex coordinator introduces deliberate cross-family judgment at the reduce stage, catching what Anthropic-family models share as blind spots. At `high`, the Fable coordinator is sufficient since the map phase is more balanced.

Save to `audit/bugs/<run-id>/findings/consolidated.md`.

### Phase 4: Verifier pass (by severity bucket, not top-N rank)

For findings flagged by Phase 3, run a verifier pass prioritized BY SEVERITY BUCKET (NOT by top-N rank). This prevents a rare Blocker from being crowded out by many Major findings.

Order: ALL Blocker → ALL Critical → ALL Major (up to the effort-level cap) → Minor (if budget remains).

For each verified finding:

1. Re-read the finding's claimed failing path against the actual source.
2. Confirm or refute the finding.
3. Strengthen the certificate: exact `file:line(s)`, the minimal counter-example input or interleaving, and the violated invariant.
4. Refine the fix recommendation: smallest safe change, references to existing patterns in the codebase.
5. Final confidence: `high` (reproduction verified by both models), `moderate` (one confirmed, other unsure), `low` (kept but flagged).
6. **Low-confidence Blocker** gets relabeled to `Potential Blocker` (not silently kept as Blocker). Same pattern for Critical at low confidence.

**Verifier anchoring guard**: the verifier MUST re-read the source independently AND state its own conclusion BEFORE reading the prior claim.

Save to `audit/bugs/<run-id>/findings/verified.md`.

### Phase 5: Report

Two artifacts: a structured `report.md` (always), and an optional standalone `report.html` companion for stakeholders.

#### Markdown report — `audit/bugs/<run-id>/report.md`

```markdown
# Harden Bugs Report
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

### [<SEVERITY>] <Finding ID>: <Title>
**Severity:** Blocker | Critical | Major | Minor
**Confidence:** high | moderate | low
**Type:** <primary bug type, optional secondary>
**Found by:** claude | codex | both

**Instances** (all locations sharing this root cause):
- `file1:line(s)`
- `file2:line(s)`

**Description**: what the issue is, in plain language.

**Counter-example**: the minimal input, interleaving, or state that triggers the bug.

**Violated invariant**: the assumption that breaks.

**Failing path**: function-level trace from entry to failure, file:line at each step.

**Recommended fix**: smallest safe change. Reference existing patterns in the codebase if relevant.

**Effort estimate**: hours / days / weeks.

---

## Findings NOT pursued (with reasoning)
One line each. Things the agents flagged that were dropped during reduce or verifier.

## Cross-cutting observations
Patterns that span multiple clusters and are worth tracking even if not actionable per-finding.
```

#### HTML companion — `audit/bugs/<run-id>/report.html` (optional)

Write it when the user wants a stakeholder-facing view. Standalone single-file HTML (no external CSS/JS, no build step). Same shape as any good findings page:

1. **Per-finding ELI5 block** (3 short paragraphs, before the technical trace):
   - **What it is** — plain-language explanation of the issue with enough context that a non-engineer understands what's wrong. Define any unavoidable jargon inline.
   - **What a user would trigger** — the concrete input, timing, or state an ordinary user (or an unlucky environment) hits, and what they see go wrong. Use a realistic example.
   - **The fix** — what to do, in plain language. Mention if a similar correct pattern already exists in the codebase.
2. **Technical trace** behind a `<details>` collapsible — counter-example, violated invariant, failing path, recommended fix. Default-collapsed.
3. **Top-of-page stat strip** — total / Blocker / Critical / Major / Minor counts as chips.
4. **"Cheapest fixes first" callout** — green-bordered, the 2-3 findings that are hours of work.
5. **Footer** with **relative links** to the markdown report and raw outputs — never absolute filesystem paths.

Design constraints: system font stack, generous whitespace, max-width ~820px; auto dark-mode via `@media (prefers-color-scheme: dark)` with CSS custom properties; severity chips red for Blocker/Critical, amber for Major, gray for Minor; code references as inline `<code>`, repo-relative only; no JavaScript (`<details>` is the only interactive element); ~30-50KB for ~10-15 findings.

**Reporting back at end-of-task**: give the absolute path to `report.md` (and `report.html` if written) so the user can click-to-open from the terminal.

## Scan prompt (Phase 2 agents; reused by the Phase 4 verifier)

```
You are auditing a code cluster for CORRECTNESS BUGS. Mindset: normal-operation failure. Assume a user hits an edge case, OR an environmental condition (timing, concurrency, missing data, latency) causes a failure.

Find ONLY issues that produce wrong results, crashes, data corruption, lost updates, or invariant violations during normal use. An issue qualifies if a confused-but-ordinary user can trigger it, OR a non-hostile condition can trigger it.

For each finding, you MUST provide a structured logical certificate:

1. Title: concise.
2. Severity (use these anchors precisely):
   - Blocker: persistent data loss / crash on common path / unrecoverable corruption that hits in production.
   - Critical: high-impact bug under realistic conditions but conditional (specific input, timing, state).
   - Major: affects feature behavior, user-visible.
   - Minor: limited impact or rare conditions.
   (No "Info" tier - if it's not a real bug per "wrong result / crash / corruption / invariant violation", it's a non-finding.)
3. Repro confidence: high / moderate / low. Findings with low repro confidence should NOT be reported (filter at Phase 2; coordinator drops any that slip through).
4. Type - pick a PRIMARY type, optionally add ONE secondary (real findings are often compound, e.g. "race + lost update", "bad retry + duplicate side effect"). Choices: wrong result / crash / silent corruption / lost update / race / deadlock / null deref / resource leak / bad error path / state invariant violation / off-by-one / bounds violation / bad retry-or-timeout / other (specify).
5. Counter-example: a minimal input, interleaving, or state that triggers the bug. Be CONCRETE: "calling foo() with x=0 after bar() has set state to Y produces..."
6. Violated invariant: what assumption is broken. Reference the function's pre/post conditions or the module's documented contract if available.
7. Failing path: exact file:line, function-level trace from entry to failure.
8. Expected vs actual behavior: what should happen, what does happen.
9. Recommended fix: smallest safe change.
10. Instances: ALL file:line locations sharing this root cause.

If you cannot provide a counter-example, mark the issue as a NON-FINDING. Do not speculate.

Categories to scan:
- Edge cases: zero, negative, max value, empty collections, null/undefined, NaN, very long strings, Unicode quirks, locale/timezone/encoding quirks
- State invariants: can two valid operations leave the system in an invalid state?
- Concurrency: race conditions, lost updates, deadlocks, missing locks, check-then-act gaps
- Error paths: do errors leak resources? Leave state inconsistent? Get silently swallowed?
- Async / promise misuse: missing awaits, unhandled rejections, fire-and-forget that should be awaited
- Resource leaks: file handles, connections, subscriptions, timers not cleaned up
- Bounds: array indexing, string slicing, arithmetic overflow/underflow producing wrong values (unchecked bigint, Rust unchecked arithmetic, etc.)
- Retries / timeouts: missing backoff, idempotency assumptions, retry storms, timeout too short or too long
- Initialization order: using-before-init, partial init under errors
- Caching: stale data, missing invalidation, key collisions
- Floating-point: comparison without epsilon, NaN propagation, accumulation drift

DO NOT FLAG:
- Style or formatting (Biome / ESLint / Prettier handle).
- Type errors in strict-mode TypeScript that the typechecker actually catches. (Type-related bugs in loose TS, Python without strict typing, or any dynamic context ARE in scope.)
- Pre-existing issues unrelated to this cluster.
- "Could be cleaner" / "consider X" suggestions without a concrete counter-example.
- Intentional design choices that the code explicitly documents.
- Issues in test, demo, fixture, or migration code UNLESS that code is production-wired.
- Framework-default behavior (e.g., React's render-on-every-prop-change) UNLESS you can show a concrete failure.
- Dead-code claims in reflective / DI / framework-registration contexts UNLESS you can confirm the registration check (e.g., grep for the symbol in DI config, route definitions, decorators).
- Maintainability concerns (use /harden-quality).
```

## Effort knob

The effort knob scales agent intelligence and depth, NOT phase composition. All phases run at every level (Codex is never skipped, even at `low`).

**Model note.** This ladder names **Fable** as the top-tier Claude model (Phase 1 map and Phase 2 cluster agents at `max`/`ultra`; the Phase 3 coordinator at `high`). Run it on Fable when available (`Agent` tool: `model: 'fable'`); fall back to Opus 4.8 (1M context) (`model: 'opus'`) only when Fable is unavailable. This skill loads a single audit dimension (correctness only), so Fable runs every leg without falling back — that is the whole reason it exists as a separate skill. The Codex legs are unaffected either way.

| Effort | Phase 1 model | Phase 2 agents per cluster | Phase 2.5 cross-rebuttal | Phase 3 coordinator | Phase 4 verifier depth | Wall-clock (rough, 10 clusters) |
|--------|---------------|----------------------------|--------------------------|---------------------|-------------------------|----------------------------------|
| `low` | Haiku | 2: Claude Haiku + Codex (minimal effort) | NO | Sonnet | top 3 (severity-bucket prioritized) | ~10-15 min |
| `medium` | Sonnet | 2: Claude Sonnet + Codex (medium effort) | NO | Sonnet | top 5 (severity-bucket prioritized) | ~25-35 min |
| `high` (default) | Sonnet | 2: Claude Sonnet + Codex (xhigh) | YES (light pass) | Fable | top 10 (severity-bucket prioritized) | ~50-70 min |
| `max` | Fable | 2: Claude Fable + Codex (xhigh) | YES (full rebuttal) | Codex xhigh ¹ | all Major+ (severity-bucket prioritized) | ~80-100 min |
| `ultra` | Fable | 4: 2 Claude Fable + 2 Codex (xhigh, independent passes) | YES + Round 2 push-back (resume sessions) | Codex xhigh ¹ | all findings (severity-bucket prioritized) | ~130-200 min |

¹ Coordinator switches from Fable (`high`) to Codex xhigh (`max`+) DELIBERATELY: at `max`, the map phase is Claude-heavy. A Codex coordinator introduces cross-family judgment at the reduce stage, catching what Anthropic-family models share as blind spots. At `high`, Fable is sufficient because the map phase is more balanced. This is intentional heterogeneity, not arbitrary model selection.

`ultra` Round 2 push-back: resume the Phase 2 / 2.5 sessions with the prompt *"Look at your prior findings. What did you miss? What did you over-assert? What second-order failure modes did your initial review not surface? Where were you anchored on the cluster's framing instead of stress-testing it?"* (Same pattern as `/blueprint mega-deep`.)

Wall-clock estimates assume ~10 clusters; scales roughly linearly with cluster count.

## Severity framework (anchored)

- **Blocker**: persistent data loss / crash on common path / unrecoverable corruption that hits in production.
- **Critical**: high-impact bug, conditional on specific input or timing.
- **Major**: affects feature behavior, user-visible.
- **Minor**: limited impact or rare conditions.

No `Info` tier. If it's not a real bug, it's a non-finding. Repro confidence is independent; speculative findings (low repro confidence) are filtered at Phase 2 or dropped by the coordinator. Low-confidence Blocker/Critical findings are relabeled (`Potential Blocker` / `Potential Critical`), never silently kept.

## Output directory layout

```
audit/bugs/<YYYY-MM-DD>-<run-id>/
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
- **Ungrounded agent debate**: agents arguing without a concrete counter-example produce confidently wrong findings. Always demand a reproducing input or interleaving.
- **Self-consensus with one model**: two Claude agents agreeing means nothing. Cross-model (Claude + Codex) disagreement is the actual signal.
- **Severity without a counter-example**: a Blocker without a reproduction is wrong-severity, not just wrong-priority. Reject during reduce.
- **Reducers that merge by file:line**: dedupe by `root cause + failing operation + affected state`, not by location. The same off-by-one in 5 places is ONE finding (but list all 5 instances).
- **Free-form chain-of-thought in agent prompts**: does not outperform structured prompts. Use the structured certificate required above.
- **Unbounded inter-procedural exploration**: cap at ~4 functions of context, with handoff-edge escalation. Beyond that, hallucinations dominate.
- **Skipping the negative list**: the negative list cuts false positives more than any prompt-engineering trick.
- **Poisoned repo-map anchoring**: a wrong or partial Phase 1 map silently corrupts every downstream cluster. Hierarchical mapping for monorepos + cross-checking the map against the actual directory tree mitigates this.
- **Cluster-boundary blindness**: traces that cross clusters can disappear at the cap unless the handoff-edge escalation rule is applied.
- **Over-merging distinct findings during dedupe**: aggressive dedupe can collapse two different root causes that share a failing operation. Dedupe by root cause + operation + state, NOT by operation alone.
- **Verifier confirmation bias**: the verifier sees the prior claim and anchors. Mitigation: the verifier MUST re-read the source independently AND state its own conclusion before reading the prior claim.
- **Non-deterministic cluster naming**: if cluster names drift between runs, runs become hard to compare. Use stable, hash-of-cluster-content-or-path-based names.

## What `/harden-bugs` is NOT

- NOT for diff-only review (use `/code-review max --fix`).
- NOT a maintainability pass (use `/harden-quality`).
- NOT a substitute for human review on Blocker findings. Verify before acting.
- NOT idempotent: rerunning on the same codebase gives slightly different results (different model rollouts, agent contexts). Cross-run agreement is signal.
- NOT composed with `/blueprint`. The report is the deliverable. The user decides what to fix.
