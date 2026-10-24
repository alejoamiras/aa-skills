// Writes the owner's page answers into the issues: one `## Decision` (every record's text, page order)
// and one `## Pickup` (lane, arc, prerequisites, gates) per issue, plus the lane label.
// Usage: bun apply-decisions.ts --answers <dir-or-json> [--apply] [--force]
// A signed page writes the choices its signoff doc snapshotted; a later change to a choice holds that record until the page is signed again.
// Reads $ORCHY_HOME/page/{decisions.json,lanes.json,public-notes.json}; a dry-run (no --apply) never calls gh.
// --apply also records each signed record against its recommendation in ${ORCHY_PROFILE_DIR:-~/.agents/orchy/profile}/<owner>-<repo>.jsonl.
import { readdirSync, readFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
if (!process.env.ORCHY_HOME) { console.error("ORCHY_HOME is not set: export the orchestrator's state dir (the page data lives in $ORCHY_HOME/page)"); process.exit(2); }
const O = join(process.env.ORCHY_HOME, "page");
const MARK = "<!-- orchy:decision -->";
const args = process.argv.slice(2);
const opt = (k: string) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : undefined; };
const APPLY = args.includes("--apply"), FORCE = args.includes("--force");
if (args.includes("--page")) { console.error("--page is gone: the block below the marker is rewritten whole, so a partial apply would drop other pages' decisions"); process.exit(2); }
const answersPath = opt("--answers"); if (!answersPath) throw new Error("--answers <dir|json> required");
const D = JSON.parse(readFileSync(join(O, "decisions.json"), "utf8"));
const S = D.site ?? {};
if (!/^[\w.-]+\/[\w.-]+$/.test(S.repo ?? "") || !S.collection) { console.error(`${join(O, "decisions.json")} needs "site": {"repo": "owner/name", "collection": ...}`); process.exit(2); }
const REPO: string = S.repo, COLL: string = S.collection, PROGRAM: string = S.program ?? S.collection;
const LANE_PREFIX: string = S.lane_label_prefix ?? "lane:", OWNER_LABEL: string = S.owner_decision_label ?? "owner-decision";
if (!existsSync(join(O, "lanes.json"))) { console.error(`no ${join(O, "lanes.json")}: write the lane map first`); process.exit(2); }
const L = JSON.parse(readFileSync(join(O, "lanes.json"), "utf8"));

