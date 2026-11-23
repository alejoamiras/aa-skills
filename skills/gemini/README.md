# gemini

Second-opinion consults from Google's Gemini (`gemini-4-carbon`) through the paid Gemini API, usable standalone ("ask gemini", "have gemini review X"). Unlike `codex`, `claude` and `kimi`, a consult is not an agent: it reads only the prompt, never the repo, so the caller pastes the material under review. The [live worker](#live-worker-linux) is an agent, on Google's Antigravity CLI.

Three scripts, the same shape as the other consult skills:

- `scripts/run-gemini.sh <prompt-file> [cwd] [effort] [model]` starts a conversation.
- `scripts/resume-gemini.sh <gemini-dir> <prompt-file>` sends a follow-up.
- `scripts/fetch-gemini.sh <gemini-dir>` collects or reports the newest turn without submitting anything.

Each turn is a stored background interaction (`POST /v1beta/interactions`), so Google holds the conversation and a call cut after its turn's id was saved can be collected later with no second charge. Stdout ends with a `GEMINI_DIR` / `RESPONSE_FILE` / `LOG_FILE` / `ENGINE` trailer; exit 3 means "pending, run fetch", and SKILL.md's "Exit codes" section says what every other exit prints.

## Key file

The key lives in `~/.config/gemini/.env`, mode 600, outside every repo: one line, `GEMINI_API_KEY=<value>`, the value only letters, digits and `. _ -` (JSON, percent and form encoding leave such a key as it is, so an echo stays a literal match for the log redactor). It is the second named key-file exception in AGENTS.md. Only `engines/api.ts` and, for a worker, `engines/agy.ts` read it. A consult's reader is started by `engines/api`, a launcher that runs Bun from an empty dir with only `PATH` and `XDG_CONFIG_HOME`, so no inherited `BUN_OPTIONS`, debug variable, `.env` or `bunfig.toml` reaches the process that holds the key. The key leaves only in the `x-goog-api-key` header, to a fixed Google origin, with redirects refused. Agents never read the file; their preflight is `ls -l`.

## Owner setup

On a machine that should consult Gemini:

```sh
(umask 077; set -C; mkdir -p ~/.config/gemini && read -rs k && printf 'GEMINI_API_KEY=%s\n' "$k" > ~/.config/gemini/.env)
echo api > ~/.agents/gemini-engine
```

`read -rs` keeps the key out of the shell history and the screen; `set -C` refuses to overwrite an existing file. In AI Studio: restrict the key to "Gemini API only", set a monthly spend cap with an alert (the cap can lag about ten minutes), and pick the retention period. Seven days is enough for follow-ups that come within hours.

A real `bun` binary must be on `PATH`. The launcher starts Bun with no `HOME`, so a version-manager shim that needs `HOME` exits 127.

## Retention

Prompts and answers stay stored at Google for the retention period: 55 days by default on a paid project, or 7, 14 or 28 days if the owner chose that. A failed turn is left out of later follow-ups but stays stored, no command deletes it, and AI Studio's logs keep their own copy.

Invocation, cost and the hard rules live in [`SKILL.md`](SKILL.md).

## Live worker (Linux)

`scripts/worker-gemini.sh` runs Gemini as an agent: Google's Antigravity CLI (`agy`) in an `agent-worktree` worktree, running every command it decides on. A Claude Code director started with `--dangerously-skip-permissions` starts it, messages it, waits on its turns and stops it. You can attach to its tmux session (`tmux -L gemini-worker`) to watch, type a message, or press Ctrl-C to stop it. [`WORKER.md`](WORKER.md) is the director's guide.

### Owner setup

The worker uses the consult's key file; it does not need `~/.agents/gemini-engine`. It needs Linux, tmux, jq 1.7 or later, git and a real `bun` on `PATH`.

