// orchy.answer/1: the owner's answer to one request, one file in <slug>.answers/ beside the requests. answer put is the
// sanctioned writer, but any process of the owner's can drop a file there, so take validates every file again and every
// reader screens the text it prints. The request's answers log is the authority: a file leaves the inbox only after its
// outcome is logged, so a take that stops anywhere is finished by the next one, and a logged id is never reconsidered.
// Usage: ts_run answers <op> <waiting-ref-regex> <requests-dir> <answers-dir> <gitleaks> ...
//   put-check <now>                 stdin, after the arguments: one answer; its put verdict, or {input} for put
//   put <input> <now>               under requests.lock: the put verdict, the file linked into the inbox when pending
//   screen <aid> <ledger> <now>     {where, sha, flagged, row}: the file found and screened, and the ledger row it files
//   take <aid> <sha> <flagged 0|1> <ask> <take|refuse> <reason or empty> <now>   under the locks: orchy.answer-take/1
//   list <all 0|1> <json 0|1> <now> | show <aid> <now>
// Exit 0; 1 refused (take: invalid); 4 take refused stale or closed; 2 could not run, and the same command reruns it to its
// one outcome; 120 stdout failed
import { closeSync, constants, fstatSync, fsyncSync, linkSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync, writeSync } from "node:fs";
import { split } from "./args.ts";
import { fromDateIso8601 } from "./holds.ts";
import {
  AID, ANSWER_FILE, ANSWER_MAX, CLOSED, CONTENT_MAX, KINDS, type LogEntry, type O, OPTION, REASONS, REV_MAX, RID, Refused, type Request, type Store,
  at, build, canon, contentBytes, contentOf, date, int, isObj, known, logEntry, meta, names, no, num, obj, pending, readCapped, readRequest, scan, seq,
  sha256, str, unanswered, write,
} from "./requests.ts";
import { STRERROR } from "./strerror.ts";
import { utf8 } from "./text.ts";

const PUT_KEYS = ["schema", "request", "rev", "kind", "choice", "go", "binding", "text", "note", "log"];
const FILE_KEYS = ["schema", "id", "request", "rev", "kind", "at", "choice", "go", "binding", "text", "note", "log", "withheld"];
const FREE = ["text", "note", "log"];
const PENDING_MAX = 100, SEQ_MAX = 99;
export class Unavailable extends Error {}
const down = (m: string): never => { throw new Unavailable(m); };
const ok = <T>(f: () => T): T | undefined => { try { return f(); } catch (e) { if (e instanceof Refused) return undefined; throw e; } };

export type Binding = { kind: "text"; sha256: string };
export type Answer = {
  schema: "orchy.answer/1"; id: string; request: string; rev: number; kind: string; at: string;
  choice?: string; go?: boolean; binding?: Binding; text?: string | null; note?: string | null; log?: string | null; withheld?: "secret";
};
export type Verdict = { state: "taken" | "refused"; reason?: string; withheld?: "secret"; why: string };
type Where = "inbox" | "taken" | "refused";

// the owner's free text: \n allowed, and \t in a log, which is pasted material
function free(v: unknown, what: string, max: number, tab = false): string {
  if (typeof v !== "string") return no(`${what} is not text`);
  str(tab ? v.replaceAll("\t", " ") : v, what, max, 1, true);
  return v;
}
const binding = (v: unknown): Binding | undefined =>
  isObj(v) && Object.keys(v).length === 2 && v.kind === "text" && typeof v.sha256 === "string" && /^[0-9a-f]{64}$/.test(v.sha256) ? { kind: "text", sha256: v.sha256 } : undefined;
const FREE_MAX: Record<string, number> = { text: 2000, note: 1000, log: 6000 };
const freeOk = (o: O, k: string) => ok(() => free(o[k], k, FREE_MAX[k], k === "log"));

