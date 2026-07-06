# blueprint-remote-view

**Status**: APPROVED — conditional approve (Alejo, 2026-07-06): ACL owner-only confirmed · all-plans scope confirmed · operator grant confirmed · CONDITION (folded in): serving is approval-window-only, automatic teardown after the verdict
**Tier**: `/blueprint light`
**Baseline**: commit `f6106ea` on `main`
**Date**: 2026-07-06

## Summary

When blueprint runs on a headless box (no browser, no `open`), the approval gate's "open eli5.html" step degrades to printing a filesystem path the human can't click from another device. This plan adds a **machine-agnostic remote-viewing contract** to the blueprint skill — an optional `BLUEPRINT_VIEW_CMD` hook that maps a plan directory to a browsable URL **for the duration of the approval gate**, and tears it down when the verdict lands — plus a **versioned reference implementation** using `tailscale serve`, wired up on the homelab server for ALL repos under `~/Projects`.

The skill never learns what "homelab" or "tailscale" is. It learns only: *if `BLUEPRINT_VIEW_CMD` is set: hook up → show URL → verdict → hook down.* Mechanism belongs to the machine.

## Contract specification (v2 — teardown added per approval condition)

```
$BLUEPRINT_VIEW_CMD <absolute-path-to-plan-dir>          # UP: publish, print URL
$BLUEPRINT_VIEW_CMD --down <absolute-path-to-plan-dir>   # DOWN: unpublish
```

- **UP** — stdout: a single line, the base URL at which `<plan-dir>` is browsable. Normalization: exactly one line; starts `http://` or `https://`; NO trailing slash. The skill appends `/eli5.html`. Exit 0 = live. Non-zero or empty stdout = skill falls through the cascade AND prints "remote view unavailable (hook failed); using file paths" (never silent when the var is set). Idempotent: repeat UP returns the same URL.
- **DOWN** — removes whatever UP published for that plan dir. Exit 0 also when nothing was published (idempotent). Failure is non-blocking for the skill but must be reported in chat.
- **Lifecycle rule (the skill enforces it)**: the skill calls UP when presenting the approval gate, and calls DOWN immediately after the user's verdict is recorded — approve, conditional approve, or reject alike. Serving exists only inside the approval window.

### Gate presentation cascade (replaces the macOS-only line)

1. Always print `<absolute path>` and `file://<absolute path>` on standalone lines (unchanged).
2. If `BLUEPRINT_VIEW_CMD` is set: run UP; on success print URL + `/eli5.html` on its own standalone line, labeled as the remote-viewing URL. On failure, print the not-silent notice.
3. If on macOS: `open <path>` (unchanged).
4. Otherwise: the printed paths are the fallback (unchanged).
5. **After the verdict is recorded**: if UP was used, run DOWN and confirm teardown in chat.

## Reference implementation: `skills/blueprint/examples/blueprint-view-tailscale.sh`

Versioned in this repo as a documented example; **not** auto-linked by `install.sh`. Machines opt in (symlink to `~/.local/bin/blueprint-view` + export the env var).

Behavior:

- Env-overridable: `BLUEPRINT_VIEW_PORT` (default `43117`, validated numeric), `BLUEPRINT_VIEW_ROOT` (default `$HOME/Projects`).
- Input canonicalized with `realpath`; **refuses** (exit 1, reason on stderr, empty stdout): paths outside ROOT; paths not inside an `implementations-plan` tree; nonexistent paths.
- **Symlink-escape guard** (UP only): pre-mount scan of the mount tree for symlinks resolving outside ROOT; refuse if any. Makes tailscale's (unverified) symlink behavior irrelevant. Residual: symlinks added post-mount — bounded by the approval-window lifecycle (mounts are short-lived now) and re-checked on any re-UP.
- UP mounts the nearest `implementations-plan` ancestor via `tailscale serve --http=$PORT --set-path=/<root-relative-path> --bg <dir>` — only plan trees are mountable, never repo code / `.env` / `node_modules`. Whole-tree per repo is deliberate (user requirement, confirmed at gate).
- **DOWN** removes that tree's path mount (`tailscale serve --http=$PORT --set-path=/<root-relative-path> off`); exit 0 when the mount didn't exist. Known behavior at Alejo's scale: two concurrent gates in the SAME repo share a mount — DOWN for one 404s the other until its gate re-presents (hook re-UPs); documented in the header, accepted.
- **Maintenance**: `--off` kills ALL mounts on the port (`tailscale serve --http=$PORT off`); `tailscale serve status` inspects. Backstop for anything orphaned (e.g. a session dying mid-gate).
- Hostname from `tailscale status --json` `.Self.DNSName` (trailing dot stripped); empty → exit non-zero with stderr reason.
- Serve mutations (UP/DOWN/`--off`) run via `sudo -n tailscale` — **empirical Phase 4 discovery: operator alone cannot serve filesystem paths** (tailscale returns 401; root required). Hard dependency documented in the header: root or passwordless sudo; `sudo -n` fails loudly rather than prompting. Operator grant kept for sudo-free `serve status`. Second discovery: tailscale stores path handlers slash-normalized — mount with `/x`, remove with `/x/` (see lessons/phase-4.md).
- Never touches `tailscale funnel`.

