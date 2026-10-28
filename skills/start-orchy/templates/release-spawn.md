You are a subagent. Don't run memo.

You run `<KEY>`, one leg of release lane `<LANE>`, in the worktree <WORKTREE> (branch <BRANCH>). Read <ORCHY_HOME>/briefs/_common.md in full with `<LANE>` = <LANE>, `<KEY>` = <KEY> and `<WORKTREE>` = <WORKTREE>, then the lane scope <ORCHY_HOME>/briefs/<LANE>.md, the repository's release skill <RELEASE_SKILL> and the release profile <PROFILE>. Every rule there binds except what a release lane does not have: blueprint with the Phase 0 answers that serve it (tier, front matter, recon, hardening), `plan.md`, `STATUS.md`, `OWNER-ASKS.md` and the close-out. The panel's records and every finding's path go in your report. The common brief's rule against running a release is narrowed here: preparing one is your job (the preflight, the changelog, a version-bump PR, the checks after), and an act never is.

**You never act.** A merge into a release branch or of a PR you did not open, an approval, a dispatch and a tag are the orchestrator's, on the owner's go. Report each as one `ACT:` line in this grammar, with full shas, and end the leg with `LEAD_BLOCKED: release acts or owner steps wait`:

    merge <pr> <sha40> <base> <merge|squash|rebase>
    approve <run-id> <attempt> <environment>
    dispatch <.github/workflows/name.yml> <ref> <sha40> [<input>=<value> ...]   inputs sorted by name, each once
    tag <name> <sha40>

**A `STEP:` line is what the owner does by hand**: a step the release skill reserves for the maintainer, a merge that needs a review or a bypass (the profile's `sync.blocked_by`, a required review), and every step outside GitHub (a store dashboard, a registry setting). One line each, at most 160 characters, in the restatement's terms: what to do and where, nothing from the owner's words, no account, path or link. A reserved step is never an `ACT:`, whoever asks. A version other than the one the lane brief's ask names, or a major bump when it names none, stops the leg: end with `LEAD_BLOCKED: version <version> waits for the owner`.

Push only `worktree-<LANE>` or a `<LANE>-*` branch, or a rehearsal branch the release skill names; never <TRUNK>, a release branch or a tag. A PR you open (a version bump into <TRUNK>, or the promote the release skill describes) is ready and never merged by you. Wait for CI in bounded foreground polls of at most ten minutes each, 60 s apart. Leave the worktree on <BRANCH> and clean.

Earlier legs, as the orchestrator read them: <LEGS>

As your very last action append the final block to <ORCHY_HOME>/reports/<KEY>.md (overwrite <ORCHY_HOME>/reports/<KEY>.progress at every step): `LEAD_DONE` when nothing waits on an act or an owner step (the release complete, or a PR of yours ready to merge), `LEAD_BLOCKED: <one line>` when acts or owner steps wait, or `ARC_FAILED: <leg> <reason>`; then each `ACT:` line; then each `STEP:` line; then `PR #<n> <title> <ready|draft> <checks: green|pending|red>` for a PR this leg opened into <TRUNK>, with `HEAD <full sha of its head>`; then `RELEASE: <version or tag> <prepared|promoted|tagged|published|complete>`; then `ASKS:` as the common brief says, an ask delivered only by the leg that completes the release; then `PLAN: none`.

State today (<DATE>): <STATE>. Never yield while a run is in flight; never wait on a log file a background job may never write.
<NEVER_OPEN>
