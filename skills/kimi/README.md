# kimi

Second-opinion consults from Moonshot's model family (Kimi K3 / K2.x) via the [Kimi Code CLI](https://www.kimi.com/code) — the same teammate pattern as [`codex`](../codex/), usable standalone ("ask kimi", "have kimi review X") or as an extra cross-model audit leg.

Ships two helper scripts: `scripts/run-kimi.sh` (fresh session — prompt file in, response + session ID out) and `scripts/resume-kimi.sh` (continue a captured session for follow-ups and rebuttals). Prompt files go through `mktemp`, sessions are resumed by explicit ID — never `--continue`, never fixed shared paths, so parallel agents can't cross wires.

Two differences from the codex skill worth knowing:

- **No read-only sandbox.** `kimi -p` auto-approves tool calls (including writes), so the scripts fingerprint `git status` before/after and report `FILES_CHANGED` in the trailer, and every prompt opens with an explicit reviewer/no-writes contract. Hard enforcement is possible via `[[permission.rules]]` deny rules in `~/.kimi-code/config.toml` if you want it.
- **Effort is an env override, not a flag.** The scripts export `KIMI_MODEL_THINKING_EFFORT` (default `max`); the model defaults to `kimi-code/k3` per the skill's conventions, falling back to the login-managed account default.

Invocation, model, and effort conventions live in [`SKILL.md`](SKILL.md).
