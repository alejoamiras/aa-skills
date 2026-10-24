# Usage: python3 -I add-page.py <spec.json>   spec: {"page": {...}, "records": [...], "manifest_rows": [...]}
import json, shutil, datetime, re, os, sys
H = os.environ.get("ORCHY_HOME") or sys.exit("ORCHY_HOME is not set: export the orchestrator's state dir (the page data lives in $ORCHY_HOME/page)")
if len(sys.argv) != 2: sys.exit("usage: python3 -I add-page.py <spec.json>")
O = f"{H}/page"; SD = f"{O}/shots"; DP = f"{O}/decisions.json"; MP = f"{SD}/manifest.json"
spec = json.load(open(sys.argv[1])); page, recs, rows = spec.get("page") or {}, spec.get("records") or [], spec.get("manifest_rows") or []
d = json.load(open(DP)); m = json.load(open(MP)) if os.path.exists(MP) else {"shots": [], "skipped": []}
mrows = m if isinstance(m, list) else m.setdefault("shots", [])
BAN = re.compile((d.get("site") or {}).get("caption_ban") or r"attack|weakness|vulnerab|exploit|advisory|GHSA|finding|broken|\bbug\b", re.I)
no = page.get("no")
if type(no) is not int: sys.exit("page.no must be an integer")
if any(p["no"] == no for p in d["pages"]): sys.exit(f"page {no} exists already: a page number is never reused")
errs = []
def need(obj, keys, where): errs.extend(f"{where}: no {k}" for k in keys if obj.get(k) in (None, ""))
def banned(text, where):
    if isinstance(text, str) and BAN.search(text): errs.append(f"{where}: {BAN.search(text).group(0)!r} is banned in what the owner sees")
need(page, ("name", "wave", "lanes", "intro"), f"page {no}")
if not recs: errs.append(f"page {no}: no records")
if not isinstance(page.get("lanes", []), list): errs.append(f"page {no}: lanes must be a list")
known = {r["id"]: r for r in d["records"]} | {c["id"]: c for c in d["charter"]}
seen = set()
for r in recs:
    rid = r.get("id") or "?"
    need(r, ("id", "issue", "page_no", "kind", "title", "lane", "buttons", "rule_or_precedent", "writes_back"), rid)
    if rid in known or rid in seen: errs.append(f"{rid}: id is not unique")
    # The page renders ids unescaped and stores answers under choice-<id>.
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", str(r.get("id"))): errs.append(f"{rid}: id must match [A-Za-z0-9_.-]")
    seen.add(rid)
    if r.get("page_no") != no: errs.append(f"{rid}: page_no {r.get('page_no')} != page {no}")
    if not isinstance(r.get("issue"), list) or not all(type(n) is int for n in r.get("issue") or []): errs.append(f"{rid}: issue must be a list of issue numbers")
    wb, kind = r["writes_back"] if isinstance(r.get("writes_back"), dict) else {}, r.get("kind")
    # apply-decisions merges an issue's sections under the first one's heading.
    for k, t in wb.items():
        if k == "options": continue
        if not isinstance(t, str) or not t.startswith("## Decision\n"): errs.append(f"{rid}: writes_back.{k} must be a template string starting with '## Decision'")
    banned(r.get("surface"), f"{rid} surface")
    if kind == "visual":
        need(r, ("surface", "options", "recommend"), rid)
        keys = [o.get("id") for o in r.get("options") or []]
        if not keys or not all(isinstance(k, str) and k for k in keys) or len(set(keys)) != len(keys): errs.append(f"{rid}: options need unique ids")
        for o in r.get("options") or []: banned(o.get("text"), f"{rid} option {o.get('id')}")
        if (r.get("recommend") or {}).get("id") not in keys: errs.append(f"{rid}: recommend.id must be one of {keys}")
        for k in ["on_choice", "options"] + (["on_as_is"] if "As is" in (r.get("buttons") or []) else []):
            if k not in wb: errs.append(f"{rid}: writes_back needs {k}")
        missing_opt = [k for k in keys if k not in (wb.get("options") or {})]
        if missing_opt: errs.append(f"{rid}: writes_back.options lacks {missing_opt}")
        for s in r.get("shots") or []:
            if s.get("kind") == "option" and not any(str(s.get("id", "")).lower().endswith(f"-{k.lower()}") for k in keys if isinstance(k, str)):
                errs.append(f"{rid}: option shot {s.get('id')} must end with -<option key> ({', '.join(k.lower() for k in keys if isinstance(k, str))})")
    elif kind == "approve":
        need(r, ("proposal",), rid)
        for k in (("on_result",) if r.get("check") else ("on_approve", "on_change")):
            if k not in wb: errs.append(f"{rid}: writes_back needs {k}")
    elif kind == "veto":
        need(r, ("line", "list"), rid)
        for k in ("on_accept", "on_strike"):
            if k not in wb: errs.append(f"{rid}: writes_back needs {k}")
    else: errs.append(f"{rid}: kind must be visual, approve or veto (a manual check is approve with check: true)")
    for s in r.get("shots") or []:
        if not s.get("id") or not s.get("kind"): errs.append(f"{rid}: every shot needs id and kind")
