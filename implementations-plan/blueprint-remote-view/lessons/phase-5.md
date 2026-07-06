# Phase 5 lessons — ship

- **apt gitleaks too old for the repo hook**: Ubuntu 26.04 ships a gitleaks without the `gitleaks git` subcommand the pre-commit hook (>= 8.19) uses; commits were blocked with a confusing "unknown command" error. Fixed by installing the current release binary (8.30.1) to `~/.local/bin`, which shadows apt in PATH. Machine-setup note for future boxes: don't rely on apt for gitleaks.
- **/code-review max value**: 15 confirmed defects on a ~130-line script + docs, including three independent bypasses of the symlink guard and a teardown that could fake success while tailscaled was down. The guard fix that survived review is SIMPLER than the original (refuse any symlink, fail closed on unscannable trees).
- **Codex round 2 catch worth remembering**: "fail closed" on a *cleanup* path is wrong — an unreadable status probe must not prevent the cleanup ATTEMPT. Fail-closed belongs on publish; best-effort + honest reporting belongs on teardown.
