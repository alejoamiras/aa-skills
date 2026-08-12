---
name: kimi
description: Invokes the Kimi Code CLI to get a second opinion from Moonshot's model family (Kimi K3 / K2.x) on a plan, design, analysis, or piece of code. Use ONLY when the user explicitly asks to involve kimi (e.g. "ask kimi", "have kimi review", "get kimi's take", "check with kimi"). Does not invoke proactively.
---

# Ask Kimi for Review

Use the `kimi` CLI (Kimi Code, by Moonshot AI) to get a second opinion from a different model family. Kimi runs as a separate agent and can read files in the current repo, so it's useful for sanity-checking plans, designs, risky code changes, or observations that you want challenged by a fresh perspective. It is the same consult pattern as the `codex` skill, with one extra safety wrinkle (see "No sandbox" below).

**Only invoke this skill when the user explicitly asks for kimi.** Do not reach for it on your own initiative.

**Kimi is not an oracle.** It can be confidently wrong, miss context, hallucinate APIs, or misread the code. Treat its response as input to your own reasoning, not a verdict. Be critical: if kimi disagrees with you, weigh the argument on its merits; if kimi agrees, don't assume that confirms your position.

## How invocation works (read this first)

This skill ships with two helper scripts under `~/.claude/skills/kimi/scripts/`:

- `run-kimi.sh` — starts a fresh kimi session
- `resume-kimi.sh` — appends a follow-up to an existing session

**Why scripts and not raw `kimi -p` calls?** The Bash tool runs each command in a fresh shell — environment variables and shell state do **not** persist between calls. The scripts do the whole flow in a single shell process (per-invocation temp dir, session-id capture, worktree fingerprinting) and print a structured trailer to stdout that you (Claude) read into the conversation transcript, which is the only "memory" that survives across Bash calls. This is the same architecture as the codex skill, and it exists because fixed shared paths caused cross-session contamination in the past.

## No sandbox — read before first use

Unlike codex (`--sandbox read-only`), **kimi's non-interactive mode has no read-only sandbox**. `kimi -p` runs under the `auto` permission policy: tool calls, including file writes and shell commands, are auto-approved. Static `deny` rules in `~/.kimi-code/config.toml` (`[[permission.rules]]`) are the only hard enforcement and this skill does not install any by default.

Mitigations, all mandatory:

1. **Every prompt must state the reviewer role explicitly** — the template below opens with "You are reviewing only. Do NOT create, modify, or delete any files." Include it every time, first call and resumes.
2. **Check `FILES_CHANGED` in the trailer.** The scripts fingerprint `git status --porcelain` before/after the run. `none` = clean, `DETECTED` = the worktree changed during the run (diff on stderr — investigate before trusting the worktree; note it can also be another agent working in the same repo), `unknown` = cwd isn't a git repo, no tripwire available.
3. **Prefer consulting kimi on committed/clean worktrees** so any write is visible and revertable.

If the user wants hard enforcement, they can add deny rules to `~/.kimi-code/config.toml` themselves (e.g. `[[permission.rules]] decision = "deny" / pattern = "Write"`); `--yolo`/`--auto` cannot override deny rules. Don't edit their config for them unless asked.

## First call

1. Write the prompt to a file with the Write tool (cleaner than heredoc quoting):

   ```
   /tmp/<some-unique-name>.md   ← not /tmp/kimi-prompt.md (see "Hard rules")
   ```

   Use `mktemp` if you need a path: `mktemp -t kimi-prompt-XXXX`. Keep it under 200KB — the prompt travels as a CLI argument, and kimi can read repo files itself; point it at paths instead of pasting blobs.

