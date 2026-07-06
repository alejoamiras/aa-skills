# Codex audit — blueprint-remote-view

- Session: 019f3864-63f0-7842-9648-ef4e6d5bdeff (xhigh, read-only sandbox, cwd=repo root)
- Date: 2026-07-06
- Verdict: conditional approve (conditions folded into plan.md rev 2)

## Prompt

```
I'm adding a "remote eli5/plan viewing" capability to a personal Claude Code skill repo (aa-skills). I want a critical second opinion on the PLAN before implementation.

## Read these files (repo root = your cwd)

- `implementations-plan/blueprint-remote-view/plan.md` — THE PLAN UNDER REVIEW (read fully)
- `skills/blueprint/SKILL.md` — the skill being modified; the approval-gate section around line 388 contains the macOS-only "open eli5.html" behavior being replaced
- `skills/blueprint/README.md` — line 42 mentions the same behavior

## Context

The blueprint skill generates `implementations-plan/<plan>/eli5.html` files and, at its approval gate, opens them in a browser. On a headless Linux server (owner's new 24/7 agent box, reachable via Tailscale from his Mac) there's no browser. The plan: an optional `BLUEPRINT_VIEW_CMD` env-var hook contract (hook receives absolute plan-dir path, prints a browsable base URL, exit 0; non-zero/empty stdout → skill silently falls through to file-path fallback), plus a versioned reference implementation `skills/blueprint/examples/blueprint-view-tailscale.sh` that mounts ONLY `implementations-plan` trees via `tailscale serve --http=43117 --set-path=/<root-relative> --bg <dir>`, hostname derived from `tailscale status --json`. Must work uniformly for ALL repos under ~/Projects (per-repo mounts accumulate on one port; URL paths mirror filesystem). One-time machine wiring: `tailscale set --operator=<user>` so no sudo at runtime.

## Facts (verified live on the box today)

- `tailscale serve --http=PORT --set-path` serving a dir tailnet-only, hostname-routed (404 on raw IP): proven by hand today
- MagicDNS on; `.Self.DNSName` = homelab.tail1eea19.ts.net; jq + shellcheck installed; port 43117 free
- Anchors exist: SKILL.md:388, README.md:42
- Repo CI = gitleaks only; no test framework; gitleaks pre-commit hook active

## Inferences (unverified — challenge these)

- `tailscale serve --bg` config persists across reboots
- Repeated `--set-path` same path+target is idempotent (planned to verify empirically in Phase 4)
- `~/.claude/settings.json` env block injects the var into future Claude Code sessions
- `tailscale status --json` `.Self.DNSName` schema stable across versions

## What I want from you

Be critical. Try to break this plan before validating it. Specifically:

1. **Adversarial/security**: what could go wrong? What would an attacker on the tailnet (or a future guest node) target? What are we trusting that we shouldn't? Path-traversal or symlink weaknesses in the "refuse outside ROOT / only implementations-plan trees" guard design? Least-privilege issues with the operator grant? Any way this accidentally exposes repo code or secrets?
2. **Assumption-attack**: attack the plan's Assumptions section. Which Facts are misstated? Which Inferences are unsafe? Which Asks SHOULD exist that were silently assumed? Return these under Facts / Inferences / Asks buckets.
3. **Design critique**: contract shape (hook returns dir base-URL and skill appends /eli5.html — vs returning the eli5 URL directly); cascade ordering (hook URL, then file paths, then macOS open); the multi-repo one-port accumulate-mounts scheme; the idempotency plan; anything simpler that achieves the same.

Respond in under 700 words: one-line verdict first using EXACTLY one of these formats: `approve` | `conditional approve (with conditions: ...)` | `reject (with blocking findings: ...)` — then bulleted findings grouped by the three asks, then a brief "what looks fine" list.
```

## Response

conditional approve (with conditions: add symlink/stale-mount/operator/ACL hardening, directly verify Claude env injection, and decide exact-plan-dir vs whole implementations-plan exposure)

