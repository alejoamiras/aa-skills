---
name: release
description: Tag, verify and publish a release of example/lib.
---

# Release

## Division of labor

The maintainer approves `Production` after inspecting the run's package tarball; that approval is never delegated.

## Release profile

```json
{"schema": "release-profile/1", "shape": "single", "tool": "tag",
 "external": ["Inspect the run's package tarball, then approve Production"]}
```