## Phases

### Phase 1: Contract + docs in the skill ✓

Edit `skills/blueprint/SKILL.md`: replace the macOS-only sentence (line 388) with the 5-step cascade (incl. post-verdict DOWN), and add a **"Remote viewing (headless boxes)"** subsection: the v2 contract (UP/DOWN, normalization, not-silent failure, lifecycle rule), example pointer, policy notes (no secrets in plan trees — gitleaks guards commits not live files; one shared browser origin — no untrusted HTML in `implementations-plan`). Update `skills/blueprint/README.md` line 42 area to mention the cascade + approval-window serving.

**Validation gate**
- Commands: `grep -q 'BLUEPRINT_VIEW_CMD' skills/blueprint/SKILL.md && grep -q -- '--down' skills/blueprint/SKILL.md && grep -q 'BLUEPRINT_VIEW_CMD' skills/blueprint/README.md && bash -n install.sh hooks/pre-commit`
- Pass criteria: all greps exit 0; `bash -n` exit 0; manual diff read for coherence.
- Layers: docs consistency + fast syntax.

### Phase 2: Reference hook script ✓

Create `skills/blueprint/examples/blueprint-view-tailscale.sh` per spec, header documenting: purpose, v2 contract, deps (`tailscale`, `jq`), one-time setup (operator + trust boundary, symlink, env var), `--down` lifecycle + same-repo concurrent-gate caveat, `--off` backstop.

**Validation gate**
- Commands: `shellcheck` + `bash -n` on the script; negative-path tests exiting non-zero with EMPTY stdout: `(a)` dir outside ROOT (`/tmp`), `(b)` dir under ROOT not in an `implementations-plan` tree, `(c)` nonexistent path, `(d)` plan dir containing a symlink escaping ROOT (fixture created + removed); plus `(e)` `--down` for a never-mounted plan dir exits 0 (idempotent teardown).
- Pass criteria: shellcheck + `bash -n` exit 0; (a)-(d) non-zero + empty stdout; (e) exit 0.
- Layers: lint + unit (guards, no tailscale needed for a-d).

### Phase 3: Homelab machine wiring ✓

`sudo tailscale set --operator=homelab`; symlink example → `~/.local/bin/blueprint-view`; export `BLUEPRINT_VIEW_CMD="$HOME/.local/bin/blueprint-view"` in `~/.zshrc` AND `~/.claude/settings.json` `env`.

**Validation gate**
- Commands: `tailscale serve status` (user, NO sudo); `zsh -ic 'echo $BLUEPRINT_VIEW_CMD'`; `command -v blueprint-view`; harness proof: env var visible inside a Claude Code execution context (`claude -p` printenv or equivalent fresh-context Bash check).
- Pass criteria: serve status exit 0 sans sudo; var correct in fresh zsh AND in a Claude Code context; symlink resolves.
- Layers: integration.

### Phase 4: End-to-end proof — multi-repo, full lifecycle ✓

UP for two repos' plans: `(a)` nulo/nulo-1 `bridge-permit2-recipient-commitment`, `(b)` this plan's dir. Re-run UP (a) for idempotency. Then DOWN (a), verify (b) unaffected; DOWN (b), verify nothing left.

**Validation gate**
- Commands: UP (a), UP (b); `curl -fsS -o /dev/null -w '%{http_code}'` on both returned URLs + `/eli5.html`; UP (a) again; DOWN (a); curl (a) again expecting failure; curl (b) still 200; DOWN (b); `tailscale serve status`.
- Pass criteria: both curls 200 via hostname URLs; repeat UP exits 0, same URL, no duplicate mount; after DOWN (a): (a) non-200/refused while (b) still 200 (independent teardown); after DOWN (b): zero blueprint mounts on port 43117; URLs normalized (no trailing slash, `http://` prefix); every mount observed during the test maps inside an `implementations-plan` tree.
- Layers: e2e over the real tailnet, full UP→verify→DOWN lifecycle.
- **Final acceptance (human)**: Alejo opens URL (b) in the Mac browser during the mounted window and confirms rendering + relative links.

