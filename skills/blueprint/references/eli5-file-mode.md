# Blueprint: ELI5 file mode and remote viewing

Read this file when `eli5_mode` is `file`: the Artifact tool is absent, or the plan must stay on your infrastructure. It holds the scaffold, how to present the file at the approval gate, and the `BLUEPRINT_VIEW_CMD` contract. The ELI5's contents, the plain-language standard and the diagram rules stay in `SKILL.md` (Required: ELI5 companion).

## Scaffold

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
    figure { margin: 1.5rem 0; } figure svg { display: block; width: 100%; max-width: 400px; height: auto; margin: 0 auto; }
    figure svg text { fill: currentColor; font-size: 15px; } figure svg .box { fill: none; stroke: currentColor; }
    figcaption, dd { color: #666; font-size: 0.9rem; }
    dt { font-weight: 600; margin-top: 0.5rem; } dd { margin-left: 0; }
  </style>
</head>
<body>
  <h1><plan-name></h1>
  <p><one-paragraph summary, plain language></p>

  <h2>Why this tier was chosen</h2>
  <p><tier picked, rubric scores, justification in 2-3 sentences></p>

  <h2>Terms</h2>
  <dl>
    <dt><term></dt><dd><one-line meaning></dd>
  </dl>

  <figure>
    <svg viewBox="0 0 320 240" role="img" aria-label="<what the diagram shows>">
      <rect class="box" x="40" y="10" width="240" height="50" rx="6"/><text x="160" y="40" text-anchor="middle"><prose name></text>
      <!-- next box below at y="90"; arrows as <path class="box" d="M160 60 V90"/> -->
    </svg>
    <figcaption><one sentence: what to notice></figcaption>
  </figure>

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
      <li>Confirm the delivery topology: which phases group into which arcs / stacked PRs (or the single-PR call).</li>
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

## Presenting it at the approval gate

**If you used the file fallback (`eli5.html`):** output BOTH of these on their own standalone lines (terminals linkify them differently — one of the two will be clickable):

```
<absolute path to eli5.html>
file://<absolute path to eli5.html>
```

Then run EVERY applicable step — additive, not first-match-wins (a macOS box with a hook configured does both 1 and 2):

1. **Remote-viewing hook** — if `BLUEPRINT_VIEW_CMD` is set, run `$BLUEPRINT_VIEW_CMD <absolute plan dir>` and VALIDATE its stdout before trusting it: success means exit 0 AND exactly one line AND it matches `^https?://` AND it has no trailing slash. On success print the returned URL + `/eli5.html` on its own standalone line, labeled as the remote-viewing URL. Anything else — non-zero exit, empty/multi-line stdout, non-URL line, trailing slash — is a hook failure: print `remote view unavailable (hook failed); using file paths` — never fail silently when the hook is configured.
2. **macOS** — run `open <absolute path to eli5.html>` so the browser pops without hunting.
3. **Neither applied** — the printed paths above are the fallback.

(Absolute paths are fine in CHAT — the no-absolute-paths rule applies to committed files only.)

**After the verdict is recorded** (file-fallback path only; approve / conditional approve / reject alike): if `BLUEPRINT_VIEW_CMD` was invoked for UP at this gate — **even if that UP failed validation or errored, since it may have partially published** — run `$BLUEPRINT_VIEW_CMD --down <absolute plan dir>` and confirm the teardown in chat. Serving exists only inside the approval window. A DOWN failure is non-blocking but must be reported. (The Artifact path has no teardown — being persistently shareable is the point.)

## Remote viewing (headless boxes): the `BLUEPRINT_VIEW_CMD` contract

When blueprint runs on a machine with no browser (e.g. a remote dev server), the machine may export `BLUEPRINT_VIEW_CMD` naming a hook that maps a plan directory to a temporary browsable URL. The skill never learns the mechanism — the hook owns it.

```
$BLUEPRINT_VIEW_CMD <absolute-path-to-plan-dir>          # UP: publish, print URL
$BLUEPRINT_VIEW_CMD --down <absolute-path-to-plan-dir>   # DOWN: unpublish
```

- **UP** stdout: exactly one line — the base URL at which the plan dir is browsable. Must start `http://` or `https://`, NO trailing slash. The skill appends `/eli5.html`. Exit 0 = live; non-zero or empty stdout = fall through the cascade with the visible notice. Repeat UP for the same dir returns the same URL (idempotent).
- **DOWN**: removes whatever UP published for that dir; exit 0 also when nothing was published (idempotent). The skill calls DOWN immediately after the approval verdict — after every ATTEMPTED UP, successful or not.
- `BLUEPRINT_VIEW_CMD` is the path to an executable; the skill invokes it directly (quoted) with the plan dir as a single argument — the value is never shell-split.
- The hook owns its security policy (what it serves, to whom).

Reference implementation for Tailscale machines: the skill's `examples/blueprint-view-tailscale.sh` (serves ONLY allowlisted doc trees — default `implementations-plan` + `audit`, the latter for `/harden` reports, override via `BLUEPRINT_VIEW_TREES` — tailnet-only, refuses any symlink, `--off` backstop). This contract section is the single source of truth; other skills (e.g. `/harden`'s report step) reference it rather than redefining it. Policy notes for ANY implementation: served doc trees must never contain secrets (gitleaks guards commits, not live files), and served HTML shares one browser origin across repos — never place untrusted HTML under a served tree.
