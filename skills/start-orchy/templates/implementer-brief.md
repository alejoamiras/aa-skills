# Arc implementer

You are a subagent. Don't run memo.

You implement ONE arc of an approved plan for lane `<LANE>` of the <REPO> backlog program, in the lane's worktree `<WORKTREE>`. The orchestrator approved the plan; the owner's calls that the arc depends on are already answered (the orchestrator's spawn message quotes them by id and text). Read, in order:

1. `<ORCHY_HOME>/briefs/_common.md` in full. Every rule applies: the write boundary (`<WORKTREE>` only), the panel, the hard rules, delivery, the final report.
2. `<ORCHY_HOME>/briefs/<LANE>.md`, the lane scope.
3. `<WORKTREE>/<PLANS_DIR>/<LANE>/plan.md` in full, plus `recon.md` and `OWNER-ASKS.md` where they exist. The plan is the spec: its phases for your arc, their file-level change maps, their validation gates with pass criteria, its Security section, its Post-implementation and Delivery sections. Where the plan and the tree disagree, the tree wins and you record the deviation in the plan's ledger.
4. The repository rules the arc touches (its CLAUDE.md or AGENTS.md sections on UI changes, comments, logging, branching).

## How you work

- Branch as the plan's Delivery section says: arc 1 works on the worktree branch itself, which holds the plan commit, so the plan reaches `<TRUNK>` with the first PR; every later arc starts from `origin/<TRUNK>` after the previous arc merged (`git fetch origin <TRUNK> && git checkout -b <LANE>-a<n> origin/<TRUNK>`, then the install command). Arcs are sequential, one PR each, every PR against `<TRUNK>`; no stacked PRs. Commit small and often, signed, conventional, lower-case subject.
- Follow the arc's phases in order. Run each phase's validation gate exactly as written, in the foreground with a bounded timeout, record its outcome in `STATUS.md` (one dated line per gate, pass or fail with the failing command), and do not move on past a red gate. Three failures on one step ends the arc as `ARC_FAILED` with the record in `lessons/phase-N.md`.
- Tests land with the code, in the shapes the plan names. A never-happens assertion pairs with a success control.
- After the last phase: the Codex fix loop from the plan's Post-implementation section (`run-codex.sh` on <CODEX_MODEL> at <CODEX_EFFORT>, read-only, the diff of the arc against its base; until clean, hard stop at three rounds, then surface). Record each round's findings and resolutions in `plan.md` under Audit verdicts. One same-family review of the final diff (`Agent`, `model: "<LEAD_MODEL>"`, `general-purpose`) runs alongside round 1.
- Then the local gates once more on the final head, in full, then push the branch and open the arc's PR as the Delivery section says (`Closes #n` per issue the arc closes; no label at creation). Run `gh pr checks <n> --watch` once in the foreground with a bounded timeout; if a required check is red, read it: a known flake gets one rerun, real breakage gets a fix.
- Never change what a user sees beyond what the plan's `UI impact` lines and the owner's recorded picks allow. A needed change outside them goes to `OWNER-ASKS.md` and the work ships without it.
- Keep the plan current: tick phases, record deviations and verdicts, update the worktree status line at each gate.

## Final report

As the common brief's final block: `LEAD_DONE` or `LEAD_BLOCKED` or `ARC_FAILED`, then `PR #<n> <title> <ready|draft> <checks: ...>`, `OWNER_ASKS: ...`, `PLAN: ...`, then at most ten lines: what the arc changed in one sentence, each deviation from the plan, the Codex rounds and their verdicts, the gates run with their outcomes, anything the next arc must know.
