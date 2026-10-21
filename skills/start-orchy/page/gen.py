# Usage: python3 -I gen.py   (DROP_PAGES=0,1 leaves settled pages' shots out; ORCHY_PAGE_BUILD=<dir> moves the output)
import json, sys, os, shutil, html, re
HERE = os.path.dirname(os.path.abspath(__file__))
H = os.environ.get("ORCHY_HOME") or sys.exit("ORCHY_HOME is not set: export the orchestrator's state dir (the page data lives in $ORCHY_HOME/page)")
O = f"{H}/page"; SHOTS_DIR = f"{O}/shots"
# The Artifact tool publishes supporting files only from the working directory or the scratchpad.
BUILD = os.environ.get("ORCHY_PAGE_BUILD") or f"{O}/build"
if not os.path.exists(f"{O}/decisions.json"): sys.exit(f"no {O}/decisions.json")
d = json.load(open(f"{O}/decisions.json"))
site = d.get("site")
if not isinstance(site, dict): sys.exit(f'{O}/decisions.json has no "site" object: add {{"repo": "owner/name", "title": "<2-4 words>", "product": "the app", "collection": "decisions", "trunk": "main"}}')
bad = [k for k in ("repo", "title", "product", "collection", "trunk") if not isinstance(site.get(k), str) or not site[k].strip()]
if bad: sys.exit(f"site lacks {', '.join(bad)}")
if not re.fullmatch(r"[\w.-]+/[\w.-]+", site["repo"]): sys.exit(f"site.repo {site['repo']!r} is not owner/name")
if not re.fullmatch(r"[A-Za-z0-9_\-.~:@+]{1,200}", site["collection"]) or site["collection"] in (".", ".."): sys.exit(f"site.collection {site['collection']!r} is not one db path segment")
need = [k for k in ("generated", "repo_head", "pages", "records", "charter", "standing_rules", "holds", "no_ask") if k not in d]
need += [f"holds.{k}" for k in ("merge_holds", "execution_gates", "reservations") if not isinstance((d.get("holds") or {}).get(k), list)]
if need: sys.exit(f"decisions.json lacks {', '.join(need)}")
# page.js interpolates ids, page numbers and issue numbers unescaped, and an id is also a db doc id.
unsafe = [f"id {x.get('id')!r}" for x in d["records"] + d["charter"] if not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", str(x.get("id")))]
unsafe += [f"page {p.get('no')!r}" for p in d["pages"] if type(p.get("no")) is not int]
unsafe += [f"issue {n!r}" for n in [n for r in d["records"] for n in r.get("issue") or []] + [n for c in d["charter"] for n in c.get("applies_to") or []]
           + [n for h in d["holds"]["merge_holds"] for n in h.get("issues") or []] + [x.get("issue") for x in d["no_ask"]] if type(n) is not int]
if unsafe: sys.exit(f"decisions.json has values the page cannot render safely: {', '.join(unsafe[:10])}")
brief = json.load(open(f"{O}/brief.json")) if os.path.exists(f"{O}/brief.json") else {}
brief.setdefault("pages", {}); brief.setdefault("records", {})
RN = json.load(open(f"{O}/render-notes.json")) if os.path.exists(f"{O}/render-notes.json") else {}
manifest = []
mp = f"{SHOTS_DIR}/manifest.json"
if os.path.exists(mp):
    m = json.load(open(mp)); manifest = m if isinstance(m, list) else (m.get("shots") or m.get("rows") or [])
os.makedirs(f"{BUILD}/shots", exist_ok=True)
# Shots of settled pages are left out of the published version (the artifact holds at most 511 files).
DROP_PAGES = {int(x) for x in os.environ.get("DROP_PAGES", "").split(",") if x.strip()}
_dropped = []
if DROP_PAGES:
    _recpage = {r["id"]: r["page_no"] for r in d["records"]}
    _parentpage = {}
    for r in d["records"]:
        for s in r.get("shots", []): _parentpage.setdefault(s["id"], set()).add(r["page_no"])
    def _pages(s):
        ps = set(_parentpage.get(s.get("parent") or s["id"], set())) | {_recpage[x] for x in (s.get("records") or []) if x in _recpage}
        return ps
    _dropped = [s for s in manifest if _pages(s) and _pages(s) <= DROP_PAGES]
    manifest = [s for s in manifest if not (_pages(s) and _pages(s) <= DROP_PAGES)]
    print(f"dropped {len(_dropped)} rows of pages {sorted(DROP_PAGES)}", file=sys.stderr)
# A file a kept row still shows must not be removed from the artifact.
_kept = {s[k] for s in manifest for k in ("light", "dark", "video") if s.get(k)}
json.dump(sorted({f"shots/{s[k]}" for s in _dropped for k in ("light", "dark", "video") if s.get(k) and s[k] not in _kept}), open(f"{BUILD}/_drop-files.json", "w"))
# copy referenced files into the build so the publish can map them as supporting files
out_shots = f"{BUILD}/shots"
shots, missing, files = [], [], {}
for s in manifest:
    have = 0
    for k in ("light", "dark", "video"):
        f = s.get(k)
        if not f: continue
        # A row names a file inside shots/ only: anything else could carry an arbitrary local file into the publish.
        if os.path.basename(f) != f or f.startswith("."): missing.append((s.get("id"), k, f, "not a plain file name")); s[k] = None; continue
        if not os.path.exists(f"{SHOTS_DIR}/{f}"): missing.append((s.get("id"), k, f)); s[k] = None; continue
        shutil.copy2(f"{SHOTS_DIR}/{f}", f"{out_shots}/{f}"); files[f"shots/{f}"] = f"shots/{f}"; have += 1
    if have: shots.append({k: s.get(k) for k in ("id", "parent", "issues", "records", "option", "light", "dark", "video", "browser", "caption", "a11y") if s.get(k) is not None})
items = []
for c in d["charter"]:
    items.append({"id": c["id"], "page_no": 0, "kind": "charter", "title": c["topic"], "question": c["question"], "options": c["options"],
                  "recommend": c["recommend"], "applies_to": c.get("applies_to", []), "change_from_triage": c.get("change_from_triage"), "buttons": c["buttons"], "issue": c.get("applies_to", [])})
for r in d["records"]:
    it = {k: r.get(k) for k in ("id", "issue", "page_no", "kind", "title", "lane", "surface", "proposal", "buttons", "rule_or_precedent", "reply", "hold", "after_shot_in_pr", "list", "line", "default", "recommend", "links") if r.get(k) is not None}
    it["shots"] = [{k: s.get(k) for k in ("id", "kind", "route", "capture", "theme", "browser") if s.get(k) is not None} for s in r.get("shots", [])]
    if r.get("check"): it["kind"] = "check"
    if r.get("premise"): it["premise"] = r["premise"]
    notes = []
    for s in r.get("shots", []):
        if s.get("kind") == "before": notes += [n for n in RN.get(s["id"], []) if n not in notes]
    if r["kind"] == "visual":
        for n_ in r["issue"]: notes += [n for n in RN.get(str(n_), []) if n not in notes]
    if notes: it["render_notes"] = notes
    if r["kind"] == "visual":
        it["options"] = [{"id": o["id"], "text": o["text"], "build": o.get("build")} for o in r["options"]]
    if brief["records"].get(r["id"]): it["brief"] = brief["records"][r["id"]]
    items.append(it)
# order: page then id; charter first on page 0
items.sort(key=lambda i: (i["page_no"], 0 if i["kind"] == "charter" else 1))  # stable: manifest order within a page
pages = [{k: p.get(k) for k in ("no", "name", "wave", "lanes", "intro", "issues")} for p in d["pages"]]
for p in pages:
    if brief["pages"].get(str(p["no"])): p["brief_intro"] = brief["pages"][str(p["no"])]
rs = d["records"]
c = {"issues_on_pages": len({n for r in rs for n in r.get("issue") or []}), "charter": len(d["charter"]), "visual": sum(r["kind"] == "visual" for r in rs),
     "approve": sum(r["kind"] in ("approve", "check") for r in rs), "mac_checks": sum(bool(r.get("check")) or r["kind"] == "check" for r in rs),
     "veto": sum(r["kind"] == "veto" for r in rs), "no_ask": len(d["no_ask"]), **(d.get("counts") or {})}
bad = {k: v for k, v in c.items() if not isinstance(v, int) or isinstance(v, bool)}
if bad: sys.exit(f"counts must be integers (they are printed into the page unescaped): {bad}")
program = site.get("program") or site["collection"]
data = {"page": program, "head": d["repo_head"], "generated": d["generated"], "pages": pages, "items": items, "shots": shots,
        "standing": d["standing_rules"], "holds": d["holds"], "noAsk": d["no_ask"], "counts": c, "site": {k: site[k] for k in ("repo", "collection", "product")}}
# "<!--" would let a later "<script" in the data swallow the closing tag.
js_data = json.dumps(data, ensure_ascii=False).replace("</", "<\\/").replace("<!--", "<\\u0021--")
css = open(f"{HERE}/page.css").read(); js = open(f"{HERE}/page.js").read()
esc = html.escape
def para(t): return re.sub(r"`([^`]+)`", r"<code>\1</code>", re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", esc(t)))
trunk, head = esc(site["trunk"]), esc(d["repo_head"])
n_choice = c["visual"] + c["charter"] + c["mac_checks"]
n_shots_refs = len({s["id"] for r in d["records"] for s in r.get("shots", [])})
lead = [para(x) for x in ([site["intro"]] if isinstance(site["intro"], str) else site["intro"])] if site.get("intro") else [
    f"The {c['issues_on_pages']} open issues that need you, at {trunk} <code>{head}</code>, reduced to <b>{n_choice} choices</b> ({c['charter']} program policies, {c['visual']} screens with built options you can look at, {c['mac_checks']} two-minute checks you run yourself) and <b>{c['approve'] - c['mac_checks']} proposals</b> that are approved when you sign their page. {c['veto']} smaller calls the review panel made are listed per page and accepted unless you strike one; {c['no_ask']} more issues are settled by a rule you already signed and are only listed. Everything else in the backlog needs no answer from you."]
how = ["Each choice shows the recommendation and why. <b>Take every open recommendation</b> fills the choices you have not made with the recommended option in one click; <b>Sign every unsigned page</b> then signs the rest. Or walk page by page. A page signs only on your click; nothing is written into an issue until it does.",
       "<b>What the counts mean.</b> A page's \"N to choose\" are the choices you must make before the page can be signed. Everything else on a page (proposals, panel calls, checks) needs no click: it is approved the moment you sign the page, so a page can carry eight items and still show \"1 to choose\"."]
intro = "\n    ".join(f"<p>{x}</p>" for x in lead + how)
final = para(site["final"]) if site.get("final") else f"The orchestrator writes a <code>## Decision</code> section into each issue (your choice, your note, the date), adds a <code>## Pickup</code> section (lane, arc, prerequisites, gates) and the lane label, and starts wave 1 unattended, one merge into {trunk} at a time. Merge holds stay in force whatever is signed, and a screen nobody foresaw comes back on a page."
page = f"""<title>{esc(site['title'])}</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;700&family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap">
<style>{css}</style>
<div class="wrap">
<header class="top">
  <div class="eyebrow">{esc(program)} · DECIDE · {len(pages)} pages · every item has a default, change only the exceptions</div>
  <h1>Backlog decisions</h1>
  <div class="intro">
    {intro}
  </div>
  <div class="toolbar">
    <span class="small muted">Screenshots:</span>
    <div class="seg" role="group" aria-label="Screenshot theme"><button type="button" data-mode="page" aria-pressed="true">Follow the page</button><button type="button" data-mode="light">Light</button><button type="button" data-mode="dark">Dark</button><button type="button" data-mode="both">Both</button></div>
    <span class="small muted">{len(shots)} shots captured of {n_shots_refs} planned.</span>
    <label class="small" style="display:inline-flex;align-items:center;gap:6px;cursor:pointer"><input type="checkbox" id="hide-signed"> Hide signed pages</label>
  </div>
  <div id="store-banner" class="banner hide" role="status"></div>
</header>
<div class="sticky"><span class="cnt" id="cnt"></span><button type="button" class="ghost" id="take-recs">Take every open recommendation</button><button type="button" id="sign-all">Sign every unsigned page</button></div>
<nav class="toc" aria-label="Pages"><div class="eyebrow">Pages</div><div class="tocgrid" id="toc"></div><p class="small muted" id="hidden-signed" hidden></p></nav>
<div id="pages"></div>
<section class="final">
  <div class="eyebrow">Whole program</div>
  <h2>When every page is signed</h2>
  <p>{final}</p>
  <div class="actions"><button type="button" class="ghost" id="take-recs-2" onclick="document.getElementById('take-recs').click()">Take every open recommendation</button><button type="button" id="sign-all-2" onclick="document.getElementById('sign-all').click()">Sign every unsigned page</button><span class="saveline" id="final-line"></span></div>
</section>
<footer><span>Generated {esc(d['generated'])} from the decision manifest at {trunk} {head}. Shots show {esc(site['product'])} at its real size, Chrome unless marked.</span><span>Answers save to this page's store as you click; only the owner can write.</span></footer>
</div>
<dialog class="lb" id="lb" aria-label="Screenshot"><div class="inner"><img id="lb-img" alt=""><figcaption id="lb-cap"></figcaption><button type="button" id="lb-close">Close</button></div></dialog>
<script>const DATA = {js_data};</script>
<script>{js}</script>
"""
open(f"{BUILD}/decisions.html", "w").write(page)
json.dump(files, open(f"{BUILD}/files.json", "w"), indent=0)
print(f"items={len(items)} shots={len(shots)} files={len(files)} missing={len(missing)} bytes={len(page)} -> {BUILD}/decisions.html", file=sys.stderr)
for mm in missing[:10]: print("  missing", mm, file=sys.stderr)
if len(files) > 510: print(f"warning: {len(files)} shot files; an artifact version holds 511 files with the page: set DROP_PAGES for settled pages", file=sys.stderr)