spec_recs = {r.get("id"): r for r in recs}
row_ids = {s.get("id") for s in mrows}
for s in rows:
    sid = str(s.get("id") or "?")
    need(s, ("id", "records", "caption"), f"row {sid}")
    if sid in row_ids: errs.append(f"row {sid}: id is not unique")
    row_ids.add(sid)
    for x in s.get("records") or []:
        if x not in spec_recs and x not in known: errs.append(f"row {sid}: record {x} does not exist")
    files = [s[k] for k in ("light", "dark", "video") if s.get(k)]
    if not files: errs.append(f"row {sid}: needs light, dark or video")
    for f in files:
        if os.path.basename(f) != f or f.startswith("."): errs.append(f"row {sid}: {f!r} must be a plain file name inside shots/")
        elif not os.path.isfile(f"{SD}/{f}"): errs.append(f"row {sid}: {f} is not in $ORCHY_HOME/page/shots/")
    banned(s.get("caption"), f"row {sid} caption")
    opts = {str(o.get("id")).lower() for x in s.get("records") or [] for o in (spec_recs.get(x) or known.get(x) or {}).get("options") or []}
    if isinstance(s.get("option"), str) and s["option"].lower() in opts and not sid.lower().endswith(f"-{s['option'].lower()}"):
        errs.append(f"row {sid}: an option {s['option']} row's id must end with -{s['option'].lower()}")
if errs: sys.exit("refused, nothing written:\n- " + "\n- ".join(errs))
for r in recs: r.setdefault("page", page["name"]); r.setdefault("shots", [])
now = datetime.datetime.now(datetime.timezone.utc)
page.setdefault("added_at", now.strftime("%Y-%m-%dT%H:%M:%SZ"))   # snapshot shows how long a page has waited for the owner
stamp = now.strftime("%Y%m%d-%H%M%S")
for f in (DP, MP):
    if os.path.exists(f): shutil.copy2(f, f"{f}.bak-p{no}-{stamp}")
d["pages"].append(page); d["records"] += recs; mrows += rows
def stage(obj, path):
    with open(f"{path}.tmp", "w") as fh: json.dump(obj, fh, ensure_ascii=False, indent=1)
# both files are staged before either is replaced, so a failure leaves the originals whole
os.makedirs(SD, exist_ok=True); stage(d, DP); stage(m, MP)
os.replace(f"{DP}.tmp", DP)
try: os.replace(f"{MP}.tmp", MP)
except OSError:
    # the manifest did not land: put decisions.json back so the two files never disagree
    if os.path.exists(f"{DP}.bak-p{no}-{stamp}"): shutil.copy2(f"{DP}.bak-p{no}-{stamp}", DP)
    raise
print(f"page {no} added: {len(recs)} records, {len(rows)} manifest rows; backups *.bak-p{no}-{stamp}")
