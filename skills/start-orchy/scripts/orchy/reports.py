# orchy.sh state's report reader: python3 -I reports.py <reports dir> prints {"reports": [...], "progress": {...}}
import sys, os, re, json, glob, hashlib
d = sys.argv[1]; out = {"reports": [], "progress": {}}
MARK = re.compile(rb"(LEAD_DONE|LEAD_BLOCKED:.*|ARC_FAILED:.*|SHOTS_READY.*|SHOTS_BLOCKED:.*)")
KEY = re.compile(r"([A-Za-z0-9_][A-Za-z0-9._-]*)-([A-Za-z0-9._]+)")   # <lane>-<arc>, the arc its last "-" segment, as marker_rx reads it
def text(b, n): return b.decode("utf-8", "replace")[:n]
def regular(p): return os.path.isfile(p) and not os.path.islink(p)
for p in sorted(glob.glob(os.path.join(d, "*.md"))):
    key = os.path.basename(p)[:-3]
    if not regular(p): out["reports"].append({"key": key, "error": "not a regular file"}); continue
    try:
        if os.path.getsize(p) > 4 << 20: out["reports"].append({"key": key, "error": "larger than 4 MiB"}); continue
        with open(p, "rb") as fh: data = fh.read()
        mtime = int(os.path.getmtime(p))
    except OSError: out["reports"].append({"key": key, "error": "unreadable"}); continue
    k = KEY.fullmatch(key); own = b"LEAD_DONE %s %s" % (k[1].encode(), k[2].encode()) if k else None
    lines = data.split(b"\n"); marks = [l for l in lines if MARK.fullmatch(l) or l == own]
    failed = [l for l in lines if l.startswith(b"ARC_FAILED:")]
    last = marks[-1] if marks else None; marker = detail = None
    if last is not None:
        marker = re.match(rb"[A-Z_]+", last).group(0).decode()
        rest = b"" if last == own else last[len(marker):].lstrip(b":").strip(); detail = text(rest, 80) if rest else None
    def lastm(rx, conv):
        m = [re.match(rx, l) for l in lines]; m = [x for x in m if x]
        return conv(m[-1].group(1)) if m else None
    out["reports"].append({"key": key, "mtime": mtime, "marker": marker, "detail": detail,
        "pr": lastm(rb"PR #(\d+)(?: |$)", int), "head": lastm(rb"HEAD ([0-9a-f]{40})$", bytes.decode),
        "codex_rounds": lastm(rb"CODEX: converged in (\d+) round", int), "arc_failed_lines": len(failed),
        "last_failed_sha": hashlib.sha256(failed[-1]).hexdigest() if failed else None})
for p in sorted(glob.glob(os.path.join(d, "*.progress"))):
    if not regular(p): continue
    try:
        with open(p, "rb") as fh: fh.seek(max(0, os.path.getsize(p) - 200)); out["progress"][os.path.basename(p)[:-9]] = text(fh.read().replace(b"\n", b" "), 200)
    except OSError: pass
print(json.dumps(out))
