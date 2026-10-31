# Requests

A **request** is one question that waits on the owner, in one format: a plain title, a shape, what it holds up, an age and a thread. An **answer** is the owner's reply to one. `orchy.sh` is the only writer of both; `scripts/orchy/requests.ts` and `answers.ts` hold the formats, `requests.sh` and `answers.sh` the commands.

## Where they live

```
${ORCHY_ASKS_DIR:-~/.agents/orchy/asks}/   700, the ask ledger's folder
  <owner>-<repo>.requests/                  700
    <rid>.json                              open, stale or taken; 600, replaced whole (temp file, then rename)
    closed/<rid>.json                       done or withdrawn, moved there by rename and kept
    requests.lock                           the writers' lock, never replaced
  <owner>-<repo>.answers/                   700
    <aid>.json                              a pending answer, 600, created whole: written in .tmp/, then link()ed in
    .tmp/                                   staging on the same file system, so a link is atomic and fails on a taken name
    taken/<aid>.json, refused/<aid>.json    moved there by take or refuse once the outcome is logged in its request
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
| `open` | `answer take` of a final answer for the current `rev` | `taken` |
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

- `request list [--json] [--all]`: one line per open request (`rid rev status shape ref age [answered] title`), every request with `--all`. `--json` prints `orchy.requests/1`, `{schema, requests: [<request> + {age_s, pending: [{id, rev, kind, at}], answered, unanswered}], errors}`, golden in `tests/mocks/orchy/requests.v1.json`. `pending` lists the answers in the inbox; `answered` (sent, not yet taken) is a pending final answer for the current `rev`, or a pending reply; `unanswered` lists the taken replies no note answers.
- `request show <rid>`: one request, open or closed, as text.

A request holds only the orchestrator's text, so these feeds print no owner words. `request list` runs on bun, found as `ORCHY_BUN`, else on PATH, else `~/.bun/bin/bun`; `check-public` finds gitleaks the same way, at `ORCHY_GITLEAKS` or `~/.local/bin/gitleaks`.

## Answers, `orchy.answer/1`

`answer put` is the one sanctioned writer, and the viewer's one write. Any process of the owner's can still drop a file in the inbox, so `take` validates every file again, and every reader screens the text it prints.

| Field | Rule |
|---|---|
| `schema`, `id` | `"orchy.answer/1"`; `<rid>.<seq>`, seq 1–99, the file's name, allocated by `put` as one more than the highest seq the request's log, the inbox, `taken/` and `refused/` hold |
| `request`, `rev` | the request, and the revision the owner saw |
| `kind` | `pick`, `approve`, `done` or `reply`; it equals the request's shape, except `reply`, which every shape takes. `sign` is refused: a page is signed on its Artifact. |
| `at` | stamped by `put` |
| `choice` | `pick`: an option id, or `other` with `text` |
| `go` | `approve`: `true`, or `false` for Not now |
| `binding` | `approve` with `go: true`: the request's binding, copied unchanged |
| `text` | `reply` (required), or a pick's Other text: 1–2000 code points |
| `note` | `pick`, `approve`, `done`, optional: 1–1000 |
| `log` | `done`, optional: 1–6000, tabs allowed; pasted material |
| `withheld` | `"secret"`, set by `take` alone, with the free text `null` |

Free text (`text`, `note`, `log`) is well-formed UTF-8 with no control character but `\n` (and `\t` in a log) and no bidi character. A file is at most 16 KiB, and unknown keys are refused. gitleaks screens the free text, and anything else a strict reader would refuse, at `put`, at `take` and `refuse`, and in every reader: a flagged answer's free text prints as `null` with `withheld: "secret"`. gitleaks is found as `ORCHY_GITLEAKS`, else on PATH, else `~/.local/bin/gitleaks`; a screen that cannot run refuses.

### `answer put`

One answer on stdin, read up to 16 KiB and screened before `requests.lock` is taken. Every verdict exits 0 with `orchy.answer-put/1` on stdout, `{schema, state: "pending" | "refused", id?, request, rev, reason?}`; exit 2 with nothing on stdout means it could not run (a busy lock, an unsafe store, no bun or gitleaks). Under the lock, first refusal wins:

| Reason | When |
|---|---|
| `invalid` | the grammar, no such request, a kind its shape refuses, an option it does not offer, a binding not its own |
| `secret` | gitleaks flagged the text; no file is written |
| `closed` | the request is done or withdrawn |
| `stale` | a final answer (not a reply) for another `rev`, or while the request is not `open` |
| `full` | a reply on content past 40 KiB, 100 answers pending in the home, or the request's seq would pass 99 |
| `conflict` | a final answer while one is pending; a reply while one is pending or taken and unanswered |
| `policy` | the caller runs below a live lead |

A reply never blocks a final answer. `put` needs no seat, and creates nothing in `$ORCHY_HOME`.

### `answer take <aid>` and `answer refuse <aid> <reason>`

The seat holder's, never a lead's. In order:

1. Find the file (inbox, `taken/` or `refused/`): regular, the user's own, at most 16 KiB; screen it.
2. Under the ledger lock alone, file the owner's sentences (`text` and `note`, never `log`) once, keyed by `answer: <aid>`: a `said` row on the ask the request's ref, else its first block, names, or else a row with no ask id, which opens no ask and emits no event. A withheld or flagged answer, and an id the log already holds, file nothing; a file whose row filed earlier holds other sentences is refused `invalid`.
3. Under `requests.lock` and the seat's takeover lock: a log entry for `<aid>` makes this a recovery, which only finishes the move and prints the logged outcome with the archived file, screened again; an inbox copy of an archived id is a replay and goes. Otherwise a flagged file is rewritten in place with its free text `null` and `withheld: "secret"`, and a file that is no JSON object with its stub, then the verdict, first match wins: withheld → `invalid`; the file's grammar, or no request → `invalid`; a closed request → `closed`; a final answer for another rev, or on a request not `open` → `stale`, the request unchanged; a misfit against the request → `invalid`; a reply while another taken reply is unanswered, or on content past 40 KiB → `invalid`; else taken. `refuse` fixes the reason, except that a secret still makes it `invalid`.
4. Log the outcome from the fields that pass their grammar (`id, state, at, rev, kind, go, reason, withheld, ask`); a taken final answer makes the request `taken`, a reply leaves its status. That write is the commit.
5. Move the file to `taken/` or `refused/`, replacing anything a deposit left under its name.
6. Print `orchy.answer-take/1`, `{schema, verdict, reason, withheld, request: {id, rev, shape, ref, blocks, binding}, answer, ask, recovered}`.

`take` exits 0 taken, 1 invalid, 4 stale or closed, 2 could not run (the answer stays pending); `refuse` exits 0. A rerun after any stop ends in the same one outcome. The orchestrator reads the owner's words from this output alone, and never types them into a command.

`request done` and `withdraw` refuse while an answer of the request is pending. `ask add --from <aid>` opens an ask whose text is a taken answer's sentences as the take filed them, once per answer; a refused or withheld answer opens none.

### Readers, `wait` and the snapshot

- `answer list [--json] [--all]`: the pending answers and the logged ones of open requests, every request's with `--all`. `--json` prints `orchy.answers/1`, `{schema, answers: [<answer> + {state, reason?, ask?}], errors}`, golden in `tests/mocks/orchy/answers.v1.json`: the owner's words, for a local reader only, never to publish. Text mode, and `answer show <aid>` on a pending answer, print ids, kinds and states, never the words.
- `wait` reports `CHANGED (answers):` and one `> <aid>` per answer new in the inbox since the last report; a removal (a take) wakes nothing. Only names in the answer-id grammar count.
- The snapshot's `-- requests` lists each taken request and each unanswered reply, ids and age, `UNSETTLED` past 30 minutes.
- The copy check counts no run that also occurs in the ledger's stored restatements or in a request's text: those passed `check-public` when written, so an owner's echo of them is not a copy.