/** The answer's own grammar: a put's input when id is unset, else the file named id. Strict: only orchy writes one. */
export function answer(o: O, id?: string): Answer {
  known(o, "the answer", id === undefined ? PUT_KEYS : FILE_KEYS, true);
  if ((id !== undefined || o.schema !== undefined) && o.schema !== "orchy.answer/1") no("schema is orchy.answer/1");
  const request = typeof o.request === "string" && RID.test(o.request) ? o.request : no("request is a request id");
  if (id !== undefined && (o.id !== id || !id.startsWith(`${request}.`))) no("its id is not its file's name under its request");
  if (o.kind === "sign") no("a sign answer is refused: a page is signed on its Artifact");
  const kind = KINDS.includes(o.kind as string) ? (o.kind as string) : no("kind is pick, approve, done or reply");
  if (o.withheld !== undefined) no("withheld is set by take alone");
  const a: Answer = { schema: "orchy.answer/1", id: id ?? "", request, rev: int(o.rev, "rev", 1, REV_MAX), kind, at: id === undefined ? "" : date(o.at, "at") };
  const fields: Record<string, string[]> = { pick: ["choice", "text", "note"], approve: ["go", "binding", "note"], done: ["note", "log"], reply: ["text"] };
  for (const k of ["choice", "go", "binding", "text", "note", "log"]) if (o[k] !== undefined && !fields[kind].includes(k)) no(`${k} does not belong to a ${kind} answer`);
  if (kind === "pick") {
    a.choice = typeof o.choice === "string" && (o.choice === "other" || OPTION.test(o.choice)) ? o.choice : no("choice is an option id, or other");
    if (a.choice === "other") a.text = free(o.text, "the other text", 2000);
    else if (o.text !== undefined) no("text goes with choice other");
  }
  if (kind === "approve") {
    a.go = typeof o.go === "boolean" ? o.go : no("go is true or false");
    if (a.go) a.binding = binding(o.binding) ?? no("a go echoes its request's binding, {kind: text, sha256}");
    else if (o.binding !== undefined) no("a not now carries no binding");
  }
  if (kind === "reply") a.text = free(o.text, "the reply", 2000);
  if (o.note !== undefined) a.note = free(o.note, "the note", 1000);
  if (o.log !== undefined) a.log = free(o.log, "the log", 6000, true);
  return a;
}

/** The fields of a file that pass their own grammar, each on its own: what a log entry and a reader may copy. */
function valid(o: O): Partial<Answer> {
  const f: Partial<Answer> = {};
  const rev = ok(() => int(o.rev, "", 1, REV_MAX)), t = ok(() => date(o.at, "")), b = binding(o.binding);
  if (rev !== undefined) f.rev = rev;
  if (KINDS.includes(o.kind as string)) f.kind = o.kind as string;
  if (t !== undefined) f.at = t;
  if (typeof o.choice === "string" && (o.choice === "other" || OPTION.test(o.choice))) f.choice = o.choice;
  if (typeof o.go === "boolean") f.go = o.go;
  if (b) f.binding = b;
  return f;
}
const ordered = (a: Partial<Answer>): O => Object.fromEntries(FILE_KEYS.filter((k) => (a as O)[k] !== undefined).map((k) => [k, (a as O)[k]]));

/** What a reader prints of a file: its valid fields, and its free text only where the screen passed it (shown). */
export function view(o: O | null, name: string, shown: boolean): O {
  const v: Partial<Answer> = { schema: "orchy.answer/1", id: name, request: name.split(".")[0], ...(o ? valid(o) : {}) };
  const held = !shown || o?.withheld !== undefined;
  for (const k of FREE) if (o && o[k] !== undefined) (v as O)[k] = held ? null : (freeOk(o, k) ?? null);
  if (held) v.withheld = "secret";
  return ordered(v);
}
// what gitleaks reads: the free text and every value no grammar vouches for, so a secret anywhere in a file is caught
export function screenText(o: O): string {
  const f = valid(o) as O, vouched: Record<string, boolean> = { schema: o.schema === "orchy.answer/1", withheld: o.withheld === "secret",
    id: typeof o.id === "string" && AID.test(o.id), request: typeof o.request === "string" && RID.test(o.request) };
  // own properties only: a key like constructor or __proto__ must not find a vouch on a prototype
  return Object.entries(o).filter(([k, v]) => (FREE.includes(k) ? v !== null : !(Object.hasOwn(vouched, k) ? vouched[k] : Object.hasOwn(f, k))))
    .map(([k, v]) => `${FILE_KEYS.includes(k) ? "" : `${k}\n`}${typeof v === "string" ? v : JSON.stringify(v)}`).join("\n");
}
// a file that is no JSON object, an oversized one included, is screened as the bytes read
const textOf = (b: Buffer, o: O | null) => (o ? screenText(o) : b.toString());

