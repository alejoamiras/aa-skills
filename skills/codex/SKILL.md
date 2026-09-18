---
name: codex
description: Invokes the Codex CLI for two things. (1) A second opinion from a different model family on a plan, design, analysis, or piece of code — ONLY when the user explicitly asks to involve codex ("ask codex", "have codex review", "get codex's take", "check with codex"). (2) Raster image generation or editing (PNG/JPEG — icons, hero images, banners, mockups, textures, sprites, photos) through Codex's built-in image_gen tool (gpt-image-2 on the ChatGPT plan, no API key) — whenever the user asks to generate, render, draw or edit an image ("generate an image", "make me a banner", "draw a…", "use codex to create a picture"). Does not invoke proactively.
---

# Ask Codex for Review

Use the `codex` CLI to get a second opinion from a different model family. Codex runs as a separate agent and can read files in the current repo, so it's useful for sanity-checking plans, designs, risky code changes, or observations that you want challenged by a fresh perspective.

**Only invoke this skill when the user explicitly asks for codex.** Do not reach for it on your own initiative.

**This is the foreign-reviewer leg for a Claude Code driver.** Its mirror is the `claude` skill (`run-claude.sh` / `resume-claude.sh`, same positional contract and trailer), which a Codex-driven session uses to consult Claude. Protocols such as blueprint name the role, not the CLI — whichever harness drives, the review comes from the other family.

**Codex is not an oracle.** It can be confidently wrong, miss context, hallucinate APIs, or misread the code. Treat its response as input to your own reasoning, not a verdict. Be critical: if codex disagrees with you, weigh the argument on its merits; if codex agrees, don't assume that confirms your position.

## How invocation works (read this first)

This skill ships with three helper scripts under `~/.claude/skills/codex/scripts/`:

- `run-codex.sh` — starts a fresh codex session
- `resume-codex.sh` — appends a follow-up to an existing session
- `image-codex.sh` — generates or edits raster images via Codex's built-in `image_gen` tool (see "Generating images" below)

**Why scripts and not raw `codex exec` calls?** The Bash tool runs each command in a fresh shell — environment variables and shell state do **not** persist between calls. A multi-step pattern like "mktemp a dir, run codex, grep the log, resume later" is impossible to do safely across separate Bash calls without a global file. Earlier versions of this skill tried, and the workaround (fixed-path files like `/tmp/codex-dir-current.txt`) caused cross-contamination between concurrent Claude sessions.

The scripts do the whole flow in a single shell process — the per-invocation temp dir lives only inside that process. They print a structured trailer to stdout that you (Claude) read into the conversation transcript, which is the only "memory" that survives across Bash calls.

## First call

1. Write the prompt to a file with the Write tool (cleaner than heredoc quoting):

   ```
   /tmp/<some-unique-name>.md   ← not /tmp/codex-prompt.md (see "Hard rules")
   ```

   Use `mktemp` if you need a path: `mktemp -t codex-prompt-XXXX`.

