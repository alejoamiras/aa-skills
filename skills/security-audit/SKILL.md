---
name: security-audit
description: "Comprehensive security audit for ecosystem projects (bridges, wallets, smart contracts). Covers business logic, code quality, and security vulnerabilities. Spawns parallel agents (Sonnet + Codex) for redundant coverage, then triages and consolidates into a severity-rated report. Special attention to Solidity, Noir, and Aztec.nr."
---

# Security Audit Skill

Comprehensive security audit process for Aztec ecosystem projects — bridges (L1<=>L2), wallets (e.g. Azguard), smart contracts, and related infrastructure.

## Three Audit Pillars

1. **Business logic** — correctness, edge cases, invariant violations
2. **Code quality & best practices** — patterns, test coverage, dependency hygiene
3. **Security & vulnerabilities** — adversarial red-teaming, exploit scenarios, attack pipelines

## Audit Workspace

All audit artifacts go into a dated folder:

```
~/audits/<repo-name>-<YYYY-MM-DD>/
├── context.md              # User-provided context and threat model
├── architecture.md         # Project structure overview
├── components/             # Per-component deep-dive notes
│   ├── <component-1>.md
│   ├── <component-2>.md
│   └── ...
├── findings/               # Raw findings before consolidation
│   ├── claude-opus.md      # Your (main agent) findings
│   ├── claude-sonnet.md    # Sonnet agent findings
│   └── codex.md            # Codex agent findings
└── report.md               # Final consolidated report
```

Create this folder structure at the start of every audit. Use `date +%Y-%m-%d` for the date.

---

## Phase 0: Context Interview (MANDATORY — do this FIRST)

Before reading any code, you MUST gather context from the user. Use the AskUserQuestion tool to ask the following. You can ask them all at once or in a natural conversation — but do NOT proceed to Phase 1 until you have answers.

### Questions to ask:

1. **What does this project do?** — One-paragraph description in the user's words. Don't rely solely on the README.
2. **What type of project is it?** — Bridge, wallet, DeFi protocol, SDK, infrastructure, etc.
3. **What assets does it handle?** — Which tokens, what's the expected TVL or value at risk?
4. **Who are the trusted actors?** — Admins, relayers, oracles, multisigs, governance. Who can do what?
5. **What's the upgrade/migration mechanism?** — Proxies, migrations, admin keys, timelocks?
6. **What's the deployment target?** — L1 only, L2 only, cross-chain? Which networks?
7. **Are there known concerns?** — Anything the user already suspects or wants special attention on?
8. **What's the maturity level?** — Is this pre-audit production code, a prototype, or already deployed?
9. **Any prior audits or reviews?** — If so, where are the reports?

### After gathering context:

Write `context.md` in the audit workspace with:
- The user's answers
- A **threat model** derived from the answers:
  - List of trusted actors and their powers
  - List of assets at risk and their value
  - Attack surface inventory (entry points, external calls, privileged operations, cross-chain messages)
  - Known vulnerability classes relevant to this project type (see smart contract checklist below)

---

## Phase 1: General Glance

Get a high-level understanding of the project structure:

- Map the directory structure, identify key directories and entry points
- Identify languages and frameworks in use
- Note any Solidity, Noir, or Aztec.nr files — these are HIGH PRIORITY
- Identify external dependencies and their versions
- Find configuration files, deployment scripts, test suites
- Check for existing documentation, CLAUDE.md, README

Write `architecture.md` with:
- Directory tree overview
- Component inventory (name, purpose, language, rough LOC)
- Dependency graph (what calls what, what imports what)
- Data flow diagram (how do assets/messages/state move through the system)

---

## Phase 2: Component Deep-Dive

Go component by component, iteratively building understanding:

For each component:
1. Read the code thoroughly
2. Understand its responsibility and boundaries
3. Map its interfaces — what it exposes, what it calls
4. Identify state it manages and invariants it should maintain
5. Note anything that catches your eye — even if you're not sure it's a bug yet

Write a file in `components/<component-name>.md` with:
- Purpose and responsibility
- Key functions/methods and what they do
- State managed and invariants
- External interactions (other components, external contracts, APIs)
- Initial observations and flags

**Important:** Write these files as you go. If you lose context or hit context limits, these files are your memory. Read them back before continuing.

---

## Phase 3: Business Logic & Quality Review

With full context, go deeper on each component:

### Business Logic
- Trace critical user flows end-to-end
- Check invariants: can any flow violate an expected invariant?
- Check edge cases: zero values, max values, empty arrays, reentrancy paths
- Check error handling: do failures leave the system in a consistent state?
- Check sequencing: can operations happen out of order?

### Code Quality & Best Practices
- Check test coverage: are critical paths tested? Are edge cases covered?
- Check dependency hygiene: outdated packages, known CVEs, unnecessary dependencies
- Check for code smells: dead code, duplicated logic, overly complex functions
- Check access control patterns: are permissions checked consistently?
- Check logging and observability: can you tell what happened from logs?

Record findings in `findings/claude-opus.md` as you go, using the severity format from Phase 6.

---

## Phase 4: Security & Vulnerability Review

This is the most critical phase. Approach as an attacker.

### 4a: Component-Level Red-Teaming

For each component:
- **Think as an attacker.** What would you try to exploit?
- For anything that catches your eye, think of **2-3 concrete attack vectors**
- Don't assume something works correctly — verify it
- Check for the vulnerability classes relevant to this project (from the threat model)
- Never rush this phase. Security is the utmost priority.

### 4b: Business Logic Attack Pipeline

After component-level review, zoom out:
- Trace attack scenarios across multiple components
- Look for assumptions one component makes about another that could be violated
- Check cross-boundary attacks: L1→L2, public→private, user→admin
- Check economic attacks: flash loans, oracle manipulation, sandwich attacks
- Check timing attacks: front-running, sequencing, race conditions
- Check state consistency attacks: can an attacker put the system into an inconsistent state?

### 4c: Smart Contract Specific (if Solidity, Noir, or Aztec.nr are present)

**These are likely very high value and will hold significant funds. Be maximally adversarial.**

#### Solidity checklist:
- Reentrancy (cross-function, cross-contract, read-only)
- Access control (missing checks, privilege escalation, default roles)
- Integer overflow/underflow (even with Solidity 0.8+, check unchecked blocks)
- Front-running / MEV exposure
- Oracle manipulation (price feeds, TWAP windows)
- Flash loan attack vectors
- Delegate call safety
- Storage collision (proxies, upgradeable contracts)
- External call return value handling
- Denial of service (gas griefing, unbounded loops)
- Signature replay / malleability
- ERC-20 quirks (fee-on-transfer, rebasing, approval race)

#### Noir / Aztec.nr checklist:
- Nullifier correctness (can nullifiers be predicted, reused, or leaked?)
- Note encryption (is the encrypted note actually only readable by the intended recipient?)
- Private → public boundary (does crossing the boundary leak private state?)
- Kernel proof verification (are proofs validated correctly at every step?)
- Constraint completeness (are all necessary constraints enforced? Can an attacker craft a valid proof for an invalid state transition?)
- Oracle trust assumptions (what oracles does the circuit rely on? Can they lie?)
- Incomplete nullifier sets (can an attacker selectively reveal/hide notes?)
- Authwit (authentication witness) correctness
- Storage slot collision in private/public state

#### Bridge-specific checklist:
- Message replay (can a message be replayed on L1 or L2?)
- Message ordering (can messages be reordered to gain advantage?)
- Relayer trust (what happens if the relayer is malicious or censors?)
- Finality assumptions (does the bridge wait for sufficient finality?)
- Token mapping correctness (is the L1↔L2 token mapping bijective and correct?)
- Withdrawal proof verification
- Deposit front-running

#### Wallet-specific checklist:
- Key management (storage, derivation, rotation)
- Transaction signing (what's shown vs what's signed)
- Permission model (what can a dApp request? Can it escalate?)
- Session key safety (expiry, scope, revocation)
- Supply chain (dependency pinning, update mechanism)

---

## Phase 5: Spawn Parallel Agents

After you have completed your own review through Phases 1-4, spawn two additional agents for redundant coverage. Both agents should audit the FULL surface — not a subset. Redundancy is intentional.

### Agent 1: Claude Sonnet 4.6

Spawn using the Agent tool with `model: "sonnet"`. Give it:

- The full `context.md` content (threat model, user answers)
- The `architecture.md` content
- Instructions to perform its own independent audit covering ALL three pillars (business logic, quality, security)
- Tell it to be adversarial and not assume correctness
- Tell it to pay special attention to Solidity/Noir/Aztec.nr if present
- Tell it to structure findings with severity ratings (see Phase 6)
- Tell it to output its findings as structured markdown

Save its output to `findings/claude-sonnet.md`.

### Agent 2: Codex (via CLI)