/** gitleaks over text; exit 3 is its finding, as check-public runs it, and any other failure means the check did not run. */
export function leaks(gl: string, text: string): boolean {
  if (text === "") return false;
  let code: number | null;
  try { code = Bun.spawnSync([gl, "stdin", "--no-banner", "--redact", "--exit-code", "3", "-l", "error"], { stdin: Buffer.from(text), stdout: "ignore", stderr: "ignore" }).exitCode; }
  catch { return down(`${gl} not found, so the secret check cannot run`); }
  return code === 3 ? true : code === 0 ? false : down(`gitleaks failed (exit ${code})`);
}

/** Against the request as it stands: a kind its shape refuses, an option it does not offer, a binding not its own. */
export function misfit(a: Answer, r: Request): string | null {
  if (a.kind !== "reply" && a.kind !== r.shape) return `a ${a.kind} answer does not fit a ${r.shape} request`;
  if (a.choice !== undefined && a.choice !== "other" && !(r.options ?? []).some((x) => x.id === a.choice)) return `${a.choice} is not one of ${r.id}'s options`;
  if (a.go && canon(a.binding) !== canon(r.binding)) return `the go's binding is not ${r.id}'s`;
  return null;
}
const refused = (reason: string, why: string, withheld?: "secret"): Verdict => ({ state: "refused", reason, ...(withheld ? { withheld } : {}), why });

/** take's verdict on a file (o: null when it is not a JSON object), first match wins. */
export function verdict(o: O | null, name: string, r: Request | null, closed: boolean): Verdict {
  if (o?.withheld !== undefined) return refused("invalid", "its text carried a secret", "secret");
  let a: Answer;
  try { a = answer(o ?? no("it is not a JSON object"), name); } catch (e) { if (e instanceof Refused) return refused("invalid", e.message.slice(9)); throw e; }
  if (!r) return refused("invalid", `there is no request ${a.request}`);
  if (closed) return refused("closed", `${r.id} is ${r.status}`);
  if (a.kind !== "reply" && (a.rev !== r.rev || r.status !== "open")) return refused("stale", `${r.id} is ${r.status} at r${r.rev}, and the answer is for r${a.rev}`);
  const m = misfit(a, r);
  if (m) return refused("invalid", m);
  if (a.kind === "reply" && unanswered(r).length) return refused("invalid", `${unanswered(r)[0]} is a reply no note answers yet`);
  if (a.kind === "reply" && contentBytes(r) > CONTENT_MAX) return refused("invalid", `${r.id} is full`);
  return { state: "taken", why: "" };
}

/** The outcome log's entry: the answer's fields that pass their grammar, never one copied as it came. */
export function entry(o: O | null, name: string, v: Verdict, ask: string, now: string): LogEntry {
  const f = o ? valid(o) : {};
  return logEntry({ id: name, state: v.state, at: now, rev: f.rev, kind: f.kind, go: f.go, reason: v.reason, withheld: v.withheld, ask: ask || undefined }, name.split(".")[0]);
}

