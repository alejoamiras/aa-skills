# Owner decision page

One HTML artifact holds every product decision the owner makes: numbered **pages** of **records**. The owner chooses options, writes notes and signs pages. Answers save into the artifact's `db` collection, and `apply-decisions.ts` writes them into the issue bodies.

| File | Role |
|---|---|
| `gen.py` | Builds the page from `$ORCHY_HOME/page/` into `build/` |
| `page.js`, `page.css` | The renderer; gen.py inlines them |
| `add-page.py` | Validates a page spec, backs up, appends it to `decisions.json` and the manifest |
| `check-brief.py` | Word limits and context ban on `brief.json` for the unsigned pages |
| `apply-decisions.ts` | Writes answers into issues (dry-run unless `--apply`) |
| `render-check.cjs` | Headless render: item/page counts and page errors |
| `smoke.sh`, `fixtures/` | End-to-end check on synthetic data |

gen, add-page, check-brief and apply read `ORCHY_HOME` from the environment and stop when it is unset. Python runs with `-I`. TypeScript runs on Bun.

## Layout of `$ORCHY_HOME/page/`

```
decisions.json      pages, records, charter, rules, site       (required)
brief.json          short form of records and page intros      (optional)
lanes.json          lane map, read by apply only               (required by apply)
unsigned.json       [3, 4]: the pages check-brief checks; env UNSIGNED=3,4 wins
public-notes.json   {"<record id>": "<reviewed public wording>"} (optional)
render-notes.json   {"<before-shot id>" | "<issue>": ["note", ...]} (optional)
shots/              manifest.json and the PNG/MP4 files it names
build/              gen.py output: decisions.html, shots/, files.json, _drop-files.json
apply-preview/      <issue>.md, the block apply writes (dry-run and --apply)
apply-receipts.json written by --apply only
```

## decisions.json

**`site`** (gen.py refuses to build without it):

| Key | |
|---|---|
| `repo` | `owner/name`: issue links and the `gh` target |
| `title` | The artifact's name, 2 to 4 words |
| `product` | Short noun phrase used in the copy, e.g. `the app` |
| `collection` | The db collection, one path segment; also the answers export subdir |
| `trunk` | Branch named in the intro and the footer |
| `program` | Optional; default `collection`. Stamped as `page` on every answer doc and shown in the eyebrow |
| `intro` | Optional paragraph(s), plain text with `**bold**` and `` `code` ``. Replaces the counts paragraph; the two how-it-works paragraphs always follow |
| `final` | Optional; the "When every page is signed" paragraph |
| `brief_ban`, `caption_ban`, `sensitive` | Optional regex sources (case-insensitive) that replace the defaults of check-brief, add-page and apply |
| `lane_label_prefix`, `owner_decision_label` | Optional; default `lane:` and `owner-decision` |

**Top level:** `generated` (date), `repo_head` (short sha), `pages`, `records`, `charter`, `standing_rules`, `holds`, `no_ask` and an optional `counts`. Any other key is ignored.

**`pages[]`:** `no` (int, never reused), `name`, `wave`, `lanes` [str], `intro` and optionally `issues` [int]. Pages render in array order. Page 0 is the charter page. It shows the charter items, `standing_rules`, `holds` and `no_ask`. Apply writes page 0 from the charter and `no_ask` only, so a record on page 0 is never written.

**`records[]`**, common keys:
- `id` (unique, `P<page>-NN` by convention), `issue` [int] (may be empty), `page` (the page name), `page_no`, `kind`, `title`, `lane` (free text).
- `rule_or_precedent` (shown as "Basis"), `buttons`, `shots` (refs, below), `writes_back`.
- Optional: `surface` (shown as "Where"), `hold` (a merge-hold id), `reply` {`at`, `note`, `answer`, `then`}, `premise`, `links` [{`href`, `label`}].

| `kind` | Adds | `writes_back` templates |
|---|---|---|
| `visual` | `options` [{`id`, `text`, `build`?}], `recommend` {`id`, `why`}; "As is" in `buttons` offers leaving it | `on_choice` {date, option, option_text, note}, `options` {key: text}, `on_as_is` {date, note} |
| `approve` | `proposal`, `after_shot_in_pr`? | `on_approve` {date, note}, `on_change` {date, note} |
| `approve` + `check: true` | A manual check: the owner records a result and a next step | `on_result` {date, result, next_step} |
| `veto` | `line`, `list` (`veto` or `confirm`), `default` | `on_accept` {date}, `on_strike` {date, note} |

Templates use these rules:
- Every template starts with `## Decision\n\n`. Apply merges an issue's later sections under the first heading.
- A line reading `Owner note: (none)` is dropped.
- `option_text` is `writes_back.options[<chosen key>]`.