type Doc = Record<string, any>;
function loadAnswers(p: string): Doc[] {
  if (p.endsWith(".json")) { const j = JSON.parse(readFileSync(p, "utf8")); return Array.isArray(j) ? j : j.docs ?? Object.values(j); }
  const dir = existsSync(join(p, COLL)) ? join(p, COLL) : p;
  return readdirSync(dir).filter(f => f.endsWith(".json")).map(f => { const j = JSON.parse(readFileSync(join(dir, f), "utf8")); const d = j.data && typeof j.data === "object" && "page" in j.data ? j.data : j; d.__id ??= f.replace(/\.json$/, ""); return d; });
}
const docs = loadAnswers(answersPath);
// The owner's free text is private: an owner-authored field reaches a public issue only as its reviewed public wording in
// public-notes.json (key "<record id>" for a note, "<record id>.<field>" otherwise), and only when it contributes to what
// was signed; nothing is written while one is missing.
const publicNotesPath = join(O, "public-notes.json");
const publicNotes: Record<string, string> = existsSync(publicNotesPath) ? JSON.parse(readFileSync(publicNotesPath, "utf8")) : {};
const pubKey = (id: string, k: string) => k === "note" ? id : `${id}.${k}`;
// What goes out verbatim (public wordings, the orchestrator's `recorded`) must not copy the owner's words or carry a secret;
// a check that cannot run refuses.
{
  const outbound = [...Object.entries(publicNotes), ...docs.filter(d => typeof d.recorded === "string" && d.recorded).map(d => [`${String(d.__id ?? d.id)}.recorded`, d.recorded as string])];
  if (outbound.length) {
    const dir = mkdtempSync(join(O, ".outbound-")), files = outbound.map(([, t], i) => { const f = join(dir, `${i}.txt`); writeFileSync(f, t + "\n"); return f; });
    // the owner's words: the ask ledger plus the raw page text, read before any wording replaces it
    const asks = join(process.env.ORCHY_ASKS_DIR ?? join(homedir(), ".agents/orchy/asks"), `${REPO.replace("/", "-")}.jsonl`);
    const raw = docs.flatMap(d => [...["note", "result", "next_step", "except"].map(k => d[k]), ...Object.values(d.notes && typeof d.notes === "object" ? d.notes : {})]).filter((t): t is string => typeof t === "string" && t !== "");
    const ledger = join(dir, "owner.jsonl");
    writeFileSync(ledger, (existsSync(asks) ? readFileSync(asks, "utf8").replace(/\n?$/, "\n") : "") + raw.map(t => JSON.stringify({ id: "page", text: t })).join("\n") + "\n");
    const ov = Bun.spawnSync(["bash", join(import.meta.dir, "../scripts/overlap.sh"), ledger, ...files]);
    const copied = outbound.filter((_, i) => ov.stdout.toString().includes(`overlap: ${files[i]} `)).map(([k]) => k);
    let gl = -1; try { gl = Bun.spawnSync([process.env.ORCHY_GITLEAKS ?? "gitleaks", "stdin", "--no-banner", "--redact", "--exit-code", "3", "-l", "error"], { stdin: new TextEncoder().encode(outbound.map(([, t]) => t).join("\n")) }).exitCode; } catch {}
    rmSync(dir, { recursive: true, force: true });
    if (ov.exitCode !== 0 && ov.exitCode !== 1) { console.error("refused: the copy check could not run"); process.exit(2); }
    if (copied.length) { console.error(`refused: these public wordings copy six consecutive words of the owner's own: ${copied.join(", ")}`); process.exit(4); }
    if (gl === 3) { console.error("refused: a public wording or a recorded text carries a secret (gitleaks)"); process.exit(4); }
    if (gl !== 0) { console.error("refused: gitleaks could not run, so the secret check cannot"); process.exit(2); }
  }
}
const SENSITIVE = S.sensitive ? new RegExp(S.sensitive, "i") : /\bfindings?\b|advisor(y|ies)|GHSA|vulnerab|exploit|\battack|confidential/i;
// a home path, an account name or a page link never reaches a public issue, reviewed wording included: the scan's own
// patterns through the scan's own engine (grep -E, line by line), so the two never disagree on what leaks
const readCfg = (f: string) => existsSync(join(process.env.ORCHY_HOME!, f)) ? JSON.parse(readFileSync(join(process.env.ORCHY_HOME!, f), "utf8")) : {};
const LEAK = [readCfg("orchy.json").scan?.leak, readCfg("local.json").prompt_ban].filter((r): r is string => typeof r === "string" && r !== "").map(r => `(${r})`).join("|");
const leaks = (t: string) => {
  if (!LEAK) return false;
  const rc = Bun.spawnSync(["grep", "-qE", "--", LEAK], { stdin: new TextEncoder().encode(t) }).exitCode;
  if (rc !== 0 && rc !== 1) { console.error("refused: scan.leak or prompt_ban is not a valid grep -E pattern"); process.exit(2); }
  return rc === 0;
};
const held: string[] = [], leaked: string[] = [];
// every free-text field that can reach an issue body goes through the leak filter; the orchestrator's own `recorded`
// keeps the sensitive-word hold, and owner-authored fields are held where they contribute (own, below)
const FREE_TEXT = ["note", "result", "next_step", "recorded", "except"];
for (const d of docs) {
  const id = String(d.__id ?? d.id ?? "").replace(/^choice-/, "");
  for (const k of FREE_TEXT) {
    if (typeof d[k] !== "string" || !d[k]) continue;
    const pub = publicNotes[pubKey(id, k)];
    if (pub !== undefined) d[k] = pub;
    else if (k === "recorded" && SENSITIVE.test(d[k])) held.push(`${id}.${k}`);
    if (leaks(d[k])) leaked.push(`${id}.${k}`);
  }
  if (d.notes && typeof d.notes === "object") for (const k of Object.keys(d.notes)) {
    if (publicNotes[k] !== undefined) d.notes[k] = publicNotes[k];
    if (typeof d.notes[k] === "string" && leaks(d.notes[k])) leaked.push(k);
  }
}
if (leaked.length) { console.error(`refused: these fields carry a local path, an account name or a page link (scan.leak or prompt_ban); reword them, or give a public wording in public-notes.json: ${[...new Set(leaked)].join(", ")}`); process.exit(4); }
// an owner-authored field that reaches an issue: its public wording, or a hold (values are already substituted above)
const own = (id: string, k: string, v: string | undefined) => { if (v && publicNotes[pubKey(id, k)] === undefined) held.push(pubKey(id, k)); };
const choices: Record<string, Doc> = {}, signoffs: Record<number, Doc> = {};
for (const d of docs) { const id = d.__id ?? d.id; if (typeof id === "string" && id.startsWith("signoff-P")) signoffs[Number(id.slice(9))] = d; else if (d.id && d.kind) choices[d.id] = d; else if (typeof id === "string" && id.startsWith("choice-")) choices[id.slice(7)] = d; }

