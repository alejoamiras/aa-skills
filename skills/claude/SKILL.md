---
name: claude
description: Invokes the Claude Code CLI headlessly to get a second opinion from the Anthropic model family (Fable / Opus) on a plan, design, analysis, or piece of code. This is the foreign-reviewer leg for sessions driven by Codex (or any non-Claude harness) — the mirror of the `codex` skill. Use ONLY when the user explicitly asks to involve Claude ("ask claude", "have claude review", "get claude's take") or when a protocol you are running (blueprint, harden) calls for the foreign reviewer and the driver is not Claude Code. Does not invoke proactively. Inside Claude Code itself, use the Agent tool instead — a Claude asking Claude is not a cross-model review.
---

# Ask Claude for Review

Use the `claude` CLI to get a second opinion from a different model family. Claude runs as a separate agent that can read files in the current repo, so it's useful for sanity-checking plans, designs, risky code changes, or observations that you want challenged by a fresh perspective.

**Only invoke this skill when the user explicitly asks for Claude, or when a protocol names the foreign reviewer and you are driving on Codex.** Do not reach for it on your own initiative.

**Claude is not an oracle.** It can be confidently wrong, miss context, hallucinate APIs, or misread the code. Treat its response as input to your own reasoning, not a verdict. Be critical: if Claude disagrees with you, weigh the argument on its merits; if Claude agrees, don't assume that confirms your position.

## How invocation works (read this first)

This skill ships with two helper scripts under `~/.agents/skills/claude/scripts/` (also linked at `~/.claude/skills/claude/scripts/`):

- `run-claude.sh` — starts a fresh headless Claude session
- `resume-claude.sh` — appends a follow-up to an existing session

**Why scripts and not raw `claude -p` calls?** Each shell command runs in a fresh shell — environment variables and shell state do **not** persist between calls. A multi-step pattern like "mktemp a dir, run claude, parse the JSON, resume later" is impossible to do safely across separate calls without a global file, and fixed-path files caused cross-contamination between concurrent sessions in the codex skill's history. The scripts do the whole flow in a single process; the per-invocation temp dir lives only inside it. They print a structured trailer that you read into your transcript, which is the only "memory" that survives across shell calls.

**Codex sandbox — the scripts must run escalated, and escalation may be refused.** `claude -p` needs the network (Anthropic API) and writes its session transcript under `~/.claude/projects/`; neither is possible inside Codex's `read-only` or `workspace-write` sandbox, where the first attempt fails with a DNS/connection error or a permission error. Don't retry inside the sandbox: rerun the script with escalated permissions (`require_escalated` + a one-line justification), which normally surfaces as one approval prompt to the user. `network_access = true` in `~/.codex/config.toml` is not sufficient on its own because of the `~/.claude` writes. **Preflight** before a protocol depends on it: the question is whether the session *has or can obtain* the access the script needs. A session already running with sufficient access (e.g. `danger-full-access`) launches it directly — use what's granted, never widen it yourself. Otherwise you need an approval, and under `approval_policy = never` or with no human present none can be granted by anything in this file — the foreign review is then **blocked**. Say so explicitly, log it (in `lessons/` when inside a plan), and let the calling protocol hold its gate; never fake the review with a same-family pass.

**What the reviewer can and cannot do.** The scripts start Claude with `--safe-mode` (no user CLAUDE.md, hooks, MCP servers, skills or plugins — auth still works, unlike `--bare`, which is API-key only), `--restricted --strict-mcp-config` and `--tools Read,Grep,Glob`: it reads files under `<cwd>` and nothing else. No Bash, so it cannot run `git diff` — put the diff under review in the prompt, as the codex protocol already does. There is deliberately **no writing mode**: a reviewer with edit rights running under Codex's escalated sandbox would have the combined blast radius of both harnesses.

## First call

1. Write the prompt to a file via `mktemp` (`mktemp -t claude-prompt-XXXX`) — never a fixed path (see "Hard rules").

2. Run the helper. Default reasoning effort is `xhigh` — keep it unless the user or the calling protocol says otherwise:

   ```bash
   ~/.agents/skills/claude/scripts/run-claude.sh <prompt-file> <cwd> xhigh read-only
   ```

   Arguments are positional and identical to `run-codex.sh`: `<prompt-file>` (required), `<cwd>` (defaults to `$PWD`), `<effort>` (`low | medium | high | xhigh | max`, defaults to `xhigh`), `<sandbox>` (only `read-only` is accepted — kept positional for parity), `<model>` (defaults to `fable`).

3. Calls take minutes at `xhigh` on a real review. Run in the background if you have other work; otherwise accept a long foreground wait.

4. The script's stdout ends with four lines you must capture:

   ```
   CLAUDE_DIR=/…/claude-XXXXXXXX
   SESSION_ID=<uuid>
   RESPONSE_FILE=/…/claude-XXXXXXXX/response.md
   LOG_FILE=/…/claude-XXXXXXXX/log.json
   ```