**Shot refs** (`records[].shots[]`) are {`id`, `kind`, `route`, `capture`, `theme`, `browser`, `reason`?}. `kind` decides where a ref shows:
- `before`: "Today, as is".
- `after`: "As it ships".
- `mockup`, `page`, `compare`: their own groups.
- `option`: the option card.
- Anything else (`context`, `reference`) is kept but not shown.

A ref with no matching row renders as "Shot not captured".

**`charter[]`** (page 0): `id`, `topic`, `question`, `options`, `recommend`, `applies_to` [int], `buttons`, `change_from_triage`? and `writes_back` {`"*"` or `"<issue>"`: template}. Its placeholders are date, option, option_text, note, page_no and page. A `*` key writes to every issue in `applies_to`.

**Page-0 blocks:**
- `standing_rules[]` {`id`, `rule`, `from`, `citation`}
- `holds` {`merge_holds` [{`id`, `what`, `rule`, `issues`, `gates`}], `execution_gates` [{`id`, `rule`}], `reservations` [{`id`, `rule`, `file`, `lanes`}]}
- `no_ask[]` {`issue`, `decision`, `rule`, `lane`?}, written to its issues when page 0 is signed.

**`counts`** (optional): `issues_on_pages`, `charter`, `visual`, `approve` (includes checks), `mac_checks` (manual checks), `veto` and `no_ask`. These are the numbers the default intro prints. A missing key is derived from the data, so leave `counts` out to keep the intro current. add-page never updates it.

## shots/manifest.json

The file is `{"shots": [rows]}` or a bare list. Each row has:
- `id` (unique), `parent` (the ref id it answers), `issues`, `records` [record ids].
- `option`: `today` for a before shot, the option key for an option shot.
- `light`, `dark`, `video`: plain file names inside `shots/`.
- `browser` (`firefox` gets a label), `caption`, `a11y` (optional screen-reader text).

