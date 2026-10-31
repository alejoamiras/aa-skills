# python3 -I limit.py <lead log>...: one "<key> <epoch|-> <UTC time|unknown>" line per log whose last line is a usage-limit
# result. Only Claude Code sets is_error, and a lead's own words reach the log only inside an escaped event or as a
# result without it, so no text a lead writes can end the log as one.
import json, os, re, sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

MON = "jan feb mar apr may jun jul aug sep oct nov dec".split()
EPOCH = re.compile(r"\blimit reached\|(\d{10})\b", re.I)
WHEN = re.compile(r"\bresets\s+(?:at\s+)?(?:(?P<mon>[a-z]{3})[a-z]*\.?\s+(?P<day>\d{1,2}),?\s+(?:at\s+)?)?"
                  r"(?P<h>\d{1,2})(?::(?P<mi>\d{2}))?\s*(?P<ap>[ap]m)?\b(?:\s*\((?P<tz>[A-Za-z_]+(?:/[A-Za-z0-9_+-]+)*)\))?", re.I)

def last_line(p):
    with open(p, "rb") as f:
        end = f.seek(0, 2); f.seek(max(0, end - 65536)); lines = f.read().rstrip(b"\r\n").split(b"\n")
    return lines[-1] if len(lines) > 1 or end <= 65536 else b""

def reset(text, anchor):
    m = EPOCH.search(text)
    if m: t = int(m.group(1))
    else:
        m = WHEN.search(text)
        if not m or not (m["ap"] or m["mi"]): return None
        h, mi = int(m["h"]), int(m["mi"] or 0)
        if m["ap"]:
            if not 1 <= h <= 12: return None
            h = h % 12 + (12 if m["ap"].lower() == "pm" else 0)
        if h > 23 or mi > 59 or (m["mon"] and m["mon"].lower() not in MON): return None
        try:
            # naive without a zone: timestamp() then applies the local offset of the reset's own date, not the anchor's
            a = datetime.fromtimestamp(anchor, ZoneInfo(m["tz"])) if m["tz"] else datetime.fromtimestamp(anchor)
            d = a.replace(hour=h, minute=mi, second=0, microsecond=0)
            if m["mon"]:
                d = d.replace(month=MON.index(m["mon"].lower()) + 1, day=int(m["day"]))
                if d.timestamp() < anchor - 86400: d = d.replace(year=d.year + 1)
            # a bare clock time is its next occurrence after the log's last write, so a later read never rolls a due
            # reset forward; one under an hour back is a rounded reset already due
            elif d.timestamp() < anchor - 3600: d += timedelta(days=1)
        except (ValueError, KeyError, OSError): return None
        t = int(d.timestamp())
    # no limit outlasts a week: a later date is not a reset, so it holds nothing
    return t if t <= anchor + 7 * 86400 + 3600 else None

for p in sys.argv[1:]:
    try: ev, anchor = json.loads(last_line(p) or b"null"), os.stat(p).st_mtime
    except (OSError, ValueError): continue
    if not (isinstance(ev, dict) and ev.get("type") == "result" and ev.get("is_error") is True
            and isinstance(ev.get("result"), str) and re.search(r"\blimit\b", ev["result"], re.I)): continue
    t = reset(ev["result"], anchor)
    print(os.path.basename(p)[:-4], "-" if t is None else t,
          "unknown" if t is None else datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
