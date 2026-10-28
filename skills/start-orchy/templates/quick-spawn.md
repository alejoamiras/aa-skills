You are a subagent. Don't run memo.

You run quick lane `<LANE>`: one small change, no plan, in the worktree <WORKTREE> (branch <BRANCH>, created from origin/<TRUNK> at its current head, dependencies installed). Read <ORCHY_HOME>/briefs/_common.md in full with `<LANE>` = <LANE>, `<KEY>` = <KEY> and `<WORKTREE>` = <WORKTREE>, then the lane scope <ORCHY_HOME>/briefs/<LANE>.md. Every rule there binds except what a lane without a plan does not have: blueprint and its Phase 0 answers, `plan.md`, `STATUS.md`, `OWNER-ASKS.md` and the close-out. The panel's records and every finding's path go in your report.

**Judge the bounds before your first edit**: one surface, at most 5 files, nothing a person sees beyond the decisions quoted below, and no change to a gate file (CI, lint, type or test config), a persisted shape (a schema, a stored format, a migration), a dependency, a lockfile or a workflow. Past them, edit nothing: leave the worktree clean, push nothing, and end with `LEAD_BLOCKED: needs a plan` and `ASKS: left out askN needs a plan` for each ask the lane brief names. The orchestrator routes them to a planned lane.

Owner decisions this change builds, quoted by id and text: <DECISIONS>

Within the bounds: make the change with its tests, run the gates at retry 0 for the touched surfaces, then the Codex fix loop on the diff (`run-codex.sh` on <CODEX_MODEL> at <CODEX_EFFORT>, read-only; until clean, hard stop at three rounds). Push only `worktree-<LANE>` or a `<LANE>-*` branch, never <TRUNK>, a release branch or a tag, and open one ready PR against <TRUNK>, <CLOSES>. Leads never merge. Append the final block from the common brief (`LEAD_DONE`, the `PR #` line, `HEAD <full sha>`, `CODEX:`, `OWNER_ASKS: none`, `ASKS:`, `PLAN: none`) to <ORCHY_HOME>/reports/<KEY>.md and overwrite <ORCHY_HOME>/reports/<KEY>.progress at every gate.

State today (<DATE>): <STATE>. Never yield while a run is in flight: run gates in the foreground with a bounded timeout; never wait on a log file a background job may never write.
<NEVER_OPEN>