2. Run the helper. Default reasoning effort is `xhigh` — keep it unless the user asks otherwise:

   ```bash
   ~/.claude/skills/codex/scripts/run-codex.sh <prompt-file> <cwd> xhigh read-only
   ```

   Arguments are positional: `<prompt-file>` (required), `<cwd>` (defaults to `$PWD`), `<effort>` (defaults to `xhigh`), `<sandbox>` (defaults to `read-only`), `<model>` (defaults to codex's configured model). Pass `workspace-write` for the sandbox only if the user explicitly wants codex to make changes.

   **Hosts where the sandbox cannot start.** Inside a nested container (Sysbox) or under an AppArmor userns restriction nobody can lift, codex's `bwrap` dies with `loopback: Failed RTM_NEWADDR: Operation not permitted` and a `read-only` consult can run nothing. Such a machine opts in — locally, never in this repo — with a one-word file: `echo approve-for-me > ~/.agents/codex-sandbox`. Keep calling the script with `read-only`; it swaps in `--approve-for-me` (workspace-write plus a model auto-reviewer that may rerun a command unsandboxed), prepends a host note telling codex to request escalation and not to modify files, and `resume-codex.sh` re-asserts `approvals_reviewer="auto_review"`, which a resume does not inherit. The machine opts in, never the caller: a positional `approve-for-me` without the file is a usage error, and a resume re-arms only where the file exists. **This mode is weaker than `read-only` and does not enforce it** — the host note is only prose, so treat whatever contains the host (the outer container, a throwaway VM) as the real boundary. Never create the file where the sandbox works, never use `danger-full-access` instead, and for untrusted content prefer pasting excerpts inline with shell use forbidden. `image-codex.sh` has no such mode; image generation is unsupported on these hosts.

3. Codex calls take several minutes at `xhigh`. Run in the background (`run_in_background: true`) if you have other work; otherwise accept a long foreground wait.

4. The script's stdout ends with four lines you must capture:

   ```
   CODEX_DIR=/var/folders/.../codex-XXXXXXXX
   SESSION_ID=<uuid>
   RESPONSE_FILE=/var/folders/.../codex-XXXXXXXX/response.md
   LOG_FILE=/var/folders/.../codex-XXXXXXXX/log.jsonl
   ```

5. **Echo the SESSION_ID and CODEX_DIR back in your reply to the user**, e.g.:

   > Codex session: `019e0913-...` (files in `/var/folders/.../codex-XXXXXXXX`)

   That puts them in the conversation transcript so a later turn can resume even after the Bash shell that ran the script is gone.

6. Read codex's reply with the Read tool from `RESPONSE_FILE`.

If the SESSION_ID scrolled out of context but you still have CODEX_DIR, the id is also persisted at `$CODEX_DIR/session_id` — `resume-codex.sh` reads it from there when its first argument is empty.

## Following up / resuming

If codex's response is unclear, seems wrong, or you want to push back, **resume the same session** rather than starting fresh — codex retains its prior reasoning.

```bash
~/.claude/skills/codex/scripts/resume-codex.sh <session-id> <followup-prompt-file> <codex-dir> xhigh
```

Pass the same `<codex-dir>` you got back from the first call so follow-up files (`response-1.md`, `followup-1.md`, `response-2.md`, …) accumulate in one place. The script auto-numbers suffixes so prior turns aren't overwritten. If both `<session-id>` and `<codex-dir>` are passed, the script verifies they match and refuses to run on mismatch, which prevents writing follow-up artifacts into an unrelated prior run's directory.

If you only have the dir (the SESSION_ID scrolled out of context), pass an empty string for the session id and the script will read it from `<codex-dir>/session_id`:

```bash
~/.claude/skills/codex/scripts/resume-codex.sh "" <followup-prompt-file> <codex-dir> xhigh
```

Do not run `resume-codex.sh` in parallel against the same `<codex-dir>` — the numbered-suffix selection isn't atomic. Sequential resumes are fine.

Resume whenever you disagree with codex, need clarification, want to point out an error in its response, or want to test whether it holds its position under pushback. Starting a new session throws away its context and often wastes a round-trip re-establishing setup.

## Reasoning effort

Standalone consults run at `xhigh` reasoning effort — that's what the helper scripts default to, and what the third positional argument controls. The whole point of asking codex is to get its strongest critique; lower effort defeats the purpose. **Exception — a calling skill may pin a lower effort deliberately**: blueprint pins `high` on GPT-6 Astra (its many review rounds make `xhigh`'s extra minutes per round a bad trade), harden uses the effort its table states. Respect the caller's level; never silently bump it. The codex banner in `LOG_FILE` echoes the effort actually used.

