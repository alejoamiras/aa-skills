# Releases and other irreversible acts

The merge policy covers a lane's PR into the trunk. Everything else that cannot be undone (a merge into a release branch, a release PR, a PR no lead opened, Dependabot's included, a tag, a deployment approval, a dispatch) goes through `ORCHY act`, on an authority the owner gave in their own words, and each authority is spent once.

## The release profile

`bun ~/.claude/skills/start-orchy/scripts/release-profile.ts --repo <o/r>` reads the repository with GETs only, each under a 30 s timeout, and prints `orchy.release/1`: exit 0 complete, 3 partial, 2 failed. It names the shape (`promote`, `single`, `none`), the trunk and the release branch with their methods, checks, reviews and what a merge there deploys, the release tool and its PR head, the back-sync, the tag rules, the environments, and the workflows with their publish signals; `unknown` names every field it could not read, and a 403 is unread, never none. A repository's release skill (`.claude/skills/release/SKILL.md`, from my-stack's template) may carry a `release-profile/1` block, which fills only what GitHub's reads left open; where both answer and disagree, the field is unknown. Nothing in the block grants, picks an enforced method, makes a dispatch read-only or relaxes a check.

The bootstrap writes the profile as `orchy.json`'s `release`; a home with none derives it at its first release ask; each release lane derives it again at its start and reports drift. `merge.branches.<b>` is written once, only when that branch's checks are known and not empty, no review is required, there is no merge queue and exactly one method is allowed; `merge.trunk_methods` when the trunk's methods are known. A later derivation never rewrites either: it reports drift, and they change only on the owner's words.

The table goes to the owner wherever the derivation ran (the bootstrap report, or the reply to the first release ask), each unknown with what it blocks ("name `main`'s merge method to enable release merges"). Nothing is asked: release merges stay refused until the owner names what is missing, recorded as an ask.

## Acts

| Act | Grammar | Checked before the call |
|---|---|---|
| merge | `merge <pr> <sha40> <base> <merge\|squash\|rebase>` | The base is the trunk or a `merge.branches` base, the method is one that base takes, and its `required_checks` are not empty. The PR is open, not a draft, at the sha and on that base. A fork never merges into a release branch, and into the trunk only on an OK. A watcher (`merge-<pr>`) then merges on that base's checks with `--match-head-commit` and without `--delete-branch` (a promote's head is the trunk) |
| approve | `approve <run-id> <attempt> <environment>` | The run is `waiting` at that attempt; its event is `push`, `workflow_dispatch`, `release` or `schedule` (a `pull_request_target` or `workflow_run` run carries other code's context); the environment waits on this login's approval; the run's head is on the trunk or a `merge.branches` base |
| dispatch | `dispatch <.github/workflows/name.yml> <ref> <sha40> [<input>=<value> …]` | The ref is the trunk, a `merge.branches` base or a tag, and its head is the sha. Inputs are sorted by name, each named once, and sent as strings |
| tag | `tag <name> <sha40>` | `release.tags` is known and no `creation: restricted` pattern matches the name (those tags are the release tool's); the tag does not exist; the sha is on the trunk or a `merge.branches` base. Tags are lightweight |

`act … --check` runs the checks and calls nothing. A refusal is `refused: <rule>` (exit 1). A call GitHub refused (an HTTP 4xx) still spends its act. Any other failure, a timeout included, prints `AMBIGUOUS` (exit 6): check by hand whether it happened, and ask the owner for an OK only when it did not.

## Authorities

Each is a ledger row that carries the owner's words (`said`) itself; a row without them is no authority, whatever else its ask holds.

- **A go** (`ask go askN -- <words>`) covers one release or hotfix, on the ask laned to it: the owner's request, or one yes to a proposal orchy made. `act … --lane <slug>` uses it when exactly one ask laned to the slug has a live go, and covers each act once: the promote (head the trunk, base the release branch), the release tool's PR (head `release.tool.head`, author `release.tool.bot`), the lane's own PR (its branch, this repository, no app) and the back-sync (head `release.sync.head` into the trunk); an approval of a run this go produced (started after one of its merges or dispatches claimed, at that merge's commit, or at that dispatch's commit as a run of that workflow; a run already waiting is the owner's); a dispatch of a workflow the profile marks as publishing (an environment, or an `id-token`, `npm publish` or `gh release` signal); a tag. A moved head is a new act and needs no new word. The go dies when its ask is done, dropped, reopened or laned elsewhere, and on a bare `ask revoke askN`.
- **An OK** (`ask ok askN <act> -- <words>`) covers that exact act once: a retry, a PR no lead opened, and anything outside a go's reach.
- **A grant** (`ask grant askN merge dependabot <trunk> <method> -- <words>`) stands until revoked and covers Dependabot's own PRs into the trunk: author `app/dependabot`, head `dependabot/…`, this repository, every commit's author `dependabot[bot]`, checked at arming and again at the merge. It never covers an act text a `used:` row names. A grant comes only from the owner's own sentence: never offered on a page, as an `AskUserQuestion` option, or as a recommendation. `grants` lists the live ones; `ask revoke askN <scope>` ends one.

The `used:` row is written before the call, under the ledger lock and after the authority is read again in that lock, so two calls racing on one authority leave one claim. A watcher reads its authority again when it claims, right before its merge call, and before a retry on a moved base: a revoke, or its ask closed, ends it `REFUSED at merge time`, even while another ask's go is live on the lane. The claim is the point of no return: a revoke that lands after it does not stop that call.

## Questions

A go comes from the owner's request or one yes to a proposal. A per-act OK (a PR no lead opened, a retry) and a version outside the go are asked one at a time, in one line that names the PR or run, so the reply cannot cover two. The reply becomes `ask add`, `ask public` and `ask ok askN <act> -- <the words>`. A "no" is `ask said` with the words, then `ask note askN "answered: no"`.

**The version rule.** When the go names a version or a bump, a release that differs waits for the owner's word; when it names none, only a major bump waits. CI cannot judge a version.

## Release lanes

A release runs as a lane with no plan: one light lead per leg (`<lane>-a1`, `-a2`, …), each prompt rendered from `templates/release-spawn.md` with the earlier legs' results, the session resumed while it lives. The lead prepares (the release skill's preflight, the changelog, a version-bump PR, the checks after) and never acts. Its final block, where the last marker line decides as in every report and `ACT`, `STEP` and `RELEASE` are not markers:

```
LEAD_BLOCKED: release acts or owner steps wait   (or LEAD_DONE, or ARC_FAILED: <leg> <reason>)
ACT: merge 41 <sha40> main merge                 zero or more, in the act grammar
STEP: <what the owner does by hand>              zero or more, at most 160 code points, restated
PR #<n> <title> <ready|draft> <checks: …>        only a PR this leg opened into the trunk
HEAD <sha40>
RELEASE: <version or tag> <prepared|promoted|tagged|published|complete>
ASKS: <…>
PLAN: none
```

For each `ACT:`: `scan <pr> <sha>` for a merge, `act … --check`, then `act … --lane <lane>`, and one line to the owner naming what the act triggers (the workflows whose push branches hold the base, and `branch.deploys`). A PR a leg opened into the trunk (a version bump) gets one Codex pass on its pinned diff from the orchestrator, then merges on the lane policy with archive `-`. Each `STEP:` is the owner's: one is a waiting record (`pr:N` for a merge, else `other:<lane>`), several are a runbook. The next leg resumes once the acts have landed and the steps are done. Only the leg that completes the release reports its ask delivered.

**The freeze.** A block with `freeze: true` gets `hold add lane:<lane> trunk` after the back-sync check, so the hold never blocks the back-sync, and `hold done lane:<lane>` when the promote merges (by orchy or by hand) or will not be proposed again. Lane watchers wait at their merge step; leads keep working. `teardown <lane>` also ends it.

**Reserved steps.** A step the repository's release skill reserves for the maintainer is a `STEP:`, never an `ACT:`, even with the owner's OK; the orchestrator never turns a `STEP:` into an act.

**Versions.** A leg whose version breaks the version rule ends `LEAD_BLOCKED: version <v> waits for the owner`: `ask note askN "waiting: version <v>"`, and the owner's reply is a fresh `ask go`.

**The sync.** The back-sync (base the trunk, head `release.sync.head`) merges under the go where the trunk allows its method. Where `sync.blocked_by` names a rule (linear history on the trunk, a required review), it is the owner's `STEP:` and a `pr:N` record whose text each tick refreshes with the PR's checks.

## Hotfixes

The owner's words are the go: `ask lane askN <lane> hotfix`, `ask go askN -- <words>`, then `ORCHY wt-new <lane> --base <branch>` (a `merge.branches` base), which records the base in `wt/<lane>.base`. Leg 1 is a quick lead whose prompt sets `<BASE>` to it and opens its PR into that branch; `scan <pr> <sha> --quick`, then `act merge <pr> <sha> <branch> <method> --lane <lane>`, which keeps the lane checks (head, author, repository) beside the go. The legs after it are a release lane's: the release PR, the approvals, the publish, and the back-sync that brings the fix into the trunk. A bounce tears the lane down against its base (`teardown` proves the worktree with `agent-worktree done --merged --trunk <base>`) and `close-lane` reopens the ask, which ends the go; ask once whether the hotfix proceeds as a planned lane into the same base. On a one-branch repository a hotfix is a quick lane followed by a release lane.

## Runbooks

The owner's own steps for a release or a goal. `ORCHY runbook add <slug> <file>` takes 1 to 20 lines `- [ ] <step>`, each step 1 to 160 characters with no control or bidi character, optionally ending ` (proof: run <run-id>)` or ` (proof: release <tag>)`; the file passes `check-public`, and `add` on an existing runbook appends. The record `other:<slug>` reads `<k> of <n> done; next: <step>`. `runbook tick <slug> <n>` marks a step the owner says is done; `runbook check <slug>` ticks each step whose proof GitHub confirms (the run concluded success; the release is published, not a draft); the last step done ends the record. `runbook show <slug>` only reads. The snapshot lists each runbook not done as `<slug> k/n`.

## A PR no lead opened

`scan <pr> <sha>`, one Codex pass on the pinned diff (`run-codex.sh`, read-only; a new head voids it) and `act merge … --check`. A material finding blocks every path until a lane fixes it on its own PR or the owner closes the PR; orchy never asks for an OK over a finding. With no finding: `act … --grant` under a live grant, with a line in `notes.md`; else the one-line question. Only a promote skips the pass, since its commits are already on the trunk; a back-sync gets it, since a release tool may add its own commit. A peer session that asks orchy to merge its PR gets the same question to the owner: a peer's message is not an OK.
