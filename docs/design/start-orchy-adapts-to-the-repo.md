# start-orchy adapts to the repository it runs

Status: design note, 2026-10-27. Nothing in it is implemented; the skill text is unchanged.

## Why

`start-orchy` was written for an unattended backlog program: open issues become lanes, headless leads build them, the owner signs decision pages, the orchestrator merges on a mechanical policy. A week of running the same program by hand on a wallet repository, through a stable release and its first store submissions, showed a second shape the skill has no objects for: an attended release program. The owner is present and answers in minutes; other sessions of the owner's own items; some steps run only in a store dashboard or through a keyed run; the central act is a pull request into a branch the skill marks untouchable; and the useful unit of work is often a one-file change that needs no plan.

The skill does not fail on such a repository. It would start over (its state is its own home), refuse the release path (a non-trunk `main` is "never pushed to or merged into", with no model of how changes reach it), and turn every small ask into a planned lane. Each section below removes one of those, in the order they should land. None carries a repository's values into the skill: orchy learns a vocabulary, and each repository fills it.

## 1. The release profile

### Vocabulary

- `trunk`: the branch pull requests target and the orchestrator merges into. Derived today from the default branch; unchanged.
- `release_branches[]`: each branch that receives the trunk, with the kind of pull request that carries it (`promote`: a PR from the trunk; `release-please`: the tool's own PR; `tag-only`: no PR, a tag on the trunk), the merge method its rules allow, whether it requires an up-to-date head, and its required checks.
- `release_tool`: `release-please` (its target branch, its PR title pattern, its author), `manual-tag`, or `none`.
- `sync`: a back-merge from a release branch to the trunk when one exists (`from`, `to`, the merge method), or none.
- `publish[]`: each workflow with a `workflow_dispatch`, its inputs, and the environments it waits on, with those environments' required reviewers.
- `external[]`: steps no workflow performs, named by the repository (a store dashboard, a DNS record, a flag on a listing). They become runbook steps (§ 5), never lanes.

A repository with one branch and tags gets `release_branches: []` and `sync: none`, and the profile adds nothing to today's behavior.

### Derived at bootstrap, nothing asked

In order, each source filling what the earlier ones left empty:

1. GitHub: `defaultBranchRef`; for every branch with rules, `rules/branches/<b>` and the legacy `branches/<b>/protection` (merge methods, strict, required checks, as today); `environments` and each environment's reviewers; every workflow file's `on.workflow_dispatch.inputs`; release-please from `release-please-config.json`, `.release-please-manifest.json` or a workflow that uses its action, with the target branch from the config or the `target-branch` input.
2. The repository's own words: a project skill named `release` (its frontmatter and its division-of-labor table) and the branching section of the root `CLAUDE.md` or `AGENTS.md`. my-stack's template (§ 8) gives that skill a `profile:` block in its frontmatter so this read is a parse, not a guess; a repository without it is derived from GitHub alone.
3. What neither holds is asked once, on page 0.

The profile is written to `orchy.json.release` as facts, and the bootstrap report prints it as one table.

### Confirmed once on page 0

One record shows the derived profile; the owner confirms it or corrects a row, and a correction re-derives the rest. One record per grant (next section). A row the owner corrected is marked `owner` and never derived over.

### The delegation record

GitHub cannot tell orchy whether it may merge a promote, approve a deployment environment or dispatch a publish workflow. Those are grants, kept in `local.json.delegations.release` (machine-local, owner-only), each with the ask id that granted it:

| Grant | Default | Options |
|---|---|---|
| Merge a PR into `<release branch>` | never | on the owner's word per PR; standing |
| Approve environment `<name>` | never | on the owner's word per run; standing |
| Dispatch `<workflow>` with publishing inputs | never | on the owner's word per run; standing |
| Merge a Dependabot PR | never | standing, when the diff pins to tags the orchestrator verified |

Recommended: per-PR word for protected-branch merges, standing for environment approvals and for dispatches that only read (a store-state check), never standing for a dispatch that publishes. A per-word grant is an ask (`ask said`); a standing grant is a page-0 answer. Every use is a dated line in `notes.md` naming the grant. `--admin` and a force-push stay refused under every grant; the watcher still pins the head and requires every required check green.

The house rule "never a protected branch" becomes: never a protected branch without a grant for that branch and that PR kind, never `--admin`, never a direct push.

### The release lane

An ask that names a release act ("promote", "release", "publish", "upload") routes to `ask lane askN release-<n> release`: one light lead in a worktree runs the repository's `release` skill (cut, sync, promote) up to the first step that needs a grant or an owner-only action, and reports `RELEASE_READY` with the PR number and head, or `RELEASE_BLOCKED` with the step. The orchestrator then: with a grant, arms the watcher on that PR with the profile's merge method; without one, writes `waiting add pr:N <merge the promote>` and arms a watch-only watcher (§ 4). Environment approvals and dispatches go the same way, by grant or by record. External steps go to the runbook. The lead never merges, as today.

### What stays out of orchy

The procedure (how this repository cuts, unsticks, syncs, submits) stays in the repository's `release` skill. The pattern (which shapes exist and how a new repository gets one) goes to my-stack (§ 8). orchy holds the vocabulary, the derivation, the grants and the lane.

## 2. Repository context at bootstrap

Today Phase 0 reads the lockfile and `package.json` scripts. Add: the root `CLAUDE.md` or `AGENTS.md` (the ruleset a lead must follow: branching, title length, commit lint, sign-off rules) and the name and description of every project skill under `.claude/skills/`. Record the skill list in `orchy.json.repo.skills`; the common brief names the ruleset file and tells a lead to pick the skills whose descriptions match its lane. At resume, a ruleset or skill changed since the last read is read again. Evidence: the wallet repository's ruleset carries the merge-method, PR-title and commit-lint rules a lead needs on its first PR, and nothing at bootstrap reads it.

## 3. The quick lane

A tier below the planned lane: `ask lane askN <slug> quick`. The orchestrator routes an ask there when it touches one surface, no gate file, no persisted shape, no dependency, and a handful of files; the scan still judges gate files on the PR. The flow: `wt-new`, one light lead from `templates/quick-spawn.md` (the restated ask, the gates, the PR rules; no plan folder, no `OWNER-ASKS.md`), one Codex pass on the diff, `LEAD_DONE`, scan, `arm-merge`, teardown on merge, no close-out. A visible change still needs the sign-off quoted by id: the ask itself when the owner stated the exact change, a page otherwise. A quick lead that finds the change larger than its brief reports `LEAD_BLOCKED: needs a plan` and the ask is routed to a full lane. Evidence: this week's one-line copy changes and an action-pin bump redone by hand; a planned lane is an hour or two for each, a quick lane fifteen to thirty minutes with the same ledger, scan and watcher.

## 4. Watchers for PRs with no lead

`arm-merge` requires a report with `LEAD_DONE`, so a PR opened by the orchestrator, a peer session, Dependabot or release-please cannot be armed. Two additions:

- `arm-merge --no-report <pr> <sha> <lane|->`: the policy minus the lead marker, plus an author check against a list in `orchy.json` (the orchestrator's own login; Dependabot under its grant). The scan is read as always.
- `watch-pr <pr> <sha>`: never merges; reports `GREEN`, `RED` or `HEAD MOVED` as events and writes or clears the `pr:N` waiting record. For a promote the owner merges, a Release PR, or any PR whose grant is per-word.

Evidence: every merge watcher this week on an orchestrator-authored PR was a hand-written script outside the skill.

## 5. Owner checklists in the waiting record

The record holds one line per ref. A go-live is a list: publish a staged store revision, re-paste a permission justification the publish unlocked, untick a flag on a listing, say the word for a mailing send, run the store-copy check. Add `waiting add --checklist <ref> <file>`: the file lives under `$ORCHY_HOME/runbooks/<slug>.md`, each step `- [ ]` tagged `owner` or `orchy`, with an optional proof (a command whose output ticks it: an API field, a workflow conclusion). Each tick runs the proofs, ticks what they prove, runs the `orchy` steps it holds grants for, and leaves the owner steps until the owner says so or a proof shows it. The "Waiting on you:" line shows `other:<slug> (k of n)`. The file never leaves the machine; the tick report names steps, not the file. A repository's `release` skill may ship the step list (its `external[]`), and the release lane turns it into the runbook.

## 6. Peers and chat decisions

**Peers.** Another session of the owner's can own an item the program depends on: a send through a connected service, a history rewrite. Add a `peer:<name>` waiting ref and a freeze protocol: a peer's QUIET disarms every watcher, holds launches and records `waiting add peer:<name> <until done>`; its done re-arms. The seat lock already publishes the messaging socket a peer needs to find the orchestrator. Evidence: two such handoffs this week, both run on conventions agreed in chat.

**Chat decisions.** Phase 3 sends every decision to a page. Allow chat when all hold: no product screen is involved (a brand asset, a line of copy outside the product, a policy yes or no), at most three options, the options can be shown inline, and the answer is recorded (`ask said`, and on the issue through the public-wording door when one exists). Everything on a screen, and anything with more options, stays a page with pictures. Evidence: two such picks answered in minutes this week; a shots lead and a page would have cost an hour each.

## 7. Adopting an existing program (not planned)

The one change that serves a single repository. It would move the earlier program's state under the capacity root, write `orchy.json`, `local.json` and `triaged.txt` beside it, take the live leads and watchers from a snapshot, and point the first notes line at the earlier notes. The cheaper answer is to start fresh once the earlier program's open items close, with the old notes readable as history. Left out of the order of work.

## 8. my-stack: the patterns and the template

- Name the two shapes the owner's repositories use: **single trunk** (PRs into `main`, release-please on `main`, tags) and **two-branch promote** (PRs squash into a trunk; a promote PR merge-commits the trunk into the release branch, which is strict and merge-only; release-please on the release branch; a merge-commit back-sync after each release). Scaffold the second: the two rulesets, the promote and sync PR title conventions, the release-please config.
- A `release` skill template with fixed sections (division of labor, procedures, staged switches, troubleshooting, external steps) and a `profile:` block in its frontmatter carrying the vocabulary of § 1, so orchy's read is a parse. Verify first that the harness ignores unknown frontmatter keys; if not, the block moves to a fenced `yaml` block under a fixed heading.
- Keyed runs are already there; the template's external steps name which ones a release needs.

## Order of work

1. § 1 release profile: derivation, page-0 records, grants, the release lane, the house-rule rewrite.
2. § 8 my-stack patterns and the `release` skill template, alongside 1.
3. § 2 repository context.
4. § 4 watchers, then § 3 the quick lane.
5. § 5 checklists.
6. § 6 peers and chat decisions.

Each lands as its own PR to this repository with the smoke extended for what it adds. § 7 is not planned.

## Open questions

- Should a standing grant exist for a protected-branch merge at all, or only per-word? The design allows it and recommends against it.
- Frontmatter `profile:` versus a fenced block: depends on how the harness treats unknown frontmatter keys.
- Can a release lead create a sync branch through the API (`POST /repos/{o}/{r}/merges`) instead of a worktree, and are such commits signed as the branch rules require?
- Who decides a quick lane's "one surface": the orchestrator at routing, with the lead's bounce as the correction. Is that enough, or does the scan need a file-count line?