The scripts pass `-c model_reasoning_effort=<effort>` on every call and default the model to **`gpt-6-astra`** (hardcoded in both consult scripts), overridable per-call via the fifth positional argument or `CODEX_MODEL`. `gpt-6-astra` became the default on 2026-09-04: GPT-6 Astra shipped 2026-09-03 (Codex CLI ≥ 0.153.1), runs on ChatGPT-account auth, and was verified end to end at `xhigh` through `run-codex.sh`. Every review and audit that other skills route through `/codex` (blueprint at `high`, harden at its table's effort) therefore runs on Astra. Only override the model when the user explicitly asks.

Model lineup, verified current 2026-09-04 (`~/.codex/models_cache.json` + the Codex models page): **`gpt-6-astra`** — GPT-6 Astra, "our most capable model for complex, demanding work", 1.05M context / 128K output — then the GPT-5.6 family as cheaper overrides: `gpt-5.6-sol` (the 5.6 flagship, about 2.5× cheaper than Astra at API rates), `gpt-5.6-terra` (balanced), `gpt-5.6-luna` (fast; the image script's default). `gpt-5.5` / `gpt-5.4` / `gpt-5.4-mini` are deprecated for ChatGPT sign-in (5.4 retired 2026-08-31); `gpt-5.3-codex-spark` is a Pro-only text-only speed preview; `gpt-reserve` and `codex-auto-review` are internal entries — never pick them. The `model_reasoning_effort` enum on Astra and the 5.6 family is now `low | medium | high | xhigh | max | ultra`: **`xhigh` stays the consult default**, `max` only when the user asks, and never `ultra` (it auto-delegates to subagents — open-ended spend). Astra's standard-user variant declines advanced *offensive* cyber asks; adversarial review phrased as defending the code passes, so if a review comes back refused, rephrase the ask rather than switching models. If Astra ever 400s with "not supported when using Codex with a ChatGPT account", that's the known intermittent entitlement-sync bug, not a policy change — `codex update`, re-auth, retry, and only then fall back to `gpt-5.6-sol`.

## Which account

Consults run on whatever `CODEX_ACCOUNT` names, falling back to the `~/.codex` login when it is unset. The managed settings ship `CODEX_ACCOUNT=best`, so by default a consult lands on the roster account with headroom — including the slot itself when the slot is the best one. With `codex-usage` installed (aa-skills `bin/`), other Codex subscriptions live as roster accounts under `~/.codex-accounts/<name>`, and the status line's `codex` segment says which one has headroom (`codex <current> … → <name>`). To run a consult on another account, set `CODEX_ACCOUNT=<name>` — or `CODEX_ACCOUNT=best` to let `codex-usage` pick — on the `run-codex.sh` call; the script routes through that account's `CODEX_HOME` and records it, so `resume-codex.sh` stays on the same account without being told (a UUID-only resume finds the session by its rollout file). A roster home is deliberately bare — the slot's `AGENTS.md` linked in, no `config.toml`, MCP servers or hooks — which is exactly what a read-only reviewer should run with; `run-codex.sh` passes model, effort and sandbox explicitly, and a resume inherits the session's sandbox from Codex itself. The status line's `codex` segment follows the same precedence as `run-codex.sh`: `CODEX_ACCOUNT` (a name, or the account `best` resolves to) beats `CODEX_HOME`, which beats the `~/.codex` login. Pin a specific `<name>` only when the user asks for that account; `best` already moves off a spent one. Never log the slot out or copy credentials between homes — Codex refresh tokens are single-use, and a copied login breaks both.

## Writing the prompt

Codex starts with zero context from this conversation. Brief it like a colleague who just walked in. The prompt should include:

1. **The question** — what specifically do you want feedback on? "Review my plan" is too vague. "Is my plan for X sound? Specifically, is the assumption about Y correct, and will the approach in Z handle edge case W?" is better.

2. **Facts vs. inferences vs. asks** — be explicit about which is which. Codex can't tell them apart from prose alone.
   - **Facts**: things you verified from the code, docs, or user — give file paths and line numbers.
   - **Inferences**: things you deduced but didn't verify — label them clearly ("I inferred that...", "I'm assuming...").
   - **Plans/observations under review**: the thing you actually want critiqued — set it off in its own section.

3. **Relevant context** — paste or reference the specific code, file paths, constraints, and prior decisions codex needs. Prefer pointing codex at files (it can read them via `-C`) over pasting large blobs, but paste short snippets inline so codex can't miss them.

4. **Explicit instruction to be critical** — ask codex to look for flaws, wrong assumptions, missed edge cases, and better alternatives. Otherwise it tends to be agreeable. Sample phrasing:

   > Be critical. I want you to find problems with this plan, not validate it. Point out wrong assumptions, missed edge cases, and anything that looks like it won't work. If you think the approach is fundamentally wrong, say so. If the plan looks correct, say that too — but only after genuinely trying to break it.

5. **Response shape** — tell codex what you want back. A short verdict + bulleted concerns is usually more useful than a long essay. E.g. "Respond in under 500 words: a one-line verdict, then bullets for each concern, then a brief 'things that look fine' list."

### Prompt template

```
I'm working on <short context — what project/feature/bug>. I want a critical second opinion on <what exactly>.

## Facts (verified)
- <fact>: <file:line or source>
- ...

## Inferences (unverified — please challenge)
- I'm assuming <X>. I haven't confirmed this.
- ...

## What I'm asking you to review
<The plan / observation / code under review. Be specific. Include code or file paths.>

## What I want from you
Be critical. Try to find problems with this before you validate it. Specifically:
- Are my facts actually correct? (Check the files if you need to.)
- Are my inferences safe?
- Does the plan handle <specific edge cases>?
- Is there a simpler/better approach I'm missing?

Respond in under <N> words: one-line verdict, then bulleted concerns, then what looks fine.
```

## After codex responds

Don't just relay codex's response to the user. Do your own pass:

- **Verify claims**: if codex says "function X does Y", "file Z doesn't exist", or "flag W isn't supported", check it. Codex can hallucinate file paths, symbols, or API details — and can also misread its own environment state (e.g. claiming a call failed when it succeeded). Verify concrete factual claims against the repo, docs, or `--help` before acting on them.
- **Weigh concerns by strength**: distinguish real objections from surface-level nitpicks.
- **Flag disagreements explicitly**: if codex contradicts something you believe, tell the user both views and your current take — don't silently flip.
- **Resume rather than start over**: if you have a specific pushback or clarifying question, run `resume-codex.sh` with the saved session id instead of opening a new session.
- **Summarize for the user**: a short digest ("codex flagged X and Y, I think X is valid and Y is a misread because...") is more useful than pasting the raw response. Offer the `RESPONSE_FILE` path in case they want to read it directly.

## Generating images

Codex CLI (≥ 0.123, verified on 0.150.1) ships a built-in `image_gen` tool backed by **gpt-image-2**, billed to the ChatGPT account — no `OPENAI_API_KEY`, no Images API credits. `codex exec` reaches it the same way the TUI does, which is what `image-codex.sh` wraps.

```bash
~/.claude/skills/codex/scripts/image-codex.sh <prompt-file> <out-dir> [effort] [model] [ref-image ...]
```

1. **Write the spec to a `mktemp` file** (`mktemp -t codex-image-XXXX`), one paragraph per asset: subject; style (photo / flat illustration / 3D render / pixel art …); size or aspect ratio; any exact text **quoted verbatim**; an avoid-list; and the filename to save as (`hero.png`, `favicon-512.png`). Generic prompts get worse images than specific ones — say what the image is *for*.
2. **Pick `out-dir` deliberately.** Previews and one-offs go to the session scratchpad. Only write into a repository when the user named the destination (asset dir, `public/`, docs images); the sandbox is `workspace-write` on that directory, so codex can touch nothing else.
3. **Run it.** Defaults are `effort=low` and `model=gpt-5.6-luna` — the reasoning model only orchestrates the image tool, so pay the fast tier. Override the model with a 4th argument or `CODEX_IMAGE_MODEL`. Budget 1–2 minutes per image. Run in the background when several assets are requested (each asset is its own `image_gen` call inside one session).
4. **Read the trailer** — same four lines as `run-codex.sh` plus `OUT_DIR=` and `IMAGE_FILES=` (`;`-separated absolute paths, verified to exist). Exit 3 = codex says image generation is unavailable (usage limit, policy refusal); exit 4 = it finished without saving anything — read `RESPONSE_FILE` before retrying.
5. **Look at every image with the `Read` tool before handing it over** and check it against the spec (subject, text accuracy, avoid-list). Off-spec → resume the session with `resume-codex.sh` and ONE targeted change ("same image, replace the blue background with white"), not a rewritten prompt.
6. **Report** the saved paths and the session id, like any other codex consult.

**Editing an existing image** — pass it as a trailing `ref-image` argument (repeatable). The script attaches it with `codex exec -i`, which is the only way the built-in tool can see a local file; state in the prompt which attachment is the edit target and which are style references, and ask to "preserve everything except …".

**Know the tool's shape.** Output dimensions are approximate (a "1024×1024" ask came back 1254×1254) — resize locally (`sips`, `Bun.Image`) when exact pixels matter. Transparent backgrounds: ask for one explicitly and keep the PNG's alpha. The tool renders dense text well (vendor claim, spot-check it). Codex keeps the original of every generation under `~/.codex/generated_images/<session-id>/` (~0.8 MB each) in addition to the copy in `out-dir` — prune that directory occasionally. Never use the skill's `scripts/image_gen.py` CLI fallback: it needs `OPENAI_API_KEY`, and the standing rule is no API secrets on this machine.

**Not for**: SVG icons that should match an existing vector system, diagrams, charts, or anything better produced as code (HTML/CSS, canvas, `artifact-diagramming`). Those stay deterministic and reviewable; a bitmap is the wrong artifact.

## Hard rules

These exist because past sessions invented unsafe workarounds. Don't.

1. **Never write codex artifacts to a fixed shared path — anywhere.** The previous bug came from files like `/tmp/codex-prompt.txt`, `/tmp/codex-output.txt`, `/tmp/codex-dir-current.txt`, `/tmp/codex_dir_<topic>`, but the real invariant is *no fixed shared mailbox file*, regardless of directory or naming scheme. A future workaround at `~/.cache/codex-current` or `/tmp/review.md` would reintroduce the same cross-session contamination. The only acceptable per-invocation paths are those allocated freshly via `mktemp` (which the scripts do internally) and a per-call prompt file you create with `mktemp -t codex-prompt-XXXX`.

2. **Never use `codex exec resume --last`.** It picks the most recent session in the current cwd globally — across all Claude sessions, not just yours. Use the `SESSION_ID` you captured from `run-codex.sh`. If you don't have it but you do have CODEX_DIR, pass `""` as the first arg to `resume-codex.sh` (it will read the id from `$CODEX_DIR/session_id`). If you have neither, tell the user and start a new session rather than gambling on `--last`.

3. **Never invoke `codex exec` directly from the Bash tool.** Use the helper scripts (`run-codex.sh`, `resume-codex.sh`, `image-codex.sh`). Direct invocation forces you back into the multi-call mktemp/grep dance that caused the original cross-contamination bug.

4. **Don't override the model unless the user explicitly asks** — the consult scripts default to `gpt-6-astra` (the image script to `gpt-5.6-luna`); a user-requested override goes through the positional model argument (or `CODEX_MODEL` / `CODEX_IMAGE_MODEL`), never by editing the scripts ad hoc.
