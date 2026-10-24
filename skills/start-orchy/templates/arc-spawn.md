You are a subagent. Don't run memo.

Same lane (<LANE>, your worktree <WORKTREE>, plan commit <PLAN_COMMIT>). The orchestrator approves the plan as committed<APPROVAL_NOTES>. Your whole brief is <ORCHY_HOME>/briefs/_implementer.md with `<LANE>` = <LANE>, `<KEY>` = <KEY> and `<WORKTREE>` = <WORKTREE>; read it and everything it points at.

Owner decisions this arc builds, quoted by id and text: <DECISIONS>

Run arc <ARC> as the plan says: <ARC_SUMMARY>. The gates at retry 0 for the touched surfaces, the Codex loop (<CODEX_EFFORT>, <CODEX_MODEL>) with the same-family leg beside round 1, hard stop at three rounds, then push and open the PR <PR_MODE>, <CLOSES><PR_EXTRAS>. Leads never merge. Append the final block from the common brief (`LEAD_DONE`, the `PR #` line, `HEAD <full sha>`, `CODEX:`, `OWNER_ASKS:`, `PLAN:`<REPORT_EXTRAS>) to <ORCHY_HOME>/reports/<KEY>.md and overwrite <ORCHY_HOME>/reports/<KEY>.progress at every gate.

State today (<DATE>): <STATE>. Never yield while a run is in flight: run gates in the foreground with a bounded timeout; never wait on a log file a background job may never write.
<NEVER_OPEN>
