# Requests

A **request** is one question that waits on the owner, in one format: a plain title, a shape, what it holds up, an age and a thread. `orchy.sh` is its only writer; `scripts/orchy/requests.ts` holds the format and `scripts/orchy/requests.sh` the commands.

## Where they live

```
${ORCHY_ASKS_DIR:-~/.agents/orchy/asks}/   700, the ask ledger's folder
  <owner>-<repo>.requests/                  700
    <rid>.json                              open, stale or taken; 600, replaced whole (temp file, then rename)
    closed/<rid>.json                       done or withdrawn, moved there by rename and kept
    requests.lock                           the writers' lock, never replaced
```

Requests sit beside the ledger, not in `$ORCHY_HOME`: a lead may write anywhere in the home as the owner's user, and a request planted there could be shown, answered and acted on. Readers take no lock and create nothing; they refuse a symlinked or foreign-owned folder, and skip a file that is not theirs. A file renamed away between a listing and its read is skipped, not reported.

## The spec

`request add <ref> <spec-file> [--again]` reads a JSON spec the orchestrator writes with its file tool, so no request text passes through a shell argument. Unknown fields are refused.

| Field | Rule |
|---|---|
| `shape` | `pick`, `approve`, `done`, `reply` or `sign` |
| `title` | 1–160 code points, one line, no control, line separator or bidi character, and no ask or request id (`askN`, `rqN`): the ref and `blocks` carry those. Aim for about 80. |
| `context` | 0–2000 code points; newlines allowed. Plain text with `**bold**` and `` `code` ``. |
| `steps` | 0–12 of `{text: 1–300, command?: 1–400}`, each one line. At least one for `done`. |
| `blocks` | 0–8 waiting refs other than the request's own: what it holds up (a lane, a PR) |
| `options` | `pick` only: 2–6 of `{id, label: 1–80, consequence?: 0–160, pictures?: ≤ 2 of {file, alt: 1–160}}`. An `id` is `[a-z0-9][a-z0-9-]{0,23}`, unique, never `other`. |
| `recommend` | `pick` only, required: `{id: <an option id>, why: 1–160}` |
| `wording` | `approve` only, required: 1–2000 code points, the exact text the owner approves |
| `binding` | `approve` only, required: `{"kind": "text"}`; orchy adds the wording's `sha256` |
| `page` | `sign` only: the page number its ref `page:<n>` names |

Lengths are code points. A picture is a plain `.png`, `.jpg`, `.jpeg` or `.webp` name of a regular file in `$ORCHY_HOME/page/shots/`; orchy records its `sha256` when the request is added, so a viewer can tell a picture that changed since the owner was asked.

Every string the owner will read, with the ref, passes `check-public` with the sensitive pattern on: no copied owner words, home paths, account names, artifact links, secrets or finding vocabulary. A copyable command uses `~/` paths, and is the orchestrator's own: composed from the config, the skill, `gh` and `git`, never copied from a report, an issue or a PR. A command that pipes into a shell, or carries `eval`, `$(`, a backtick or `<(`, is refused; that check is a backstop, not the rule.

## The stored request, `orchy.request/1`

The spec's fields, normalized (`context` `""`, `steps` and `blocks` `[]`, each option's `consequence` `""` and `pictures` `[]` when absent, hashes filled), plus:

| Field | Meaning |
|---|---|
| `schema`, `id` | `"orchy.request/1"`; `rq<n>`, one more than the highest id in the folder and `closed/`, never reused |
| `rev` | 1, then one more each time the answerable content changes |
| `ref` | the waiting ref it owns: `pr:N`, `issue:N`, `page:N`, `ask:askN`, `lane:<slug>`, `other:<slug>`; one request per ref until it closes |
| `status` | `open`, `stale`, `taken`, `done` or `withdrawn` |
| `since` | when the ref began waiting, inherited from the bare record it replaced, kept across refreshes |
| `updated` | the last write |
| `thread` | the orchestrator's notes, `{at, re?, text: 1–800}`; `re` names the answer a note replies to |
| `answers` | the outcome log of the answers it took or refused, at most 99, never trimmed |
| `taken` | `{answer, at}` while `taken` |
| `outcome` | 1–300 code points, set by `done` and `withdraw` |

