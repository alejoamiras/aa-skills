# Phase 4 lessons — e2e lifecycle

## Attempt 1 (2026-07-06): FAILED — two real bugs

**Symptom**: every UP returned `401 Unauthorized: must be root, or be an operator and able to run 'sudo tailscale' to serve a path`; every DOWN returned rc=0 yet the mount survived in `tailscale serve status`.

**Bug 1 — operator grant is insufficient for PATH serving.** `tailscale set --operator=<user>` covers most CLI operations (incl. `serve status` and port proxying) but *serving a filesystem path* additionally requires root (tailscaled, running as root, reads those files). Plan's "no sudo at runtime" decision was wrong; discovered only because Phase 4 exercises the hook as the real user instead of root. Fix: serve-mutating calls (`--set-path ... --bg`, `... off`) go through `sudo -n tailscale` (non-interactive; requires root or passwordless sudo — documented in the script header as a hard dependency). `tailscale status`/`serve status` stay sudo-free. Operator grant kept: still useful for status and port-proxy cases, just not load-bearing for path serves.

**Bug 2 — DOWN masked failure.** `... off 2>/dev/null || true` conflated "mount absent" (fine → exit 0) with "permission/daemon error" (must be reported). The 401 was swallowed and DOWN exited 0 with the mount still live — precisely the "teardown honesty" failure the plan's security section warns about. Fix: DOWN now (1) exits 0 fast if the mount isn't present, (2) attempts the off, (3) re-checks presence and exits 1 with stderr if the mount survived.

**Also learned**: tailscale normalizes path mounts to a trailing slash in `serve status` (`/x` mounts display as `/x/`). Presence checks must match the normalized form (`grep -qF "/<rel>/"`).

## Attempt 2 (post sudo-fix): DOWN honestly failed — third bug

With `sudo -n` in place, UP/curl/idempotency all passed, but DOWN reported `teardown failed` — the new honesty check caught that `--set-path=/x off` returns `handler does not exist` while the handler is stored as `/x/`. **Removal must use the slash-normalized form** (`--set-path="/<rel>/" off`) even though creation uses the bare form. Attempt 1's `|| true` had been masking this asymmetry too — the honest-DOWN fix from bug 2 is what surfaced bug 3. Fixed in the script with a comment.

## Attempt 3: PASS — full lifecycle green

UP(a) + UP(b) 200 via tailnet hostname; repeat UP same URL, mount count stable at 2; DOWN(a) → (a) 404 while (b) 200; DOWN(b) → zero mounts on the port. All URLs normalized (http:// prefix, no trailing slash).
