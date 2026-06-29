---
name: codex
description: Invokes the Codex CLI to get a second opinion from a different model family on a plan, design, analysis, or piece of code. Use ONLY when the user explicitly asks to involve codex (e.g. "ask codex", "have codex review", "get codex's take", "check with codex"). Does not invoke proactively.
---

# Ask Codex for Review

Use the `codex` CLI to get a second opinion from a different model family. Codex runs as a separate agent and can read files in the current repo, so it's useful for sanity-checking plans, designs, risky code changes, or observations that you want challenged by a fresh perspective.

**Only invoke this skill when the user explicitly asks for codex.** Do not reach for it on your own initiative.

**Codex is not an oracle.** It can be confidently wrong, miss context, hallucinate APIs, or misread the code. Treat its response as input to your own reasoning, not a verdict. Be critical: if codex disagrees with you, weigh the argument on its merits; if codex agrees, don't assume that confirms your position.

## How invocation works (read this first)

This skill ships with two helper scripts under `~/.claude/skills/codex/scripts/`:

- `run-codex.sh` — starts a fresh codex session
- `resume-codex.sh` — appends a follow-up to an existing session

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

   Arguments are positional: `<prompt-file>` (required), `<cwd>` (defaults to `$PWD`), `<effort>` (defaults to `xhigh`), `<sandbox>` (defaults to `read-only`). Pass `workspace-write` for the sandbox only if the user explicitly wants codex to make changes.

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

Always run codex at `xhigh` reasoning effort — that's what the helper scripts default to, and what the third positional argument controls. The whole point of asking codex is to get its strongest critique; lower effort defeats the purpose. The codex banner in `LOG_FILE` will echo `reasoning effort: xhigh` when wired up correctly.

The scripts pass `-c model_reasoning_effort=<effort>` on every call. Don't pass `-m` (model override) unless the user explicitly asks — codex uses the model from `~/.codex/config.toml`.

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

## Hard rules

These exist because past sessions invented unsafe workarounds. Don't.

1. **Never write codex artifacts to a fixed shared path — anywhere.** The previous bug came from files like `/tmp/codex-prompt.txt`, `/tmp/codex-output.txt`, `/tmp/codex-dir-current.txt`, `/tmp/codex_dir_<topic>`, but the real invariant is *no fixed shared mailbox file*, regardless of directory or naming scheme. A future workaround at `~/.cache/codex-current` or `/tmp/review.md` would reintroduce the same cross-session contamination. The only acceptable per-invocation paths are those allocated freshly via `mktemp` (which the scripts do internally) and a per-call prompt file you create with `mktemp -t codex-prompt-XXXX`.

2. **Never use `codex exec resume --last`.** It picks the most recent session in the current cwd globally — across all Claude sessions, not just yours. Use the `SESSION_ID` you captured from `run-codex.sh`. If you don't have it but you do have CODEX_DIR, pass `""` as the first arg to `resume-codex.sh` (it will read the id from `$CODEX_DIR/session_id`). If you have neither, tell the user and start a new session rather than gambling on `--last`.

3. **Never invoke `codex exec` directly from the Bash tool.** Use the helper scripts. Direct invocation forces you back into the multi-call mktemp/grep dance that caused the original cross-contamination bug.

4. **Don't pass `-m` (model override) unless the user explicitly asks** — codex uses the model from `~/.codex/config.toml`.