const fill = (t: string, v: Record<string, string>) => t.replace(/\{(\w+)\}/g, (_, k) => v[k] ?? `{${k}}`).replace(/^Owner note: (\(none\))?\s*$/gm, "").replace(/\n{3,}/g, "\n\n");
const dateOf = (iso: string) => (iso || new Date().toISOString()).slice(0, 10);
const charterById = Object.fromEntries(D.charter.map((c: any) => [c.id, c]));

// issue -> [{page, order, text}]
const out: Record<number, { page: number; order: number; text: string }[]> = {};
const push = (issue: number, page: number, order: number, text: string) => (out[issue] ??= []).push({ page, order, text });
const manual: string[] = [];
const recorded: string[] = [];
// What a signoff snapshotted is what was signed. Three outcomes per record: a doc (answered), undefined (signed as the
// default; a doc added after signing does not count), or HELD (changed after signing: nothing of its issues is written).
const HELD: Doc = { __held: true };
// Owner record: only what a signoff snapshotted counts; `explicit` is false for a default the owner signed without touching.
// A take-all pick is kept but never scored as agreement, and a `read` (left to the orchestrator, or a note instead of an option) scores neither way.
const ownerRows: Doc[] = [];
const ownerRow = (s: Doc, p: any, r: any, a: Doc | undefined, recommended: string, agreeOn: (c: string) => boolean) => {
  if (!(s.choices && typeof s.choices === "object" && r.id in s.choices)) return;
  const chosen: string = a?.choice ?? recommended;
  ownerRows.push({ repo: REPO, page: p.no, record: r.id, kind: r.kind ?? "charter", category: r.category ?? "other", recommended, chosen,
    agreed: chosen === "read" ? null : agreeOn(chosen), explicit: s.choices[r.id] !== null, via_recommend_all: Array.isArray(s.taken_all) ? s.taken_all.includes(r.id) : a?.viaRecommendAll === true, note: a?.note ?? "", signed_at: s.at ?? "" });
};
const heldIssues = new Set<number>();
const heldPages: number[] = [];
const pagesToWrite = D.pages.filter((p: any) => signoffs[p.no]).filter((p: any) => {
  const s = signoffs[p.no];
  // an `except` note withholds the whole page until the orchestrator settles it with the owner and sets except_resolved on the signoff doc
  if (s.except && !s.except_resolved) {
    heldPages.push(p.no); manual.push(`page ${p.no} HELD by its except note (set except_resolved on signoff-P${p.no} once settled): ${s.except}`);
    for (const r of D.records.filter((r: any) => r.page_no === p.no)) for (const n of r.issue) heldIssues.add(n);
    if (p.no === 0) { for (const c of D.charter) for (const n of c.applies_to ?? []) heldIssues.add(n); for (const x of D.no_ask ?? []) heldIssues.add(x.issue); }
    return false;
  }
  return true;
});
const signed = (s: Doc, id: string): Doc | undefined => {
  const live = choices[id];
  if (!(s.choices && typeof s.choices === "object" && id in s.choices)) return live;   // a signoff without a snapshot: the live doc
  const snap = s.choices[id];
  if (snap === null) return undefined;
  if ((live?.choice ?? null) !== snap) {
    manual.push(`${id} changed after page ${s.page_no} was signed (signed ${snap}, now ${live?.choice ?? "the default"}); held until the page is signed again`);
    const rec = D.records.find((r: any) => r.id === id) ?? charterById[id]; for (const n of rec?.issue ?? rec?.applies_to ?? []) heldIssues.add(n);
    return HELD;
  }
  const note = s.notes && typeof s.notes === "object" && typeof s.notes[id] === "string" ? s.notes[id] : "";
  return { ...(live ?? {}), choice: snap, note };
};
for (const p of pagesToWrite) {
  const s = signoffs[p.no], date = dateOf(s.at);
  let order = 0;
  if (p.no === 0) {
    for (const c of D.charter) {
      const a = signed(s, c.id); if (a === HELD) continue; if (!a) { manual.push(`${c.id} unanswered though page 0 is signed`); continue; }
      ownerRow(s, p, c, a, c.recommend?.id ?? "", ch => ch === c.recommend?.id);
      own(c.id, "note", a.note);
      const optText = c.options.find((o: any) => o.id === a.choice)?.text ?? "";
      for (const [key, tpl] of Object.entries<string>(c.writes_back)) {
        const targets = key === "*" ? c.applies_to : [Number(key)];
        for (const n of targets) {
          const pr = D.records.find((r: any) => Array.isArray(r.issue) && r.issue.includes(n));
          const pg = pr ? D.pages.find((q: any) => q.no === pr.page_no) : undefined;
          let t = fill(tpl, { date, option: a.choice, option_text: optText, note: a.note || "(none)", page_no: pr?.page_no ?? "", page: pg?.name ?? "" });
          if (!pr) t = t.replace(/^Applied to this issue on page.*$\n?/m, "");
          if (a.note) t = t.trimEnd() + `\n\nOwner note: ${a.note}\n`;
          push(n, 0, order++, t);
        }
      }
    }
    for (const n of D.no_ask) push(n.issue, 0, order++, `## Decision\n\nOwner, ${date}, page 0 (Program charter): settled by a rule already signed, listed on the page and not struck.\n\n${n.decision}\n\nRule: ${n.rule}\n`);
    continue;
  }
  for (const r of D.records.filter((r: any) => r.page_no === p.no)) {
    const a = signed(s, r.id), wb = r.writes_back; let text = ""; if (a === HELD) continue;
    if (r.kind === "approve" && !r.check) ownerRow(s, p, r, a, "approve", ch => ch !== "change");
    else if (r.kind === "veto") ownerRow(s, p, r, a, "accept", ch => ch !== "strike");
    else if (r.kind === "visual" && a) ownerRow(s, p, r, a, r.recommend?.id ?? "", ch => ch === r.recommend?.id);
    if (r.check) { own(r.id, "result", a?.result); own(r.id, "next_step", a?.next_step); }
    else if (r.kind === "approve" || (r.kind === "veto" && a?.choice === "strike") || (r.kind === "visual" && a && (a.choice !== "read" || a.recorded))) own(r.id, "note", a?.note);
    if (r.check) { if (!a) { manual.push(`${r.id} (#${r.issue.join(", #")}) manual check not recorded; nothing written`); continue; } text = fill(wb.on_result, { date, result: a.result || "", next_step: a.next_step || "the orchestrator proposes one" }); }
    else if (r.kind === "approve") text = a?.choice === "change" ? fill(wb.on_change, { date, note: a.note || "" }) : fill(wb.on_approve, { date, note: a?.note || "" });
    else if (r.kind === "veto") text = a?.choice === "strike" ? fill(wb.on_strike, { date, note: a.note || "" }) : fill(wb.on_accept, { date });
    else if (r.kind === "visual") {
      if (!a) { manual.push(`${r.id} unanswered though page ${p.no} is signed`); continue; }
      if (a.choice === "read" && a.recorded) { recorded.push(`${r.id} (#${r.issue.join(", #")})`); text = `## Decision\n\nOwner, ${date}, decision page ${p.no} (${p.name}), ${r.title}: **a note instead of an option**.\n\nOwner note: ${a.note || "(none)"}\n\nRecorded: ${a.recorded}\n`; for (const n of r.issue) push(n, p.no, order++, text); continue; }
      if (a.choice === "read") { manual.push(`${r.id} (#${r.issue.join(", #")}) READ OPTION: the owner left it to the orchestrator; note: ${a.note || "(none)"}`); continue; }
      text = a.choice === "asis" ? fill(wb.on_as_is, { date, note: a.note || "(none)" }) : fill(wb.on_choice, { date, option: a.choice, option_text: wb.options?.[a.choice] ?? "", note: a.note || "(none)" });
    }
    if (a?.note && r.kind === "approve" && a.choice !== "change") text = text.trimEnd() + `\n\nOwner note: ${a.note}\n`;
    for (const n of r.issue) push(n, p.no, order++, text);
  }
}