2. Run the helper. Default thinking effort is `max` — keep it unless the user asks otherwise:

   ```bash
   ~/.claude/skills/kimi/scripts/run-kimi.sh <prompt-file> <cwd> max kimi-code/k3
   ```

   Arguments are positional: `<prompt-file>` (required), `<cwd>` (defaults to `$PWD`; kimi has no `-C` flag, the script cds there), `<effort>` (defaults to `max`), `<model>` (defaults to the account's `default_model`). **Pass `kimi-code/k3` explicitly** — K3 is the flagship (1M context, always-thinking) and the strongest reviewer. If kimi errors that the model/alias is unavailable (K3 needs a paid tier; alias names come from `kimi login` provisioning — check `kimi provider list`), retry once with the model argument omitted to use the account default, and tell the user which model actually answered.

3. Kimi calls can take several minutes at `max` effort. Run in the background (`run_in_background: true`) if you have other work; otherwise accept a long foreground wait.

4. The script's stdout ends with five lines you must capture:

   ```
   KIMI_DIR=/var/folders/.../kimi-XXXXXXXX
   SESSION_ID=<opaque id>
   RESPONSE_FILE=/var/folders/.../kimi-XXXXXXXX/response.md
   LOG_FILE=/var/folders/.../kimi-XXXXXXXX/log.txt
   FILES_CHANGED=none|DETECTED|unknown
   ```

5. **Echo the SESSION_ID and KIMI_DIR back in your reply to the user**, e.g.:

   > Kimi session: `session_019e...` (files in `/var/folders/.../kimi-XXXXXXXX`)

   That puts them in the conversation transcript so a later turn can resume even after the Bash shell that ran the script is gone.

6. Read kimi's reply with the Read tool from `RESPONSE_FILE`. Act on `FILES_CHANGED=DETECTED` before anything else.

Exit codes: `0` = completed; `3` = blocked, `6` = paused (goal-mode statuses — rare in one-shot prompts); anything else is a failure — read the LOG_FILE tail the script prints. A common first-run failure is `No model configured`: kimi isn't logged in — ask the user to run `kimi login` (device-code flow, ~30s); never run auth flows yourself. Beta caveat (true as of 2026-08): Kimi Code access is beta-gated — `kimi login` can complete the OAuth device flow and STILL fail with "unable to verify your membership benefits", leaving `kimi provider list` empty. That means the account has no beta access / active plan yet; it is not a bug in the flow, so don't retry-loop it — surface it to the user and stop.

If the SESSION_ID scrolled out of context but you still have KIMI_DIR, the id is also persisted at `$KIMI_DIR/session_id` — `resume-kimi.sh` reads it from there when its first argument is empty. The original cwd is persisted at `$KIMI_DIR/cwd` and reused on resume.

## Following up / resuming

If kimi's response is unclear, seems wrong, or you want to push back, **resume the same session** rather than starting fresh — kimi retains its prior reasoning.

```bash
~/.claude/skills/kimi/scripts/resume-kimi.sh <session-id> <followup-prompt-file> <kimi-dir> max
```

Pass the same `<kimi-dir>` you got back from the first call so follow-up files (`response-1.md`, `followup-1.md`, `log-1.txt`, …) accumulate in one place and the run reuses the original cwd. The script auto-numbers suffixes so prior turns aren't overwritten. If both `<session-id>` and `<kimi-dir>` are passed, the script verifies they match and refuses to run on mismatch, which prevents writing follow-up artifacts into an unrelated prior run's directory.

If you only have the dir (the SESSION_ID scrolled out of context), pass an empty string for the session id and the script will read it from `<kimi-dir>/session_id`:

```bash
~/.claude/skills/kimi/scripts/resume-kimi.sh "" <followup-prompt-file> <kimi-dir> max
```

Do not run `resume-kimi.sh` in parallel against the same `<kimi-dir>` — the numbered-suffix selection isn't atomic. Sequential resumes are fine.

Resume whenever you disagree with kimi, need clarification, want to point out an error in its response, or want to test whether it holds its position under pushback. Starting a new session throws away its context and often wastes a round-trip re-establishing setup.

## Thinking effort and model

Always run kimi at `max` thinking effort — that's what the helper scripts default to (exported as `KIMI_MODEL_THINKING_EFFORT`, kimi's forced override), and what the third positional argument controls. The whole point of asking kimi is to get its strongest critique; lower effort defeats the purpose. Valid levels: `off` | `low` | `high` | `max` (some models accept a narrower set; the env override forces it regardless).

Model selection (fourth positional on run, fifth on resume, or `$KIMI_MODEL`):

