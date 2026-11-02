// harden.findings/1: a run's verified findings as data, beside its report.md. The agent supplies only the coverage
// (scope, exclude) and each entry's id, category, files, symbol, confidence and ref; titles and impacts come from the
// report's headings, and fingerprints, statuses, counts and gone entries are computed here.
// Usage (through run.sh):
//   write <abs run dir> <abs entries file>   writes <run dir>/findings.json; prints the FINDINGS line, then a summary
//   check <abs run dir>                      holds <run dir>/findings.json to the schema and its report.md; prints ok
// A refusal is one line on stderr and exit 1; a usage error exits 2.
import { createHash } from "node:crypto";
import { closeSync, constants, fstatSync, fsyncSync, lstatSync, openSync, readdirSync, readSync, renameSync, unlinkSync, writeSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";

export const SCHEMA = "harden.findings/1";
export type Focus = "security" | "bugs" | "quality";
// the FINDINGS line's buckets, in the order orchy's schedules.sh renders them
export const BUCKETS: Record<Focus, string[]> = {
  security: ["critical", "high", "medium", "low"],
  bugs: ["blocker", "critical", "major", "minor"],
  quality: ["architectural", "structural", "local", "cosmetic"],
};
export const FOCUSES = Object.keys(BUCKETS) as Focus[];
// the bugs prompt's primary types
export const BUG_TYPES = ["wrong result", "crash", "silent corruption", "lost update", "race", "deadlock", "null deref", "resource leak",
  "bad error path", "state invariant violation", "off-by-one", "bounds violation", "bad retry-or-timeout", "other"];
const CONFIDENCE = ["high", "moderate", "low"];
const JSON_MAX = 4 << 20, PRIMARY_MAX = 8 << 20, LIST_MAX = 500, FILES_MAX = 64, SCOPE_MAX = 64, NOTE_MAX = 300, BASE_READS = 20;
const ID = /^[A-Z][A-Z0-9]{0,7}-[0-9]{1,5}$/;
const RUN = /^(\d{4})-(\d{2})-(\d{2})-[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const HEADING = /^\[([^\]]{1,40})\] ([A-Z][A-Z0-9]{0,7}-[0-9]{1,5}): (.+)$/;
const REF = /^(#[1-9][0-9]{0,8}|GHSA(-[23456789cfghjmpqrvwx]{4}){3})$/;
const FP = /^[0-9a-f]{16}$/;
const DRAFT_KEYS = ["id", "category", "files", "symbol", "confidence", "ref"];
const ENTRY_KEYS = ["id", "impact", "title", "category", "files", "symbol", "confidence", "status", "fingerprint", "heading", "ref"];
const TOP_KEYS = ["schema", "focus", "run", "scope", "exclude", "baseline", "baseline_note", "counts", "findings", "tracked", "gone"];

export type Draft = { id: string; category: string; files: string[]; symbol: string; confidence: string; ref?: string };
export type Entry = { id: string; impact: string; title: string; category: string; files: string[]; symbol: string; confidence: string;
  status: string; fingerprint: string; heading: string; ref?: string };
export type Data = { schema: typeof SCHEMA; focus: Focus; run: string; scope: string[]; exclude: string[]; baseline: string | null; baseline_note: string | null;
  counts: Record<string, number>; findings: Entry[]; tracked: Entry[]; gone: Entry[] };
type Heading = { label: string; id: string; title: string; text: string; line: number };
type O = Record<string, unknown>;

export class Refused extends Error {}
const no = (m: string): never => { throw new Refused(m); };
const isObj = (v: unknown): v is O => typeof v === "object" && v !== null && !Array.isArray(v);
const span = (a: number, b: number) => Array.from({ length: b - a }, (_, i) => a + i);
// C0, DEL and C1 controls, the line and paragraph separators, and every Bidi_Control character
const BAD = new Set([...span(0, 0x20), ...span(0x7f, 0xa0), 0x2028, 0x2029, 0x61c, 0x200e, 0x200f, ...span(0x202a, 0x202f), ...span(0x2066, 0x206a)]);
const badChar = (s: string) => [...s].some((c) => BAD.has(c.codePointAt(0) as number));
// a quoted excerpt for a refusal, safe to print whatever the tree planted
const show = (s: string) => JSON.stringify([...s].slice(0, 60).map((c) => (BAD.has(c.codePointAt(0) as number) ? "\uFFFD" : c)).join(""));

function text(v: unknown, what: string, max: number): string {
  if (typeof v !== "string" || !v.isWellFormed() || v !== v.trim()) return no(`${what} is not trimmed text`);
  const n = [...v].length;
  if (n < 1 || n > max) no(`${what} is ${n} characters; 1 to ${max}`);
  return badChar(v) ? no(`${what} carries a control, line separator or bidi character`) : v;
}
function list(v: unknown, what: string, max: number, min = 0): unknown[] {
  if (!Array.isArray(v)) return no(`${what} is not a list`);
  return v.length < min || v.length > max ? no(`${what} holds ${min} to ${max} items, not ${v.length}`) : v;
}
function keys(o: O, what: string, allowed: string[]): void {
  for (const k of Object.keys(o)) if (!allowed.includes(k)) no(`${what} has an unknown field ${show(k)}`);
}
/** A repo-relative path in the one spelling a fingerprint can rely on. */
export function path(v: unknown, what: string): string {
  const p = text(v, what, 512);
  if (Buffer.byteLength(p) > 512) no(`${what} is over 512 bytes`);
  if (/:\d+(-\d+)?$/.test(p)) no(`${what} ${show(p)} ends in a line number; lines belong in report.md`);
  if (p.includes("\\") || p.split("/").some((s) => s === "" || s === "." || s === "..")) no(`${what} ${show(p)} is not a repo-relative path`);
  return p;
}
export const runName = (s: string) => {
  const m = RUN.exec(s);
  if (!m) return false;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  return d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3];
};

/** The category as the focus's prompt names it: a CWE, a bugs primary type, or a smell. */
export function category(focus: Focus, v: unknown, what: string): string {
  const c = text(v, what, 80);
  if (focus === "security") {
    const m = /^CWE-([0-9]{1,5})$/i.exec(c);
    return m ? `CWE-${Number(m[1])}` : no(`${what} ${show(c)} is not CWE-<n>`);
  }
  if (focus === "bugs") {
    const t = c.toLowerCase().replace(/\s+/g, " ");
    return BUG_TYPES.includes(t) ? t : no(`${what} ${show(c)} is not a primary type of the bugs prompt (${BUG_TYPES.join(", ")})`);
  }
  return c;
}
const canon = (focus: Focus, c: string) =>
  focus === "quality" ? c.normalize("NFKC").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "") : c.toLowerCase();

