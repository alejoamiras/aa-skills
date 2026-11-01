// orchy.request/1: one question that waits on the owner, one file per request. orchy.sh is the only writer and holds
// requests.lock and the seat's takeover lock around every write here; readers take no lock, since a file is only ever
// replaced whole by rename. The status is the authority and the folder follows it: a done or withdrawn file still in
// the open folder is a close that stopped before its move, and the next write finishes it.
// Usage: ts_run requests <op> <waiting-ref-regex> ...   (a refusal is one line on stderr, exit 1)
//   spec <ref> <spec-file> <shots-dir>                     {content, text}: the stored content, and the text check-public reads
//   add <dir> <ref> <content> <again 0|1> <bare since> <now>   "<rid> r<rev> created|refreshed|unchanged"
//   note <dir> <rid> <re-aid> <text> <now> | stale <dir> <rid> <reason> <now>   "<rid> r<rev> noted|stale"
//   close <dir> <rid> <done|withdrawn> <outcome> <check 0|1> <now>   "<rid> <status> <ref>", the file moved to closed/;
//                                                          with check 1, only the checks, writing nothing
//   list <dir> <all 0|1> <json 0|1> <now> | show <dir> <rid> <now>
import { createHash } from "node:crypto";
import { closeSync, constants, fstatSync, fsyncSync, lstatSync, openSync, readdirSync, readSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { args } from "./args.ts";
import { fromDateIso8601 } from "./holds.ts";
import { STRERROR } from "./strerror.ts";
import { badChar, utf8 } from "./text.ts";

export const FILE_MAX = 64 * 1024, CONTENT_MAX = 40 * 1024, LOG_MAX = 99, REV_MAX = 999999999;
const SHAPES = ["pick", "approve", "done", "reply", "sign"] as const;
const STATUSES = ["open", "stale", "taken", "done", "withdrawn"] as const;
const KINDS = ["pick", "approve", "done", "reply"], REASONS = ["stale", "closed", "invalid", "policy", "withdrawn"];
const CLOSED: ReadonlySet<string> = new Set(["done", "withdrawn"]);
const FILE = /^rq[1-9][0-9]{0,8}\.json$/;
export const RID = /^rq[1-9][0-9]{0,8}$/, AID = /^rq[1-9][0-9]{0,8}\.[1-9][0-9]?$/;
const OPTION = /^[a-z0-9][a-z0-9-]{0,23}$/, PICTURE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.(png|jpe?g|webp)$/;
// a backstop for the obvious remote-exec shapes, not a boundary: a command is the orchestrator's own, never copied in
const REMOTE_EXEC = /\|\s*(?:sudo\s+(?:-\S+\s+)*)?(?:env\s+)?(?:\S*\/)?(?:ba|da|z|k|c|tc|fi)?sh\b|\beval\b|\$\(|`|<\(/;
const CONTENT_KEYS = ["shape", "title", "context", "steps", "blocks", "options", "recommend", "wording", "binding", "page"];

export type Shape = (typeof SHAPES)[number];
export type Status = (typeof STATUSES)[number];
export type Picture = { file: string; alt: string; sha256: string };
export type Option = { id: string; label: string; consequence: string; pictures: Picture[] };
export type Step = { text: string; command?: string };
export type Content = {
  shape: Shape; title: string; context: string; steps: Step[]; blocks: string[];
  options?: Option[]; recommend?: { id: string; why: string }; wording?: string; binding?: { kind: "text"; sha256: string }; page?: number;
};
export type Note = { at: string; re?: string; text: string };
export type LogEntry = { id: string; rev?: number; kind?: string; go?: boolean; state: "taken" | "refused"; reason?: string; withheld?: string; ask?: string; at: string };
export type Request = { schema: "orchy.request/1"; id: string; rev: number; ref: string } & Content
  & { status: Status; since: string; updated: string; taken?: { answer: string; at: string }; outcome?: string; thread: Note[]; answers: LogEntry[] };
export type Store = { dir: Buffer; wref: RegExp; now: string };

export class Refused extends Error {}
const no = (m: string): never => { throw new Refused(`refused: ${m}`); };
type O = Record<string, unknown>;
const isObj = (v: unknown): v is O => typeof v === "object" && v !== null && !Array.isArray(v);
const cps = (s: string) => [...s].length;
const sha256 = (b: string | Uint8Array) => createHash("sha256").update(b).digest("hex");
const at = (dir: Buffer, ...names: string[]) => Buffer.concat([dir, Buffer.from(`/${names.join("/")}`)]);
const num = (id: string) => Number(id.slice(2).split(".")[0]);

function obj(v: unknown, what: string): O {
  return isObj(v) ? v : no(v === undefined ? `${what} is required` : `${what} is not an object`);
}
function arr(v: unknown, what: string, max: number, min = 0): unknown[] {
  if (!Array.isArray(v)) return no(`${what} is not a list`);
  return v.length < min || v.length > max ? no(`${what} holds ${min} to ${max}, not ${v.length}`) : v;
}
function known(o: O, what: string, allowed: string[], strict: boolean): void {
  if (strict) for (const k of Object.keys(o)) if (!allowed.includes(k)) no(`${what} has an unknown field ${JSON.stringify(k)}`);
}
/** Text of min..max code points, well-formed, no control, line separator or bidi character; nl lets \n through. */
export function str(v: unknown, what: string, max: number, min = 1, nl = false): string {
  if (typeof v !== "string" || !v.isWellFormed()) return no(`${what} is not text`);
  const n = cps(v);
  if (n < min || n > max) no(`${what} is ${n} characters; ${min} to ${max}`);
  if (badChar(nl ? v.replaceAll("\n", "") : v)) no(`${what} carries a control, line separator or bidi character`);
  return v;
}
// what utc_now writes: fromdateiso8601 alone would let a stored time carry any text after a blank
const date = (v: unknown, what: string) =>
  (typeof v === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(v) && fromDateIso8601(v) !== null ? v : no(`${what} is not a UTC time`));
// a waiting record's since, which jq reads more loosely, in the form a request stores
function utc(v: string): string {
  const t = fromDateIso8601(v) ?? no("the waiting record's since is not a time");
  return new Date(t * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}
const int = (v: unknown, what: string, lo: number, hi: number) =>
  (Number.isSafeInteger(v) && (v as number) >= lo && (v as number) <= hi ? (v as number) : no(`${what} is not a whole number from ${lo} to ${hi}`));

// at most cap + 1 bytes, so a caller can tell a file over its cap from one at it
function readCapped(fd: number, cap: number): Buffer {
  const b = Buffer.alloc(cap + 1);
  let n = 0;
  for (let k = 1; k > 0 && n <= cap; n += k) k = readSync(fd, b, n, cap + 1 - n, null);
  return b.subarray(0, n);
}

function hashShot(shots: Buffer, file: string): string {
  if (!lstatSync(shots, { throwIfNoEntry: false })?.isDirectory()) return no("page/shots is not a directory");
  let fd: number;
  try { fd = openSync(at(shots, file), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
  catch { return no(`picture ${file} is not a file in page/shots`); }
  try {
    if (!fstatSync(fd).isFile()) no(`picture ${file} is not a regular file`);
    const h = createHash("sha256"), b = Buffer.alloc(1 << 16);
    for (let n = readSync(fd, b); n > 0; n = readSync(fd, b)) h.update(b.subarray(0, n));
    return h.digest("hex");
  } finally { closeSync(fd); }
}

// shots set: a spec, whose pictures are hashed from the folder and whose binding orchy fills; unset: a stored request
function picture(v: unknown, shots: Buffer | undefined): Picture {
  const p = obj(v, "a picture");
  known(p, "a picture", ["file", "alt"], shots !== undefined);
  if (typeof p.file !== "string" || !PICTURE.test(p.file)) no("a picture is a plain .png, .jpg, .jpeg or .webp name in page/shots");
  const file = p.file as string, alt = str(p.alt, "a picture's alt text", 160);
  if (shots) return { file, alt, sha256: hashShot(shots, file) };
  return { file, alt, sha256: typeof p.sha256 === "string" && /^[0-9a-f]{64}$/.test(p.sha256) ? p.sha256 : no("a picture's sha256 is 64 hex digits") };
}
function options(v: unknown, shots: Buffer | undefined): Option[] {
  const os = arr(v ?? no("a pick lists its options"), "a pick's options", 6, 2).map((x): Option => {
    const o = obj(x, "an option");
    known(o, "an option", ["id", "label", "consequence", "pictures"], shots !== undefined);
    if (typeof o.id !== "string" || !OPTION.test(o.id) || o.id === "other") no("an option id is [a-z0-9-], 1 to 24, and never other");
    return { id: o.id as string, label: str(o.label, "an option's label", 80),
      consequence: o.consequence === undefined ? "" : str(o.consequence, "an option's consequence", 160, 0),
      pictures: arr(o.pictures ?? [], "an option's pictures", 2).map((p) => picture(p, shots)) };
  });
  if (new Set(os.map((o) => o.id)).size !== os.length) no("two options share an id");
  return os;
}
function step(v: unknown, i: number, strict: boolean): Step {
  const s = obj(v, `step ${i}`);
  known(s, `step ${i}`, ["text", "command"], strict);
  const st: Step = { text: str(s.text, `step ${i}'s text`, 300) };
  if (s.command === undefined) return st;
  st.command = str(s.command, `step ${i}'s command`, 400);
  if (REMOTE_EXEC.test(st.command)) no(`step ${i}'s command pipes into a shell, or carries eval, $(, a backtick or <(`);
  return st;
}
function binding(v: unknown, wording: string, stored: boolean): { kind: "text"; sha256: string } {
  const b = obj(v, "an approve's binding"), h = sha256(wording);
  if (stored ? b.kind !== "text" || b.sha256 !== h : canon(b) !== canon({ kind: "text" }))
    no(stored ? "the binding is not its wording's sha256" : 'binding is {"kind": "text"}: an approve binds its wording, never a PR, an ask or an act');
  return { kind: "text", sha256: h };
}

/** The answerable content of a spec (shots: the folder its pictures are hashed from) or of a stored request. */
export function content(o: O, ref: string, wref: RegExp, shots?: Buffer): Content {
  const strict = shots !== undefined;
  if (!wref.test(ref)) no("a ref is pr:<n>, issue:<n>, page:<n>, ask:<askN>, lane:<slug> or other:<slug>");
  const shape = SHAPES.find((s) => s === o.shape) ?? no(`shape is one of ${SHAPES.join(", ")}`);
  const title = str(o.title, "the title", 160);
  if (/\b(ask|rq)[0-9]+\b/.test(title)) no("the title names an ask or a request; its ref and blocks carry those");
  const blocks = arr(o.blocks ?? [], "blocks", 8).map((b) => (typeof b === "string" && wref.test(b) && b !== ref ? b : no("blocks are waiting refs other than the request's own")));
  if (new Set(blocks).size !== blocks.length) no("blocks names a ref twice");
  const c: Content = { shape, title, context: o.context === undefined ? "" : str(o.context, "the context", 2000, 0, true),
    steps: arr(o.steps ?? [], "steps", 12).map((s, i) => step(s, i + 1, strict)), blocks };
  if (shape === "done" && c.steps.length === 0) no("a done request lists its steps");
  if (strict) for (const [k, s] of [["options", "pick"], ["recommend", "pick"], ["wording", "approve"], ["binding", "approve"], ["page", "sign"]])
    if (o[k] !== undefined && shape !== s) no(`${k} belongs to a ${s} request`);
  if (shape === "pick") {
    const os = (c.options = options(o.options, shots)), r = obj(o.recommend, "a pick's recommendation");
    known(r, "a pick's recommendation", ["id", "why"], strict);
    if (!os.some((x) => x.id === r.id)) no("the recommendation is not one of the options");
    c.recommend = { id: r.id as string, why: str(r.why, "the recommendation's why", 160) };
  }
  if (shape === "approve") c.binding = binding(o.binding, (c.wording = str(o.wording, "the wording", 2000, 1, true)), !strict);
  if (shape === "sign") {
    c.page = int(o.page, "a sign request's page", 0, 999999999);
    if (ref !== `page:${c.page}`) no("a sign request's ref is page:<its page>");
  }
  return c;
}

/** Every string the owner will read, one per line, for check-public. */
export function publicText(ref: string, c: Content): string {
  const t = [ref, ...c.blocks, c.title, c.context, ...c.steps.flatMap((s) => [s.text, s.command ?? ""]),
    ...(c.options ?? []).flatMap((o) => [o.id, o.label, o.consequence, ...o.pictures.flatMap((p) => [p.file, p.alt])]),
    c.recommend?.why ?? "", c.wording ?? ""];
  return `${t.filter((s) => s !== "").join("\n")}\n`;
}

export function specFile(path: Buffer | string, ref: string, wref: RegExp, shots: Buffer): Content {
  let raw: Buffer;
  try {
    const fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK);
    try { raw = readCapped(fd, FILE_MAX); } finally { closeSync(fd); }
  } catch { return no("cannot read the spec file"); }
  if (raw.length > FILE_MAX) no(`the spec file is over ${FILE_MAX} bytes`);
  const t = utf8(raw) ?? no("the spec file is not UTF-8");
  let o: unknown;
  try { o = JSON.parse(t); } catch { return no("the spec file is not JSON"); }
  const s = obj(o, "the spec");
  known(s, "the spec", CONTENT_KEYS, true);
  return content(s, ref, wref, shots);
}

