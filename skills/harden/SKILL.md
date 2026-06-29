---
name: harden
description: Whole-codebase audit skill with three focuses (security / bugs / quality) and five effort levels (low / medium / high / max / ultra). Map-reduce protocol with parallel Claude + Codex agents per cluster, coordinator-of-specialists shape (Cloudflare-style). Produces impact-bucketed reports under `audit/<focus>/<date-run-id>/`. Use when finishing a vibecoded project that needs cleanup passes before shipping, or any time the user wants a whole-codebase scan rather than a diff review. Trigger phrases include "/harden security", "/harden bugs", "/harden quality", "audit this codebase for X", "whole repo review", "bug hunt", "security pass", "maintainability audit", "scan this repo". Auto-fire ONLY on explicit audit verbs (audit / scan / whole repo review / bug hunt / security pass / maintainability audit), NOT on generic "shipping prep" or "implementation help" language. If the user invokes bare `/harden` or "harden this app" without specifying focus, ask which focus they want (security / bugs / quality / all three sequentially) before proceeding. NOT for diff-only review (use /code-review) and NOT for smart contracts (out of scope — Solidity/Noir/Aztec.nr need a smart-contract-specialized audit).
---

# Harden

Whole-codebase audit skill. Three focuses, five effort levels, map-reduce protocol with parallel Claude + Codex agents and a coordinator-of-specialists shape.

## Invocation

```
/harden <focus> [effort]
```

- `<focus>` (required): `security` | `bugs` | `quality`
- `[effort]` (default `high`): `low` | `medium` | `high` | `max` | `ultra`

Examples:
- `/harden security` runs a security audit at default `high` effort.
- `/harden quality max` runs a quality pass at `max` effort.
- `/harden bugs ultra` runs the most thorough (and slowest) bug hunt.

If the user invokes bare `/harden` or "harden this app" without specifying a focus, ASK which focus they want (security / bugs / quality / all three sequentially) before proceeding.

## Routing rule (which focus to pick)

A finding belongs to AT MOST ONE focus. When ambiguous, apply this rule:

- **`security`** if an untrusted or over-privileged actor can violate confidentiality, integrity, authorization, or availability (covers accidental data exposure, over-broad authz, secret leakage to logs, even without overt "attacker action").
- **`bugs`** if normal operation triggers a wrong result, crash, corruption, or invariant violation, AND the primary impact is NOT a security-property violation.
- **`quality`** only if behavior is currently correct and the finding is about maintainability or change cost.

**Tiebreaker**: if BOTH security and bugs apply, route to **security** when the primary impact is a security-property violation. A correctness bug an attacker can leverage routes to security; one that only confuses users routes to bugs.

## Protocol

The phases are identical across focuses; only the prompts and severity frameworks differ.

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
> 3. **Trust boundaries**: auth/session/secrets handling, external API calls, user-input sinks, file/DB writes.
> 4. **Dependency graph**: which modules import which (one level deep).
> 5. **Frameworks in use**: web frameworks, ORMs, validation libs, crypto libs, DI containers, event buses.
> 6. **Test surfaces**: where tests live, what coverage looks like (rough).
> 7. **Generated / vendored / fixture code**: paths that should be excluded from finding-eligibility unless production-wired.

Save to `audit/<focus>/<run-id>/raw/repo-map.md` (flat) or `audit/<focus>/<run-id>/raw/repo-map/<package>.md` (hierarchical, per package).

Effort scales which model is used (Haiku at `low`, Sonnet at `medium`+, Fable at `max`+). **While Fable is deactivated, use Opus 4.8 (1M context) in its place** — see the Model note under Effort knob.

### Phase 2: Map (parallel agents per cluster)

Cluster the repo into bounded units. Do NOT run agents on raw files at random. The main agent (you) decides clusters from the Phase 1 output. Cluster routes differ by focus:

- **`security`**: by **entrypoint** (each HTTP route + its handlers + sinks) and by **sink family** (DB writes, file writes, external calls, deserialization, eval). Trust-boundary-crossing flows each get their own cluster.
- **`bugs`**: by **state owner** (modules that own mutable state) and by **call graph** (functions that share callers or callees). Error-path-heavy modules get their own cluster.
- **`quality`**: by **package boundary** and by **similarity** (modules that look like they might duplicate each other based on the repo map).

