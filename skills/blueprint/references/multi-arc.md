# Blueprint: multi-arc delivery

Read this file before writing the Delivery section of a plan with more than one arc, or one that recommends lanes. It holds review pipelining, parallel lanes and the agent-safe `gh stack` commands. Whatever the plan adopts from here is written into its own Delivery and Post-implementation sections: the implementing session reads plan.md, not this file.

## Review pipelining and parallel lanes

Both are written into plan.md, audited, and approved with the rest of the plan; nothing here is improvised mid-run.

- **Review pipelining** (multi-arc plans, per boundary). Delivery may mark an arc boundary `pipelined` and name the interfaces arc N+1 consumes from arc N as frozen. At that boundary:
  - In this order: commit arc N to a clean tree, run `gh stack add <arc-N+1-branch>` in the plan worktree (which releases arc N's branch), then check out arc N's branch in a review worktree (`git worktree add <path> <arc-N-branch>`), with its own deps and run-isolation claims.
  - Codex reviews in that worktree, and fixes are committed there, so each resumed pass sees them. Meanwhile the plan worktree implements arc N+1, but its loop does not start yet.
  - No `gh stack sync` or rebase while the review runs, even though arc N moves.
  - When N's loop converges: checkpoint N+1 to a clean tree, run one `gh stack sync`, rerun N+1's gates, and remove the review worktree. Only then may N+1's loop start.
  - A fix that changes a frozen interface ends pipelining at that boundary: finish N's loop, sync, then rework N+1.
- **Parallel lanes** run only when the owner approves them at the approval gate. Agent subagents only, at most 3. The plan then pins down:
  - the common base SHA;
  - the lanes table: lane → phases → owned paths → `Agent` model → worktree slug and branch;
  - the join order and the exact commands that rebase each lane onto the stack tip as the next arc;
  - the gates rerun after each join; any conflict resolution is re-reviewed before that arc counts as clean.

  The implementing session coordinates: only it touches the stack, plan.md, `index.md` and `lessons.md`, and it removes each lane worktree after its join.

## `gh stack` mechanics (agent-safe forms)

`gh stack` prompts interactively when underspecified — always pass branches and flags explicitly:

- **Start** (arc 1): `gh stack init --adopt <current-branch>` to make the worktree branch layer 1, or `gh stack init <arc-1-branch>`; add `--base <trunk>` if trunk isn't the repo's default branch.
- **Arc boundary** (previous arc's phases all green AND its quality loop converged — see the Post-implementation section; at a `pipelined` boundary, as soon as the phases are green): `gh stack add <arc-N-branch>` — subsequent commits land on the new layer.
- **Publish — only in the Delivery step, after the quality loops converge** (see PR timing, `SKILL.md` Delivery section): `gh stack submit --auto` (titles auto-generate from commits; conventional commits make them right), then `gh pr edit` each PR with a proper body. Then the close-out layer: `gh stack add <slug>-close-out`, commit the close-out (it cites the arc PR numbers, which is why it comes second), and `gh stack submit --auto` again — it opens a PR only for the branch that lacks one. Then watch checks. Never submit during implementation, not even as drafts.
- **Stay current**: `gh stack sync` after trunk moves or fixes land on a lower arc (during a pipelined review, only once, when that review converges) — it cascade-rebases and pushes `--force-with-lease --atomic`. On conflict: `gh stack rebase`, resolve, `--continue`.
- Per-arc loop fixes land on their own arc automatically (the arc is the tip while its loop runs). Final-integration-pass fixes go on the top arc unless they squarely belong to a lower one and moving them is cheap (`gh stack down`/`up`, then `gh stack sync` to cascade).
- **`gh stack merge` merges the named PR AND every PR below it** — a land-to-trunk action: the user's call, never autonomous/AFK.

Caution: sync/rebase rewrite arc-branch history. Fine while the agent owns every arc branch; the moment another human pushes to one, stop syncing autonomously and surface it.