**Adversarial / Security**
- Biggest gap: mounting the whole nearest `implementations-plan` exposes every plan in that repo, not just the current plan. That may include old lessons, copied logs, debugging output, or uncommitted sensitive notes. Gitleaks on commits does not protect live uncommitted files.
- Canonicalizing the input path is not enough. If `tailscale serve` follows symlinks inside the served tree, a symlink under `implementations-plan` could expose files outside it. Add an explicit `find -L <mount> ...` guard, reject symlinks escaping the mount/root, or mount a sanitized staging directory.
- Operator grant is broader than “this script can serve plan dirs.” Any process running as that user may be able to modify Tailscale serve state, and possibly serve arbitrary files or enable other Tailscale features depending on policy. Document that trust boundary honestly.
- Tailnet-only is not the same as private-to-you. Future shared/guest nodes, a compromised device, or broad ACLs can read these URLs. Add an ask for ACL posture: all tailnet members, or only owner devices?
- One-port multi-repo serving creates one browser origin for every repo’s plan HTML. If any served HTML is malicious or untrusted, it can read other mounted plan docs from the same origin. “No JS in eli5” should be explicit, or accept same-origin cross-repo exposure.
- “Silently fall through” is too quiet when `BLUEPRINT_VIEW_CMD` is set. A concise “remote view unavailable; using file path fallback” is safer for diagnosing broken wiring.

**Assumption Attack**
- **Facts:** Fact 3 is overstated. “No kernel socket” does not mean “no clash possible”; there can still be Tailscale serve config collisions on the same tailnet host/port/path. Fact 5 over-relies on gitleaks; it does not make served plan trees secret-safe. Fact 7, passwordless sudo, is a security property, not just an enablement fact.
- **Inferences:** `--bg` persistence is double-edged: if true, stale mounts persist and widen exposure after the work is done. Idempotency should test same path/same target and path replacement behavior. `~/.claude/settings.json` is not validated by `zsh -ic`; Phase 3 needs a real Claude Code session/env proof or this stays an inference. `.Self.DNSName` is acceptable if treated as runtime best-effort with clear failure.
- **Asks:** Add explicit asks for: tailnet ACL/access scope; whether serving all plans in a repo is acceptable or only the current plan; whether broad local operator rights are acceptable; retention/cleanup policy for old mounts; whether plan/lesson files are allowed to contain sensitive operational details.

**Design Critique**
- Prefer hook returns the final `eli5.html` URL, not a base URL the skill mutates. It reduces slash-joining bugs, lets the hook verify the exact URL it emits, and still supports relative links.
- If keeping base URL, specify normalization: one line, no trailing slash or exactly one trailing slash, must be `http://` or `https://`, skill appends safely.
- Mount exact plan dirs unless you intentionally want repo-wide plan browsing. Exact plan-dir mounts reduce accidental disclosure and stale surface.
- Phase 4’s “exactly two expected mounts” conflicts with the accumulate-mounts model. Either reset before test or assert the expected mounts exist and no blueprint-owned mount escapes `implementations-plan`.
- Add a cleanup/status story: documented `tailscale serve reset` is blunt; a scoped prune command or manual status checklist would be better.

**What Looks Fine**
- Env-var hook keeps the skill machine-agnostic.
- Versioned example but opt-in wiring is the right default.
- Non-zero/empty stdout fallback preserves existing behavior.
- Runtime no-sudo script is good, as long as the operator grant risk is documented.
- Avoiding `tailscale funnel` is the right boundary.
## Adopted / Rejected

| Finding | Decision |
|---|---|
| Whole-tree mount exposes all plans incl. uncommitted notes | Adopted as explicit gate ask #2 + policy note (user requirement overrides per-plan preference) |
| Symlink-escape via served tree | Adopted: pre-mount symlink scan + negative test (d) |
| Operator grant breadth | Adopted: trust boundary documented in script header + plan; gate ask #3 |
| Tailnet != private; ACL posture | Adopted as gate ask #1 |
| Same-origin cross-repo HTML | Adopted: no-untrusted-HTML policy note in SKILL.md; per-repo ports rejected (YAGNI) |
| Silent fallback too quiet | Adopted: visible fallback notice in contract + cascade |
| Fact 3 overstated (port clash) | Adopted: reworded + Phase 4 mount-table assertion |
| Fact 5 gitleaks over-reliance | Adopted: reworded, policy note |
| Fact 7 sudo framing | Adopted: reworded as security posture |
| settings.json env not actually validated | Adopted: Phase 3 gate now proves env inside a Claude Code context |
| Stale mounts / persistence double-edge | Adopted: --off flag + serve status story |
| Phase 4 exact-count vs accumulate contradiction | Adopted: reworded to present+no-escape assertions |
| Hook should return eli5 URL directly | REJECTED: base-URL keeps lessons/audits browsable; normalization rules kill the slash-join bug class |
| Scoped per-mount prune command | REJECTED for now: YAGNI at 2-device scale; --off suffices |