For each cluster, spawn TWO agents in parallel (always, regardless of effort level):

- **Claude agent** (model per effort level, see Effort knob below).
- **Codex agent** via `/codex` at matching codex effort level (read-only sandbox). At `low` effort, codex runs at minimal effort but still runs. Codex is never skipped: keeping cross-model coverage constant across all tiers is non-negotiable (different model families catch different blind spots).

Each agent receives:
- The cluster's source code.
- Repo-map summaries of the dependencies the cluster imports (NOT full source code of dependencies).
- The focus-specific prompt (see Per-focus prompts below).
- The negative list (what NOT to flag).

**Context cap with handoff-edge escalation**: in-cluster traces are capped at ~4 functions of inter-procedural context (RepoAudit guidance; beyond that, hallucination rates spike). However, the cap **escalates across cluster boundaries** when the trace would cross a **handoff edge**:
- Event emit → listener
- DI inject site → consumer
- RPC / message-queue produce → consume
- Framework hook → handler (e.g., middleware → route)

For each handoff edge, the agent can request the handoff target's signature plus its immediate handler (one function) without violating the cap. This catches event-driven, DI-heavy, and cross-service flows that the hard cap would miss.

Output per agent goes to:
- `audit/<focus>/<run-id>/raw/<cluster>-claude.md`
- `audit/<focus>/<run-id>/raw/<cluster>-codex.md`

### Phase 2.5: Cross-rebuttal (only at `high` effort and above)

This phase exists only at `high`, `max`, and `ultra` effort levels. It widens the methodological gap with `medium` (where the two agents stay blind to each other).

After Phase 2 raw findings are saved, spawn a brief cross-rebuttal pass per cluster:

- Claude agent reads Codex's raw findings AND its own, then adds: "what did Codex miss? What looks overconfident in Codex's claims?"
- Codex agent reads Claude's raw findings AND its own, then adds the same challenge.

Each agent appends to its own raw file (`<cluster>-claude.md` and `<cluster>-codex.md`) with a `## Cross-rebuttal` section. At `max`, this is a full rebuttal pass (substantive challenge per finding). At `ultra`, it runs twice (Round 2 push-back as well; see Effort knob).

### Phase 3: Reduce (coordinator/judge)

Spawn ONE coordinator agent (top-tier model per effort level). Inputs: all raw findings from Phase 2 + 2.5.

Coordinator tasks:

1. **Deduplicate by root cause + sink + impacted boundary**. Same root cause appearing in N places is ONE finding, not N. BUT: each finding must include an `instances` list of ALL N locations so remediation scope is accurate. A single SQLi root cause appearing in 5 places gets reported as one finding with `instances: [file1:L42, file2:L77, file3:L101, ...]`.
2. **Resolve cross-model disagreements**. When Claude flagged and Codex did not (or vice versa), keep the finding but mark `cross-model disagreement` as a confidence signal. Convergence is the strongest evidence available.
3. **Drop speculative findings**. No concrete trace = drop. No exception. "Could be vulnerable" without a source-to-sink path is noise.
4. **Apply focus-specific severity** (see Severity frameworks). For security, assign CVSS bands HERE at the reduce stage (not at Phase 2 where bands drift). For bugs, anchor severity per the concrete-anchor rubric. For quality, weight maintenance impact by blast radius + change frequency.
5. **Surface cross-cutting findings** that span multiple clusters (taint paths crossing modules, duplication across packages, inconsistencies in error handling).
6. **Sanity check finding density**: aim for ~1.2 findings per cluster on average (Cloudflare's production target). Higher counts suggest the negative list is failing; rerun with stricter filters if needed.

Why the coordinator model changes between effort levels (Fable at `high`, Codex xhigh at `max`+): at `max` effort, the map phase is Claude-heavy (Fable + Fable rebuttal + Codex). A Codex coordinator at `max` introduces deliberate cross-family judgment at the reduce stage, catching what Anthropic-family models share as blind spots. At `high`, the Fable coordinator is sufficient since the map phase is more balanced.

Save to `audit/<focus>/<run-id>/findings/consolidated.md`.

### Phase 4: Verifier pass (by severity bucket, not top-N rank)

For findings flagged by Phase 3, run a verifier pass prioritized BY SEVERITY BUCKET (NOT by top-N rank). This prevents a rare Critical from being crowded out by many High findings.

Order: ALL Critical → ALL High → ALL Medium (up to the effort-level cap) → Low (if budget remains).

For each verified finding (Claude + Codex disagree-then-converge):

1. Re-read the finding's claimed trace against the actual source.
2. Confirm or refute the finding.
3. Strengthen the trace: exact `file:line(s)`, full source-to-sink path (security), counter-example input or interleaving (bugs), or specific duplicated locations (quality).
4. Refine the fix recommendation: smallest safe change, references to existing patterns in the codebase.
5. Final confidence: `high` (trace verified by both models), `moderate` (one confirmed, other unsure), `low` (kept but flagged).
6. **Low-confidence Critical** gets relabeled to `Potential Critical` (not silently kept as Critical). Same pattern for Blocker / High at low confidence.

Save to `audit/<focus>/<run-id>/findings/verified.md`.

### Phase 5: Report

Two artifacts: a structured `report.md` (always), and a standalone `report.html` companion (currently security focus only; see "HTML companion" below for extension to bugs/quality).

#### Markdown report — `audit/<focus>/<run-id>/report.md`

```markdown
# Harden Report: <focus>
**Repo:** <path/name>
**Date:** YYYY-MM-DD
**Effort:** <level>
**Run ID:** <id>
**Models:** <models used per phase>
**Scope:** <what was audited, what was excluded>

## Executive summary
2-3 paragraphs: what was audited, headline findings, recommended priorities.

## Methodology
Map-reduce shape, agent count per cluster, models per phase, cap on inter-procedural context, handoff-edge escalation policy, negative list applied. State any unattended-fallback assumptions explicitly. **Document deviations from the formal effort spec explicitly** (e.g., "ran 1 Claude + 1 Codex per cluster instead of 2 of each; absorbed Phase 2.5 rebuttal into Phase 3 coordinator dedup"). Honest deviation notes are more useful than pretending the spec was followed.

## Findings

### [<IMPACT>] <Finding ID>: <Title>
**Impact:** <focus-appropriate label: CVSS band for security, Blocker/Critical/Major/Minor for bugs, architectural/structural/local/cosmetic + blast radius for quality>
**Confidence:** <high | moderate | low>
**Mapping:** <OWASP/CWE for security, bug-type for bugs, Fowler smell or analog for quality>
**Found by:** <claude | codex | both>

**Instances** (all locations sharing this root cause):
- `file1:line(s)`
- `file2:line(s)`
- ...

**Description**: what the issue is, in plain language.

**Trace** (focus-specific):
- security: source → sanitizer gap → sink, file:line at each step
- bugs: minimal counter-example input or interleaving + violated invariant + failing path
- quality: concrete locations + coupling diagram or dead-code evidence

**Why it matters**: real impact, with blast radius and change-frequency notes for quality findings.

**Recommended fix**: smallest safe change. Reference existing patterns in the codebase if relevant.

**Effort estimate**: hours / days / weeks.

---

## Findings NOT pursued (with reasoning)
One line each. Things the agents flagged that were dropped during reduce or verifier.

## Cross-cutting observations
Patterns that span multiple clusters and are worth tracking even if not actionable per-finding.
```

#### HTML companion — `audit/<focus>/<run-id>/report.html`

**Currently scoped to security focus.** Bugs and quality should follow the same shape later (per-finding ELI5 + collapsible technical trace) — but the language inside each section needs to change for those focuses ("what an attacker would do" → "what a user would trigger" for bugs; → "what gets harder to change" for quality). Don't ship the HTML companion for bugs/quality with security wording.

The HTML companion is a **standalone single-file HTML** (no external CSS, no JavaScript dependencies, no build step) optimized for stakeholders who need to read findings without reading code. It complements the markdown by:

1. **Per-finding ELI5 block** (3 short paragraphs, before the technical trace):
   - **What it is** — plain-language explanation of the issue with enough background context that a non-engineer understands what's wrong. Avoid jargon; if a term is unavoidable, define it inline.
   - **What an attacker would do** (security) / **What a user would trigger** (bugs) / **What gets harder to change** (quality) — a concrete scenario in real terms. Use realistic examples (Cyrillic 'c' in "USDC", iframe inheriting parent's permissions, "Token.transfer" with hidden args).
   - **The fix** — what to do, in plain language. Mention if a similar pattern already exists in the codebase ("the same check already lives in `exportPlain`; just mirror it").

2. **Technical trace** tucked behind `<details>` collapsibles — the full file:line citations, recommended fix, and any notes from the markdown finding. Default-collapsed so the page reads fast.

3. **Top-of-page stat strip** — total / Critical / High / Medium / Low counts as visual chips.

4. **"Cheapest fixes first" callout** — green-bordered callout near the top listing the 2-3 findings that are hours of work (vs days/weeks). These are the ones to land in the first PR.

5. **Coupled-pair callouts** — amber-bordered callouts for findings that should ship together (e.g., F-001 + F-002 in the reference run were both about frame-vs-tab trust scoping).

6. **Cross-cutting observations** rendered as their own H3 sections (not nested inside any finding), with the architectural theme explained in 1-2 paragraphs.

7. **Footer** linking to the markdown report, consolidated/verified findings, and raw cluster outputs. Use **relative links** — the HTML file lives alongside these artifacts in the audit dir; never write absolute paths into committed HTML.

**Design constraints** (do not deviate without a reason):
- Plain typography (system font stack), generous whitespace, max-width ~820px for readability.
- Auto dark-mode via `@media (prefers-color-scheme: dark)` — define CSS custom properties for `--bg`, `--fg`, `--muted`, `--hairline`, `--surface`, `--code`, `--link`, `--high`, `--high-bg`, `--med`, `--med-bg`, `--low`, `--low-bg`, `--green`, `--green-bg`. Switch values inside the media query.
- Severity chips: red palette for High/Critical/Blocker, amber for Medium/Major, gray for Low/Minor/Info.
- Code references stay as inline `<code>` (e.g., `wallet-bridge/dispatcher.ts:288-317`) — never use full filesystem paths. Repo-relative only.
- One finding = one `.finding` block (`background: var(--surface)`, `border: 1px solid var(--hairline)`, `border-radius: 8px`, padding ~1.2rem).
- No JavaScript. `<details>` is the only interactive element. Page must work with JS disabled.
- File size budget: ~30-50KB for ~10-15 findings.

**HTML scaffold reference** — copy `report-template.html` (bundled next to this SKILL.md) for new runs, then fill in per-finding content. It implements every design constraint above with placeholder findings. Key structural elements:

```html
<div class="finding">
  <div class="finding-header">
    <span class="chip chip-high">High</span>
    <span class="finding-id">F-XXX</span>
    <span class="finding-title"><finding title></span>
  </div>

  <div class="meta-line">
    <span class="chip chip-info">Found by Claude+Codex</span>
    &nbsp;<span class="chip chip-info">confidence: high</span>
    &nbsp;<span class="chip chip-info">CWE-NNN</span>
    &nbsp;<span class="chip chip-info">fix: hours · CHEAPEST</span>
  </div>

  <div class="eli5">
    <p><strong>What it is.</strong> <plain-language explanation></p>
    <p><strong>What an attacker would do.</strong> <concrete scenario></p>
    <p><strong>The fix.</strong> <plain-language remediation></p>
  </div>

  <details>
    <summary>Technical trace</summary>
    <p><strong>Trace</strong>: <full file:line citations></p>
    <p><strong>Fix</strong>: <exact code-level recommendation></p>
  </details>
</div>
```

**When to write the HTML companion**: ALWAYS for security focus. Mark "TODO" in the report.md if bugs/quality and skip the HTML for now — the per-finding ELI5 language needs domain-specific phrasing the security shape doesn't cover.

**Reporting back to the user at end-of-task**: give the absolute path to `report.html` so they can click-to-open from the terminal. The HTML is the primary stakeholder-facing artifact; the markdown is the engineering-facing artifact.

## Per-focus prompts

The prompts below are the EXACT prompts sent to Phase 2 agents and reused for Phase 4 verification. Language-agnostic, web/backend focus (smart contracts are out of scope — they need a smart-contract-specialized audit).

### `security` prompt

```
You are auditing a code cluster for SECURITY vulnerabilities. Mindset: adversarial. Assume an attacker is actively trying to exploit this code OR that an untrusted/over-privileged actor can violate a security property.

Find ONLY issues where an untrusted or over-privileged actor can violate confidentiality, integrity, authorization, or availability. This covers attacker-driven exploits AND accidental violations (e.g. secret leakage to logs, over-broad authz, unintended public data exposure).

For each finding, you MUST provide:

1. Title: concise.
2. Impact factors (Phase 3 will assign the CVSS v4.0 band): describe impact (CIA+A property violated, blast radius) AND exploitability factors (attack vector, attack complexity, privileges required, user interaction). Do NOT assign a CVSS band yourself.
3. Evidence confidence: high / moderate / low.
4. OWASP / CWE mapping: which OWASP Top 10 category, which CWE number (cite from current Top 25).
5. Trace: exact source (where untrusted input enters, or where over-privileged access is granted) → sink (where harm manifests), with file:line at every step.
6. Missing control: what validation / sanitization / authn / authz / scope-narrowing is absent at that path.
7. Exploit story or violation scenario: step-by-step how the violation occurs, with realistic inputs or conditions.
8. Preconditions: what must be true (configuration, role, attacker capabilities) for the violation to occur.
9. Why mitigations fail: if you considered existing defenses (input validation elsewhere, framework protections), explain why they do not cover this path.
10. Instances: ALL file:line locations sharing this root cause (Phase 3 dedupes by root cause but tracks every instance).

If you cannot provide a concrete trace, mark the issue as a NON-FINDING. Do not speculate.

Categories to scan (CWE numbers from current Top 25 — 2024/2025 list):
- Injection: SQL (CWE-89), OS command (CWE-78), code (CWE-94), SSTI / template injection, XXE
- XSS (CWE-79): reflected, stored, DOM
- SSRF (CWE-918)
- Path Traversal (CWE-22), Unrestricted File Upload (CWE-434)
- Auth: missing (CWE-306), improper (CWE-287), hard-coded credentials (CWE-798)
- Authz: missing (CWE-862), incorrect (CWE-863), improper privilege management (CWE-269), over-broad scopes
- Sessions: fixation, hijacking, missing rotation, missing expiry
- Deserialization (CWE-502)
- CSRF (CWE-352)
- Open redirect, token leakage in URLs / referrers / logs
- CORS misconfiguration
- HTTP request smuggling, cache poisoning
- Prototype pollution (JS), pickle / deserialization gadgets (Python)
- Crypto misuse: weak algorithms, hardcoded keys, missing IVs, predictable randomness, missing integrity
- Sensitive data exposure (CWE-200), insufficient credential protection (CWE-522)
- DoS / resource exhaustion: unbounded loops, regex catastrophic backtracking, file-handle exhaustion, memory bombs
- Trust boundary violations: implicit trust of input that should not be trusted

NOTES (not findings unless reachable exploit path is concrete):
- Logging gaps for security-relevant events: noted in cross-cutting observations, not as findings unless a detection-failure scenario is concrete.
- Outdated packages with known CVEs: flagged for separate dependency-audit verification, not as findings unless the vulnerable code path is reachable.

DO NOT FLAG:
- Theoretical risks with no exploit path.
- Defense-in-depth suggestions ("you could also validate here") without a concrete vector.
- Framework-default protections (CSRF tokens, HTTPS-only cookies, secure headers from helmet/Spring Security/etc.) UNLESS you can show a concrete bypass.
- Issues in test, demo, fixture, or migration code UNLESS that code is production-wired (imported by production paths, exposed via prod build, or shipped with the binary).
- Generic "consider input validation" notes without a concrete source-to-sink trace.
- Smart contract vulnerabilities (out of scope — use a smart-contract-specialized audit).
- Pre-existing issues unrelated to this cluster.
- Quality or maintainability concerns (use /harden quality).
```

### `bugs` prompt

```
You are auditing a code cluster for CORRECTNESS BUGS. Mindset: normal-operation failure. Assume a user (not an attacker) hits an edge case, OR a non-adversarial environmental condition (timing, concurrency, missing data, latency) causes a failure.

Find ONLY issues that produce wrong results, crashes, data corruption, lost updates, or invariant violations during normal use. An issue qualifies if a confused-but-non-malicious user can trigger it, OR a non-adversarial condition can trigger it.

If the primary impact is a security-property violation (an attacker can leverage it), route to `/harden security` instead. The routing rule's tiebreaker: security takes precedence when primary impact is security-property.

For each finding, you MUST provide a structured logical certificate:

1. Title: concise.
2. Severity (use these anchors precisely):
   - Blocker: persistent data loss / crash on common path / unrecoverable corruption that hits in production.
   - Critical: high-impact bug under realistic conditions but conditional (specific input, timing, state).
   - Major: affects feature behavior, user-visible.
   - Minor: limited impact or rare conditions.
   (No "Info" tier - if it's not a real bug per "wrong result / crash / corruption / invariant violation", it's a non-finding.)
3. Repro confidence: high / moderate / low. Findings with low repro confidence should NOT be reported (filter at Phase 2; coordinator drops any that slip through).
4. Type — pick a PRIMARY type, optionally add ONE secondary (real findings are often compound, e.g. "race + lost update", "bad retry + duplicate side effect"). Choices: wrong result / crash / silent corruption / lost update / race / deadlock / null deref / resource leak / bad error path / state invariant violation / off-by-one / bounds violation / bad retry-or-timeout / other (specify).
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
- Concurrency: race conditions, lost updates, deadlocks, missing locks, TOCTOU
- Error paths: do errors leak resources? Leave state inconsistent? Get silently swallowed?
- Async / promise misuse: missing awaits, unhandled rejections, fire-and-forget that should be awaited
- Resource leaks: file handles, connections, subscriptions, timers not cleaned up
- Bounds: array indexing, string slicing, integer overflow (esp. unchecked arithmetic in bigint, Rust unchecked, etc.)
- Retries / timeouts: missing backoff, idempotency assumptions, retry storms, timeout too short or too long
- Initialization order: using-before-init, partial init under errors
- Caching: stale data, missing invalidation, key collisions
- Floating-point: comparison without epsilon, NaN propagation, accumulation drift

DO NOT FLAG:
- Security issues (use /harden security per the routing rule).
- Style or formatting (Biome / ESLint / Prettier handle).
- Type errors in strict-mode TypeScript that the typechecker actually catches. (Type-related bugs in loose TS, Python without strict typing, or any dynamic context ARE in scope.)
- Pre-existing issues unrelated to this cluster.
- "Could be cleaner" / "consider X" suggestions without a concrete counter-example.
- Intentional design choices that the code explicitly documents.
- Issues in test, demo, fixture, or migration code UNLESS that code is production-wired.
- Framework-default behavior (e.g., React's render-on-every-prop-change) UNLESS you can show a concrete failure.
- Dead-code claims in reflective / DI / framework-registration contexts UNLESS you can confirm the registration check (e.g., grep for the symbol in DI config, route definitions, decorators).
- Quality / maintainability concerns (use /harden quality).
```

### `quality` prompt

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

3. Maintenance impact (NOT severity in the security sense). Use the four buckets BUT also weight by blast radius and change frequency:
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
- Security or correctness issues (other focuses).
- Pre-existing patterns the codebase consistently uses UNLESS they create measurable duplication, coupling, or change amplification. (Conventions are not smells unless they cost something.)
- Issues in test, demo, fixture, or migration code UNLESS that code is production-wired.
- Dead-code claims in reflective / DI / framework-registration contexts UNLESS you can confirm no registration covers it.
- Framework defaults you would override with no clear gain.
```

## Effort knob

The effort knob scales agent intelligence and depth, NOT phase composition. All phases run at every level (Codex is never skipped, even at `low`).

**Model note — Fable → Opus fallback.** This ladder names **Fable** as the top-tier Claude model (Phase 1 map and Phase 2 cluster agents at `max`/`ultra`; the Phase 3 coordinator at `high`). **Fable is currently deactivated — wherever this skill says "Fable", substitute Opus 4.8 (1M context)** (`Agent` tool: `model: 'opus'`) until Fable returns, then prefer Fable again. This swaps only the concrete model; the map-reduce shape, per-cluster agent counts, and the cross-family Codex coordination (footnote ¹) are unchanged. The Codex legs are unaffected.

| Effort | Phase 1 model | Phase 2 agents per cluster | Phase 2.5 cross-rebuttal | Phase 3 coordinator | Phase 4 verifier depth | Wall-clock (rough, 10 clusters) |
|--------|---------------|----------------------------|--------------------------|---------------------|-------------------------|----------------------------------|
| `low` | Haiku | 2: Claude Haiku + Codex (minimal effort) | NO | Sonnet | top 3 (severity-bucket prioritized) | ~10-15 min |
| `medium` | Sonnet | 2: Claude Sonnet + Codex (medium effort) | NO | Sonnet | top 5 (severity-bucket prioritized) | ~25-35 min |
| `high` (default) | Sonnet | 2: Claude Sonnet + Codex (xhigh) | YES (light pass) | Fable | top 10 (severity-bucket prioritized) | ~50-70 min |
| `max` | Fable | 2: Claude Fable + Codex (xhigh) | YES (full rebuttal) | Codex xhigh ¹ | all Medium+ (severity-bucket prioritized) | ~80-100 min |
| `ultra` | Fable | 4: 2 Claude Fable + 2 Codex (xhigh, independent passes) | YES + Round 2 push-back (resume sessions) | Codex xhigh ¹ | all findings (severity-bucket prioritized) | ~130-200 min |

¹ Coordinator switches from Fable (`high`) to Codex xhigh (`max`+) DELIBERATELY: at `max`, the map phase is Claude-heavy. A Codex coordinator introduces cross-family judgment at the reduce stage, catching what Anthropic-family models share as blind spots. At `high`, Fable is sufficient because the map phase is more balanced. This is intentional heterogeneity, not arbitrary model selection.

`ultra` Round 2 push-back: resume the Phase 2 / 2.5 sessions with the prompt *"Look at your prior findings. What did you miss? What did you over-assert? What second-order risks did your initial review not surface? Where were you anchored on the cluster's framing instead of attacking it?"* (Same pattern as `/plan mega-deep`.)

Wall-clock estimates assume ~10 clusters; scales roughly linearly with cluster count.

## Severity frameworks (per focus)

### `security` impact factors → CVSS band

Phase 2 agents do NOT assign CVSS bands directly (would drift across runs). They report **impact factors** and **exploitability factors**:

- Impact: which CIA+A property is violated, blast radius (single user, all users, system-wide), data sensitivity.
- Exploitability: attack vector (network / adjacent / local / physical), attack complexity (low / high), privileges required (none / low / high), user interaction (none / required).

Phase 3 coordinator assigns the final CVSS v4.0 band:
- Critical (9.0-10.0): exploit chain credible AND high impact (RCE, full auth bypass, mass exfiltration of sensitive data).
- High (7.0-8.9): significant impact, exploit requires specific conditions but realistic.
- Medium (4.0-6.9): limited impact OR unusual conditions.
- Low (0.1-3.9): minor impact, defense-in-depth at edge of attack surface.

Low-confidence Critical findings are relabeled to `Potential Critical` (NOT silently kept as Critical). Same pattern for Blocker/High at low confidence.

### `bugs` severity (anchored)

- **Blocker**: persistent data loss / crash on common path / unrecoverable corruption that hits in production. (No "security-adjacent" here; routing rule sends security to `/harden security`.)
- **Critical**: high-impact bug, conditional on specific input or timing.
- **Major**: affects feature behavior, user-visible.
- **Minor**: limited impact or rare conditions.

No `Info` tier. If it's not a real bug, it's a non-finding.

Repro confidence is independent. Speculative findings (low repro confidence) are filtered at Phase 2 or dropped by the coordinator.

### `quality` maintenance impact + weighting

Four scope buckets:
- architectural: wrong abstraction at module/package level
- structural: wrong shape within a module
- local: within a single function/file
- cosmetic: minor

Plus weighting by **blast radius** (how many files/modules touched by this smell) and **change frequency** (how often the affected code is modified, from git history if available). Priority = scope × blast radius × change frequency.

A `local` duplication touched weekly may rank higher than a dormant `architectural` smell. The report's Findings table sorts by computed priority, not just scope.

## Output directory layout

```
audit/<focus>/<YYYY-MM-DD>-<run-id>/
├── raw/
│   ├── repo-map.md                   # flat (single-codebase) OR
│   ├── repo-map/<package>.md         # hierarchical (monorepo)
│   ├── <cluster-1>-claude.md         # Phase 2 raw + Phase 2.5 cross-rebuttal appended
│   ├── <cluster-1>-codex.md
│   ├── <cluster-2>-claude.md
│   └── ...
├── findings/
│   ├── consolidated.md               # after Phase 3 reduce
│   └── verified.md                   # after Phase 4 verifier
├── report.md                         # Phase 5 markdown report (always)
└── report.html                       # Phase 5 HTML companion (security focus only today; extend to bugs/quality later)
```

Multiple runs on the same codebase get separate dated directories; they do not overwrite each other. Compare runs by reading multiple `report.md` files side by side.

**`report.html` is the stakeholder-facing primary artifact for security audits.** Always write it (for security focus). It gets opened by non-engineers and engineers alike to triage and prioritize; the markdown is the engineering-detail companion. For bugs/quality, the HTML companion needs domain-specific phrasing (see Phase 5) and should NOT be written until the language is adapted — security wording on a quality report misleads readers.

## Known failure modes (avoid these)

From the multi-agent LLM auditing literature plus codex-flagged failure modes specific to this skill:

- **Monolithic single-agent on whole repo**: hallucinations spike on graphs with millions of edges. The phase structure exists for this reason. Do not skip it.
- **Ungrounded agent debate**: agents arguing without trace evidence produce confidently wrong findings. Always demand source-to-sink (security), counter-example (bugs), or named smell (quality).
- **Self-consensus with one model**: two Claude agents agreeing means nothing. Cross-model (Claude + Codex) disagreement is the actual signal.
- **Severity without trace**: a Critical finding without an exploit path is wrong-severity, not just wrong-priority. Reject during reduce.
- **Reducers that merge by file:line**: dedupe by `root cause + sink + impacted boundary`, not by location. The same SQLi pattern in 5 places is ONE finding (but list all 5 instances).
- **Free-form chain-of-thought in agent prompts**: does not outperform structured prompts. Use the structured certificates required by the focus prompts.
- **Unbounded inter-procedural exploration**: cap at ~4 functions of context, with handoff-edge escalation. Beyond that, hallucinations dominate.
- **Skipping the negative list**: the negative list cuts false positives more than any prompt-engineering trick.
- **Poisoned repo-map anchoring**: a wrong or partial Phase 1 map silently corrupts every downstream cluster. Hierarchical mapping for monorepos + cross-checking the map against actual directory tree mitigates this.
- **Cluster-boundary blindness**: traces that cross clusters can disappear at the cap unless the handoff-edge escalation rule is applied.
- **Over-merging distinct findings during dedupe**: aggressive dedupe can collapse two different root causes that share a sink. Dedupe by root cause + sink + boundary, NOT by sink alone.
- **Verifier confirmation bias**: the verifier sees the prior claim and anchors. Mitigation: the verifier MUST re-read the source independently AND state its own conclusion before reading the prior claim.
- **Non-deterministic cluster naming**: if cluster names drift between runs (e.g. "auth-handlers" vs "auth-cluster-1"), runs become hard to compare. Use stable, hash-of-cluster-content-or-path-based names.

## What `/harden` is NOT

- NOT for diff-only review (use `/code-review max --fix`).
- NOT for smart contracts (out of scope: Solidity/Noir/Aztec.nr need a smart-contract-specialized audit).
- NOT a substitute for human review on critical findings. Verify before acting on Critical / Blocker.
- NOT idempotent: rerunning on the same codebase gives slightly different results (different model rollouts, agent contexts). Cross-run agreement is signal.
- NOT composed with `/blueprint`. The report is the deliverable. The user decides what to fix; `/blueprint` is a separate skill for implementing fixes if the user chooses to.
