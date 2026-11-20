# gemini

Second-opinion consults from Google's Gemini (`gemini-4-carbon`) through the paid Gemini API, usable standalone ("ask gemini", "have gemini review X"). Unlike `codex`, `claude` and `kimi`, Gemini here is not an agent: it reads only the prompt, never the repo, so the caller pastes the material under review.

Three scripts, the same shape as the other consult skills:

- `scripts/run-gemini.sh <prompt-file> [cwd] [effort] [model]` starts a conversation.
- `scripts/resume-gemini.sh <gemini-dir> <prompt-file>` sends a follow-up.
- `scripts/fetch-gemini.sh <gemini-dir>` collects or reports the newest turn without submitting anything.

Each turn is a stored background interaction (`POST /v1beta/interactions`), so Google holds the conversation and a call that is cut can be collected later with no second charge. Stdout ends with a `GEMINI_DIR` / `RESPONSE_FILE` / `LOG_FILE` / `ENGINE` trailer; exit 3 means "pending, run fetch", and every failure ends with an `ERROR:` and a `NEXT:` line that says whether a new submission may be charged.

## Key file

The key lives in `~/.config/gemini/.env`, mode 600, outside every repo: one line, `GEMINI_API_KEY=<value>`, the value only letters, digits and `. _ ~ -` (an echo of such a key stays a literal match for the log redactor). It is the second named key-file exception in AGENTS.md. Only `engines/api.ts` reads it, started by `engines/api`, a launcher that runs Bun from an empty dir with only `PATH` and `XDG_CONFIG_HOME`, so no inherited `BUN_OPTIONS`, debug variable, `.env` or `bunfig.toml` reaches the process that holds the key. The key leaves only in the `x-goog-api-key` header, to a fixed Google origin, with redirects refused. Agents never read the file; their preflight is `ls -l`.

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
