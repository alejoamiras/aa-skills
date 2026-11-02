// orchy.json `schedules`, recurring harden runs, and their run records, orchy.schedule-run/1, under runs/<id>/. orchy.sh
// holds schedules.lock around every config write and runs.lock around every record write; readers take no lock, since
// both are only ever replaced whole by rename.
// Usage: ts_run schedules <op> ...   (a refusal is one line on stderr, exit 1)
//   add <list> <id> <focus> <effort> <day> <HH:MM> <zone> <skip-filed 0|1> <now>   {schedules, changed, message}
//   set <list> <id> <pause|resume|remove> <now>                                    {schedules, changed, message}
//   view <runs> <list> <facts> <now> <json 0|1>        orchy.schedules/1, or one text line per schedule
//   slots <runs> <list> <now>                          "<id> <epoch s> <iso>": each unpaused schedule's due slot and next
//   begin <runs> <id> <slot> <now> <key> <lane>              a started record, written before anything runs
//   launched <runs> <id> <file> <account> <reading>          its account and start reading, once the lead runs
//   skip <runs> <id> <slot> <lane> <now> <reason> [<file>]   a skipped record, or that started one when it never launched
//   settle <runs> <id> <file> <marker line|""> <findings line> <receipt> <account> <reading> <now>
//                                                            the run as its files tell it now, again after each resume
import { closeSync, constants, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { args } from "./args.ts";
import { isObj, no, type O, Refused, readCapped } from "./requests.ts";
import { STRERROR } from "./strerror.ts";
import { badChar, utf8 } from "./text.ts";

export const FOCUSES = ["security", "quality", "bugs"], EFFORTS = ["low", "medium", "high", "max", "ultra"];
const DAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const STATUSES = ["started", "done", "blocked", "failed", "skipped"];
const KEYS = ["id", "focus", "effort", "when", "skip_filed", "paused", "since"];
export const ID = /^[a-z0-9][a-z0-9-]{0,31}$/;
const ZONE = /^[A-Za-z_]+(?:\/[A-Za-z0-9_+-]+)*$/;   // limit.py's: an IANA name, never an offset like +03:00
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const FILE = /^\d{8}T\d{6}Z\.json$/, LANE = /^harden-(security|quality|bugs)-\d{8}$/;
const NAME = /^[A-Za-z0-9_][A-Za-z0-9._-]{0,99}$/, BUCKET = /^[a-z][a-z-]{0,23}$/;
export const MAX = 16, KEEP = 6, TEXT_MAX = 300, RECORD_MAX = 16 * 1024;
const DAY_MS = 86_400_000;

export type Schedule = { id: string; focus: string; effort: string; when: string; skip_filed: boolean; paused: boolean; since: string };
export type When = { day: number; hh: number; mm: number; zone: string };
export type Reading = { week_left_pct: number | null; week_resets_at: number | null; session_left_pct: number | null;
  session_resets_at: number | null; session_window: string | null; observed_at: number | null };
export type Window = { start: Reading | null; end: Reading | null; week_used_pct: number | null; session_used_pct: number | null };
export type Run = { schema: "orchy.schedule-run/1"; schedule: string; slot: string; start: string; end: string | null; status: string;
  reason: string | null; lane: string; key: string | null; account: string | null; cost_usd: number | null; marker: string | null;
  detail: string | null; counts: Record<string, number> | null; window: Window | null };
export type Facts = { mode: string | null; hold: string | null; open: string[]; alive: string[] };

export const iso = (t: number) => new Date(t).toISOString().replace(/\.\d{3}Z$/, "Z");
/** A run's lane and worktree: the focus and its slot's UTC date, so no worktree an earlier run left stops a later one. */
export const laneOf = (focus: string, slotAt: number) => `harden-${focus}-${iso(slotAt).slice(0, 10).replace(/-/g, "")}`;
const time = (s: unknown, what: string): number => {
  const t = typeof s === "string" && ISO.test(s) ? Date.parse(s) : NaN;
  return Number.isFinite(t) ? t : no(`${what} is not a time like 2026-11-09T09:00:00Z`);
};

const zones = new Map<string, Intl.DateTimeFormat>();
function fmt(zone: string): Intl.DateTimeFormat {
  let f = zones.get(zone);
  if (!f) zones.set(zone, (f = new Intl.DateTimeFormat("en-US", { timeZone: zone, hourCycle: "h23", year: "numeric", month: "numeric",
    day: "numeric", hour: "numeric", minute: "numeric", second: "numeric" })));
  return f;
}
/** The zone's wall clock at instant t, read as if it were UTC. */
function wall(t: number, zone: string): number {
  const p: Record<string, number> = {};
  for (const x of fmt(zone).formatToParts(t)) if (x.type !== "literal") p[x.type] = Number(x.value);
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
}

/** The instant of a wall time in a zone, as Temporal's `compatible`, Python's fold=0 and RFC 5545 read it: a time the
 *  zone skips runs that much later, a time it repeats runs at its first occurrence. */
export function at(y: number, mo: number, d: number, hh: number, mm: number, zone: string): number {
  const t0 = Date.UTC(y, mo - 1, d, hh, mm);
  // the offsets a day either side straddle any one transition near the date
  const before = wall(t0 - DAY_MS, zone) - (t0 - DAY_MS), after = wall(t0 + DAY_MS, zone) - (t0 + DAY_MS);
  const fit = [t0 - before, t0 - after].filter((c) => wall(c, zone) === t0);
  return fit.length ? Math.min(...fit) : t0 - before;
}

// the slot on the local date k days from t's local date, in the schedule's zone. A time the zone skips can push a slot
// past its date's midnight, so both walks reach one date beyond the week
function onDay(w: When, t: number, k: number): number | null {
  const l = new Date(wall(t, w.zone)), d = new Date(Date.UTC(l.getUTCFullYear(), l.getUTCMonth(), l.getUTCDate() + k));
  return d.getUTCDay() === w.day ? at(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate(), w.hh, w.mm, w.zone) : null;
}
/** The latest slot at or before t. */
export function slot(w: When, t: number): number {
  for (let k = 0; k <= 8; k++) { const s = onDay(w, t, -k); if (s !== null && s <= t) return s; }
  throw new Error("no slot in the week before");
}
/** The first slot after t. */
export function after(w: When, t: number): number {
  for (let k = -1; k <= 7; k++) { const s = onDay(w, t, k); if (s !== null && s > t) return s; }
  throw new Error("no slot in the week after");
}

/** A weekday, a time and an IANA zone, `mon 09:00 Europe/London`; the day and the hour may come in any case and width. */
export function parseWhen(s: string): When & { text: string } {
  const m = /^([A-Za-z]{3}) ([0-9]{1,2}):([0-9]{2}) (\S+)$/.exec(s);
  const day = m ? DAYS.indexOf(m[1].toLowerCase()) : -1, hh = m ? Number(m[2]) : NaN, mm = m ? Number(m[3]) : NaN;
  if (!m || day < 0 || !(hh <= 23 && mm <= 59)) no(`when is "<mon..sun> <HH:MM> <zone>", not "${s.slice(0, 60)}"`);
  let zone = "";
  try { zone = ZONE.test(m![4]) ? fmt(m![4]).resolvedOptions().timeZone : ""; } catch { zone = ""; }
  if (!zone) no(`${m![4].slice(0, 60)} is not an IANA time zone (Europe/London, America/New_York, UTC)`);
  return { day, hh, mm, zone, text: `${DAYS[day]} ${String(hh).padStart(2, "0")}:${m![3]} ${zone}` };
}

function entry(v: unknown, i: number): Schedule {
  if (!isObj(v)) no(`schedule ${i + 1} is not an object`);
  const o = v as O, extra = Object.keys(o).filter((k) => !KEYS.includes(k)), missing = KEYS.filter((k) => !(k in o));
  if (extra.length || missing.length) no(`schedule ${i + 1} ${extra.length ? `has unknown key ${extra[0]}` : `lacks ${missing[0]}`}`);
  if (typeof o.id !== "string" || !ID.test(o.id)) no(`schedule ${i + 1}: an id is 1 to 32 of a-z, 0-9 and -, not dash-led`);
  const id = o.id as string;
  if (!FOCUSES.includes(o.focus as string)) no(`${id}: focus is ${FOCUSES.join(", ")}`);
  if (!EFFORTS.includes(o.effort as string)) no(`${id}: effort is ${EFFORTS.join(", ")}`);
  if (typeof o.when !== "string") no(`${id}: when is a string`);
  if (typeof o.skip_filed !== "boolean" || typeof o.paused !== "boolean") no(`${id}: skip_filed and paused are true or false`);
  time(o.since, `${id}: since`);
  return { id, focus: o.focus as string, effort: o.effort as string, when: parseWhen(o.when as string).text,
    skip_filed: o.skip_filed as boolean, paused: o.paused as boolean, since: o.since as string };
}
/** orchy.json's schedules, each held to the entry grammar, at most MAX, ids unique. */
export function schedules(v: unknown): Schedule[] {
  if (!Array.isArray(v)) no("orchy.json schedules is not a list");
  const l = (v as unknown[]).map(entry);
  if (l.length > MAX) no(`at most ${MAX} schedules`);
  const dup = l.find((s, i) => l.findIndex((x) => x.id === s.id) !== i);
  if (dup) no(`two schedules are named ${dup.id}`);
  return l;
}

export function add(l: Schedule[], a: string[], now: number): { schedules: Schedule[]; changed: boolean; message: string } {
  const [id, focus, effort, day, hhmm, zone, skip] = a;
  if (l.some((s) => s.id === id)) no(`a schedule ${id} exists; remove it first`);
  const s = entry({ id, focus, effort, when: `${day} ${hhmm} ${zone}`, skip_filed: skip === "1", paused: false, since: iso(now) }, l.length);
  const next = schedules([...l, s]);
  return { schedules: next, changed: true, message: `schedule ${id} added: harden ${focus} ${effort}, ${s.when}; next ${iso(after(parseWhen(s.when), now))}` };
}

export function set(l: Schedule[], id: string, op: string, now: number): { schedules: Schedule[]; changed: boolean; message: string } {
  const s = l.find((x) => x.id === id) ?? no(`no schedule ${id}`);
  if (op === "remove") return { schedules: l.filter((x) => x !== s), changed: true, message: `schedule ${id} removed; its run records stay` };
  if (op === "pause") return s.paused ? { schedules: l, changed: false, message: `schedule ${id} is already paused` }
    : { schedules: l.map((x) => (x === s ? { ...x, paused: true } : x)), changed: true, message: `schedule ${id} paused` };
  if (op !== "resume") no("set takes pause, resume or remove");
  if (!s.paused) return { schedules: l, changed: false, message: `schedule ${id} is not paused` };
  // a resume starts the clock again: a slot that passed while paused never runs
  return { schedules: l.map((x) => (x === s ? { ...x, paused: false, since: iso(now) } : x)), changed: true,
    message: `schedule ${id} resumed; next ${iso(after(parseWhen(s.when), now))}` };
}

/** The slot due now: the latest one, unless paused, older than the schedule, or spent by a record. One attempt per slot. */
export function due(s: Schedule, runs: Run[], now: number): number | null {
  if (s.paused) return null;
  const t = slot(parseWhen(s.when), now);
  return t < Date.parse(s.since) || runs.some((r) => Date.parse(r.slot) >= t) ? null : t;
}
export const next = (s: Schedule, now: number) => (s.paused ? null : after(parseWhen(s.when), Math.max(now, Date.parse(s.since))));

const text = (v: unknown, what: string): string | null => {
  if (v === null) return null;
  return typeof v === "string" && [...v].length <= TEXT_MAX && !badChar(v) ? v : no(`${what} is not one line of at most ${TEXT_MAX} characters`);
};
/** A lead's text cut to one storable line: a control, separator or bidi character drops it whole. */
const clip = (s: string) => { const t = [...s.trim()].slice(0, TEXT_MAX).join(""); return t && !badChar(t) ? t : null; };
const num = (v: unknown) => (v === null || (typeof v === "number" && Number.isFinite(v)) ? (v as number | null) : no("a number is expected"));
function reading(v: unknown): Reading | null {
  if (v === null) return null;
  if (!isObj(v)) no("a reading is an object");
  const o = v as O, w = o.session_window;
  if (w !== null && w !== undefined && (typeof w !== "string" || !/^[a-z0-9_-]{1,16}$/.test(w))) no("session_window is a short word");
  return { week_left_pct: num(o.week_left_pct ?? null), week_resets_at: num(o.week_resets_at ?? null), session_left_pct: num(o.session_left_pct ?? null),
    session_resets_at: num(o.session_resets_at ?? null), session_window: (w as string | undefined) ?? null, observed_at: num(o.observed_at ?? null) };
}
function counts(v: unknown): Record<string, number> | null {
  if (v === null) return null;
  const ok = isObj(v) && Object.keys(v).length <= 16 && Object.entries(v).every(([k, n]) => BUCKET.test(k) && Number.isSafeInteger(n) && (n as number) >= 0);
  return ok ? (v as Record<string, number>) : no("counts are at most 16 bucket=count pairs");
}
function window(v: unknown): Window | null {
  if (v === null) return null;
  if (!isObj(v)) no("window is an object");
  const o = v as O;
  return { start: reading(o.start ?? null), end: reading(o.end ?? null), week_used_pct: num(o.week_used_pct ?? null), session_used_pct: num(o.session_used_pct ?? null) };
}
/** A stored record, held to orchy.schedule-run/1 for the schedule its folder names. */
export function record(v: unknown, id: string): Run {
  if (!isObj(v) || v.schema !== "orchy.schedule-run/1") no("not an orchy.schedule-run/1 record");
  const o = v as O;
  if (o.schedule !== id) no(`a record of ${String(o.schedule).slice(0, 40)}, not ${id}`);
  time(o.slot, "slot"); time(o.start, "start"); if (o.end !== null) time(o.end, "end");
  if (!STATUSES.includes(o.status as string)) no(`status is ${STATUSES.join(", ")}`);
  if (typeof o.lane !== "string" || !LANE.test(o.lane)) no("lane is harden-<focus>-<YYYYMMDD>");
  for (const k of ["key", "account"]) if (o[k] !== null && (typeof o[k] !== "string" || !NAME.test(o[k] as string))) no(`${k} is a name`);
  const marker = o.marker;
  if (marker !== null && !["LEAD_DONE", "LEAD_BLOCKED", "ARC_FAILED"].includes(marker as string)) no("marker is LEAD_DONE, LEAD_BLOCKED or ARC_FAILED");
  const cost = num(o.cost_usd);
  if (cost !== null && cost < 0) no("cost_usd is not negative");
  return { schema: "orchy.schedule-run/1", schedule: id, slot: o.slot as string, start: o.start as string, end: o.end as string | null, status: o.status as string,
    reason: text(o.reason, "reason"), lane: o.lane as string, key: o.key as string | null, account: o.account as string | null, cost_usd: cost,
    marker: marker as string | null, detail: text(o.detail, "detail"), counts: counts(o.counts), window: window(o.window) };
}

const join = (dir: string, name: string) => `${dir}/${name}`;
function dirState(p: string): "missing" | "dir" {
  try { const st = lstatSync(p); if (st.isDirectory() && !st.isSymbolicLink() && st.uid === process.getuid?.()) return "dir"; }
  catch (e) { if ((e as { code?: string }).code === "ENOENT") return "missing"; throw e; }
  return no(`${p} must be a directory owned by this user, not a symlink`);
}
function readRecord(dir: string, name: string, id: string): Run | { error: string } | null {
  let fd: number;
  try { fd = openSync(join(dir, name), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
  catch (e) { const c = (e as { code?: string }).code; return c === "ENOENT" ? null : { error: c === "ELOOP" ? "a symlink" : `cannot be read (${STRERROR[c ?? ""] ?? c})` }; }
  try {
    const st = fstatSync(fd);
    if (!st.isFile() || st.uid !== process.getuid?.()) return { error: "not a regular file owned by this user" };
    const b = readCapped(fd, RECORD_MAX), t = b.length > RECORD_MAX ? null : utf8(b);
    if (t === null) return { error: `not UTF-8 within ${RECORD_MAX} bytes` };
    try { return record(JSON.parse(t), id); } catch (e) { return { error: e instanceof Refused ? e.message.slice(9) : "not JSON" }; }
  } finally { closeSync(fd); }
}
/** A schedule's records, newest first, and the files that are not records. */
export function runs(root: string, id: string): { runs: Run[]; errors: { file: string; error: string }[] } {
  const dir = join(root, id), out: Run[] = [], errors: { file: string; error: string }[] = [];
  if (dirState(root) === "missing" || dirState(dir) === "missing") return { runs: out, errors };
  for (const n of readdirSync(dir).filter((x) => FILE.test(x)).sort().reverse()) {
    const r = readRecord(dir, n, id);
    if (r && "error" in r) errors.push({ file: `runs/${id}/${n}`, error: r.error });
    else if (r) out.push(r);
  }
  return { runs: out, errors };
}

const fileOf = (start: string) => `${start.replace(/[-:]/g, "")}.json`;
function write(root: string, r: Run, replace: boolean): string {
  for (const d of [root, join(root, r.schedule)]) if (dirState(d) === "missing") mkdirSync(d, { mode: 0o700 });
  const dir = join(root, r.schedule), name = fileOf(r.start), tmp = join(dir, `.${name}.${process.pid}.tmp`);
  if (!replace) try { lstatSync(join(dir, name)); no(`runs/${r.schedule}/${name} exists`); } catch (e) { if (e instanceof Refused) throw e; }
  const fd = openSync(tmp, "wx", 0o600);
  try {
    try { writeFileSync(fd, `${JSON.stringify(record(r, r.schedule))}\n`); fsyncSync(fd); } finally { closeSync(fd); }
    renameSync(tmp, join(dir, name));
  } catch (e) { try { unlinkSync(tmp); } catch {} throw e; }
  return name;
}
function prune(root: string, id: string): void {
  const dir = join(root, id);
  for (const n of readdirSync(dir).filter((x) => FILE.test(x)).sort().slice(0, -KEEP)) try { unlinkSync(join(dir, n)); } catch {}
}

const blank = (id: string, slotAt: string, lane: string, start: string): Run => ({ schema: "orchy.schedule-run/1", schedule: id, slot: slotAt, start,
  end: null, status: "started", reason: null, lane, key: null, account: null, cost_usd: null, marker: null, detail: null, counts: null, window: null });
function load(root: string, id: string, name: string): Run {
  const r = readRecord(join(root, id), name, id);
  return !r || "error" in r ? no(`runs/${id}/${name}: ${r ? r.error : "gone"}`) : r;
}
/** Spends the slot before wt-new or launch runs, so a start killed midway can neither vanish nor start twice. */
export function begin(root: string, id: string, slotAt: string, now: number, key: string, lane: string): string {
  const name = write(root, { ...blank(id, slotAt, lane, iso(now)), key }, false);
  prune(root, id);
  return name;
}
export function launched(root: string, id: string, name: string, account: string, start: Reading | null): Run {
  const r = load(root, id, name);
  if (r.status !== "started" || r.account !== null) no(`runs/${id}/${name} is not a start waiting for its account`);
  const out = { ...r, account, window: { start, end: null, week_used_pct: null, session_used_pct: null } };
  write(root, out, true);
  return out;
}
export function skip(root: string, id: string, slotAt: string, lane: string, now: number, reason: string, name?: string): string {
  const why = clip(reason) ?? "no reason given";
  if (name === undefined) {
    const n = write(root, { ...blank(id, slotAt, lane, iso(now)), end: iso(now), status: "skipped", reason: why }, false);
    prune(root, id);
    return n;
  }
  const r = load(root, id, name);
  if (r.status !== "started" || r.account !== null || r.slot !== slotAt || r.lane !== lane) no(`runs/${id}/${name} is not this start's record`);
  return write(root, { ...r, end: iso(now), status: "skipped", reason: why, key: null }, true);
}

/** `FINDINGS: none` or `FINDINGS: <bucket>=<n> ...` from a report; anything else is no counts. */
export function findings(line: string): Record<string, number> | null {
  if (line === "FINDINGS: none") return {};
  const m = /^FINDINGS: ([a-z][a-z-]{0,23}=[0-9]{1,6}(?: [a-z][a-z-]{0,23}=[0-9]{1,6}){0,15})$/.exec(line);
  return m ? Object.fromEntries(m[1].split(" ").map((p) => { const [k, n] = p.split("="); return [k, Number(n)]; })) : null;
}
/** What the account's headroom fell by across the run, when both readings sit in one window and the later is newer. */
export function used(a: Reading | null, b: Reading | null, left: "week_left_pct" | "session_left_pct"): number | null {
  const resets = left === "week_left_pct" ? "week_resets_at" : "session_resets_at";
  if (!a || !b || (left === "session_left_pct" && (a.session_window === "none" || b.session_window === "none"))) return null;
  const x = a[left], y = b[left], ra = a[resets], rb = b[resets];
  if (x === null || y === null || a.observed_at === null || b.observed_at === null || b.observed_at <= a.observed_at) return null;
  // a reset time read twice may drift by the rounding of "resets in 3h 12m"; a different window moves it by hours
  if (ra === null || rb === null || Math.abs(ra - rb) > 300 || x < y) return null;
  return x - y;
}
/** A run as its files tell it now: ended by the final marker its latest invocation appended, or, with none (""), started again. */
export function settle(root: string, id: string, name: string, marker: string, line: string, receipt: unknown, account: string,
  end: Reading | null, now: number): Run {
  const run = load(root, id, name);
  if (run.key === null || run.status === "skipped") no(`runs/${id}/${name} had no lead`);
  const m = marker === "" ? null : (/^(LEAD_DONE|LEAD_BLOCKED|ARC_FAILED)(.*)$/.exec(marker) ?? no("no final marker"));
  // a key's segments in the receipt, one per launch or resume, each with only its own cost
  const segs = (isObj(receipt) && Array.isArray(receipt.lanes) ? receipt.lanes : []).filter((l: O) => isObj(l) && l.lane === run.lane)
    .flatMap((l: O) => (Array.isArray(l.runs) ? l.runs : [])).filter((s: O) => isObj(s) && s.key === run.key);
  const priced = segs.map((s: O) => s.cost_usd).filter((c: unknown): c is number => typeof c === "number" && Number.isFinite(c) && c >= 0);
  const ended = segs.map((s: O) => s.ended).filter((t: unknown): t is string => typeof t === "string" && ISO.test(t)).sort().at(-1);
  const start = run.window?.start ?? null;
  // a start killed between launch and its record leaves the account only in .started
  const base = { ...run, account: run.account ?? (NAME.test(account) ? account : null),
    cost_usd: priced.length ? Math.round(priced.reduce((a: number, c: number) => a + c, 0) * 1e6) / 1e6 : null };
  const out: Run = m === null
    ? { ...base, end: null, status: "started", marker: null, detail: null, counts: null, window: run.window && { start, end: null, week_used_pct: null, session_used_pct: null } }
    : { ...base, end: ended ?? iso(now), status: { LEAD_DONE: "done", LEAD_BLOCKED: "blocked", ARC_FAILED: "failed" }[m[1]] as string,
        marker: m[1], detail: m[1] === "LEAD_DONE" ? null : clip(m[2].replace(/^:/, "")), counts: findings(line),
        window: { start, end, week_used_pct: used(start, end, "week_left_pct"), session_used_pct: used(start, end, "session_left_pct") } };
  // a dead lead that never reports is recomputed at every snapshot; an unchanged record keeps its file and its mtime
  if (JSON.stringify(out) !== JSON.stringify(run)) write(root, out, true);
  return out;
}

function why(s: Schedule, f: Facts, lane: string | null): string | null {
  if (s.paused) return "paused";
  if (f.mode === "triage") return "the program is in triage mode";
  if (f.hold) return `held by ${f.hold}`;
  // the date's lane taken by another schedule's run: a start in that minute would share its key and replace its prompt
  return lane !== null && f.open.includes(lane) ? `the worktree ${lane} already stands` : null;
}
export function view(root: string, l: Schedule[], f: Facts, now: number) {
  const errors: { file: string; error: string }[] = [];
  const out = l.map((s) => {
    const r = runs(root, s.id), d = due(s, r.runs, now), n = next(s, now), t = d ?? n, lane = t === null ? null : laneOf(s.focus, t);
    const w = why(s, f, lane);
    errors.push(...r.errors);
    // skips are left out: one's lane may stand for another schedule's run on the same date
    const open = [...new Set(r.runs.filter((x) => x.status !== "skipped" && f.open.includes(x.lane)).map((x) => x.lane))];
    return { ...s, lane, next: n === null ? null : iso(n), due: d === null ? null : iso(d),
      will_start: w === null, why: w, open, runs: r.runs.slice(0, KEEP).map((x) => ({ ...x, alive: x.key !== null && f.alive.includes(x.key) })) };
  });
  return { schema: "orchy.schedules/1", at: iso(now), schedules: out, errors };
}
type Entry = ReturnType<typeof view>["schedules"][number];
export function line(e: Entry): string {
  const what = `harden ${e.focus} ${e.effort}${e.skip_filed ? ", skips filed" : ""}`;
  const skip = e.will_start || e.paused ? "" : `; will skip: ${e.why}`, n = e.open.length;
  const wait = n ? `; ${n} worktree${n === 1 ? " waits" : "s wait"} on you` : "";
  if (e.due) return `DUE ${e.id}: ${what}, slot ${e.due}; ORCHY schedule start ${e.id}${skip}${wait}`;
  const r = e.runs[0], said = r?.reason ?? r?.detail;
  const last = !r ? "" : `; last ${r.status} ${r.start}${said ? `: ${said}` : ""}`;
  const run = r?.alive ? `; running ${r.key}${r.account ? ` on ${r.account}` : ""}` : r?.status === "started" ? `; ${r.key} has no live lead and no final marker` : "";
  return `${e.id}: ${what}, ${e.when}; ${e.paused ? "paused" : `next ${e.next}`}${skip}${last}${run}${wait}`;
}

function facts(v: unknown): Facts {
  const strs = (x: unknown) => (Array.isArray(x) && x.every((y) => typeof y === "string") ? (x as string[]) : no("facts lists are strings"));
  if (!isObj(v)) no("facts is an object");
  const o = v as O, s = (x: unknown) => (x === null || typeof x === "string" ? (x as string | null) : no("facts mode and hold are strings"));
  return { mode: s(o.mode), hold: s(o.hold), open: strs(o.open), alive: strs(o.alive) };
}
function run(op: string, a: string[]): { out: string; err?: string } {
  const json = (i: number, what: string): unknown => { try { return JSON.parse(a[i] || "null"); } catch { return no(`${what} is not JSON`); } };
  const now = (i: number) => time(a[i], "now");
  switch (op) {
    case "add": return { out: `${JSON.stringify(add(schedules(json(0, "the list")), a.slice(1, 8), now(8)))}\n` };
    case "set": return { out: `${JSON.stringify(set(schedules(json(0, "the list")), a[1], a[2], now(3)))}\n` };
    case "view": {
      const v = view(a[0], schedules(json(1, "the list")), facts(json(2, "the facts")), now(3));
      if (a[4] === "1") return { out: `${JSON.stringify(v)}\n` };
      return { out: v.schedules.length ? v.schedules.map((e) => `${line(e)}\n`).join("") : "no schedules\n", err: v.errors.map((e) => `error: ${e.file}: ${e.error}\n`).join("") };
    }
    case "slots": {
      const t = now(2), rows = schedules(json(1, "the list")).flatMap((s) => {
        const d = due(s, runs(a[0], s.id).runs, t), n = next(s, t);
        return [d, n].filter((x): x is number => x !== null).map((x) => `${s.id} ${Math.floor(x / 1000)} ${iso(x)}\n`);
      });
      return { out: rows.join("") };
    }
    case "begin": {
      if (!ID.test(a[1]) || !NAME.test(a[4])) no("begin takes a schedule id and a lead key");
      return { out: `${begin(a[0], a[1], iso(time(a[2], "slot")), now(3), a[4], a[5])}\n` };
    }
    case "launched": {
      if (!ID.test(a[1]) || !FILE.test(a[2]) || !NAME.test(a[3])) no("launched takes a schedule id, a record file and an account");
      return { out: `${launched(a[0], a[1], a[2], a[3], reading(json(4, "the reading"))).account}\n` };
    }
    case "skip": {
      if (!ID.test(a[1]) || (a[6] !== undefined && !FILE.test(a[6]))) no("skip takes a schedule id and maybe a record file");
      return { out: `${skip(a[0], a[1], iso(time(a[2], "slot")), a[3], now(4), a[5] ?? "", a[6])}\n` };
    }
    case "settle": {
      if (!ID.test(a[1]) || !FILE.test(a[2])) no("settle takes a schedule id and a record file");
      const r = settle(a[0], a[1], a[2], a[3], a[4], json(5, "the receipt"), a[6] ?? "", reading(json(7, "the reading")), now(8));
      return { out: `${r.schedule} ${a[2]} ${r.status}\n` };
    }
  }
  return no(`unknown schedules op ${op}`);
}

if (import.meta.main) {
  const raw = await args();
  try {
    const a = raw.map((b) => utf8(b) ?? no("an argument is not UTF-8"));
    const r = run(a[0] ?? "", a.slice(1));
    if (r.err) process.stderr.write(r.err);
    process.stdout.write(r.out);
  } catch (e) {
    const c = (e as { code?: string }).code;
    process.stderr.write(`${e instanceof Refused ? e.message : `refused: the schedules store failed (${c ? STRERROR[c] ?? c : (e as Error).message})`}\n`);
    process.exitCode = 1;
  }
}
