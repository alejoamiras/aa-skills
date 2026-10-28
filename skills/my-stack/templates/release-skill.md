---
name: release
description: Releases <repository>, from the preflight through the promote of dev into main, the release PR, the publishing approvals and dispatches, and the checks after, to the back-sync. Use when asked to cut, ship, promote, publish or hotfix a release.
---

# Release

How `<repository>` ships, in my-stack's promote shape: features land on `dev`, `main` is what ships, and release-please cuts each version on `main`. Replace every `<...>`, and keep the section names: orchy's release leads look for them.

## Division of labor

| Step | Who |
|---|---|
| Preflight, changelog preview, verification | whoever runs this skill: it reads and reports, and merges nothing |
| Promote PR, `dev` into `main` | opened by the release lead; merged with a merge commit by orchy under the owner's go, or by the maintainer |
| Release PR | opened by release-please; merged under the go when its version is the one the go named (no version named: anything but a major) |
| Publishing approvals and dispatches | orchy under the go, except the steps reserved below |
| Back-sync, `main` into `dev` | opened by the release App; merged with a merge commit |

**Reserved for the maintainer.** Each is reported as a `STEP:`, never run as an `ACT:`, and never approved on the maintainer's behalf, whoever asks:

- <Approve `production` after checking the staged build on the preview URL.>
- Every external step below.

## Procedures

### Stable release

1. **Preflight.** No back-sync is open (`gh pr list --base dev --head main --state open` prints nothing), `dev`'s required checks are green on its head, and `git log --oneline origin/main..origin/dev` is the release's content. Read it as the changelog will: every `feat` and `fix` since the last tag.
2. **Promote.** `gh pr create --base main --head dev --title "chore(release): promote dev to main"`. It merges with a merge commit once its checks pass; `main` requires it up to date, which the preflight's back-sync check ensures.
3. **Release PR.** release-please opens it from `release-please--branches--main` with the version and the changelog. A version other than the one asked for, or an unasked major, waits for the maintainer.
4. **Publish.** Merging the release PR tags `v<version>` (the App) and runs `release.yml`. Each publish job waits in its environment: approve each one that is not reserved, and dispatch each target that does not run on the tag (`gh workflow run release.yml --ref main -f <input>=true`).
5. **Verify.** <The registry lists the version; each store holds the staged build; production serves it.>
6. **Back-sync.** The App opens `chore(release): sync main into dev`; it merges with a merge commit, never a squash.

### Hotfix

Branch from `main`, fix, test, and open a PR into `main` (merge commit). Then steps 3 to 6: the release PR, the publish, the checks, and the back-sync that brings the fix into `dev`.

## Staged switches

Inputs and variables that stage a release instead of shipping it. Each defaults to the side that publishes nothing.

| Switch | Default | Effect |
|---|---|---|
| `dry_run` (dispatch input) | `true` | <builds and packs; publishes nothing> |
| `publish_<target>` (dispatch input) | `false` | <submits the build to that store or registry> |
| `<VARIABLE>` (repository variable) | `<value>` | <what it gates> |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No release PR after the promote | no `feat` or `fix` since the last tag, or the App's token failed | read the release-please job's log; rotate the App's key if it expired |
| The promote is behind `main` | the last back-sync has not merged | merge the back-sync first |
| The back-sync conflicts | a commit reached `main` outside a promote or a hotfix | merge `main` into a branch cut from `dev`, resolve, and open it with the back-sync's title |
| A publish job waits | its environment needs a reviewer | approve it, unless it is reserved |
| The tag already exists | a re-run after a partial release | never move a published tag; cut the next patch |

## External steps

What GitHub cannot see, in order. Each is the maintainer's, and each is listed again in the block's `external`.

1. <Publish the staged revision in each store's dashboard.>
2. <Confirm the registry's trusted publisher still names this repository and `release.yml`.>

## Release profile

orchy's release derivation (start-orchy's `scripts/release-profile.ts`) reads the first fenced `json` block in this section. GitHub's own answers win: the block fills only what GitHub cannot say, and where both say different things the field becomes unknown. It grants nothing, picks no enforced merge method, makes no dispatch safe, and relaxes no check.

| Key | Values |
|---|---|
| `schema` | `release-profile/1` |
| `shape` | `promote`, `single` or `none` |
| `release_branch` | the branch that ships |
| `tool` | `release-please`, `tag`, `dispatch` or `none` |
| `sync` | `method` (`merge`, `squash` or `rebase`), `opened_by` (`app` or `maintainer`), `head` (the back-sync PR's head branch) |
| `freeze` | `true` holds trunk merges from the back-sync check until the promote merges |
| `external` | the external steps, at most 20 |

Strings are 1 to 160 characters with no control or bidi character. A block that breaks a rule is ignored whole; an unknown key is ignored alone.

```json
{"schema": "release-profile/1", "shape": "promote", "release_branch": "main", "tool": "release-please",
 "sync": {"method": "merge", "opened_by": "app", "head": "main"}, "freeze": true,
 "external": ["Publish the staged revision in each store's dashboard"]}
```