export function logEntry(v: unknown, rid: string): LogEntry {
  const e = obj(v, "an answers entry");
  if (typeof e.id !== "string" || !AID.test(e.id) || !e.id.startsWith(`${rid}.`)) no("an answers entry's id is not one of this request's");
  const l: LogEntry = { id: e.id, state: e.state === "taken" || e.state === "refused" ? e.state : no("an answers entry's state is taken or refused"), at: "" };
  if (e.rev !== undefined) l.rev = int(e.rev, "an answers entry's rev", 1, REV_MAX);
  if (e.kind !== undefined) l.kind = KINDS.includes(e.kind as string) ? (e.kind as string) : no("an answers entry's kind is unknown");
  if (e.go !== undefined) l.go = typeof e.go === "boolean" ? e.go : no("an answers entry's go is not a boolean");
  if (e.reason !== undefined) l.reason = REASONS.includes(e.reason as string) ? (e.reason as string) : no("an answers entry's reason is unknown");
  if (e.withheld !== undefined) l.withheld = e.withheld === "secret" ? "secret" : no("an answers entry's withheld is unknown");
  if (e.ask !== undefined) l.ask = typeof e.ask === "string" && /^ask[0-9]{1,9}$/.test(e.ask) ? e.ask : no("an answers entry's ask is not an ask id");
  l.at = date(e.at, "an answers entry's time");
  return l;
}