- **`kimi-code/k3`** — Kimi K3, the flagship (July 2026): 1M-token context, always-thinking, efforts low/high/max. Requires a paid Kimi Code tier. **Use this for consults.**
- Account default (empty model argument) — the login-managed `default_model`, typically `kimi-code/kimi-for-coding` (Moonshot's rolling coding alias, K2.7-Code-class). The fallback when K3 is unavailable.
- Aliases are provisioned by `kimi login` into `~/.kimi-code/config.toml`; list them with `kimi provider list` if a name errors.

Only deviate from K3-at-max when the user asks or when the account can't access it.

## Writing the prompt

Kimi starts with zero context from this conversation. Brief it like a colleague who just walked in. The prompt should include:

1. **The reviewer contract, first line** — "You are reviewing only. Do NOT create, modify, or delete any files, and do not run commands that change state."

2. **The question** — what specifically do you want feedback on? "Review my plan" is too vague. "Is my plan for X sound? Specifically, is the assumption about Y correct, and will the approach in Z handle edge case W?" is better.

3. **Facts vs. inferences vs. asks** — be explicit about which is which. Kimi can't tell them apart from prose alone.
   - **Facts**: things you verified from the code, docs, or user — give file paths and line numbers.
   - **Inferences**: things you deduced but didn't verify — label them clearly ("I inferred that...", "I'm assuming...").
   - **Plans/observations under review**: the thing you actually want critiqued — set it off in its own section.

4. **Relevant context** — paste or reference the specific code, file paths, constraints, and prior decisions kimi needs. Prefer pointing kimi at files (it reads the cwd workspace) over pasting large blobs, but paste short snippets inline so kimi can't miss them.

5. **Explicit instruction to be critical** — ask kimi to look for flaws, wrong assumptions, missed edge cases, and better alternatives. Otherwise it tends to be agreeable.

6. **Response shape** — tell kimi what you want back. A short verdict + bulleted concerns is usually more useful than a long essay.

### Prompt template

```
You are reviewing only. Do NOT create, modify, or delete any files, and do not run commands that change state (no installs, no git writes). Read-only inspection commands are fine.

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

## After kimi responds

Don't just relay kimi's response to the user. Do your own pass:

- **Check the trailer first**: `FILES_CHANGED=DETECTED` means the worktree changed during the run — inspect the stderr diff and `git status` before trusting anything else.
- **Verify claims**: if kimi says "function X does Y", "file Z doesn't exist", or "flag W isn't supported", check it. Kimi can hallucinate file paths, symbols, or API details. Verify concrete factual claims against the repo, docs, or `--help` before acting on them.
- **Weigh concerns by strength**: distinguish real objections from surface-level nitpicks.
- **Flag disagreements explicitly**: if kimi contradicts something you believe, tell the user both views and your current take — don't silently flip.
- **Resume rather than start over**: if you have a specific pushback or clarifying question, run `resume-kimi.sh` with the saved session id instead of opening a new session.
- **Summarize for the user**: a short digest ("kimi flagged X and Y, I think X is valid and Y is a misread because...") is more useful than pasting the raw response. Offer the `RESPONSE_FILE` path in case they want to read it directly.

## Hard rules

These mirror the codex skill's rules — they exist because past sessions invented unsafe workarounds. Don't.

1. **Never write kimi artifacts to a fixed shared path — anywhere.** No `/tmp/kimi-prompt.md`, no `~/.cache/kimi-current`, no fixed mailbox file of any kind, regardless of directory or naming scheme — such files cross-contaminate concurrent Claude sessions. The only acceptable per-invocation paths are those allocated freshly via `mktemp` (which the scripts do internally) and a per-call prompt file you create with `mktemp -t kimi-prompt-XXXX`.

2. **Never use `kimi --continue` / `-c`, and never bare `-S` without an id.** `--continue` picks the most recent session in the cwd — across all Claude sessions working in that repo, not just yours. Bare `-S` opens an interactive picker that can't work non-interactively. Use the `SESSION_ID` you captured from `run-kimi.sh`. If you don't have it but you do have KIMI_DIR, pass `""` as the first arg to `resume-kimi.sh`. If you have neither, tell the user and start a new session rather than gambling on `--continue`.

3. **Never invoke `kimi -p` directly from the Bash tool.** Use the helper scripts. Direct invocation loses the session-id capture, the worktree tripwire, and the artifact dir, and forces you back into the multi-call mktemp/grep dance that caused the original cross-contamination bug in the codex era.

4. **Never run `kimi login` or any auth flow yourself.** If kimi reports no model configured / auth errors, tell the user to run `! kimi login` (device-code flow) and wait.

5. **Model/effort discipline**: `kimi-code/k3` at `max` effort per this skill; deviate only on explicit user request or documented unavailability fallback (and say so). Overrides go through the positional arguments (or `$KIMI_MODEL`), never by editing the scripts ad hoc.
