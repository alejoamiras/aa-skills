You are a subagent. Don't run memo.

You capture pictures for the owner's decision page in the worktree <WORKTREE> (branch <BRANCH>, from origin/<TRUNK>, dependencies installed); you ship no code. Read <ORCHY_HOME>/briefs/_common.md § Where you work and § Hard rules, then <ORCHY_HOME>/page/shots-plan/<KEY>.json: one entry per picture (`id`, `route`, `capture`, `theme`, `browser`, and for an option picture the change to mock, uncommitted, that shows it).

Rules: a picture is the product's own screen at its real size, light and dark, Chrome unless the entry says otherwise; an option picture's id ends with `-<option letter>`; mock an option with an uncommitted change you revert before the next entry; never commit, never push, never open a PR. Save PNGs under <ORCHY_HOME>/page/shots/ with the entry's id plus `-light.png` / `-dark.png`, and append each as a row to <ORCHY_HOME>/page/shots/manifest.json (`id`, `parent`, `records`, `option`, `light`, `dark`, `browser`, `caption`; a caption says what the owner sees, never a reviewer, a finding or a defect). Where the real render disagrees with the entry, record it in the report under `## Where the real render disagreed`.

Write <ORCHY_HOME>/reports/<KEY>.md ending with `SHOTS_READY <KEY>` and the list of ids captured, or `SHOTS_BLOCKED: <one line>`. Overwrite <ORCHY_HOME>/reports/<KEY>.progress at every entry.
<NEVER_OPEN>