/** A stored request, read by its own fields only: a reader ignores a key it does not know. */
export function stored(v: unknown, id: string, wref: RegExp): Request {
  const o = obj(v, "the request");
  if (o.schema !== "orchy.request/1" || o.id !== id) no("it is not orchy.request/1 under its own id");
  const ref = typeof o.ref === "string" ? o.ref : no("its ref is not text");
  const status = STATUSES.find((s) => s === o.status) ?? no("its status is unknown");
  const thread = arr(o.thread, "the thread", Number.MAX_SAFE_INTEGER).map((x): Note => {
    const n = obj(x, "a thread note");
    const re = n.re === undefined ? undefined : typeof n.re === "string" && AID.test(n.re) ? n.re : no("a thread note's re is not an answer id");
    return { at: date(n.at, "a thread note's time"), ...(re ? { re } : {}), text: str(n.text, "a thread note", 800, 1, true) };
  });
  const answers = arr(o.answers, "the answers log", LOG_MAX).map((e) => logEntry(e, id));
  const t = o.taken === undefined ? undefined : obj(o.taken, "its taken");
  const taken = t && { answer: typeof t.answer === "string" && AID.test(t.answer) ? t.answer : no("its taken answer is not an answer id"), at: date(t.at, "its taken time") };
  return build({ id, rev: int(o.rev, "its rev", 1, REV_MAX), ref, status, since: date(o.since, "its since"), updated: date(o.updated, "its updated"),
    taken, outcome: o.outcome === undefined ? undefined : str(o.outcome, "its outcome", 300), thread, answers }, content(o, ref, wref));
}

