# orchy.sh receipt's model: python3 -I receipt.py <home> <repo> <lane or ''> <asks: id -> {state, lane}> <json 0|1> <offline 0|1>
import sys, os, re, json, glob, subprocess, datetime
H, repo, want = sys.argv[1:4]
asks = json.loads(sys.argv[4] or "{}")   # ask id -> {state, lane}; never the owner's words
as_json, offline = sys.argv[5] == "1", sys.argv[6] == "1"
# keys are <lane>-plan, <lane>-a<n>, <lane>-closeout; only logs written before invocation markers need the name
legacy_lane = lambda k: re.sub(r"-(plan|a\d+|closeout|shots[\w-]*)$", "", k)
KINDS = (("in", "input_tokens", "inputTokens"), ("out", "output_tokens", "outputTokens"),
         ("cache-read", "cache_read_input_tokens", "cacheReadInputTokens"), ("cache-write", "cache_creation_input_tokens", "cacheCreationInputTokens"))
UTC = datetime.timezone.utc
def epoch(at):
    try: return datetime.datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC).timestamp()
    except (TypeError, ValueError): return None
iso = lambda t: datetime.datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
segs = []
for path in sorted(glob.glob(f"{H}/leads/*.log")):
    key = os.path.basename(path)[:-4]; seg = None; mine = []
    def new(lane, k, at, cmd=None):
        s = {"lane": lane, "key": k, "at": at, "cmd": cmd, "sid": None, "result": None, "after": {}, "mtime": os.path.getmtime(path), "file": mine}
        segs.append(s); mine.append(s); return s
    for line in open(path, errors="replace"):
        try: e = json.loads(line)
        except ValueError: continue
        if not isinstance(e, dict): continue
        t = e.get("type")
        if t == "orchy_invocation": seg = new(e.get("lane") or legacy_lane(key), e.get("key") or key, e.get("at") or "", e.get("cmd")); continue
        if t == "system" and e.get("subtype") == "init":
            if seg is None or (seg["sid"] and not seg["at"]): seg = new(legacy_lane(key), key, "")
            seg["sid"] = seg["sid"] or e.get("session_id"); continue
        if seg is None: seg = new(legacy_lane(key), key, "")
        if t == "result": seg["result"] = e; seg["after"] = {}
        elif t == "assistant" and isinstance(e.get("message"), dict) and e["message"].get("usage"):
            seg["after"][e["message"].get("id") or id(e)] = e["message"]["usage"]   # a message repeats per content block: keep the last
# On --resume, total_cost_usd and modelUsage are the session's running totals: each session counts its last result once,
# plus the unpriced usage of runs killed after it. A run's own cost is its total minus the session's previous total.
lanes, by_sid = {}, {}
for i, s in enumerate(segs): s["sid"] = s["sid"] or f"unknown-{i}"
def order(s):  # an unmarked segment sits just before the next marked one in its log, else at the log's mtime;
    # only order within a session matters: ties go by the session's running total so far in this log (a killed run has
    # none of its own), then by position in the log
    i = s["file"].index(s); later = [x["at"] for x in s["file"][i + 1:] if x["at"]]
    total = max([float(x["result"].get("total_cost_usd") or 0) for x in s["file"][:i + 1] if x["result"] and x["sid"] == s["sid"]] or [0.0])
    return (s["at"] or (later[0] if later else iso(s["mtime"])), 1 if s["at"] else 0, total, i)
for s in sorted(segs, key=order): by_sid.setdefault(s["sid"], []).append(s)
for sid, ss in by_sid.items():
    L = lanes.setdefault(ss[0]["lane"], {"cost": 0.0, "tok": {k[0]: 0 for k in KINDS}, "partial": 0, "sessions": 0, "keys": set(), "start": None, "end": 0, "runs": []})
    L["sessions"] += 1
    done = [j for j, s in enumerate(ss) if s["result"]]
    if done:
        r = ss[done[-1]]["result"]; L["cost"] += float(r.get("total_cost_usd") or 0)
        for mu in (r.get("modelUsage") or {}).values():
            for name, _, camel in KINDS: L["tok"][name] += int(mu.get(camel) or 0)
    for s in ss[done[-1] if done else 0:]:
        L["partial"] += sum(int(u.get(snake) or 0) for u in s["after"].values() for _, snake, _ in KINDS)
    prev = 0.0
    for s in ss:
        L["keys"].add(s["key"]); L["end"] = max(L["end"], s["mtime"])
        if s["at"] and (L["start"] is None or s["at"] < L["start"]): L["start"] = s["at"]
        r, cost = s["result"], None
        if r:
            total = float(r.get("total_cost_usd") or 0); cost = round(total - prev if total >= prev else total, 6); prev = total
        # the log's mtime is the file's, not the run's: it is the last resort, flagged approx
        t0, dur, ended, approx = epoch(s["at"]), (r or {}).get("duration_ms"), None, True
        if t0 is not None and isinstance(dur, (int, float)): ended, approx = iso(t0 + dur / 1000), False
        else:
            later = [x for x in s["file"][s["file"].index(s) + 1:] if x["at"]]
            ended = later[0]["at"] if later else iso(s["mtime"])
        L["runs"].append({"key": s["key"], "session": s["sid"], "cmd": s["cmd"], "at": s["at"] or None, "ended": ended, "approx": approx, "cost_usd": cost})