### Phase 5: Index, lessons, ship

Update `implementations-plan/index.md`; lessons file for any debugging; `/code-review max --fix` on the diff (fixes committed separately); codex post-impl audit (net diff from `f6106ea` + code-review commit summary + adversarial ask); address high/critical; conventional commits; push `main`.

**Validation gate**
- Commands: `git status --porcelain` (empty after push); `git log --oneline -8`; `gh run list --limit 1 --json conclusion`.
- Pass criteria: clean tree; commits pushed incl. separate code-review commit(s) if any; gitleaks CI `success`.
- Layers: repo hygiene + CI (secret scan).

## Security & Adversarial Considerations

- **Threat model**: HTTP serving of `implementations-plan` trees to tailnet members, now bounded to approval windows. Tailnet confirmed owner-devices-only (gate ask #1); if that ever changes, revisit — but the approval-window lifecycle already shrinks exposure from "forever" to "minutes/hours".
- **What's exposed during a window**: ALL plans/lessons of that repo, incl. uncommitted notes (gitleaks guards commits, NOT live files). Deliberate (gate ask #2 confirmed) + policy note in SKILL.md: plan trees must never hold secrets.
- **Least privilege / scope**: refuse outside-ROOT / outside-implementations-plan / nonexistent; `realpath` kills `../` and symlink tricks at the entry; pre-mount symlink-escape scan closes the in-tree hole regardless of tailscale's follow behavior; residual post-mount symlink risk bounded by window lifetime. Serve mutations require root/passwordless-sudo (`sudo -n`, loud failure) — operator alone proved insufficient for path serving (Phase 4); operator kept for status only (gate ask #3 confirmed; both ≤ passwordless sudo here). Never `funnel`.
- **Teardown honesty**: DOWN failures are non-blocking but must be reported; `--off` is the documented backstop for orphaned mounts (e.g. session death mid-gate); `tailscale serve status` is the inspection tool.
- **Same-origin note**: one port = one origin across repos during overlapping windows. Served HTML is skill-generated; no-untrusted-HTML policy stated in SKILL.md; revisit with per-repo ports if that policy ever changes.
- **Supply chain**: zero new deps (`tailscale`, `jq`, `coreutils` from OS repos); script versioned + gitleaks-scanned.
- **Input validation**: single positional arg (+ `--down`/`--off` flags) canonicalized before use; mount path built only from the ROOT-relative canonical path; port validated numeric; URL emitted only after all guards pass.

## Assumptions

**Facts** (verified this session, 2026-07-05/06):
1. `tailscale serve --http=PORT --set-path=/x --bg <dir>` serves a dir tailnet-only, hostname-routed (404 on raw IP) — hand-proven twice today (nulo plan dir; this plan's own eli5 at the gate, HTTP 200 on port 43117).
2. MagicDNS on; `.Self.DNSName` = `homelab.tail1eea19.ts.net`, derivable from `tailscale status --json`.
3. Port 43117 has no kernel-socket listener; tailscale serve claims don't occupy kernel sockets — no clash with app sockets. Config-level collisions remain possible in principle; Phase 4 asserts the mount table.
4. Anchors exist: `skills/blueprint/SKILL.md:388`, `skills/blueprint/README.md:42`.
5. `jq` + `shellcheck` installed; gitleaks pre-commit + CI guard commits (NOT live served files).
6. Proof plan exists with eli5.html (nulo/nulo-1 `bridge-permit2-recipient-commitment`).
7. Passwordless sudo for `homelab` — machine-level posture this plan inherits (operator adds no NEW capability here; elsewhere it's a real grant).

**Inferences** (unverified, with mitigations):
1. `tailscale serve --bg` persists across reboots — now LOW-impact either way: approval-window lifecycle means mounts are torn down long before reboots matter; `--off` backstops orphans.
2. ~~Per-path `--set-path=<path> off` removes a single mount cleanly~~ → **VERIFIED in Phase 4, with a catch**: removal only matches the slash-normalized handler (`/x/`), not the creation form (`/x`) — fixed in the script, documented in lessons/phase-4.md. DOWN (a) while (b) stays live: proven.
3. Repeat UP same path+target is idempotent — **VERIFIED in Phase 4** (same URL, mount count unchanged).
4. `tailscale status --json` `.Self.DNSName` schema stable across Alejo's tailscale versions; hook fails loudly if absent.

**Asks**: none open. Gate answers 2026-07-06: ACL owner-only ✓ · whole-tree scope ✓ (with the approval-window condition, folded in) · operator grant ✓.

## Decision ledger (light-tier, abbreviated)

- Hook location: versioned example (chosen) vs machine-local-only (rejected: lost on rebuild, undocumented).
- URL contract: dir base-URL + normalization, skill appends `/eli5.html` (chosen) vs eli5-URL direct (**codex preference — rejected**: over-fits one file; normalization kills the slash-join bug class).
- Serving scope: whole `implementations-plan` tree per repo (chosen: user requirement, gate-confirmed) vs per-plan mounts (codex preference — overridden).
- **Serving lifetime: approval-window-only with skill-enforced DOWN (chosen — user condition at gate)** vs persistent accumulating mounts (original design — rejected by user: unnecessary standing exposure) vs TTL self-expiry (rejected: timer complexity for no added value).
- Hostname: runtime MagicDNS derivation (chosen) vs short name (rejected: client search-domain assumption) vs hardcoded (rejected: machine-specific).
- sudo: REVISED during Phase 4 — original "operator grant, no sudo at runtime" was empirically wrong (tailscale requires root for path serving). Final: `sudo -n` for serve mutations with loud non-interactive failure + operator for status. "Rejected: sudo in script" is thereby overturned by reality, with the trust boundary stated in the script header.
- Port: stable 43117 (chosen) vs random-per-run (rejected).
- Cleanup: contract-level DOWN + `--off` backstop (chosen; supersedes docs-only cleanup) vs scoped prune tooling (rejected: YAGNI).

## Codex audit

Session `019f3864-63f0-7842-9648-ef4e6d5bdeff` (xhigh, read-only, 2026-07-06). Verdict: **conditional approve**; all conditions folded (rev 2), then the user's approval condition added the DOWN lifecycle (rev 3). Transcript + adopted/rejected table: `audit-codex.md`.

## Approval record

**Conditional approve** — Alejo, 2026-07-06. Asks resolved: ACL owner-only ✓, whole-tree ✓, operator ✓. Condition: approval-window-only serving with automatic teardown → folded in as contract v2 DOWN + cascade step 5 + Phase 4 lifecycle proof. Scope otherwise as presented. `/harden`: skipped (decided Phase 0).

## Seeds (FINAL — post-approval)

### Recommended: `/goal`

```
/goal All five phases marked ✓ in implementations-plan/blueprint-remote-view/plan.md (phase headers in the file), each ✓ backed by its validation gate's commands reported passing in the transcript (shellcheck/bash -n exit 0; negative cases a-d exit non-zero with empty stdout and --down-when-unmounted exits 0; env var proven inside a Claude Code execution context; both multi-repo curls print 200; repeat UP returns the same URL with no duplicate mount; after DOWN (a) its URL stops answering 200 while (b) still answers 200; after DOWN (b) zero blueprint mounts remain on port 43117; git tree clean after push and gitleaks CI concluded success); /code-review max --fix complete with fixes committed separately; codex post-impl audit complete with high/critical findings addressed; LESSONS_FILE=implementations-plan/blueprint-remote-view/lessons/phase-N.md printed for each phase that needed debugging.
```

### Alternative: `/loop 15m`

```
/loop 15m Drive implementations-plan/blueprint-remote-view forward per plan.md (authoritative state, APPROVED rev 3 with DOWN lifecycle). Each firing: reality-check plan.md + lessons/ + git status; no task in hand → next pending phase; after each meaningful edit run shellcheck + bash -n on touched scripts; phase green = its validation gate as written in plan.md passes — paste the result, mark ✓ in plan.md, log lessons, print LESSONS_FILE=...; stuck or design fork → /codex xhigh (resume session 019f3864-63f0-7842-9648-ef4e6d5bdeff where prior context helps), decide, log, act; same step failed 5 times → stop and reassess with codex; all phases ✓ → /code-review max --fix (commit separately) → codex post-impl audit (net diff from f6106ea + code-review commit summary + adversarial ask) → address high/critical → wrap-up and stop. Hard limits: no scope beyond plan.md, no new serve mechanisms, never funnel, serving only within approval windows.
```
