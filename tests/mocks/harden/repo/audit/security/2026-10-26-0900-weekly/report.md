# Harden Report: security
**Repo:** example-app
**Run ID:** 0900-weekly

## Executive summary
Three findings.

## Findings

### [High] F-001: Path traversal in upload
**Instances**:
- `src/upload.ts:6`

---

### [Medium] F-002: Session cookie lacks HttpOnly
**Instances**:
- `src/session.ts:2`

---

### [Low] F-003: Error responses leak stack traces
**Instances**:
- `src/errors.ts:4`

## Findings NOT pursued (with reasoning)
### [Low] N-1: not a finding heading, outside the two sections