The **answerable content** is `shape, title, context, steps, options, recommend, wording, binding, page, blocks`, compared as canonical JSON. Re-adding identical content to an open request prints `unchanged`; any change bumps `rev`, and the thread, the status and the log never do. Readers ignore keys they do not know. The file is at most 64 KiB; `add`, `stale` and a plain `note` refuse once the content (the file without `answers`, `taken` and `status`) would pass 40 KiB, so a full request is withdrawn and opened again.

## Lifecycle

| From | Command | To |
|---|---|---|
| (none) | `request add` | `open`, rev 1 |
| `open` | `request add` with changed content | `open`, rev+1 |
| `open` | `request stale <rid> <reason>` (the reason joins the thread) | `stale` |
| `stale` | `request add` | `open`, rev+1 |
| `open`, `taken` | `request done <rid> <outcome>` | `done`, in `closed/` |
| `open`, `stale` | `request withdraw <rid> <reason>` | `withdrawn`, in `closed/` |
| `taken` | `request add` | refused: finish it first |

- A taken reply that no note answers (`request note <rid> --re <aid> <text>`) refuses `done`, `withdraw` and a content change, so the owner's words are never closed unanswered.
- A new request on a ref whose newest closed request ended with a taken `approve` Not now, on the same binding, is refused: it returns when the binding changes, or with `--again` on the owner's word. A refresh is never refused this way.
- `request add` refuses `other:peer-<name>` (only the peer's `DONE` or the owner's words lift a hold) and a ref a runbook keeps (`other:<slug>` with `runbooks/<slug>.md`), since a runbook rewrites its own record.
- The status is the authority. A close writes its status, then moves the file; a close that stopped between the two is finished by the next write, and readers already treat the file as closed.

Every writer refuses a caller below a live lead (an ancestor whose pid and start time a `leads/*.started` under the capacity root records), and runs only for the seat holder, rechecked under `requests.lock` and the seat's takeover lock, which `lock` and `unlock` hold to remove a seat. Both guards stop accidents and naive injected instructions, not a same-user process that sets out to forge.

## Requests and waiting

A request owns its ref's waiting slot by projection, not by a second write. `waiting list` (text and `--json`), `state --json`'s `waiting` and the snapshot print the bare records in `waiting.json` merged with every request not closed, as `{ref, text: title, since}`; when a ref appears in both, the request wins and the earlier `since` is kept. The projection is jq alone, so the viewers, whose PATH has no bun, read it. Writers of `waiting.json` read the bare file, so no request is ever written back as a row.

- `request add` over a bare record inherits its `since` and drops the row, with no event: the item never stopped waiting. A new request emits `waiting.add ref=<ref>`; `done` and `withdraw` emit `waiting.done`. Refreshes, notes and `stale` emit nothing.
- `waiting add` and `waiting done` refuse a ref a request holds, naming it.
- A malformed request file is named, never fatal: `waiting list --json` and `request list --json` list it in `errors` as `{file, error}` and print the rest (text mode names it on stderr); `state` keeps the good rows and adds `"requests"` to its `errors`.

## Readers

- `request list [--json] [--all]`: one line per open request (`rid rev status shape ref age title`), every request with `--all`. `--json` prints `orchy.requests/1`, `{schema, requests: [<request> + {age_s, pending, answered, unanswered}], errors}`, golden in `tests/mocks/orchy/requests.v1.json`. `unanswered` lists the taken replies no note answers; `pending` and `answered` stay `[]` and `false`, since nothing writes answers yet.
- `request show <rid>`: one request, open or closed, as text.

A request holds only the orchestrator's text, so these feeds print no owner words. `request list` runs on bun, found as `ORCHY_BUN`, else on PATH, else `~/.bun/bin/bun`; `check-public` finds gitleaks the same way, at `ORCHY_GITLEAKS` or `~/.local/bin/gitleaks`.