if (held.length) { console.error(`refused: these fields reach an issue and need a public wording in public-notes.json first (key "<record id>" for a note, "<record id>.<field>" for result, next_step or recorded): ${[...new Set(held)].join(", ")}`); process.exit(4); }

// Pickup from the lane map (an arc built only from owner asks has no issues)
const arcOf: Record<number, { lane: any; arc: any }> = {};
for (const lane of L.lanes) for (const arc of lane.arcs) for (const i of arc.issues ?? []) arcOf[i] = { lane, arc };
const noArc: Record<number, string> = {};
for (const lane of L.lanes) for (const x of lane.no_arc ?? []) noArc[x.issue] = `${lane.slug}: ${x.reason}`;
for (const x of L.unassigned ?? []) noArc[x.issue] = x.reason;
const holdOf: Record<number, Set<string>> = {};
for (const r of D.records) if (r.hold) for (const n of r.issue) (holdOf[n] ??= new Set()).add(r.hold);
for (const h of D.holds.merge_holds) for (const n of h.issues) (holdOf[n] ??= new Set()).add(h.id);
function pickup(n: number): string {
  const a = arcOf[n]; const holds = [...(holdOf[n] ?? [])].sort();
  if (!a) return `## Pickup\n\nNo arc: ${noArc[n] ?? "not in the lane map"}.${holds.length ? ` Holds: ${holds.join(", ")}.` : ""}\n`;
  const pre = (a.arc.depends_on ?? []).map((d: any) => "- " + (d.gate ? `gate ${d.gate}: ${d.reason}` : d.decision ? `${d.decision}: ${d.reason}` : d.issue ? `#${d.issue} (${d.lane ?? ""}): ${d.reason}` : d.lane ? `after ${d.lane} merges: ${d.reason}` : JSON.stringify(d)));
  const wave = L.proposed_order.waves.find((w: any) => w.lanes.includes(a.lane.slug))?.wave ?? a.lane.wave ?? "follow-ups";
  const lines = [`## Pickup`, ``, `Lane \`${a.lane.slug}\`, ${a.arc.id}${a.arc.name ? ` (${a.arc.name})` : ""}; wave ${wave}.`, ``];
  if (pre.length) lines.push(`Prerequisites:`, ...pre, ``);
  if (holds.length) lines.push(`Merge holds: ${holds.join(", ")} (decision page 0).`, ``);
  const gates = [(a.arc.e2e ?? []).map((g: string) => `\`${g}\``).join(", "), a.arc.visible ? "a visible change ships with its after shot in the PR" : ""].filter(Boolean);
  if (gates.length) lines.push(`Gates before the PR opens: ${gates.join("; ")}.`);
  return lines.join("\n") + "\n";
}
const sectionsFor = (n: number, withPickup = true) => { const segs = out[n].sort((x, y) => x.page - y.page || x.order - y.order); const [first, ...rest] = segs; return `${MARK}\n${first.text.trimEnd()}\n${rest.map(s => "\n" + s.text.replace(/^## Decision\n+/, "").trimEnd() + "\n").join("")}${withPickup ? "\n" + pickup(n) : ""}`; };

