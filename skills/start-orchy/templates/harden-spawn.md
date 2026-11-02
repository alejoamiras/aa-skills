You are a subagent. Don't run memo.

You run the scheduled audit `<LANE>` (lead key `<KEY>`): the harden skill's `<FOCUS>` focus at effort `<EFFORT>`, unattended, in the worktree <WORKTREE> (branch <BRANCH>, created from origin/<TRUNK> at its current head, dependencies installed). An audit changes no product file. Read the sections "Where you work" and "Hard rules" of <ORCHY_HOME>/briefs/_common.md with its lane as <LANE>, its key as <KEY>, its worktree as <WORKTREE> and its branch as <BRANCH>: they bind. Then read the harden skill's SKILL.md and run it with these Phase 0 answers, so it asks nothing:

- Focus `<FOCUS>`, effort `<EFFORT>`; `claude_model` `<CLAUDE_MODEL>`, `codex_model` `<CODEX_MODEL>`.
- Scope: the whole repository minus generated, vendored, `node_modules`, `dist` and `build` directories and anything the never-open line below names.
- Snapshot: this worktree as it stands. You are a guest in it (Phase 0.5): audit in place, skip the registration, open no other worktree.
- No known concerns named; read the project type from the repository.
- `report_mode` file (`report.html` beside `report.md`) and `filing: ask`, which unattended means Phase 6 writes its proposed list and files nothing. Open no issue, advisory, comment or PR.
- <SKIP_FILED>

Commit the run's directory on <BRANCH> alone (`git add -f` when `audit/` is ignored) as `docs(audit): <FOCUS> <DATE>`, push nothing and leave the worktree in place: the owner lands or discards it. Overwrite <ORCHY_HOME>/reports/<KEY>.progress at every phase. Last, append this block to <ORCHY_HOME>/reports/<KEY>.md, each line flush left, as shown:

```
LEAD_DONE
REPORT <the run's report.md, relative to the worktree>
COMMIT <the commit's full sha, or none>
FINDINGS: <BUCKETS>
```

`LEAD_BLOCKED: <why>` or `ARC_FAILED: <why>` replaces `LEAD_DONE` when the run could not finish. `FINDINGS:` counts the verified findings per impact bucket, zeros included, a finding relabeled `Potential` in its bucket; `FINDINGS: none` when the run verified nothing. At most ten lines of summary follow. The findings themselves stay in the report: never in this block, a commit message or a file outside the worktree.

Today is <DATE>. Never yield while a run is in flight: run every phase in the foreground with a bounded timeout.
<NEVER_OPEN>
