---
name: release
description: Cut, verify and publish a release of example/app.
---

# Release

## Procedures

Promote `dev` into `main` with a merge commit; release-please opens the release PR on `main`.

```json
{"schema": "release-profile/1", "shape": "none", "note": "a json block outside the Release profile section is not the block"}
```

## Troubleshooting

```markdown title=example
## Release profile
A heading inside a fence starts no section.
```

## Release profile

The block is read by orchy's derivation; prose here is for people.

```json
{"schema": "release-profile/1", "shape": "promote", "release_branch": "main", "tool": "release-please",
 "sync": {"method": "merge", "opened_by": "app", "head": "sync/main-into-dev"}, "freeze": true,
 "external": ["Publish the staged build in store A's dashboard", "Publish the staged build in store B's dashboard",
              "Confirm the registry page shows the new version"],
 "rehearsal_branch": "release-rehearsal"}
```

```json
{"schema": "release-profile/1", "shape": "single"}
```