1. Turn off `agy`'s self-update: put `export AGY_CLI_DISABLE_AUTO_UPDATE=true` in your shell profile. The worker sets it for its own `agy`, but a run by hand without it lets `agy` replace itself, and the next start refuses the changed file.
2. Install `agy` by hand. Read Google's installer (`https://antigravity.google/cli/install.sh`), then do its steps yourself: download the archive, check its SHA512 against the manifest, and copy the binary to `~/.local/bin/agy`. Skip `agy install`: it only edits shell profiles.
3. Put `"modelProvider": "gemini"` in `~/.gemini/antigravity-cli/settings.json`. Without it `agy` ignores the key and may run on a Google sign-in, a consumer plan, so the worker refuses to start.
4. Never sign in with Google inside `agy`; if a sign-in exists, sign out first. Its header should read "Gemini API key".
5. Write the pin, the record of the `agy` you approve. Only you write it; agents never do.

   ```sh
   (umask 077; p=$(realpath ~/.local/bin/agy); printf 'path=%s\nsha256=%s\nversion=%s\n' "$p" "$(sha256sum "$p" | cut -d' ' -f1)" "$("$p" --version | head -1)" > ~/.agents/gemini-agy)
   ```

   Its three lines are `path=` (the binary's real path), `sha256=` (its hash) and `version=` (its `--version`). The worker hashes the binary at every start, runs exactly the file it hashed, and refuses any other. After every `agy` update, check the new binary, then rewrite the pin.
6. In your own terminal, never inside Claude Code, run `~/.claude/skills/gemini/scripts/worker-gemini.sh tui`. It starts the pinned `agy` interactively with the key and without the permission flag, and refuses to run under an agent. When `agy` exits, `tui` ends whatever it left running.
   - Pick a colour scheme.
   - On "Terms of Service & Data Use", untick the data-collection box before Done: pressing Done accepts the terms.
   - Answer the folder-trust prompt.
   - In `/config`, set Enable Telemetry off, then quit.

   `worker-gemini.sh tui models` lists the model names.

A worker can plant files that run code with the key at every later start, your own `agy` included. So the worker refuses `~/.gemini/config/hooks.json`, and refuses `mcp_config.json` unless it is empty or has no `mcpServers` entry. `agy` writes an empty `mcp_config.json` itself.

### Where the key goes

The key is in the environment of `agy`, so every command a worker runs can read it, and so can any process of your user through `/proc`. The worker keeps it out of argv, tmux's environment, its log and its pane. A sender can still put it in a message; the pump refuses and deletes such a message, unsent. What `agy` writes on its own is outside that promise: scan for the literal key yourself now and then, never through an agent (`grep -rlFf <(sed -n 's/^GEMINI_API_KEY=//p' ~/.config/gemini/.env) ~/.gemini ~/.cache/gemini-worker`; no output means clean). The bounds are the key's "Gemini API only" restriction, the project spend cap and revoking the key. Where `/proc/sys/kernel/core_pattern` pipes crashes to a collector, the launcher's `ulimit -c 0` does not stop the kernel handing that collector a crash image, which can hold the key; on the host this was built on, the collector stored nothing in a test with a canary key.

### Spend

There is no default token cap. `start --cap <tokens>` ends a worker after the turn that reaches the cap. The count includes cached reads, since `agy` reports cumulative totals with them. Without a cap, three things bound a worker:
- its watchdog: 30 minutes per turn, or 15 minutes with no output;
- its director's life;
- the AI Studio project spend cap.

That project cap is the only bound on money, and it lags about ten minutes, so set it before the first worker. For scale: on 2026-11-23, three short turns counted 28,794 tokens plus 35,972 cached reads, about 7 cents at Carbon's November price.

### Out of scope

- Codex directors and headless leads.
- Steering or cancelling a turn in flight.
- Resuming an ended worker, except by hand in your own terminal: `worker-gemini.sh tui --conversation <id>`, with the id from the `init` event in the worker's log.
- A worker outliving its director.
- Listing or tailing beyond `tmux -L gemini-worker ls` and `wait`.
- macOS, and pruning old state dirs under `~/.cache/gemini-worker/`.
- `agy acp`, a key-injecting proxy, a guardian process, an installer or an updater.