/** The ask a request's answers file their sentences on: its ref's, else its first block's, if the ledger holds it. */
export function linked(r: Request | null, asks: ReadonlySet<string>): string {
  return [r?.ref, r?.blocks[0]].map((x) => x?.match(/^ask:(ask[0-9]+)$/)?.[1]).find((x) => x !== undefined && asks.has(x)) ?? "";
}
/** The ledger row an answer's sentences go in: a said row on the linked ask, else a row with no ask id that no fold opens. */
export function ledgerRow(o: O, name: string, r: Request | null, asks: ReadonlySet<string>, now: string): O | null {
  const t = ["text", "note"].map((k) => freeOk(o, k)).filter((x) => x !== undefined).join("\n");
  if (t === "" || o.withheld !== undefined) return null;
  const ask = linked(r, asks);
  return ask ? { id: ask, at: now, said: t, answer: name } : { at: now, answer: name, text: t };
}
function askIds(ledger: Buffer): Set<string> {
  let t: string;
  try { t = readFileSync(ledger, "utf8"); } catch (e) { if ((e as { code?: string }).code === "ENOENT") return new Set(); throw e; }
  const ids = new Set<string>();
  for (const l of t.split("\n")) {
    let o: unknown = null;
    try { o = JSON.parse(l); } catch {}
    if (isObj(o) && typeof o.id === "string") ids.add(o.id);
  }
  return ids;
}