type Meta = Pick<Request, "id" | "rev" | "ref" | "status" | "since" | "updated" | "thread" | "answers" | "taken" | "outcome">;
// the one key order every write uses, so two writes of the same request are the same bytes
function build(m: Meta, c: Content): Request {
  const { id, rev, ref, status, since, updated, taken, outcome, thread, answers } = m;
  return { schema: "orchy.request/1", id, rev, ref, ...c, status, since, updated, ...(taken ? { taken } : {}), ...(outcome !== undefined ? { outcome } : {}), thread, answers };
}
const meta = (r: Request): Meta => r;
const contentOf = (r: Request) => Object.fromEntries(CONTENT_KEYS.filter((k) => k in r).map((k) => [k, (r as O)[k]])) as Content;
export const canon = (v: unknown): string =>
  JSON.stringify(v, (_, x) => (isObj(x) ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]])) : x));
/** What a request's caps measure: the file without its answers log and its lifecycle fields. */
export const contentBytes = (r: Request) => Buffer.byteLength(JSON.stringify({ ...r, answers: undefined, taken: undefined, status: undefined }));
const full = (r: Request) => contentBytes(r) > CONTENT_MAX && no(`${r.id} is full (${CONTENT_MAX} bytes of content); withdraw it and open a new one`);

/** Taken replies no thread note answers yet: the owner's words the orchestrator still owes a reply. */
export function unanswered(r: Request): string[] {
  const re = new Set(r.thread.map((n) => n.re));
  return r.answers.filter((e) => e.state === "taken" && e.kind === "reply" && !re.has(e.id)).map((e) => e.id);
}

