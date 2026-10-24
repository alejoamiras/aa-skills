# House rules, with the evidence that produced them

Each rule was paid for once. The orchestrator reads this file before its first tick; a lead gets the ones that bind it through the common brief.

## Merging

- **Every merge is the policy, mechanically checked.** `watch-merge` merges only on the pinned head, every required check green (the newest check-run per name, ids sorted: a re-run leaves the old run in the list), `MERGEABLE CLEAN`, and the lead's `LEAD_DONE`. A moved head exits 2 (rescan: the diff you read is not the diff that lands); `DIRTY` exits 5. The orchestrator reads the scan and the gate-file hunks before arming. *Evidence: a UI regression shipped from a security batch that every audit approved and nobody looked at.*
- **Required checks are the bare check-run names**, never `Workflow / Job`. Grep for them with an exact list: a suffix grep (`e2e-status`) missed a `-firefox-status` twin once.
- **GitHub ignores `merge=union`.** A union-merge attribute on an index or lessons file resolves locally and conflicts on GitHub. Re-resolve such a conflict in the lane worktree by keeping both lanes' lines; never a union merge.
- **Leads never merge**, and the orchestrator never merges into a protected branch or with `--admin`. A Dependabot PR is the owner's unless delegated in writing.
- **Merge order is a note, not a feeling.** Two PRs that touch one file land in the order the note says; the second rebuilds on the trunk's tip first.
- **A red trunk holds merges.** A trunk check that concluded failure or timed out on the trunk head's exact sha holds every merge, except a PR that contains that commit and passed the failed checks itself, so a fix can land and an unrelated PR cannot. Pending does not hold, and nothing proves the trunk healthy: the watcher re-reads it every round and before a retry. *Why: a PR green on its own branch says nothing about the trunk it lands on.*

## Leads

