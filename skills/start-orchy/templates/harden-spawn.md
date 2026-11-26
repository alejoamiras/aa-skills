You are a subagent. Don't run memo.

You run the scheduled audit `<LANE>` (lead key `<KEY>`): the harden skill's `<FOCUS>` focus at effort `<EFFORT>`, unattended, in the worktree <WORKTREE> (branch <BRANCH>, created from origin/<TRUNK> at its current head, dependencies installed). An audit changes no product file. Read the sections "Where you work" and "Hard rules" of <ORCHY_HOME>/briefs/_common.md with its lane as <LANE>, its key as <KEY>, its worktree as <WORKTREE> and its branch as <BRANCH>: they bind, so every prompt file the run writes goes under <ORCHY_HOME>/scratch/<LANE>/ (`mktemp -p` there), never `/tmp`. Then read the harden skill's SKILL.md and run it with these Phase 0 answers, so it asks nothing:

- Focus `<FOCUS>`, effort `<EFFORT>`; `claude_model` `<CLAUDE_MODEL>`, `codex_model` `<CODEX_MODEL>`, `gemini_model` `<GEMINI_MODEL>` (use it as given; never replace it with your own `run-agy.sh --check`).
- Scope: the whole repository minus generated, vendored, `node_modules`, `dist` and `build` directories and anything the never-open line below names.
- Snapshot: this worktree as it stands. You are a guest in it (Phase 0.5): audit in place, skip the registration, open no other worktree.
- No known concerns named; read the project type from the repository.
- `report_mode` file (`report.html` beside `report.md`) and `filing: ask`, which unattended means Phase 6 writes its proposed list and files nothing. Open no issue, advisory, comment or PR.
- <SKIP_FILED>
- Headroom: skip the headroom gate (launch judged this account), and give Phase 2's fan-out `--exclude-from <ORCHY_HOME>/prompts/<KEY>.never.json`.

Commit the run's directory on <BRANCH> alone (`git add -f` when `audit/` is ignored) as `docs(audit): <FOCUS> <DATE>`, push nothing and leave the worktree in place: the owner lands or discards it. Overwrite <ORCHY_HOME>/reports/<KEY>.progress at every phase. Last, append this block to <ORCHY_HOME>/reports/<KEY>.md, each line flush left, as shown:

```
LEAD_DONE
REPORT <the run's report.md, relative to the worktree>
COMMIT <the commit's full sha, or none>
FINDINGS: <BUCKETS>
GEMINI: <answered N of M calls | unavailable (<reason>)>
```

`LEAD_BLOCKED: <why>` or `ARC_FAILED: <why>` replaces `LEAD_DONE` when the run could not finish; an unattributed change in the git config or hooks during a Gemini call ends the run with `LEAD_BLOCKED: git config or hooks changed during a Gemini call`, never `ARC_FAILED`. `FINDINGS:` is the line Phase 5's findings data step printed, copied as is: the verified findings per impact bucket, zeros included, a finding relabeled `Potential` in its bucket, or `FINDINGS: none` when the run verified nothing. `GEMINI:` counts the run's Gemini calls that answered out of every one it made or skipped, or, when it made none, gives the reason word (`off` when `gemini_model` is `off`); it holds nothing. At most ten lines of summary follow. The findings themselves stay in the report: never in this block, a commit message or a file outside the worktree.

Today is <DATE>. Never yield while a run is in flight: run every phase in the foreground with a bounded timeout, except the Gemini calls harden starts in the background (each up to 40 minutes, at most three at once): poll each in bounded loops until it ends, and never yield or write the final block with one still running.
<NEVER_OPEN>
