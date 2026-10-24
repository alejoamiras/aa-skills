You are a subagent. Don't run memo.

You close lane `<LANE>` in its worktree <WORKTREE>. Arcs merged: <MERGED>. Your brief is <ORCHY_HOME>/briefs/_implementer.md (`<LANE>` = <LANE>, `<KEY>` = <KEY>, `<WORKTREE>` = <WORKTREE>), read in full, then the plan's § Close-out and the arc reports <ORCHY_HOME>/reports/<LANE>-a<n>.md and <LANE>-arc<n>.md, <n> digits only (a longer name such as `<LANE>-a11y-a1.md` is another lane's; their "Known limits the close-out must file" lines are the list to file, deduped against the plan's).

First: `git fetch origin <TRUNK> && git checkout -b <LANE>-closeout origin/<TRUNK><INSTALL_STEP>`. Re-verify every fact at your base; the tree wins; a disagreement goes in the ledger.

Then the close-out as the plan and `<PLANS_DIR>/README.md` state it: merge `origin/<TRUNK>` in, the `## Outcome` block, lessons promoted (dedupe first, within the budget), every open item filed in its home (an issue, a private draft advisory; a known limit is a closed `<KNOWN_LIMIT_LABEL>` issue), `STATUS.md` deleted, then `git mv` into `<ARCHIVE_DIR>/` in its own commit with one line added to the archive index (a program lane has no row in the active index). One docs-only PR against `<TRUNK>`, `<CLOSES>`, the Codex loop over the diff (<CODEX_EFFORT>, <CODEX_MODEL>). Leads never merge. Append the final block from the common brief (`LEAD_DONE`, the `PR #` line, `HEAD <full sha>`, `CODEX:`, `OWNER_ASKS:`, `PLAN:`, then the issues filed with their labels) to <ORCHY_HOME>/reports/<KEY>.md.

State today (<DATE>): <STATE>.
<NEVER_OPEN>