5. **Echo the SESSION_ID and CLAUDE_DIR back in your reply to the user** so a later turn can resume even after the shell that ran the script is gone.

6. Read Claude's reply from `RESPONSE_FILE`. `LOG_FILE` is the raw JSON result (`is_error`, `num_turns`, `total_cost_usd`, `permission_denials`) — check `permission_denials` if the answer looks like Claude couldn't see something (a path outside `<cwd>` is denied by design). A non-zero exit means the run is NOT a review: exit 1 covers a reported error, malformed output, and — on resume — an answer under a different session id; don't quote `RESPONSE_FILE` as findings in that case.

If the SESSION_ID scrolled out of context but you still have CLAUDE_DIR, the id is also persisted at `$CLAUDE_DIR/session_id` — `resume-claude.sh` reads it from there when its first argument is empty.

## Following up / resuming

If Claude's response is unclear, seems wrong, or you want to push back, **resume the same session** rather than starting fresh — Claude retains its prior reasoning.

```bash
~/.agents/skills/claude/scripts/resume-claude.sh <session-id> <followup-prompt-file> <claude-dir> xhigh
```

Pass the same `<claude-dir>` you got back from the first call: follow-up files (`response-1.md`, `followup-1.md`, `log-1.json`, …) accumulate there, and the run resumes in the cwd and on the model recorded by the first call (so a session that fell back to `opus` stays on `opus`). If both `<session-id>` and `<claude-dir>` are passed, the script verifies they match and refuses on mismatch. Only the dir? Pass `""` as the session id. If Claude answers under a different session id the script exits 1 and reports the id it actually used — treat that as a fresh session, not a continuation. Don't resume the same dir in parallel — the numbered-suffix selection isn't atomic.

## Reasoning effort and model

Standalone consults run at `xhigh` — the whole point of asking is the strongest critique. A calling protocol may pin lower deliberately (blueprint pins `high` for every foreign-reviewer round); respect the caller's level, never silently bump it. The script sets `--effort` and `CLAUDE_CODE_EFFORT_LEVEL` together because the env var outranks the flag.

The model defaults to **`fable`** (Claude's top-tier alias — Fable 5.1 today), overridable via the fifth positional argument or `CLAUDE_MODEL`; `resume-claude.sh` reuses whatever the first call ran on unless told otherwise. Pass `opus` while Fable is unavailable. `sonnet`/`haiku` are for smoke-testing the plumbing, not for reviews. Check the CLI is logged in with `claude auth status` before a long unattended run.

## Writing the prompt

Claude starts with zero context from this conversation — and, under `--safe-mode`, none of the user's global instructions either. Brief it like a colleague who just walked in — the same template as the codex skill: the specific question; **Facts** (verified, with file:line) vs **Inferences** (unverified, to challenge) vs the thing under review; relevant paths (Claude reads files in `<cwd>` itself — prefer pointing at files over pasting blobs, but paste short critical snippets inline, and paste the diff under review in full since it cannot run `git`); an explicit instruction to be critical ("find problems with this, don't validate it; if the approach is fundamentally wrong, say so"); and the response shape you want ("under N words: one-line verdict, bulleted concerns, then what looks fine"). The script prepends a short role preamble (independent reviewer, not the driver, read-only) — don't repeat it. Anything you paste — diffs, logs — lands in the reviewer's transcript under the driver's `~/.claude/projects/`; redact secrets before sending, exactly as you would for codex.

## After Claude responds

- **Verify claims**: file paths, symbols, flags, "X doesn't exist" — check them before acting. Claude can misread the repo, and it can also misreport its own environment (e.g. that it could not read a file when it never tried).
- **Weigh concerns by strength**; separate real objections from nitpicks.
- **Flag disagreements explicitly** — both views and your current take; don't silently flip.
- **Resume rather than restart** for pushback or clarification.
- **Summarize for the user**; offer `RESPONSE_FILE` for the raw text.

## Hard rules

1. **Never write consult artifacts to a fixed shared path — anywhere.** Only `mktemp` paths: the scripts allocate theirs internally; your prompt file comes from `mktemp -t claude-prompt-XXXX`.
2. **Never use `claude --continue` (or `-c`).** It resumes the most recent session for the cwd — across every session on the machine, not just yours. Resume only by the explicit `SESSION_ID` (or `""` + `CLAUDE_DIR`). Have neither? Tell the user and start fresh.
3. **Never invoke `claude -p` directly.** Use the helper scripts.
4. **Don't override the model unless the user explicitly asks** — override via the positional argument or `CLAUDE_MODEL`, never by editing the scripts.
5. **Never widen the reviewer** — no `--dangerously-skip-permissions`, no `bypassPermissions`, no extra `--tools`, no writing mode. If a task needs Claude to *change* code, that is a driver's job in a Claude Code session, not a consult.
