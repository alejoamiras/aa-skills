# From scratch: an empty folder becomes a repository

`/start-orchy` in an empty folder runs this procedure, in the owner's session, by the orchestrator itself (never a lead). It hands over to Phase 0 step 2 with a repository on GitHub, a green gate on `main`, and what to build captured as `ask1`. Every step stops on failure and names the step and the reason; nothing here retries a create or a push. A run interrupted once step 3 has captured the ask is not resumed: step 3 refuses a home or ledger that already exists for the name, the guard refuses a folder with scaffold files, and the owner finishes by hand, removes that home and ledger, or picks another name.

## 1. Guard

Proceed only when all of these hold; otherwise refuse and say what the owner can do instead.

- Phase 0 step 1's tool checks pass (`gh auth status`, `claude-usage`, `codex login status`, `agent-worktree`, `jq`, `bun`), plus `gitleaks` and `actionlint`: nothing is created on GitHub for a program that cannot run.
- The folder is not `$HOME`, compared physically (`pwd -P` against `cd "$HOME" && pwd -P`).
- `ls -A` lists nothing, or only `.git`:
  - with nothing, `git rev-parse --show-toplevel` fails: an empty subfolder of another repository is that repository's;
  - with `.git`, it is a real directory (`[ -d .git ] && [ ! -L .git ]`), `git rev-parse --show-toplevel` prints this folder's `pwd -P`, `git rev-parse --verify -q HEAD` fails, and `git for-each-ref` and `git remote` print nothing: no commit at HEAD, no branch, tag or remote, so no history anywhere.
- The token carries the classic scopes `repo` and `workflow` (pushing `.github/workflows/` needs `workflow`):

  ```sh
  gh api -i user > "$tmp" || stop "cannot read the token's scopes"
  scopes=$(tr -d '\r' < "$tmp" | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' | tr ',' '\n' | tr -d ' ')
  [ -n "$scopes" ] || stop "no X-OAuth-Scopes header: a fine-grained or app token, whose permissions this check cannot see"
  for s in repo workflow; do grep -qx "$s" <<<"$scopes" || stop "the token lacks '$s': run  gh auth refresh -h github.com -s $s"; done
  ```

  Whole names only: `public_repo` is not `repo`. The refresh is a device-code flow the owner runs; the orchestrator never runs it.

On a refusal: a folder with files is emptied or moved by the owner, never by orchy; a repository with history or a remote gets an `origin` and an ordinary `/start-orchy` from its root; `$HOME` gets a fresh folder.

## 2. One question batch

What to build comes from the `/start-orchy` message, or from one chat question when it says nothing. It is the owner's words: keep it in this session until step 3 hands it to the ledger, never in a file before that.

Then one `AskUserQuestion`, recommended answer first:

- **Owner and name**: the owner's login and each org from `gh api user/orgs --jq '.[].login'`; the folder's name first.
- **Visibility**: private first. A public repository gets a ruleset (step 8); a private one on a free plan cannot have one, a known limit.
- **Accounts, caps, never-open files and a standing rule**: Phase 0 step 3's questions.
- **The public description**: one or two sentences restated from what to build by SKILL.md § Asks, shown in full for the owner's OK or correction. The README, `package.json`'s `description` and `gh repo create --description` carry exactly this text.

## 3. Capture the ask, before any scaffold file

`orchy.sh` runs before the repository exists when every call carries `ORCHY_REPO=<owner>/<name>` (until step 6 adds `origin`). First, the directory `ORCHY home` prints must not exist: an earlier run for this name got that far, so stop as the header says.