/** Names one finding across runs: lines, title, id, run id and every file but the primary are left out. */
export function fingerprint(focus: Focus, cat: string, primary: string, symbol: string): string {
  return createHash("sha256").update(["harden-fp/1", focus, canon(focus, cat), primary, symbol].join("\0")).digest("hex").slice(0, 16);
}

const impactOf = (focus: Focus, label: string) => {
  const b = label.toLowerCase().replace(/^potential /, "");
  return BUCKETS[focus].includes(b) ? b : null;
};
function parseHeading(focus: Focus, t: string, where: string): Heading {
  text(t, `${where}: a finding's heading`, 300);
  const m = HEADING.exec(t) ?? no(`${where}: a finding's heading is "### [<impact>] <id>: <title>", not ${show(t)}`);
  const [, label, id, title] = m;
  text(title, `${where}: ${id}'s title`, 200);
  if (impactOf(focus, label) === null) no(`${where}: ${id}'s label [${show(label).slice(1, -1)}] is not ${BUCKETS[focus].join(", ")} or Potential <one of them>`);
  return { label, id, title, text: t, line: 0 };
}

/** The finding headings of `## Findings` and `## Already tracked`, outside fenced blocks; any other `### ` there refuses. */
export function headings(focus: Focus, md: string): { findings: Map<string, Heading>; tracked: Map<string, Heading> } {
  const out = { findings: new Map<string, Heading>(), tracked: new Map<string, Heading>() };
  const seen = new Set<string>();
  let section: keyof typeof out | null = null, fence = "";
  md.split("\n").forEach((raw, i) => {
    const line = raw.replace(/\r$/, ""), where = `report.md line ${i + 1}`;
    const f = /^ {0,3}(`{3,}|~{3,})/.exec(line);
    if (fence) { if (f && f[1][0] === fence[0] && f[1].length >= fence.length && line.trim() === f[1]) fence = ""; return; }
    if (f) { fence = f[1]; return; }
    const h = /^(#{1,3}) (.*?)(?:\s+#+)?\s*$/.exec(line);
    if (!h) return;
    if (h[1].length < 3) {
      section = h[1] === "##" && h[2] === "Findings" ? "findings" : h[1] === "##" && h[2] === "Already tracked" ? "tracked" : null;
      if (section) { if (seen.has(section)) no(`${where}: a second "## ${h[2]}" section`); seen.add(section); }
      return;
    }
    if (!section) return;
    const hd = { ...parseHeading(focus, h[2], where), line: i + 1 };
    if (out.findings.has(hd.id) || out.tracked.has(hd.id)) no(`${where}: ${hd.id} is headed twice`);
    out[section].set(hd.id, hd);
  });
  return out;
}

type Ref = "required" | "optional";
function draftEntry(focus: Focus, v: unknown, what: string, ref: Ref): Draft {
  if (!isObj(v)) return no(`${what} is not an object`);
  keys(v, what, ENTRY_KEYS);
  const id = typeof v.id === "string" && ID.test(v.id) ? v.id : no(`${what}'s id is not like F-001`);
  const at = `${id}`;
  const files = list(v.files, `${at}'s files`, FILES_MAX, 1).map((p, j) => path(p, `${at}'s file ${j + 1}`));
  if (new Set(files).size !== files.length) no(`${at} lists a file twice`);
  const confidence = CONFIDENCE.includes(v.confidence as string) ? (v.confidence as string) : no(`${at}'s confidence is high, moderate or low`);
  const d: Draft = { id, category: category(focus, v.category, `${at}'s category`), files, symbol: text(v.symbol, `${at}'s symbol`, 120), confidence };
  if (ref === "required" || (ref === "optional" && "ref" in v)) d.ref = typeof v.ref === "string" && REF.test(v.ref) ? v.ref : no(`${at}'s ref is #<n> or a GHSA id`);
  return d;
}
// sorted, so two runs' coverage compares as lists
function prefixes(v: unknown, what: string, min: number): string[] {
  const out = list(v, what, SCOPE_MAX, min).map((p, j) => path(p, `${what} entry ${j + 1}`)).sort();
  return new Set(out).size === out.length ? out : no(`${what} lists a prefix twice`);
}
function scopeOf(v: unknown): string[] {
  const s = list(v, "scope", SCOPE_MAX, 1);
  if (s.includes(".")) return s.length === 1 ? ["."] : no('scope is ["."] alone or a list of repo-relative prefixes');
  return prefixes(s, "scope", 1);
}
/** The agent's entries file; computed fields it may carry (a complete file passed back) are ignored. */
export function drafts(focus: Focus, v: unknown): { scope: string[]; exclude: string[]; findings: Draft[]; tracked: Draft[] } {
  if (!isObj(v)) return no("the entries file is not a JSON object");
  keys(v, "the entries file", TOP_KEYS);
  const findings = list(v.findings, "findings", LIST_MAX).map((e, i) => draftEntry(focus, e, `finding ${i + 1}`, "optional"));
  const tracked = list(v.tracked ?? [], "tracked", LIST_MAX).map((e, i) => draftEntry(focus, e, `tracked ${i + 1}`, "required"));
  const ids = [...findings, ...tracked].map((d) => d.id), dup = ids.find((x, i) => ids.indexOf(x) !== i);
  if (dup) no(`${dup} appears twice`);
  return { scope: scopeOf(v.scope), exclude: prefixes(v.exclude ?? [], "exclude", 0), findings, tracked };
}

const ordered = (e: Entry): Entry => {
  const o = Object.fromEntries(ENTRY_KEYS.filter((k) => k !== "ref").map((k) => [k, e[k as keyof Entry]])) as Entry;
  if (e.ref !== undefined) o.ref = e.ref;
  return o;
};

/** A complete file held to the schema on its own: shape, grammar, fingerprints, statuses and counts. No tree is read. */
export function validate(v: unknown, focus?: Focus, run?: string): Data {
  if (!isObj(v) || v.schema !== SCHEMA) return no(`not ${SCHEMA}`);
  keys(v, "the file", TOP_KEYS);
  for (const k of TOP_KEYS) if (!(k in v)) no(`the file lacks ${k}`);
  const f = FOCUSES.includes(v.focus as Focus) ? (v.focus as Focus) : no("focus is security, bugs or quality");
  if (focus && f !== focus) no(`a ${f} file, not ${focus}`);
  if (typeof v.run !== "string" || !runName(v.run)) no("run is not <YYYY-MM-DD>-<id>");
  if (run !== undefined && v.run !== run) no(`a file of run ${show(v.run)}, not ${run}`);
  if (v.baseline !== null && (typeof v.baseline !== "string" || !runName(v.baseline))) no("baseline is not a run name or null");
  if ((v.baseline === null) === (v.baseline_note === null)) no("exactly one of baseline and baseline_note is null");
  if (v.baseline_note !== null) text(v.baseline_note, "baseline_note", NOTE_MAX);
  const entry = (e: unknown, what: string, statuses: string[], ref: Ref): Entry => {
    if (!isObj(e)) return no(`${what} is not an object`);
    const d = draftEntry(f, Object.fromEntries(Object.entries(e).filter(([k]) => DRAFT_KEYS.includes(k))), what, ref);
    keys(e, d.id, ENTRY_KEYS);
    for (const k of ENTRY_KEYS) if (k !== "ref" && !(k in e)) no(`${d.id} lacks ${k}`);
    const h = parseHeading(f, typeof e.heading === "string" ? e.heading : no(`${d.id}'s heading is not text`), `${d.id}'s heading`);
    if (h.id !== d.id || h.title !== e.title || impactOf(f, h.label) !== e.impact) no(`${d.id}'s heading, title and impact disagree`);
    if (!statuses.includes(e.status as string)) no(`${d.id}'s status is ${statuses.join(" or ")}`);
    if (typeof e.fingerprint !== "string" || !FP.test(e.fingerprint) || e.fingerprint !== fingerprint(f, d.category, d.files[0], d.symbol))
      no(`${d.id}'s fingerprint is not the one its category, first file and symbol give`);
    if (e.category !== d.category) no(`${d.id}'s category is not in its stored spelling`);
    return ordered({ ...d, impact: e.impact as string, title: e.title as string, status: e.status as string, fingerprint: e.fingerprint as string,
      heading: e.heading as string });
  };
  const findings = list(v.findings, "findings", LIST_MAX).map((e, i) => entry(e, `finding ${i + 1}`, ["new", "recurring"], "optional"));
  const tracked = list(v.tracked, "tracked", LIST_MAX).map((e, i) => entry(e, `tracked ${i + 1}`, ["new", "recurring"], "required"));
  const gone = list(v.gone, "gone", 2 * LIST_MAX).map((e, i) => entry(e, `gone ${i + 1}`, ["gone"], "optional"));
  const ids = [...findings, ...tracked].map((d) => d.id), dup = ids.find((x, i) => ids.indexOf(x) !== i);
  if (dup) no(`${dup} appears twice`);
  if (JSON.stringify(v.counts) !== JSON.stringify(counts(f, findings))) no("counts are not the findings' impacts, every bucket in order");
  return { schema: SCHEMA, focus: f, run: v.run as string, scope: scopeOf(v.scope), exclude: prefixes(v.exclude, "exclude", 0), baseline: v.baseline as string | null,
    baseline_note: v.baseline_note as string | null, counts: v.counts as Record<string, number>, findings, tracked, gone };
}

export function counts(focus: Focus, findings: { impact: string }[]): Record<string, number> {
  const c = Object.fromEntries(BUCKETS[focus].map((b) => [b, 0]));
  for (const e of findings) c[e.impact]++;
  return c;
}
/** The line a scheduled run's report block carries; orchy's findings() reads it back as these counts. */
export function findingsLine(d: Pick<Data, "focus" | "counts" | "findings" | "tracked">): string {
  if (d.findings.length + d.tracked.length === 0) return "FINDINGS: none";
  return `FINDINGS: ${BUCKETS[d.focus].map((b) => `${b}=${d.counts[b]}`).join(" ")}`;
}

/** Statuses by fingerprint, as a multiset: within one fingerprint equal titles pair first, then ids in order. */
export function diff(current: Entry[], base: Entry[]): { status: Map<Entry, string>; gone: Entry[] } {
  const status = new Map<Entry, string>(), paired = new Set<Entry>();
  const byId = (a: Entry, b: Entry) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  for (const fp of new Set(current.map((e) => e.fingerprint))) {
    const cur = current.filter((e) => e.fingerprint === fp).sort(byId), old = base.filter((e) => e.fingerprint === fp).sort(byId);
    const take = (e: Entry, b: Entry | undefined) => { if (b) { paired.add(b); status.set(e, "recurring"); } };
    for (const e of cur) take(e, old.find((b) => !paired.has(b) && b.title === e.title));
    for (const e of cur) if (!status.has(e)) take(e, old.find((b) => !paired.has(b)));
    for (const e of cur) if (!status.has(e)) status.set(e, "new");
  }
  const gone = base.filter((b) => !paired.has(b)).map((b) => ({ ...b, status: "gone" }));
  return { status, gone };
}

// Reads open no-follow and non-blocking, so a planted symlink or FIFO as the last component refuses instead of leading
// out or hanging; a symlinked directory above it is the caller's to refuse.
function read(file: string, cap: number, what: string): Buffer {
  let fd: number;
  try { fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
  catch (e) {
    const c = (e as { code?: string }).code;
    return no(c === "ENOENT" ? `${what} does not exist` : c === "ELOOP" ? `${what} is a symlink` : `${what} cannot be read (${c})`);
  }
  try {
    if (!fstatSync(fd).isFile()) no(`${what} is not a regular file`);
    const b = Buffer.alloc(cap + 1);
    let n = 0;
    for (let k = 1; k > 0 && n <= cap; n += k) k = readSync(fd, b, n, cap + 1 - n, null);
    return n > cap ? no(`${what} is over ${cap} bytes`) : b.subarray(0, n);
  } finally { closeSync(fd); }
}
const STRICT = new TextDecoder("utf-8", { fatal: true });
function readText(file: string, cap: number, what: string): string {
  try { return STRICT.decode(read(file, cap, what)); } catch (e) { if (e instanceof Refused) throw e; return no(`${what} is not UTF-8`); }
}
function readJson(file: string, what: string): unknown {
  const t = readText(file, JSON_MAX, what);
  try { return JSON.parse(t); } catch { return no(`${what} is not JSON`); }
}
// lstat: a symlink to a directory is not one
const isRealDir = (p: string) => lstatSync(p, { throwIfNoEntry: false })?.isDirectory() === true;

/** <root>/audit/<focus>/<run>, every directory from audit/ down a real one. */
export function runPaths(dir: string): { runDir: string; run: string; focus: Focus; focusDir: string; root: string } {
  if (!isAbsolute(dir)) no("the run directory must be an absolute path");
  const runDir = resolve(dir), run = basename(runDir), focusDir = dirname(runDir), auditDir = dirname(focusDir);
  const focus = basename(focusDir) as Focus;
  if (basename(auditDir) !== "audit" || !FOCUSES.includes(focus)) no(`${show(dir)} is not <repo>/audit/<security|bugs|quality>/<run>`);
  if (!runName(run)) no(`the run directory ${show(run)} is not named <YYYY-MM-DD>-<id> with a real date`);
  for (const d of [auditDir, focusDir, runDir]) if (!isRealDir(d)) no(`${show(d.slice(dirname(auditDir).length + 1))} is not a directory (a symlink is refused)`);
  return { runDir, run, focus, focusDir, root: dirname(auditDir) };
}

const same = (a: string[], b: string[]) => a.length === b.length && a.every((x, i) => x === b[i]);
/** The newest earlier run of the focus with this coverage, so nothing this run did not look at reads gone. A malformed
 *  findings.json met first stops the search: no baseline, and the note says why. */
export function baseline(focusDir: string, focus: Focus, run: string, scope: string[], exclude: string[]): { data: Data | null; name: string | null; note: string | null } {
  const names = readdirSync(focusDir).filter((n) => runName(n) && n < run).sort().reverse()
    .filter((n) => isRealDir(join(focusDir, n)) && lstatSync(join(focusDir, n, "findings.json"), { throwIfNoEntry: false }));
  for (const name of names.slice(0, BASE_READS)) {
    let d: Data;
    try { d = validate(readJson(join(focusDir, name, "findings.json"), "the file"), focus, name); }
    catch (e) {
      if (!(e instanceof Refused)) throw e;
      return { data: null, name: null, note: `${name}/findings.json refused: ${[...e.message].slice(0, 160).join("")}` };
    }
    if (same(d.scope, scope) && same(d.exclude, exclude)) return { data: d, name, note: null };
  }
  const note = names.length > BASE_READS
    ? `none of the newest ${BASE_READS} earlier ${focus} runs with findings.json has this scope and exclusions; older ones are not read`
    : `no earlier ${focus} run with this scope and exclusions carries findings.json${names.length ? ` (${names.length} of other coverage)` : ""}`;
  return { data: null, name: null, note };
}

type Section = "findings" | "tracked";
const SECTION: Record<Section, string> = { findings: "## Findings", tracked: "## Already tracked" };
/** The data and the report name the same findings, one heading each, in the same section. */
function agree(hs: ReturnType<typeof headings>, findings: Entry[], tracked: Entry[]): void {
  for (const [from, list] of [["findings", findings], ["tracked", tracked]] as const) {
    for (const e of list) if (hs[from].get(e.id)?.text !== e.heading) no(`${e.id} has no heading ${show(e.heading)} under ${SECTION[from]} in report.md`);
    const ids = new Set(list.map((e) => e.id));
    for (const h of hs[from].values()) if (!ids.has(h.id)) no(`report.md line ${h.line} heads ${h.id} under ${SECTION[from]}, which the data lacks there`);
  }
}

function present(root: string, p: string, what: string): void {
  if (!lstatSync(join(root, p), { throwIfNoEntry: false })) no(`${what} ${show(p)} does not exist in the tree`);
}
/** The run's complete file from the agent's entries, today's tree, its report.md and the baseline. */
export function build(runDir: string, entriesFile: string): Data {
  const { run, focus, focusDir, root } = runPaths(runDir);
  if (!isAbsolute(entriesFile)) no("the entries file must be an absolute path");
  const d = drafts(focus, readJson(entriesFile, "the entries file"));
  for (const s of d.scope) if (s !== ".") present(root, s, "scope entry");
  for (const e of [...d.findings, ...d.tracked]) {
    e.files.slice(1).forEach((p) => present(root, p, `${e.id}'s file`));
    const up = e.files[0].split("/").slice(0, -1);
    up.forEach((_, i) => { if (!isRealDir(join(root, ...up.slice(0, i + 1)))) no(`${e.id}'s first file ${show(e.files[0])} lies under a symlink or a file`); });
    if (!read(join(root, e.files[0]), PRIMARY_MAX, `${e.id}'s first file ${show(e.files[0])}`).includes(Buffer.from(e.symbol)))
      no(`${e.id}'s symbol ${show(e.symbol)} does not occur in its first file ${show(e.files[0])}`);
  }
  const hs = headings(focus, readText(join(resolve(runDir), "report.md"), JSON_MAX, "report.md"));
  const full = (list: Draft[], from: Section): Entry[] => list.map((e) => {
    const h = hs[from].get(e.id) ?? no(`${e.id} has no "### [<impact>] ${e.id}: <title>" heading under ${SECTION[from]}`);
    return ordered({ ...e, impact: impactOf(focus, h.label) as string, title: h.title, status: "new",
      fingerprint: fingerprint(focus, e.category, e.files[0], e.symbol), heading: h.text });
  });
  const findings = full(d.findings, "findings"), tracked = full(d.tracked, "tracked");
  agree(hs, findings, tracked);
  const b = baseline(focusDir, focus, run, d.scope, d.exclude);
  const { status, gone } = diff([...findings, ...tracked], b.data ? [...b.data.findings, ...b.data.tracked] : []);
  for (const e of [...findings, ...tracked]) e.status = status.get(e) as string;
  return { schema: SCHEMA, focus, run, scope: d.scope, exclude: d.exclude, baseline: b.name, baseline_note: b.note, counts: counts(focus, findings),
    findings, tracked, gone };
}

/** Replaces findings.json by a fresh file renamed over it, so a planted link at that name is replaced, never followed. */
export function write(runDir: string, entriesFile: string): { data: Data; line: string; summary: string } {
  const data = build(runDir, entriesFile), dir = resolve(runDir), tmp = join(dir, `.findings.json.${process.pid}.tmp`);
  // the limit every reader holds it to, check and the next run's baseline included
  const out = `${JSON.stringify(data, null, 2)}\n`;
  if (Buffer.byteLength(out) > JSON_MAX) no(`findings.json would be over ${JSON_MAX} bytes`);
  const fd = openSync(tmp, "wx", 0o644);
  try {
    try { writeSync(fd, out); fsyncSync(fd); } finally { closeSync(fd); }
    renameSync(tmp, join(dir, "findings.json"));
  } catch (e) { try { unlinkSync(tmp); } catch {} throw e; }
  const all = [...data.findings, ...data.tracked], n = (s: string) => all.filter((e) => e.status === s).length;
  const since = data.baseline ? `${data.gone.length} gone since ${data.baseline}` : `no baseline: ${data.baseline_note}`;
  return { data, line: findingsLine(data), summary: `${data.findings.length} findings, ${data.tracked.length} tracked: ${n("new")} new, ${n("recurring")} recurring; ${since}` };
}

/** A run's findings.json against the schema, its own directory and its own report.md; history is never re-read. */
export function check(runDir: string): Data {
  const { runDir: dir, focus, run } = runPaths(runDir);
  const data = validate(readJson(join(dir, "findings.json"), "findings.json"), focus, run);
  agree(headings(focus, readText(join(dir, "report.md"), JSON_MAX, "report.md")), data.findings, data.tracked);
  return data;
}

if (import.meta.main) {
  const [op, ...a] = process.argv.slice(2);
  try {
    if (op === "write" && a.length === 2) { const r = write(a[0], a[1]); process.stdout.write(`${r.line}\n${r.summary}\n`); }
    else if (op === "check" && a.length === 1) { check(a[0]); process.stdout.write("ok\n"); }
    else { process.stderr.write("usage: findings.ts write <abs run dir> <abs entries file> | check <abs run dir>\n"); process.exitCode = 2; }
  } catch (e) {
    process.stderr.write(`${e instanceof Refused ? e.message : `findings: ${(e as Error).message}`}\n`);
    process.exitCode = 1;
  }
}
