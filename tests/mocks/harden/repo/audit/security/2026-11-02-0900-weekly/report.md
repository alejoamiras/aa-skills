# Harden Report: security
**Repo:** example-app
**Run ID:** 0900-weekly

## Executive summary
Two findings; one more already tracked.

## Findings

### [High] F-001: Upload path escapes the upload directory
**Instances**:
- `src/upload.ts:8`
- `src/fs.ts:3`

---

### [Potential Critical] F-002: Stored XSS in the profile bio ##
**Trace**: a bio saved as

```markdown
## Findings
### [Low] F-099: text inside a fence is no heading
```

renders as HTML.

## Already tracked

### [Medium] F-003: Session cookie lacks HttpOnly
**Instances**:
- `src/session.ts:2`

## Findings NOT pursued (with reasoning)
None.