const dirOf = (ans: Buffer, w: Where) => (w === "inbox" ? ans : at(ans, w));
const parse = (b: Buffer): O | null => {
  const t = b.length > ANSWER_MAX ? null : utf8(b);
  try { const o = t === null ? null : (JSON.parse(t) as unknown); return isObj(o) ? o : null; } catch { return null; }
};
/** An answer file's bytes; null when there is none; an error for a symlink, another user's file or a non-file. */
function readAnswer(dir: Buffer, file: string): Buffer | null | { error: string } {
  let fd: number;
  try { fd = openSync(at(dir, file), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
  catch (e) { const c = (e as { code?: string }).code; return c === "ENOENT" ? null : { error: c === "ELOOP" ? "a symlink" : `cannot be read (${STRERROR[c ?? ""] ?? c})` }; }
  try {
    const st = fstatSync(fd);
    return st.isFile() && st.uid === process.getuid?.() ? readCapped(fd, ANSWER_MAX) : { error: "not a regular file of this user's" };
  } finally { closeSync(fd); }
}
function present(dir: Buffer, file: string): Buffer | null {
  const b = readAnswer(dir, file);
  return b && "error" in b ? no(`${file}: ${b.error}`) : b;
}
function locate(ans: Buffer, name: string): { where: Where; bytes: Buffer; o: O | null } | null {
  for (const where of ["inbox", "taken", "refused"] as Where[]) {
    const bytes = present(dirOf(ans, where), `${name}.json`);
    if (bytes) return { where, bytes, o: parse(bytes) };
  }
  return null;
}
/** The request an answer names, open or closed; a request file that cannot be read stops the caller, which decides nothing. */
function find(s: Store, rid: string): { r: Request; closed: boolean; dir: Buffer } | null {
  for (const [dir, inClosed] of [[s.dir, false], [at(s.dir, "closed"), true]] as const) {
    const x = readRequest(dir, `${rid}.json`, s.wref);
    if (x && "r" in x) return { r: x.r, closed: inClosed || CLOSED.has(x.r.status), dir };
    if (x) down(`${rid}: ${x.error}`);
  }
  return null;
}
function writeNew(path: Buffer, data: string | Buffer): void {
  const fd = openSync(path, "wx", 0o600);
  try { writeFileSync(fd, data); fsyncSync(fd); } finally { closeSync(fd); }
}

type PutVerdict = { schema: "orchy.answer-put/1"; state: "pending" | "refused"; id?: string; request: string | null; rev: number | null; reason?: string };
const putRefused = (o: unknown, reason: string): PutVerdict => {
  const r = isObj(o) && typeof o.request === "string" && RID.test(o.request) ? o.request : null, rev = isObj(o) ? valid(o).rev ?? null : null;
  return { schema: "orchy.answer-put/1", state: "refused", request: r, rev, reason };
};
/** put's unlocked half: the body read, held to its grammar and screened. */
export function putCheck(s: Store, gl: string, body: Buffer): PutVerdict | { input: O } {
  const t = body.length > ANSWER_MAX ? null : utf8(body);
  let o: unknown = null;
  try { if (t !== null) o = JSON.parse(t); } catch {}
  const a = isObj(o) ? ok(() => answer(o as O)) : undefined;
  if (!a) return putRefused(o, "invalid");
  if (leaks(gl, screenText(o as O))) return putRefused(o, "secret");
  return find(s, a.request) ? { input: ordered({ ...a, id: undefined, at: undefined }) } : putRefused(o, "invalid");
}
/** put under requests.lock: the request's checks and the inbox's limits, then the file created whole by link(). */
export function put(s: Store, input: O, now: string): PutVerdict {
  const a = answer(input), f = find(s, a.request), v = (reason: string) => putRefused(a, reason);
  if (!f) return v("invalid");
  const r = f.r;
  if (f.closed) return v("closed");
  if (a.kind !== "reply" && (a.rev !== r.rev || r.status !== "open")) return v("stale");
  if (misfit(a, r)) return v("invalid");
  if (a.kind === "reply" && contentBytes(r) > CONTENT_MAX) return v("full");
  const ps = pending(s.ans, r.id);
  // a pending file whose kind cannot be read counts as a final answer, so a broken deposit never lets a second one in
  if (a.kind !== "reply" && ps.some((p) => p.kind !== "reply")) return v("conflict");
  if (a.kind === "reply" && (ps.some((p) => p.kind === "reply") || unanswered(r).length)) return v("conflict");
  if (names(s.ans, ANSWER_FILE).length >= PENDING_MAX) return v("full");
  const used = [...r.answers.map((e) => e.id), ...(["inbox", "taken", "refused"] as Where[]).flatMap((w) => names(dirOf(s.ans, w), ANSWER_FILE).map((n) => n.slice(0, -5)))];
  const n = 1 + Math.max(0, ...used.filter((x) => x.startsWith(`${r.id}.`)).map(seq));
  if (n > SEQ_MAX) return v("full");
  const id = `${r.id}.${n}`, tmp = at(s.ans, ".tmp", `${id}.${process.pid}`);
  writeNew(tmp, `${JSON.stringify(ordered({ ...a, id, at: now }))}\n`);
  try { linkSync(tmp, at(s.ans, `${id}.json`)); }
  catch (e) { if ((e as { code?: string }).code === "EEXIST") return v("conflict"); throw e; }
  finally { unlinkSync(tmp); }
  return { schema: "orchy.answer-put/1", state: "pending", id, request: r.id, rev: a.rev };
}

/** take's unlocked steps: the file found and screened, and the ledger row its sentences go in while it is pending. */
export function screen(s: Store, gl: string, name: string, ledger: Buffer, now: string): O {
  const f = locate(s.ans, name) ?? no(`no answer ${name}`), r = find(s, name.split(".")[0])?.r ?? null;
  const flagged = leaks(gl, textOf(f.bytes, f.o));
  // an id the log settled is a replay, whose words are never filed
  const logged = r?.answers.some((e) => e.id === name) ?? false;
  const row = f.where === "inbox" && f.o && !flagged && !logged ? ledgerRow(f.o, name, r, askIds(ledger), now) : null;
  return { where: f.where, sha: sha256(f.bytes), flagged, logged, row };
}

type Take = { out: O; code: number };
function report(name: string, o: O | null, shown: boolean, e: Pick<LogEntry, "state" | "reason" | "withheld" | "ask">, r: Request | null, recovered: boolean, refuse: boolean): Take {
  const rq = r && { id: r.id, rev: r.rev, shape: r.shape, ref: r.ref, blocks: r.blocks, binding: r.binding ?? null };
  const out = { schema: "orchy.answer-take/1", verdict: e.state, reason: e.reason ?? null, withheld: e.withheld ?? null, request: rq,
    answer: view(o, name, shown && e.withheld === undefined), ask: e.ask ?? null, recovered };
  const code = refuse ? (e.state === "refused" ? 0 : 1) : e.state === "taken" ? 0 : e.reason === "stale" || e.reason === "closed" ? 4 : 1;
  return { out, code };
}
// what a take keeps of a file: its bytes as screened, or, flagged or no answer object, its redacted stub
function scrub(f: { bytes: Buffer; o: O | null }, name: string, flagged: boolean): { bytes: Buffer; o: O } {
  if (f.o && !flagged) return { bytes: f.bytes, o: f.o };
  const o = view(f.o, name, !flagged);
  return { bytes: Buffer.from(`${JSON.stringify(o)}\n`), o };
}
// bytes to <folder>/<name>.json by rename, so no reader sees a partial file; the inbox copy goes once they are archived
function place(s: Store, name: string, folder: Where, bytes: Buffer): void {
  const tmp = at(s.ans, ".tmp", `${name}.${process.pid}.${folder}`);
  writeNew(tmp, bytes);
  try { renameSync(tmp, at(dirOf(s.ans, folder), `${name}.json`)); } catch (e) { unlinkSync(tmp); throw e; }
  if (folder !== "inbox") try { unlinkSync(at(s.ans, `${name}.json`)); } catch (e) { if ((e as { code?: string }).code !== "ENOENT") throw e; }
}
// A recovery finishes only the move, and prints the outcome as logged. An inbox copy is archived scrubbed, or goes when the
// archive already holds those bytes; an archive with other bytes leaves both, since either could be a deposit.
function recover(s: Store, gl: string, name: string, f: { where: Where; bytes: Buffer; o: O | null }, sha: string, flagged: boolean,
  e: Pick<LogEntry, "state" | "reason" | "withheld" | "ask">, r: Request | null, refuse: boolean): Take {
  const file = `${name}.json`, dir = at(s.ans, e.state);
  if (f.where === "inbox") {
    if (sha256(f.bytes) !== sha) down(`${name} changed since it was screened; take it again`);
    const c = scrub(f, name, flagged), kept = present(dir, file);
    if (kept && !kept.equals(c.bytes)) no(`${name}: the inbox and ${e.state}/ hold different files under one settled id; move the wrong one aside`);
    if (kept) unlinkSync(at(s.ans, file));
    else place(s, name, e.state as Where, c.bytes);
    return report(name, c.o, !flagged, e, r, true, refuse);
  }
  // not the file this run screened when another folder holds one too, so screened again
  const b = present(r ? dir : dirOf(s.ans, f.where), file), o = b && parse(b);
  return report(name, o, b === null || !leaks(gl, textOf(b, o)), e, r, true, refuse);
}
/** take and refuse under the locks: a logged outcome wins, then the redaction, the verdict, the log entry as the commit, the move.
 * fixed, a reason, refuses whatever the verdict; refuse sets the exit a refuse command has. */
export function take(s: Store, gl: string, name: string, sha: string, flagged: boolean, ask: string, fixed: string, refuse = fixed !== ""): Take {
  const rid = name.split(".")[0], found = find(s, rid), f = locate(s.ans, name) ?? no(`no answer ${name}`);
  const logged = found?.r.answers.find((e) => e.id === name);
  if (logged) return recover(s, gl, name, f, sha, flagged, logged, found!.r, refuse);
  if (f.where !== "inbox") {
    if (found) no(`${name} is in ${f.where}/, but ${rid} never logged it, so it is no pending answer`);
    return recover(s, gl, name, f, sha, flagged, { state: "refused", reason: "invalid" }, null, refuse);
  }
  if (sha256(f.bytes) !== sha) down(`${name} changed since it was screened; take it again`);
  // the redaction lands before any verdict, so no stop after it leaves the raw text on disk
  const c = scrub(f, name, flagged), o = c.o;
  if (c.bytes !== f.bytes) place(s, name, "inbox", c.bytes);
  let v = verdict(o, name, found?.r ?? null, found?.closed ?? false);
  // an answer to no request has no log to keep a reason, so it is invalid on every run
  if (fixed && v.withheld === undefined && found) v = refused(fixed, `refused as ${fixed}`);
  const e = found ? entry(o, name, v, ask, s.now) : v;
  if (found) {
    const r = found.r, final = v.state === "taken" && (e as LogEntry).kind !== "reply";
    write(found.dir, build({ ...meta(r), status: final ? "taken" : r.status, updated: s.now, taken: final ? { answer: name, at: s.now } : r.taken,
      answers: [...r.answers, e as LogEntry] }, contentOf(r)));
  }
  // the verified bytes, never the inbox path, which any process may have replaced since; over whatever a deposit left there
  place(s, name, v.state, c.bytes);
  return report(name, o, !flagged, e, found ? (find(s, rid)?.r ?? found.r) : null, false, refuse);
}

type Row = { o: O | null; name: string; state: string; reason?: string; ask?: string; text: string };
/** The pending answers, and the logged ones of the requests in view (every request with all), oldest first. */
function rows(s: Store, all: boolean): { rows: Row[]; errors: { file: string; error: string }[] } {
  const out: Row[] = [], errors: { file: string; error: string }[] = [];
  const add = (w: Where, name: string, extra: Partial<Row>) => {
    const file = `${w === "inbox" ? "" : `${w}/`}${name}.json`;
    const b = readAnswer(dirOf(s.ans, w), `${name}.json`);
    if (!b || "error" in b) { if (b || w !== "inbox") errors.push({ file, error: b?.error ?? "missing" }); return; }
    const o = parse(b);
    if (!o) { errors.push({ file, error: "not an answer" }); return; }
    out.push({ o, name, state: "pending", text: o ? screenText(o) : "", ...extra });
  };
  for (const n of names(s.ans, ANSWER_FILE)) add("inbox", n.slice(0, -5), {});
  const reqs = [...scan(s.dir, s.wref).ok.filter((r) => all || !CLOSED.has(r.status)), ...(all ? scan(at(s.dir, "closed"), s.wref).ok : [])];
  for (const r of reqs) for (const e of r.answers) add(e.state as Where, e.id, { state: e.state, reason: e.reason, ask: e.ask });
  out.sort((x, y) => num(x.name) - num(y.name) || seq(x.name) - seq(y.name));
  return { rows: out, errors };
}
// one gitleaks run when nothing is flagged, which is the usual case; one per answer to find which, when something is
function shown(gl: string, rs: Row[]): boolean[] {
  if (!leaks(gl, rs.map((r) => r.text).join("\n"))) return rs.map(() => true);
  return rs.map((r) => !leaks(gl, r.text));
}
export function list(s: Store, gl: string, all: boolean): { answers: O[]; errors: { file: string; error: string }[] } {
  const { rows: rs, errors } = rows(s, all), vis = shown(gl, rs);
  return { answers: rs.map((r, i) => ({ ...view(r.o, r.name, vis[i]), state: r.state, ...(r.reason ? { reason: r.reason } : {}), ...(r.ask ? { ask: r.ask } : {}) })), errors };
}
const age = (now: string, t: unknown) => {
  const x = typeof t === "string" ? fromDateIso8601(t) : null, d = x === null ? null : fromDateIso8601(now)! - x;
  return d === null ? "?" : d < 3600 ? `${Math.floor(d / 60)}m` : `${Math.floor(d / 3600)}h`;
};
const line = (a: O, now: string) => `${a.id}  ${a.state}${a.reason ? ` ${a.reason}` : ""}  ${a.kind ?? "?"}  r${a.rev ?? "?"}  ${age(now, a.at)}${a.withheld ? "  withheld" : ""}`;
/** One answer as text; the owner's words only once it is taken or refused, since a pending one reaches the orchestrator by take. */
export function show(s: Store, gl: string, name: string): string {
  const rs = rows(s, true).rows.filter((r) => r.name === name);
  const r = rs.find((x) => x.state === "pending") ?? rs[0] ?? no(`no answer ${name}`);
  const a = { ...view(r.o, name, r.state !== "pending" && !leaks(gl, r.text)), state: r.state, reason: r.reason };
  const o = [line(a, s.now), ...(a.choice !== undefined ? [`choice: ${a.choice}`] : []), ...(a.go !== undefined ? [`go: ${a.go}`] : []), ...(r.ask ? [`filed on ${r.ask}`] : [])];
  if (r.state !== "pending") for (const k of FREE) if (typeof a[k] === "string") o.push(`${k}:`, ...(a[k] as string).split("\n").map((l) => `  ${l}`));
  return `${o.join("\n")}\n`;
}

function run(op: string, wref: RegExp, a: Buffer[], body: Buffer): { out: string; err?: string; code?: number } {
  const [dir, ans, glb, ...b] = a;
  const t = (i: number) => utf8(b[i] ?? Buffer.alloc(0)) ?? no("an argument is not UTF-8");
  const gl = utf8(glb ?? Buffer.alloc(0)) ?? "";
  const store = (now: string): Store => ({ dir, ans, wref, now: date(now, "the time") });
  const aid = (i: number) => (AID.test(t(i)) ? t(i) : no("an answer id is rq<n>.<seq>"));
  const json = (v: unknown) => `${JSON.stringify(v)}\n`;
  switch (op) {
    case "put-check": {
      const v = putCheck(store(t(0)), gl, body);
      return { out: json(v), err: "input" in v ? "" : `refused: ${v.reason}\n` };
    }
    case "put": { const v = put(store(t(1)), obj(JSON.parse(t(0)), "the input"), t(1)); return { out: json(v), err: v.reason ? `refused: ${v.reason}\n` : "" }; }
    case "screen": return { out: json(screen(store(t(2)), gl, aid(0), b[1], t(2))) };
    case "take": {
      const fixed = t(5);
      if (fixed && !REASONS.includes(fixed)) no(`a refusal's reason is one of ${REASONS.join(", ")}`);
      const r = take(store(t(6)), gl, aid(0), t(1), t(2) === "1", /^ask[0-9]{1,9}$/.test(t(3)) ? t(3) : "", fixed, t(4) === "refuse");
      return { out: json(r.out), code: r.code };
    }
    case "list": {
      const s = store(t(2)), l = list(s, gl, t(0) === "1");
      if (t(1) === "1") return { out: json({ schema: "orchy.answers/1", ...l }) };
      return { out: l.answers.map((x) => `${line(x, s.now)}\n`).join(""), err: l.errors.map((e) => `error: ${e.file}: ${e.error}\n`).join("") };
    }
    case "show": return { out: show(store(t(1)), gl, aid(0)) };
  }
  return no(`unknown answer op ${op}`);
}

function emit(s: string): void {
  const b = Buffer.from(s);
  for (let n = 0; n < b.length;) n += writeSync(1, b, n);
}

if (import.meta.main) {
  // put-check's body follows its six arguments, and may hold any byte
  const raw = Buffer.from(await Bun.stdin.arrayBuffer()), first = split(raw, 1)[0][0]?.toString();
  const [[op, wref, ...rest], body] = split(raw, first === "put-check" ? 6 : Infinity);
  let r: { out: string; err?: string; code?: number };
  try { r = run(op?.toString() ?? "", new RegExp(wref?.toString() ?? "^$"), rest, body); }
  catch (e) {
    const c = (e as { code?: string }).code;
    const m = e instanceof Refused ? e.message : e instanceof Unavailable ? `cannot run: ${e.message}` : `cannot run: the answers store failed (${c ? STRERROR[c] ?? c : (e as Error).message})`;
    r = { out: "", err: `${m}\n`, code: e instanceof Refused ? 1 : 2 };
  }
  if (r.err) process.stderr.write(r.err);
  try { emit(r.out); process.exitCode = r.code ?? 0; } catch { process.exitCode = 120; }
}
