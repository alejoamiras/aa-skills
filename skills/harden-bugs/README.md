# harden-bugs

A **whole-codebase correctness audit** — not a diff review, not a maintainability pass. One focus (bugs), five effort levels (`low` → `ultra`). Built as a map-reduce over parallel cross-model agents with a coordinator-of-specialists shape, drawing on the multi-agent auditing literature (RepoAudit's inter-procedural context caps, Cloudflare's coordinator pattern and ~1.2-findings-per-cluster density target, diverse-ensemble verification).

> This README explains the concepts. The exact prompt and protocol live in [`SKILL.md`](SKILL.md) — if they ever disagree, SKILL.md wins.

## Why it exists as a separate skill

`/harden` bundles three focuses (security / bugs / quality) into one skill. That means running a bug hunt through it pulls the security prompt into context too — and Fable ships extra safety measures for dual-use capabilities, so a combined run gets deflected or downgraded off Fable. `harden-bugs` is a faithful clone of the harness with **every trace of security language removed**, so it runs clean on any model, Fable included. Same phases, same cross-model rigor, correctness only.

## Invocation

```
/harden-bugs [low|medium|high|max|ultra]   # effort defaults to high
```

A finding qualifies only if normal operation produces a wrong result, crash, corruption, lost update, or invariant violation — triggered by an ordinary user or a non-hostile environmental condition (timing, concurrency, missing data). Maintainability goes to `/harden-quality`.

## How the harness works

```mermaid
flowchart TD
    S0["Phase 0 — scope confirm"] --> S1["Phase 1 — repo map (hierarchical for monorepos)"]
    S1 --> CL["Main agent clusters the repo — by state owner + call graph"]
    CL --> A["Claude agent per cluster"]
    CL --> B["Codex agent per cluster"]
    A --> R["Phase 2.5 — cross-rebuttal (high effort and above)"]
    B --> R
    R --> S3["Phase 3 — coordinator reduce: dedupe by root cause, resolve cross-model disagreements, anchor severity"]
    S3 --> S4["Phase 4 — verifier pass, by severity bucket"]
    S4 --> S5["Phase 5 — report.md (+ optional report.html)"]
```

The design decisions that matter:

- **Map before audit.** A structured repo map (entrypoints, state owners, dependency edges, generated-code exclusions) is built first; agents audit *clusters* derived from it, never random files. Monorepos get two-level hierarchical mapping so one bad map can't poison every downstream phase.
- **Cross-model always.** Every cluster gets a Claude agent *and* a Codex agent, at every effort level. Two same-family agents agreeing means nothing; cross-family convergence is the strongest confidence signal available, and disagreement is itself recorded as a signal.
- **Evidence or it doesn't exist.** Every finding needs a minimal counter-example — a reproducing input, interleaving, or state — plus the violated invariant. "Could break" is a non-finding by construction. The negative list (what NOT to flag) cuts more false positives than any prompting trick.
- **Bounded context.** In-cluster traces cap at ~4 functions of inter-procedural depth (beyond that, hallucination rates spike), with an escalation rule for handoff edges (event→listener, DI inject→consumer, hook→handler) so event-driven flows don't vanish at cluster boundaries.
- **Dedupe by root cause, not location.** The same off-by-one in 5 places is one finding with 5 `instances` — remediation scope stays accurate without inflating counts.
- **Anchoring-guarded verification.** The verifier re-reads the source and states its own conclusion *before* seeing the original claim, ordered by severity bucket so a lone Blocker is never crowded out by many Majors. Low-confidence Blockers get relabeled `Potential Blocker`, never silently kept.

## What each effort level differentiates

Effort scales **agent intelligence and depth, never phase composition** — all phases run at every level.

| Effort | Map | Per-cluster agents | Cross-rebuttal | Coordinator | Verification |
|---|---|---|---|---|---|
| `low` | Haiku | Claude Haiku + Codex (minimal) | — | Sonnet | top 3 |
| `medium` | Sonnet | Claude Sonnet + Codex (medium) | — | Sonnet | top 5 |
| `high` ← default | Sonnet | Claude Sonnet + Codex (xhigh) | light | Fable | top 10 |
| `max` | Fable | Claude Fable + Codex (xhigh) | full | Codex xhigh | all Major+ |
| `ultra` | Fable | 2× Claude Fable + 2× Codex, independent passes | full + Round 2 push-back | Codex xhigh | everything |

The coordinator deliberately switches family at `max`+: the map phase becomes Claude-heavy there, so a Codex judge at the reduce stage catches what Anthropic-family models share as blind spots. Fable is the top-tier Claude model; runs fall back to Opus 4.8 (1M context) only if Fable is unavailable.

## Severity (anchored)

Blocker (data loss / crash on a common path) → Critical (high-impact but conditional) → Major (user-visible feature behavior) → Minor. No "Info" tier: not a real bug, not a finding. Repro confidence is tracked independently; low-confidence findings are filtered out.

## Output

```
audit/bugs/<YYYY-MM-DD>-<run-id>/
├── raw/         # repo map + per-cluster agent outputs (+ rebuttals)
├── findings/    # consolidated.md, verified.md
├── report.md    # engineering-facing (always)
└── report.html  # stakeholder-facing (optional)
```

The optional HTML report leads each finding with a three-paragraph plain-language ELI5 (what it is, what a user would trigger, the fix) and tucks the technical trace behind a collapsible — built for the person who must prioritize fixes without reading code.

## What it is NOT

Not a diff reviewer (use a code-review tool), not a maintainability pass (use `/harden-quality`), not idempotent (cross-run agreement is signal), and not a substitute for human judgment on Blocker findings. It is domain-agnostic — app, backend, and smart-contract code are all in scope.
