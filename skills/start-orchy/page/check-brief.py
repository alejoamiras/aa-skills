# Usage: python3 -I check-brief.py   (pages from UNSIGNED=80,81 or $ORCHY_HOME/page/unsigned.json)
import json, re, sys, os
H = os.environ.get("ORCHY_HOME") or sys.exit("ORCHY_HOME is not set: export the orchestrator's state dir (the page data lives in $ORCHY_HOME/page)")
O = f"{H}/page"
if not os.path.exists(f"{O}/brief.json"): sys.exit(f"no {O}/brief.json to check")
d = json.load(open(f"{O}/decisions.json")); b = json.load(open(f"{O}/brief.json"))
if os.environ.get("UNSIGNED", "").strip(): UNSIGNED = {int(x) for x in os.environ["UNSIGNED"].split(",") if x.strip()}
elif os.path.exists(f"{O}/unsigned.json"): UNSIGNED = {int(x) for x in json.load(open(f"{O}/unsigned.json"))}
else: sys.exit("no unsigned pages: set UNSIGNED=80,81 or write $ORCHY_HOME/page/unsigned.json ([80, 81])")
BAD = re.compile((d.get("site") or {}).get("brief_ban") or r"\.(vue|ts|js|md|json)\b|:\d{2,}\b|review table|\bC\d{1,2}\b|\bOA-\d+|\bP\d{1,2}-\d\d|\(verified\)|\(inferred\)|\bR\d\b|\bH\d\b|precedent|arc \d|plan\b", re.I)
W = lambda s: len(str(s).split())
errs = []
recs = {r["id"]: r for r in d["records"] if r["page_no"] in UNSIGNED}
for rid, r in recs.items():
    x = b.get("records", {}).get(rid)
    if not x: errs.append(f"{rid}: missing"); continue
    if W(x.get("ask", "")) == 0 or W(x["ask"]) > 28: errs.append(f"{rid}: ask {W(x.get('ask',''))} words")
    if BAD.search(x.get("ask", "")): errs.append(f"{rid}: ask cites context: {BAD.search(x['ask']).group(0)!r}")
    if r["kind"] == "visual":
        ids = [o["id"] for o in r["options"]]
        if list(x.get("options", {}).keys()) != ids: errs.append(f"{rid}: options {list(x.get('options',{}).keys())} != {ids}")
        for k, t in x.get("options", {}).items():
            if W(t) > 20: errs.append(f"{rid}: option {k} {W(t)} words")
            if BAD.search(t): errs.append(f"{rid}: option {k} cites context: {BAD.search(t).group(0)!r}")
        rec = (r.get("recommend") or {}).get("id")
        if rec and x.get("pick", {}).get("id") != rec: errs.append(f"{rid}: pick {x.get('pick',{}).get('id')} != recommend {rec}")
        if W(x.get("pick", {}).get("why", "")) > 22: errs.append(f"{rid}: pick why {W(x['pick']['why'])} words")
    if x.get("now") and W(x["now"]) > 22: errs.append(f"{rid}: now {W(x['now'])} words")
    for k in ("now", "pick"):
        v = x.get(k); v = v.get("why", "") if isinstance(v, dict) else (v or "")
        if BAD.search(v): errs.append(f"{rid}: {k} cites context: {BAD.search(v).group(0)!r}")
# brief.json keeps every page's records; the ones on signed pages are history, not errors
extra = set(b.get("records", {})) - set(recs)
if extra: print(f"note: {len(extra)} brief records belong to signed pages", file=sys.stderr)
for pno in UNSIGNED:
    pi = b.get("pages", {}).get(str(pno))
    if pi is None: errs.append(f"page {pno}: missing intro")
    elif W(pi) > 24: errs.append(f"page {pno}: intro {W(pi)} words")
print("\n".join(errs) if errs else f"OK: {len(recs)} records, {len(UNSIGNED)} pages")
sys.exit(1 if errs else 0)