type Read = { r: Request } | { error: string } | null;
/** One request file; null when it was renamed away since the listing. */
export function readRequest(dir: Buffer, name: string, wref: RegExp): Read {
  let fd: number;
  try { fd = openSync(at(dir, name), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
  catch (e) { const c = (e as { code?: string }).code; return c === "ENOENT" ? null : { error: c === "ELOOP" ? "a symlink" : `cannot be read (${STRERROR[c ?? ""] ?? c})` }; }
  try {
    const st = fstatSync(fd);
    if (!st.isFile()) return { error: "not a regular file" };
    if (st.uid !== process.getuid?.()) return { error: "owned by another user" };
    const b = readCapped(fd, FILE_MAX);
    if (b.length > FILE_MAX) return { error: `over ${FILE_MAX} bytes` };
    const t = utf8(b);
    if (t === null) return { error: "not UTF-8" };
    let o: unknown;
    try { o = JSON.parse(t); } catch { return { error: "not JSON" }; }
    return { r: stored(o, name.slice(0, -5), wref) };
  } catch (e) {
    if (e instanceof Refused) return { error: e.message.slice(9) };
    throw e;
  } finally { closeSync(fd); }
}

function names(dir: Buffer): string[] {
  try { return readdirSync(dir).filter((n) => FILE.test(n)).sort((a, b) => num(a) - num(b)); }
  catch (e) { if ((e as { code?: string }).code === "ENOENT") return []; throw e; }
}
export function scan(dir: Buffer, wref: RegExp, prefix = ""): { ok: Request[]; errors: { file: string; error: string }[] } {
  const ok: Request[] = [], errors: { file: string; error: string }[] = [];
  for (const n of names(dir)) {
    const x = readRequest(dir, n, wref);
    if (x && "r" in x) ok.push(x.r);
    else if (x) errors.push({ file: prefix + n, error: x.error });
  }
  return { ok, errors };
}

function write(dir: Buffer, r: Request): void {
  const tmp = at(dir, `.${r.id}.${process.pid}.tmp`);
  const fd = openSync(tmp, "wx", 0o600);
  try {
    try { writeFileSync(fd, `${JSON.stringify(r)}\n`); fsyncSync(fd); } finally { closeSync(fd); }
    renameSync(tmp, at(dir, `${r.id}.json`));
  } catch (e) { try { unlinkSync(tmp); } catch {} throw e; }
}
// a close that stopped between its write and its move is finished before any other write
function settle(s: Store): Request[] {
  const open: Request[] = [];
  for (const r of scan(s.dir, s.wref).ok) {
    if (CLOSED.has(r.status)) renameSync(at(s.dir, `${r.id}.json`), at(s.dir, "closed", `${r.id}.json`));
    else open.push(r);
  }
  return open;
}
function current(s: Store, rid: string, verb: string): Request {
  if (!RID.test(rid)) no("a request id is rq<n>");
  const r = settle(s).find((x) => x.id === rid);
  if (r) return r;
  const c = readRequest(at(s.dir, "closed"), `${rid}.json`, s.wref);
  return no(c && "r" in c ? `${rid} is ${c.r.status}; ${verb} does not apply` : `no open request ${rid}`);
}

/** The last final answer a closed request took was a Not now on this same binding: re-asking would nag. */
export function notNow(closed: Request, c: Content): boolean {
  const last = closed.answers.filter((e) => e.state === "taken" && e.kind !== "reply").at(-1);
  return closed.status === "done" && last?.kind === "approve" && last.go === false && c.shape === "approve" && canon(closed.binding) === canon(c.binding);
}

export function add(s: Store, ref: string, c: Content, again: boolean, bareSince: string): string {
  const open = settle(s), cur = open.find((r) => r.ref === ref);
  const bare = bareSince && utc(bareSince);
  const earlier = (a: string) => (bare && fromDateIso8601(bare)! < fromDateIso8601(a)! ? bare : a);
  if (cur) {
    if (cur.status === "taken") no(`${cur.id} is taken; finish it with request done first`);
    const same = canon(contentOf(cur)) === canon(c);
    if (same && cur.status === "open") {
      // the bare row goes after this, so an earlier since it held is kept here, with no new rev
      if (earlier(cur.since) !== cur.since) write(s.dir, { ...cur, since: earlier(cur.since), updated: s.now });
      return `${cur.id} r${cur.rev} unchanged\n`;
    }
    const owed = unanswered(cur);
    if (!same && owed.length) no(`${cur.id} has a reply no note answers; answer it with request note ${cur.id} --re ${owed[0]} first`);
    if (cur.rev >= REV_MAX) no(`${cur.id} has no revision left; withdraw it and open a new one`);
    const r = build({ ...meta(cur), rev: cur.rev + 1, status: "open", since: earlier(cur.since), updated: s.now }, c);
    full(r);
    write(s.dir, r);
    return `${r.id} r${r.rev} refreshed\n`;
  }
  const closed = scan(at(s.dir, "closed"), s.wref).ok, last = closed.filter((r) => r.ref === ref).at(-1);
  if (!again && last && notNow(last, c)) no(`${ref} was answered not now on this binding; it returns when the binding changes, or with --again on the owner's word`);
  const n = Math.max(0, ...[...names(s.dir), ...names(at(s.dir, "closed"))].map(num)) + 1;
  if (n > 999999999) no("no request id is left");
  const since = bare || s.now;
  const r = build({ id: `rq${n}`, rev: 1, ref, status: "open", since, updated: s.now, thread: [], answers: [] }, c);
  full(r);
  write(s.dir, r);
  return `${r.id} r1 created\n`;
}

export function note(s: Store, rid: string, re: string, text: string): string {
  const cur = current(s, rid, "note"), t = str(text, "a note", 800, 1, true);
  if (re && !unanswered(cur).includes(re)) no(`${re} is not a taken reply of ${rid} that no note answers yet`);
  const r = { ...cur, thread: [...cur.thread, { at: s.now, ...(re ? { re } : {}), text: t }], updated: s.now };
  if (!re) full(r);   // a note that answers a reply is always admitted: one reply is open at a time, so this bounds the file
  write(s.dir, r);
  return `${rid} r${r.rev} noted\n`;
}

export function stale(s: Store, rid: string, reason: string): string {
  const cur = current(s, rid, "stale"), t = str(reason, "the reason", 300);
  if (cur.status !== "open") no(`${rid} is ${cur.status}; only an open request goes stale`);
  const r: Request = { ...cur, status: "stale", thread: [...cur.thread, { at: s.now, text: t }], updated: s.now };
  full(r);
  write(s.dir, r);
  return `${rid} r${r.rev} stale\n`;
}

export function close(s: Store, rid: string, to: string, outcome: string, check = false): string {
  const from = to === "done" ? ["open", "taken"] : to === "withdrawn" ? ["open", "stale"] : no("a request closes as done or withdrawn");
  const cur = current(s, rid, to === "done" ? "done" : "withdraw"), t = str(outcome, "the outcome", 300), owed = unanswered(cur);
  if (!from.includes(cur.status)) no(`${rid} is ${cur.status}; ${to === "done" ? "done" : "withdraw"} does not apply`);
  if (owed.length) no(`${rid} has a reply no note answers; answer it with request note ${rid} --re ${owed[0]} first`);
  if (check) return `${rid} ${to} ${cur.ref}\n`;
  write(s.dir, build({ ...meta(cur), status: to as Status, updated: s.now, taken: undefined, outcome: t }, contentOf(cur)));
  // the status is the commit: a move that fails here is finished by the next write
  try { renameSync(at(s.dir, `${rid}.json`), at(s.dir, "closed", `${rid}.json`)); } catch {}
  return `${rid} ${to} ${cur.ref}\n`;
}

const age = (s: number) => (s < 3600 ? `${Math.floor(s / 60)}m` : `${Math.floor(s / 3600)}h`);
export function list(s: Store, all: boolean): { requests: (Request & { age_s: number; pending: never[]; answered: boolean; unanswered: string[] })[]; errors: { file: string; error: string }[] } {
  const a = scan(s.dir, s.wref), c = all ? scan(at(s.dir, "closed"), s.wref, "closed/") : { ok: [], errors: [] };
  const now = fromDateIso8601(s.now)!;
  const rs = [...a.ok.filter((r) => all || !CLOSED.has(r.status)), ...c.ok].sort((x, y) => num(x.id) - num(y.id));
  // the pending answers live in the answers inbox, which nothing reads yet
  return { requests: rs.map((r) => ({ ...r, age_s: now - fromDateIso8601(r.since)!, pending: [], answered: false, unanswered: unanswered(r) })), errors: [...a.errors, ...c.errors] };
}

export function render(r: Request, now: string): string {
  const o: string[] = [`${r.id} r${r.rev} ${r.status} ${r.shape} on ${r.ref}, waiting ${age(fromDateIso8601(now)! - fromDateIso8601(r.since)!)} (since ${r.since})`];
  const ind = (t: string) => t.split("\n").map((l) => `  ${l}`);
  if (r.blocks.length) o.push(`blocks ${r.blocks.join(" ")}`);
  o.push(`title: ${r.title}`);
  if (r.context) o.push("context:", ...ind(r.context));
  r.steps.forEach((x, i) => o.push(`step ${i + 1}: ${x.text}`, ...(x.command ? [`  $ ${x.command}`] : [])));
  for (const x of r.options ?? []) o.push(`option ${x.id}${x.id === r.recommend?.id ? " (recommended)" : ""}: ${x.label}${x.consequence ? ` - ${x.consequence}` : ""}`,
    ...x.pictures.map((p) => `  picture ${p.file} ${p.sha256.slice(0, 8)}: ${p.alt}`));
  if (r.recommend) o.push(`why: ${r.recommend.why}`);
  if (r.wording !== undefined) o.push(`wording (sha256 ${r.binding?.sha256.slice(0, 8)}):`, ...ind(r.wording));
  if (r.outcome !== undefined) o.push(`outcome: ${r.outcome}`);
  for (const n of r.thread) o.push(`note ${n.at}${n.re ? ` re ${n.re}` : ""}:`, ...ind(n.text));
  for (const e of r.answers) o.push(`answer ${e.id} ${e.state}${e.reason ? ` ${e.reason}` : ""}${e.kind ? ` ${e.kind}` : ""}${e.rev ? ` r${e.rev}` : ""} ${e.at}`);
  return `${o.join("\n")}\n`;
}

function run(op: string, wref: RegExp, a: Buffer[]): { out: string; err?: string } {
  const t = (i: number, what: string) => utf8(a[i] ?? Buffer.alloc(0)) ?? no(`${what} is not UTF-8`);
  const store = (now: number): Store => ({ dir: a[0], wref, now: date(t(now, "the time"), "the time") });
  switch (op) {
    case "spec": { const c = specFile(a[1], t(0, "the ref"), wref, a[2]); return { out: `${JSON.stringify({ content: c, text: publicText(t(0, "the ref"), c) })}\n` }; }
    case "add": {
      const ref = t(1, "the ref"), c = content(obj(JSON.parse(t(2, "the content")), "the content"), ref, wref);
      return { out: add(store(5), ref, c, t(3, "") === "1", t(4, "the since")) };
    }
    case "note": return { out: note(store(4), t(1, "the id"), t(2, "the answer id"), t(3, "the note")) };
    case "stale": return { out: stale(store(3), t(1, "the id"), t(2, "the reason")) };
    case "close": return { out: close(store(5), t(1, "the id"), t(2, "the status"), t(3, "the outcome"), t(4, "") === "1") };
    case "list": {
      const s = store(3), l = list(s, t(1, "") === "1");
      if (t(2, "") === "1") return { out: `${JSON.stringify({ schema: "orchy.requests/1", ...l })}\n` };
      return { out: l.requests.map((r) => `${r.id}  r${r.rev}  ${r.status}  ${r.shape}  ${r.ref}  ${age(r.age_s)}  ${r.title}\n`).join(""),
        err: l.errors.map((e) => `error: ${e.file}: ${e.error}\n`).join("") };
    }
    case "show": {
      const s = store(2), rid = t(1, "the id");
      if (!RID.test(rid)) no("a request id is rq<n>");
      const x = readRequest(s.dir, `${rid}.json`, wref) ?? readRequest(at(s.dir, "closed"), `${rid}.json`, wref);
      return x && "r" in x ? { out: render(x.r, s.now) } : no(x ? `${rid}: ${x.error}` : `no request ${rid}`);
    }
  }
  return no(`unknown request op ${op}`);
}

if (import.meta.main) {
  const [op, wref, ...rest] = await args();
  try {
    const r = run(op?.toString() ?? "", new RegExp(wref?.toString() ?? "^$"), rest);
    if (r.err) process.stderr.write(r.err);
    process.stdout.write(r.out);
  } catch (e) {
    const c = (e as { code?: string }).code;
    const m = e instanceof Refused ? e.message : `refused: the request store failed (${c ? STRERROR[c] ?? c : (e as Error).message})`;
    process.stderr.write(`${m}\n`);
    process.exitCode = 1;
  }
}
