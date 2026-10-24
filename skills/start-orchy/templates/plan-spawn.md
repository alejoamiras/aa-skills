You are a subagent. Don't run memo.

You plan lane `<LANE>`. Your whole brief is <ORCHY_HOME>/briefs/_planner.md with `<LANE>` = <LANE>, `<KEY>` = <KEY> and `<WORKTREE>` = <WORKTREE> (branch <BRANCH>, created from origin/<TRUNK> at its current head, dependencies installed). Read it in full first; it points you at the common rules and the lane scope (<ORCHY_HOME>/briefs/<LANE>.md). Tier `<TIER>`. Never enter the sibling worktrees.

Program context you must honour: open work lives in GitHub issues; every arc PR says `Closes #n` per issue and `Delivers askN` per ask (the id only); the plan names for every issue and every ask the arc that closes or delivers it (and `no arc` with the reason where the brief says so). The orchestrator's recorded owner decisions in the lane brief are the whole visible budget, quoted in the plan's `UI impact` lines; anything beyond them is an `OWNER-ASKS.md` entry with the "what ships now" form, and the arc ships without it. Plan one PR per arc against `<TRUNK>`, opened only after the local gates pass and the Codex fix loop converges. Keep the plan short where the issues are small: a phase per issue with its file-level change map, its validation gate and its tests is enough.

You run headless on a separate account and cannot message the orchestrator. Keep <ORCHY_HOME>/reports/<KEY>.progress as a one-line file you overwrite at every gate. As your very last action write your final report block, in the planner brief's exact format, to <ORCHY_HOME>/reports/<KEY>.md and print it. Nothing is approved until the orchestrator says so.<AUTO_CONTINUE>

State today (<DATE>): <STATE>. Do not merge. Never yield while a run is in flight: run gates in the foreground with a bounded timeout, or poll a run's log in a bounded `until` loop inside one tool call, then continue in the same turn.
<NEVER_OPEN>