def gh(*a):
    p = subprocess.run(["gh", *a, "--repo", repo], capture_output=True, text=True)
    if p.returncode: raise RuntimeError(p.stderr.strip()[:120])
    return p.stdout.split()
model = {"schema": "orchy.receipt/1", "offline": offline, "lanes": [], "total": None}
for lane in sorted(lanes):
    if want and lane != want: continue
    L = lanes[lane]; prs, failed, rounds = [], 0, 0
    try: named = [f[:-3] for f in os.listdir(f"{H}/reports") if re.fullmatch(rf"{re.escape(lane)}-(plan|closeout|a\d+|arc\d+)\.md", f)]
    except OSError: named = []
    for k in sorted(L["keys"] | set(named)):
        try: rep = open(f"{H}/reports/{k}.md", errors="replace").read()
        except OSError: continue
        prs += [int(n) for n in re.findall(r"^PR #(\d+) ", rep, re.M)]
        failed += len(re.findall(r"^ARC_FAILED:", rep, re.M)); rounds += sum(int(n) for n in re.findall(r"^CODEX: converged in (\d+) round", rep, re.M))
    prs = sorted(set(prs)); merged = []
    for n in prs:
        try: out = open(f"{H}/watch/merge-{n}.out", errors="replace").read()
        except OSError: continue
        if re.search(rf"^#{n} MERGED [0-9a-f]+", out, re.M): merged.append(n)
    closed, gh_error = None, None
    if not offline:
        try:
            refs = sorted({int(i) for n in merged for i in gh("pr", "view", str(n), "--json", "closingIssuesReferences", "--jq", ".closingIssuesReferences[].number")})
            closed = [i for i in refs if gh("issue", "view", str(i), "--json", "state", "--jq", ".state") == ["CLOSED"]]
        except RuntimeError as err: gh_error = str(err)
    t0 = epoch(L["start"]); wall = None if t0 is None else int(L["end"] - t0)
    done_asks = sorted((i for i, a in asks.items() if a.get("state") == "done" and a.get("lane") == lane), key=lambda i: int(i[3:]) if i[3:].isdigit() else 0)
    model["lanes"].append({"lane": lane, "cost_usd": L["cost"], "unpriced_tokens": L["partial"], "sessions": L["sessions"],
        "tokens": {k.replace("-", "_"): v for k, v in L["tok"].items()}, "wall_s": wall, "start": L["start"], "prs": prs, "merged": merged,
        "issues_closed": closed, "gh_error": gh_error, "failed_arcs": failed, "codex_rounds": rounds, "asks_done": done_asks, "runs": L["runs"]})
if not want: model["total"] = {"cost_usd": sum(l["cost_usd"] for l in model["lanes"]), "unpriced_tokens": sum(l["unpriced_tokens"] for l in model["lanes"])}
missing = bool(want) and want not in lanes
if as_json:
    print(json.dumps(model)); sys.exit(1 if missing else 0)
for l in model["lanes"]:
    wall = "?" if l["wall_s"] is None else f"{int(l['wall_s'] // 3600)}h{int(l['wall_s'] % 3600 // 60):02d}m"
    if offline: issues = "? (offline)"
    elif l["gh_error"] is not None: issues = f"? (gh: {l['gh_error']})"
    else: issues = f"{len(l['issues_closed'])}" + (f" ({' '.join(f'#{i}' for i in l['issues_closed'])})" if l["issues_closed"] else "")
    tok = " ".join(f"{k.replace('_', '-')} {v}" for k, v in l["tokens"].items())
    part = f" + {l['unpriced_tokens']} unpriced tokens from killed runs" if l["unpriced_tokens"] else ""
    print(f"{l['lane']}: ${l['cost_usd']:.2f} API-equivalent{part}; {l['sessions']} session(s); tokens {tok}; wall {wall}; "
          f"PRs {' '.join(f'#{n}' for n in l['prs']) or '-'} (merged {' '.join(f'#{n}' for n in l['merged']) or '-'}); issues closed {issues}; "
          f"failed arcs {l['failed_arcs']}; Codex rounds {l['codex_rounds']}; asks done {len(l['asks_done'])}" + (f" ({' '.join(l['asks_done'])})" if l["asks_done"] else ""))
if not want and len(lanes) > 1:
    t = model["total"]; print(f"total: ${t['cost_usd']:.2f} API-equivalent" + (f" + {t['unpriced_tokens']} unpriced tokens" if t["unpriced_tokens"] else ""))
rec_file = os.path.join(os.environ.get("ORCHY_PROFILE_DIR") or os.path.expanduser("~/.agents/orchy/profile"), repo.replace("/", "-") + ".jsonl")
if os.path.exists(rec_file):
    last = {}
    for line in open(rec_file, errors="replace"):
        try: o = json.loads(line); last[o["record"]] = o
        except (ValueError, KeyError, TypeError): continue
    cats, take_all, neither = {}, 0, 0
    for o in last.values():
        if o.get("via_recommend_all"): take_all += 1
        elif o.get("agreed") is None: neither += 1
        else: c = cats.setdefault(o.get("category") or "other", [0, 0]); c[0] += bool(o["agreed"]); c[1] += 1
    print("owner took the recommendation: " + (", ".join(f"{k} {a}/{n}" for k, (a, n) in sorted(cats.items())) or "nothing scored yet")
          + f"; {take_all} taken all at once (not scored), {neither} left to the orchestrator")
if missing: print(f"no lead logs for lane {want}", file=sys.stderr); sys.exit(1)
