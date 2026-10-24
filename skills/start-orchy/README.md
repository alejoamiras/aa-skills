# start-orchy

One Claude Code session runs a repository as an always-on program, and is where the owner asks for anything about it: a question is answered, a change becomes a lane, "file it" becomes an issue. It triages the open issues into lanes too, gives each lane its own git worktree and a headless lead on one of the owner's other `claude-usage` accounts, merges converged PRs on a fixed policy, and turns every product decision into a page with pictures that the owner signs. It watches PRs, issues and the trunk every two minutes, ticks every 35 minutes while there is work, and idles without inventing any when there is none.

What makes it safe to leave running:

- **The owner's words stay with the orchestrator.** Each ask is kept in a private local ledger and is handed on only as a restatement that carries the behavior and how to check it, never people, places, reasons or quotes; a restatement that dropped anything waits for the owner's OK before any lead or reviewer sees it. The restatement passes a copy check and a secret scan before it is stored, and every prompt, brief and note passes the copy check again before a lead reads it.
- **Leads never merge; the orchestrator merges only on a mechanical policy** (pinned head, every required check green, MERGEABLE CLEAN, the lead's own done marker, a gate-weakening scan it reads), and never into a protected branch.
- **The owner decides what a person sees**, on a decision page with each option's own picture, or by a message quoted on the issue. Nothing visible ships on an audit's approve.
- **Nothing leaves the machine that maps the owner's accounts**: a prompt that carries a roster name is refused before the launch, and a PR whose diff, body or commit messages carry a home path or an account assignment is flagged before it merges.
- **Leads stay steerable and accountable**: auto permission mode by default, a note to a live lead lands after its next tool call (`ORCHY say`), a stuck lead shows as `STALLED?` with the command it is stuck on, the caps hold across every program on an account, a failed trunk check holds merges, and every lane ends with a receipt (API-equivalent cost, PRs, closed issues).
- **State lives outside the repo** (`~/.cache/orchy/<owner>-<repo>`): reports, briefs, prompts, watchers, pages. The repository sees only lane branches, plans and PRs.

The playbook is [`SKILL.md`](SKILL.md); the rules with their evidence are [`references/house-rules.md`](references/house-rules.md); the decision-page data model is [`page/README.md`](page/README.md). The `blueprint` skill plans every lane, the `codex` skill is the panel's foreign leg, `agent-worktree` and `claude-usage` (this repo's `bin/`) are the hands.
