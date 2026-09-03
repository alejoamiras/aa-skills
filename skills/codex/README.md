# codex

Second-opinion consults from a different model family via the [Codex CLI](https://github.com/openai/codex). Used as the cross-model audit leg by [`blueprint`](../blueprint/) and [`harden`](../harden/), or standalone ("ask codex", "have codex review X").

Ships three helper scripts: `scripts/run-codex.sh` (fresh session — prompt file in, response + session ID out), `scripts/resume-codex.sh` (continue a captured session for follow-ups and rebuttals) and `scripts/image-codex.sh` (generate or edit raster images through Codex's built-in `image_gen` tool — gpt-image-2 on the ChatGPT plan, no API key; spec file + output dir in, verified image paths out). Prompt files go through `mktemp`, sessions are resumed by explicit ID — never `--last`, never fixed shared paths, so parallel agents can't cross wires.

Invocation and effort conventions live in [`SKILL.md`](SKILL.md).