Run `codex exec` in the background with a crafted prompt. Use:
```bash
cat <<'PROMPT' | codex exec -s read-only --full-auto -C "<project-root>" -
You are performing a security audit of a codebase. You are one of three independent reviewers — your findings will be compared against two Claude models for completeness.

## Project Context
<paste context.md content here>

## Architecture
<paste architecture.md content here>

## Your Task
Perform a comprehensive security audit covering:

1. **Business Logic** — correctness, invariant violations, edge cases
2. **Code Quality** — patterns, test coverage, dependency issues
3. **Security Vulnerabilities** — think as an attacker, find exploit scenarios

For every finding, rate severity as:
- CRITICAL: Direct loss of funds or complete system compromise
- HIGH: Significant impact but requires specific conditions
- MEDIUM: Limited impact or low likelihood
- LOW: Minor issues, best practice violations
- INFO: Observations and recommendations

For any Solidity, Noir, or Aztec.nr code: be MAXIMALLY adversarial. These likely hold significant funds.

For each finding, include:
- Title
- Severity
- Location (file:line)
- Description of the issue
- Attack scenario (how would an attacker exploit this?)
- Recommended fix

Think of 2-3 ways to break anything that catches your eye. Do not rush. Do not assume correctness.

Output your findings as structured markdown.
PROMPT
```

Save its output to `findings/codex.md`.

---

## Phase 6: Triage & Consolidation

Once all three reviews are complete:

### Severity Classification

Every finding must be rated:

| Severity | Criteria |
|----------|----------|
| **CRITICAL** | Direct loss of funds, complete system compromise, or bypass of core security mechanism. Exploitable now. |
| **HIGH** | Significant impact (partial fund loss, privilege escalation) but requires specific conditions or attacker sophistication. |
| **MEDIUM** | Limited impact or low likelihood. Could become high-severity if conditions change. |
| **LOW** | Minor issues, deviations from best practices, code quality concerns that don't directly enable exploits. |
| **INFO** | Observations, recommendations, and improvements with no direct security impact. |

### Triage Process

1. **Merge findings** from all three sources (`claude-opus.md`, `claude-sonnet.md`, `codex.md`)
2. **Deduplicate** — group findings that describe the same underlying issue
3. **Evaluate feasibility** — for each unique finding:
   - Is the attack actually possible given the system's constraints?
   - What preconditions are needed?
   - What's the realistic impact?
   - Could it be a false positive?
4. **Assign final severity** based on likelihood × impact
5. **Note disagreements** — if one agent flagged something critical that others missed, call it out explicitly. These are often the most interesting findings.

### Final Report

Write `report.md` with:

```markdown
# Security Audit Report: <Project Name>
**Date:** <YYYY-MM-DD>
**Audited by:** Claude Opus 4.6 (lead), Claude Sonnet 4.6, OpenAI Codex (gpt-5.4)
**Repository:** <repo URL or path>
**Commit:** <commit hash at time of audit>

## Executive Summary
<2-3 paragraph overview: what was audited, overall assessment, critical findings count>

## Scope
<What was audited, what was excluded, any limitations>

## Threat Model
<From context.md — trusted actors, assets at risk, attack surface>

## Findings Summary

| # | Title | Severity | Status |
|---|-------|----------|--------|
| 1 | ...   | CRITICAL | ...    |
| 2 | ...   | HIGH     | ...    |

## Detailed Findings

### [C-01] <Title>
**Severity:** CRITICAL
**Location:** `file:line`
**Found by:** <which agent(s)>

**Description:**
<What the issue is>

**Attack Scenario:**
<Step-by-step how an attacker would exploit this>

**Impact:**
<What happens if exploited>

**Recommendation:**
<How to fix it>

---
<repeat for each finding, ordered by severity>

## Code Quality Observations
<Non-security findings: patterns, test coverage, dependencies>

## Recommendations
<Prioritized list of actions>

## Appendix
- Agent-specific raw findings: see findings/ directory
- Methodology: three-agent redundant audit with triage
```

---

## Important Reminders

- **Never rush.** Security is the utmost priority. There is no time pressure.
- **Never assume correctness.** Verify everything. If something looks fine, try harder to break it.
- **Write as you go.** The audit workspace is your memory. If you lose context, read your own notes.
- **When something catches your eye, explore it.** Think of 2-3 attack vectors before moving on.
- **Redundancy is intentional.** All three agents audit everything. Overlapping findings confirm severity; unique findings from one agent are often the most valuable.
- **Ask for more context if needed.** If you don't understand a component's purpose, ask the user before guessing.