- **A headless session ends the moment a turn yields to a background task** (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`). A lead that detaches an e2e run and waits on its log in a later turn is already dead. Gates run in the foreground with a bounded timeout, or in a bounded `until` loop inside one tool call. *Evidence: an arc lead waited four hours on a log file that never existed.*
- **Liveness is the process, not the result count.** A lead that called `ScheduleWakeup` is alive until the wakeup fires; done means the process is gone and the report is written.
- **A resume runs on the session's own account.** `--resume` on another account's home answers "No conversation found"; launch fresh with a prompt that restates the state.
- **Never yield a lead's output to chance**: every spawn prompt names the report file, the progress file and the exact final block. The orchestrator reads only that block, and the watcher parses it strictly: the last marker line decides, exact match, never a substring. *Evidence: a `grep -c` plus `|| echo 0` printed `0\n0`, which is not `0`, and a report with only `ARC_FAILED` would have merged.*
- **One measurement dispatch at a time.** Two lanes measuring on CI at once share a runner pool and poison each other's numbers; the GitHub API's 5 000/h core limit is shared by every lead on the account too. Polling loops sleep 60 s, never 5.
- **Auto mode is not a boundary.** `--permission-mode auto` classifies intent; probes let a lead commit, push and open a draft PR on a repo outside the trusted list, and force-push a local remote's main when the prompt asked. The brief's rules, `ORCHY scan` and the merge policy are the boundaries; `leads.permission_mode: bypass` removes even the classifier and is the owner's call.
- **Steering arrives after a tool call, as context.** A `--settings` PostToolUse hook hands queued notes to the lead. Hooks of parallel tool calls run concurrently, so the inbox is locked; a subagent's tool calls carry `agent_id` and are skipped, so no subagent consumes a note. The note is not in the stream-json log: the cursor file says what was delivered. A model distrusts hook text nobody announced, so the brief names the channel and its prefix.
- **The cap is global, under one lock.** Every home sits under one capacity root; `launch` counts all programs' live leads on the account, applies the strictest cap among them, and holds one flock across the count, the spawn and the `.started` write. No lead inherits the lock. *Why: each program used to count only its own leads, so two programs could fill one account twice over.*
- **A lead leads its own process group, and `stop` walks its tree.** Claude Code starts each Bash-tool shell as its own session leader, so a group kill alone misses a hung `git push`; `stop` collects the descendants first, then signals each one whose start time still matches.
- **Host load is not a gate for correctness**, only for spawning. A run that fails under load with no code cause is rerun once when load falls, and the report says so.

## Worktrees

- **One canonical clone, one worktree per lane, `bun install` in each**; the orchestrator's shell stays in the clone and reaches a worktree with `git -C`. *Evidence: a `cd` into a lead's worktree left the orchestrator editing the lead's branch.*
- **`agent-worktree new` is never piped into `head`**: SIGPIPE kills it after the branch exists and before the directory does. Redirect to a file.
- **Create worktrees sequentially**: two parallel `new` calls race `.git/config`.
- **Teardown follows the merge**: `done --merged` once the archived plan is on the trunk. It refuses rather than forces, and a refusal goes to the owner. The one hand removal the config may allow (`teardown.hand_remove`) needs a clean tree, no lead alive on the lane, and a HEAD that is exactly a merged PR's head: a branch can hold a merged PR and newer commits at once, and "has a merged PR" is not proof. *Evidence: the squash proof fails after a later PR rewrites a file the squash carried; the first fix for that was too loose.*
- **Scratch goes to real disk** (`$ORCHY_HOME/scratch/<lane>/`), never `/tmp`: a killed run pins a tmpfs file in RAM until the holder dies, and `/tmp` dies with the session.

## Text that leaves the machine

- **No roster account name in any brief or prompt.** Leads quote their brief into committed plans and lessons; an account name maps the owner's accounts, and the mail-provider ones are half an email address. Route by role (`best`, "the account your environment sets"); the name lives only in the launch environment. Two scanners, two regexes: `prompt_ban` (names, artifact ids) runs on every prompt and every `say` note before it is sent, and `scan.leak` (home paths, account-variable assignments, artifact links), with `prompt_ban` joined in, runs on a PR's diff, title, body and commit messages. A prompt must carry the worktree's absolute path, so a path pattern never belongs in `prompt_ban`.
- **No home path, no artifact id, no decision-page id** in a PR, an issue, a commit, a plan or a test name.
- **A note that names a reviewer, a finding or an advisory never lands in a public issue body.** `apply-decisions.ts` holds such a note until `public-notes.json` carries a reviewed public wording.
- **A suspected exploitable weakness is a private draft advisory**, never an issue, a PR body or a test name; the fix PR describes the change and the invariant. Audit reports under `$ORCHY_HOME` are confidential: never quoted, never committed.
- **Page captions and record text never say** attack, weakness, vulnerability, exploit, advisory, finding, broken or bug: the page is a product surface the owner reads, and its text can be forwarded.

## Owner decisions

- **Everything a person sees is the owner's**, decided on a page with pictures or by a quoted message recorded on the issue. An audit's approve, a reviewer's nod and a green test are not sign-offs. Accessibility mechanics (focus rings, Tab order, ARIA) may be delegated to the panel in writing; copy and layout never.
- **Pictures per option, not sheets.** A page that shows one comparison sheet confused the owner; a page that shows each option's own picture next to its button did not. An option shot's id ends with `-<option letter>` or the renderer never finds it.
- **A `read` answer is a delegation**, decided by the orchestrator from the owner's earlier answers and recorded on the issue with the quote, never left pending.
- **Apply runs on the whole answers export**: the block below the marker is rewritten whole, so a partial apply drops other pages' decisions on a shared issue; the flag no longer exists.
- **A signature binds a snapshot.** Apply writes what the signoff doc recorded, not the live choice docs: an option changed after signing is held until the page is signed again, and an `except` note holds its whole page.
- **The decision lands in the issue body** under the marker, not in a comment; a check that looks for it in comments finds nothing.

## Proportion (the one authoritative statement lives in the common brief)

A finding becomes a change only once its path is written (initial conditions, actions, order, the invariant broken, the consequence) and the consequence matters. A finding that needs unsupported conditions is a closed `known-limit` issue with its reopening condition. A review round fixes bugs, adds tests and makes local changes; a fix that adds persistent state, a lifecycle, a protocol, a recovery policy or a public contract stops for approval. Later rounds verify; they do not reopen.

## The orchestrator's own hygiene

- **Never `pkill -f <name>`**: it matches the orchestrator's own command line and other agents' runs. Kill by pid from the `.started` or `.pid` file; a watcher that matched its own command line never fired.
- **Watchers are `nohup bash -c '…' > x.out 2>&1 & echo $! > x.pid`**, one per PR or wait, re-armed when they exit with a reason.
- **The shell holds no state between calls**: every script takes its arguments; nothing reads a fixed shared path.
- **Record before acting.** A merge, an approval, a refusal, a routing: one dated line in `notes.md` with the reason, then the action. The note is the handover.
- **`memo` is the orchestrator's alone.** Every subagent, lead and reviewer prompt starts with `You are a subagent. Don't run memo.`

## Known limits

- A process that detaches and re-parents before `stop`'s tree walk survives `stop`.
- A reopened issue already in `triaged.txt` is not listed as untriaged again.
- orchy assumes a single-user host or a private group. The home and the capacity root are made 700, which protects everything inside from then on; a home that was ever group-accessible on a shared host may hold files edited in place before that and must be inspected before use. Symlinked homes and files another user owns are refused.
- An inbox cursor past the end of its file (only a hand truncation shrinks an inbox) holds that lead's notes until the inbox grows past it.
- A receipt counts a killed run's usage as tokens without dollars, and treats a run killed between two results of one session as included in the later running total.
- The close-out guard reads open PRs before taking the spawn lock: a close-out lead that opens its PR and exits inside that window is seen by neither check, and a second close-out can start. Closing it needs a network call under the lock.