const issues = Object.keys(out).map(Number).sort((a, b) => a - b);
for (const n of [...heldIssues].sort((a, b) => a - b)) manual.push(`#${n} NOT WRITTEN: a held page or record contributes to it; its current decisions stay`);
const prevDir = join(O, "apply-preview"); mkdirSync(prevDir, { recursive: true });
const receiptsPath = join(O, "apply-receipts.json");
const receipts: Record<string, any> = existsSync(receiptsPath) ? JSON.parse(readFileSync(receiptsPath, "utf8")) : {};
const sh = async (cmd: string[]) => { const p = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe" }); const [o, e] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]); const code = await p.exited; if (code !== 0) throw new Error(`${cmd.slice(0, 4).join(" ")}: ${e.trim() || o.trim()}`); return o; };
const labelsEnsured = new Set<string>();
let written = 0, skipped = 0;
for (const n of issues) {
  if (heldIssues.has(n)) continue;
  const block = sectionsFor(n); writeFileSync(join(prevDir, `${n}.md`), block);
  const lane = arcOf[n]?.lane.slug;
  if (!APPLY) continue;
  const cur = JSON.parse(await sh(["gh", "issue", "view", String(n), "--repo", REPO, "--json", "body,labels,state"]));
  const norm = (t: string) => t.replace(/\r\n/g, "\n").trimEnd();
  const newBlock = cur.state === "CLOSED" ? sectionsFor(n, false) : block;
  const idx = cur.body.indexOf(MARK);
  if (idx >= 0 && norm(cur.body.slice(idx)) === norm(newBlock) && !FORCE) { skipped++; receipts[n] = { at: new Date().toISOString(), lane, pages: [...new Set(out[n].map(s => s.page))], note: "unchanged" }; continue; }
  const body = (idx >= 0 ? cur.body.slice(0, idx) : cur.body).trimEnd() + "\n\n" + newBlock;
  const tmp = join(prevDir, `_${n}.body.md`); writeFileSync(tmp, body);
  const edit = ["gh", "issue", "edit", String(n), "--repo", REPO, "--body-file", tmp];
  if (lane) { const lbl = `${LANE_PREFIX}${lane}`; if (!labelsEnsured.has(lbl)) { await sh(["gh", "label", "create", lbl, "--repo", REPO, "--color", "0E8A16", "--description", `${PROGRAM} lane ${lane}`, "--force"]); labelsEnsured.add(lbl); } edit.push("--add-label", lbl); }
  if (cur.labels.some((l: any) => l.name === OWNER_LABEL)) edit.push("--remove-label", OWNER_LABEL);
  await sh(edit); receipts[n] = { at: new Date().toISOString(), lane, pages: [...new Set(out[n].map(s => s.page))] }; written++;
  writeFileSync(receiptsPath, JSON.stringify(receipts, null, 1));
  await Bun.sleep(1200);
}
if (APPLY && ownerRows.length) {
  // append-only, last row per record wins; a row equal to the record's live one is not appended again
  const dir = process.env.ORCHY_PROFILE_DIR ?? join(homedir(), ".agents/orchy/profile"), file = join(dir, `${REPO.replace("/", "-")}.jsonl`);
  const live: Record<string, string> = {}, text = existsSync(file) ? readFileSync(file, "utf8") : "";
  for (const l of text.split("\n")) { try { const o = JSON.parse(l); live[o.record] = l; } catch {} }
  const fresh = ownerRows.map(o => JSON.stringify(o)).filter(l => live[JSON.parse(l).record] !== l);
  // a torn last line would otherwise swallow the first appended row
  const lead = text && !text.endsWith("\n") ? "\n" : "";
  if (fresh.length) { mkdirSync(dir, { recursive: true, mode: 0o700 }); appendFileSync(file, lead + fresh.join("\n") + "\n", { mode: 0o600 }); }
}
console.log(`${APPLY ? "applied" : "dry-run"}: pages signed ${pagesToWrite.map((p: any) => p.no).join(",") || "none"}; issues ${issues.length}; written ${written}; skipped ${skipped}; previews in ${prevDir}`);
if (recorded.length) console.log("RECORDED READ OPTIONS (written from their recorded field):\n- " + recorded.join("\n- "));
if (manual.length) console.log("MANUAL:\n- " + manual.join("\n- "));
if (heldPages.length || heldIssues.size) process.exit(3);