1. `git init -b main`, or, when the empty `.git` exists, `git symbolic-ref HEAD refs/heads/main`.
2. The home `ORCHY home` prints, made with mode 700, holding `orchy.json` from `examples/orchy.example.json` without its `bootstrap` and `approved_at` keys (Phase 0 step 4 writes them), with `repo` and `trunk: "main"`, and `local.json` per Phase 0 step 4 from step 2's answers, `prompt_ban` included.
3. `ORCHY ask list --all` prints nothing (an ask there is an earlier run's: stop as the header says); then `ORCHY ask add <what to build, the owner's words>` prints `ask1`, and `ORCHY ask public ask1 <the signed description>` runs the same `check-public` every handoff does. A refusal goes back to the owner with a new wording; nothing is written into the folder until the wording passes.

## 4. Scaffold

1. `bunfig.toml` with `[install] minimumReleaseAge = 604800` before anything installs: my-stack's step 1 installs before its step 3 sets the age.
2. my-stack § Scaffolding a New Repo, steps 1–7, 10 and 11, in this folder: step 1 without its `mkdir`, `cd` and `git init`, and step 3 completing the `bunfig.toml` written above. Steps 8 (run isolation), 9 (frontend) and 12 (infrastructure) only when the description needs them; otherwise each becomes an ask after step 9 here.
3. One test colocated with the entry module that asserts one real behavior of it: `bun test` exits 1 when it finds no test.
4. One PR-gate workflow named after the package, with no `changes` filter while there is one package: orchy's merge watcher counts only a completed, successful check, so a skipped required check would block every PR.

   ```yaml
   name: <package>
   on:
     pull_request:
       branches: [main]
     workflow_dispatch:
   permissions:
     contents: read
   jobs:
     test:
       runs-on: ubuntu-latest
       timeout-minutes: 10
       steps:
         - uses: actions/checkout@v6
         - uses: oven-sh/setup-bun@v2
           with:
             bun-version: 1.4.2
         - run: bun install --frozen-lockfile
         - run: bun run lint
         - run: bun test
         - run: bun audit
     actionlint:
       runs-on: ubuntu-latest
       timeout-minutes: 5
       steps:
         - uses: actions/checkout@v6
         - uses: docker://rhysd/actionlint:1.7.12
   ```

5. The secret scan, on pushes to `main` and on pull requests:

   ```yaml
   name: gitleaks
   on:
     push:
       branches: [main]
     pull_request:
   permissions:
     contents: read
     pull-requests: read
   jobs:
     scan:
       runs-on: ubuntu-latest
       timeout-minutes: 5
       steps:
         - uses: actions/checkout@v6
           with:
             fetch-depth: 0
         - uses: gitleaks/gitleaks-action@v2
           env:
             GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
   ```

   On a pull request the action lists its commits through the API, which `pull-requests: read` allows; without it every PR scan fails with a 403 before scanning. The action needs a license on an org-owned repository: there, run a pinned gitleaks release, checked against its published checksums, with `gitleaks git --redact --no-banner`. Locally, `gitleaks git --pre-commit --staged --redact --no-banner` is the first line of `.husky/pre-commit`.

## 5. First commit

The local gates green (`bun run lint`, `bun test`, `bun audit`, `actionlint`); `gitleaks dir .` clean. A fresh tree can fail `bun audit` on a transitive advisory whose fixed version is younger than `minimumReleaseAge`: `bun audit fix` installs it past the age gate, and frozen installs accept the lockfile afterwards, so it is a deliberate bypass the commit message names (advisory, package, version, age); never a lower age. The scaffold's paths staged by name, never `git add -A`; one signed commit; `gitleaks git` clean.

## 6. Create and push

`gh repo create <owner>/<name> --<visibility> --description "<public description>" --source . --remote origin --push`: the one direct push to a trunk orchy ever makes, covered by the signed name and visibility. A failure after the repository exists stops with what exists; never a second create. `origin` takes gh's `git_protocol`, which plain git (watchers, `agent-worktree`, leads) may not be able to fetch: `git ls-remote origin` must pass, or `origin` is set to the URL form the machine's other clones use and checked again.

## 7. Prove the gate on `main`

1. Note the time to the second, then `gh workflow run <package>.yml --ref main`, retried up to five times 10 s apart while GitHub registers the new workflow.
2. The run is the newest `gh run list --workflow <package>.yml --event workflow_dispatch --branch main --json databaseId,createdAt,headSha` entry whose `headSha` is the scaffold commit and whose `createdAt` is at or after that time, polled up to 60 s while it registers. Any such run proves the same commit's jobs, so a retried dispatch is harmless.
3. `gh run watch <id> --exit-status`; a red or missing run stops with its link.
4. Its job names (`gh run view <id> --json jobs --jq '.jobs[].name'`) are the required checks: the same jobs run on `pull_request`.

## 8. Ruleset (public only)

```sh
printf '%s\n' "${jobs[@]}" | jq -R '{context: .}' | jq -s '{
  name: "main", target: "branch", enforcement: "active",
  conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
  rules: [
    {type: "pull_request", parameters: {required_approving_review_count: 0, dismiss_stale_reviews_on_push: false,
      require_code_owner_review: false, require_last_push_approval: false, required_review_thread_resolution: false}},
    {type: "required_status_checks", parameters: {strict_required_status_checks_policy: false, required_status_checks: .}},
    {type: "non_fast_forward"}]}' | gh api -X POST "repos/<owner>/<name>/rulesets" --input -
```

No review is required, since the merge watcher cannot give one. A private repository gets no ruleset.

## 9. Bootstrap

Phase 0 from step 2, over the home step 3 made: `merge.required_checks` set to step 7's job names (they win over the ruleset derivation), Phase 0 step 3's questions already answered in step 2, `ask1` already captured and routed like any ask once `bootstrap` is `complete`. Add the clone to `~/.agents/clones.md`.