Other keys are ignored. A ref shows a row when any of these hold:
- `row.id == ref.id`
- `row.parent == ref.id`
- the row names the record with `option: "today"` (picture groups) or with `option: <key>` (that option's card)

## brief.json, lanes.json, answers, receipts

**brief.json:** `{"pages": {"<no>": intro}, "records": {"<id>": {"ask", "now", "options": {"<key>": text}, "pick": {"id", "why"}}}}`. An item with a brief shows the short form and folds the full text under "Full detail". check-brief enforces these for the unsigned pages:
- Word limits: ask ≤ 28 (not empty), option ≤ 20, pick.why ≤ 22, now ≤ 22, page intro ≤ 24.
- The `options` keys equal the record's option ids, and `pick.id` equals `recommend.id`.
- No text cites context (file names, record ids, "plan", "precedent").
- No brief record sits on another page.

**lanes.json:** `{"lanes": [{"slug", "wave"?, "arcs": [{"id", "name"?, "issues", "depends_on": [{"decision"|"gate"|"lane"|"issue", "reason"}], "e2e": [str], "visible"}], "no_arc": [{"issue", "reason"}]}], "proposed_order": {"waves": [{"wave", "lanes": [slug]}]}, "unassigned": [{"issue", "reason"}]}`. An issue's `## Pickup` names its lane, arc, wave, prerequisites, merge holds and gates.

**Answer docs:**

| Doc | Fields |
|---|---|
| `choice-<record id>` | `page`, `page_no`, `id`, `kind`, `issue`, `choice`, `note`, `at`, `by`; a check adds `result` and `next_step`; `viaRecommendAll` |
| `signoff-P<no>` | `page`, `page_no`, `name`, `head`, `choices` {id: choice or null}, `notes`, `except`, `changed`, `at`, `by`; the orchestrator may add `except_resolved: true` |

- `choice` is an option key, `asis`, `read`, `approve`, `change`, `strike` or `result`.
- No doc means the default: approve or accept.
- When the owner chooses `read`, decide the item, then write the decision as `recorded: "<text>"` into that doc with ArtifactData `update`. Apply writes it as "a note instead of an option".
- A doc's id is its `__id` or its file name. A single `.json` answers file holds an array, `{"docs": [...]}` or a map, each doc with `__id`.

**apply-receipts.json:** `{"<issue>": {"at", "lane", "pages": [no], "note"?: "unchanged"}}`.

## Sequence

```sh
S=<skill>/page; export ORCHY_HOME=<state dir>
python3 -I $S/add-page.py <spec.json>        # spec: {"page": {...}, "records": [...], "manifest_rows": [...]}
UNSIGNED=3,4 python3 -I $S/check-brief.py    # when the pages carry a brief
ORCHY_PAGE_BUILD=<scratchpad>/decisions-build DROP_PAGES=1,2 python3 -I $S/gen.py
(cd <dir whose node_modules has puppeteer> && node $S/render-check.cjs <build>/decisions.html)
```

`add-page.py` refuses the whole spec, writing nothing, in any of these cases:
- The page number already exists, or the spec has no records.
- An id is reused, or a `page_no` does not match the page.
- A required key or `writes_back` template is missing, or a template does not start with `## Decision`.
- An option shot id lacks its `-<key>` suffix.
- A row's file is missing from `shots/`.
- A caption, surface or option text matches `caption_ban` (attack, weakness, vulnerab…, exploit, advisory, GHSA, finding, broken, bug).

**Build.** `ORCHY_PAGE_BUILD` exists because the Artifact tool publishes supporting files only from the working directory or the scratchpad. `render-check` prints `{"items", "toc", "pages", ...}` and the first page errors. Outside claude.ai, `claude is not defined` is the expected one.

**Publish** (Artifact tool):
- First publish: `file_path: <build>/decisions.html`, `root: <build>` and `files` set to the map in `<build>/files.json`.
  - Also pass `icon`, a one-line `description`, and `capabilities: {"db": {"rules": [{"path": "<collection>", "read": "owner", "write": "owner"}]}, "user": {}}`: answers can carry notes the owner would not show a viewer, so only the owner reads or writes them.
- Republish: the same `file_path`. Pass only new files, plus `"<path>": null` for each path in `<build>/_drop-files.json`, and omit `capabilities`.
- Limits: at most 255 files per publish (send the rest in later publishes to the same url), 511 per version including the page, 16 MB per page.

**Answers.** Export into a fresh, empty directory each time: the page deletes a choice doc when an answer returns to its default, and a stale file would bring it back.

```
ArtifactData {action: "list", url: <artifact url>, collection: "<collection>", query: {"limit": 1000}, out_dir: "<fresh dir>"}
```

Repeat with `query.cursor` while a `next_cursor` comes back. The files land in `<fresh dir>/<collection>/`, and apply accepts either directory.

**Apply.**

```sh
bun $S/apply-decisions.ts --answers <fresh dir>             # dry-run: apply-preview/<issue>.md, never calls gh
bun $S/apply-decisions.ts --answers <fresh dir> --apply     # gh issue edit, lane label, receipts
```

- There is no partial apply: the block below the marker is rewritten whole from every signed page, so apply always takes the full export. `--force` rewrites blocks that have not changed.
- Everything from `<!-- orchy:decision -->` to the end of an issue body is replaced on every apply, so nothing goes below that marker by hand.
- A closed issue gets its Decision without a Pickup.
- `--apply` adds `<lane_label_prefix><slug>` (creating the label) and removes `owner_decision_label`.
- Apply writes the choices a signoff snapshotted (`choices`, `notes`), never the live docs alone: a choice changed after signing is held, and a signoff whose `except` note is set holds its whole page (exit 3) until `except_resolved: true` is written onto that signoff doc with ArtifactData `update`.
- `MANUAL` lines list what is still yours: unanswered or held items, read options without `recorded`, held pages and unrecorded checks.

## Rules the renderer and the tools impose

- **Option shots:** the record's ref has `kind: "option"` and an id ending in `-<option key>`, compared case-insensitively as the renderer does. The manifest row with that id carries `option: "<key>"`. A before shot is a `kind: "before"` ref whose row has `option: "today"`.
- **Visual and charter items** must be chosen before their page can be signed. Everything else on the page is approved by the signature.
- **`DROP_PAGES`** lists settled pages, because an artifact version holds at most 511 files. Their rows leave the build and their files go to `_drop-files.json`. A file that a kept row still shows is never listed.
- **`writes_back`:** every record needs the templates for its kind before apply runs. A missing one makes apply throw before anything is written.
- **Notes** go into public issue bodies. A note matching `site.sensitive` stops apply with exit 4 until `public-notes.json` maps that record id to reviewed wording.
  - The default pattern catches findings, advisories, GHSA, vulnerabilities, exploits, attacks and "confidential".
  - Add reviewers' names to `site.sensitive`.
- **Captions and surfaces** describe what the owner sees, never a reviewer, a finding or a defect.
- **Data safety:** page.js writes record ids, page numbers and issue numbers into the HTML unescaped, and stores answers under `choice-<id>`.
  - So gen.py and add-page.py refuse an id outside `[A-Za-z0-9_.-]` and any number that is not an integer.
  - gen.py also checks `repo` and `collection`, and copies only plain file names from `shots/`.
  - Everything else the page renders is escaped.

`bash smoke.sh` runs the whole chain on `fixtures/` in a temp `ORCHY_HOME`:
- `ORCHY_SMOKE_TMP` moves its scratch dir.
- Run it from a directory with `node_modules/puppeteer` to include the render check.
