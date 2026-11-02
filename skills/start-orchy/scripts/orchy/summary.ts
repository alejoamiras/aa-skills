// orchy.summary/1: the one or two plain lines a viewer shows for the program, and since when they have stood (an unchanged
// set keeps the time). A lead can write the home as the owner's user, so every read checks the file again.
// Usage: ts_run summary set <file> <now> <line> [<line>]   ("summary set", or "summary unchanged since <since>")
//        ts_run summary show <file> <now>                   ("since <since> (<age>)" and each line, or "no summary")
import { closeSync, constants, fstatSync, fsyncSync, openSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { args } from "./args.ts";
import { fromDateIso8601 } from "./holds.ts";
import { Refused, age, date, isObj, no, readCapped } from "./requests.ts";
import { STRERROR } from "./strerror.ts";
import { badChar, utf8 } from "./text.ts";

export const SCHEMA = "orchy.summary/1", LINE_MAX = 140, FILE_MAX = 4096;
export type Summary = { schema: typeof SCHEMA; since: string; lines: string[] };
// the GFM the orchestrator writes in chat (bold, code, tables, tags, links) and URLs; ids name nothing to a reader
const MARKUP = /[`*|<>[\]]|:\/\//, ID = /\b(ask|rq)[0-9]+\b/;

/** Why a line is not plain text a person would say aloud, or null. */
export function lineError(l: string): string | null {
  if (!l.isWellFormed()) return "is not text";
  const n = [...l].length;
  if (n < 1 || n > LINE_MAX) return `is ${n} characters; 1 to ${LINE_MAX}`;
  if (badChar(l)) return "carries a control, line separator or bidi character";
  if (!/\S/u.test(l)) return "is blank";
  if (MARKUP.test(l)) return "carries markup or a link (` * | < > [ ] ://); a summary is plain text";
  if (ID.test(l)) return "names an ask or a request by its id; say what it is";
  return null;
}

export function lines(ls: string[]): string[] {
  if (ls.length < 1 || ls.length > 2) no(`a summary is 1 or 2 lines, not ${ls.length}`);
  ls.forEach((l, i) => { const e = lineError(l); if (e) no(`line ${i + 1} ${e}`); });
  return ls;
}

export function parse(o: unknown): Summary {
  if (!isObj(o) || o.schema !== SCHEMA) return no(`its schema is not ${SCHEMA}`);
  const since = date(o.since, "its since");
  if (!Array.isArray(o.lines) || !o.lines.every((l) => typeof l === "string")) no("its lines are not a list of text");
  return { schema: SCHEMA, since, lines: lines(o.lines as string[]) };
}

/** The stored summary, or null when there is none; any other file refuses, so nothing is shown or written through it. */
export function load(path: Buffer): Summary | null {
  // named, never the path: a home path may hold any byte, and a refusal is one plain line
  const p = "summary.json", fix = "; read it, remove it, then set the summary again";
  let fd: number;
  try { fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
  catch (e) {
    const c = (e as { code?: string }).code ?? "";
    return c === "ENOENT" ? null : no(`${p} ${c === "ELOOP" ? "is a symlink" : `cannot be read (${STRERROR[c] ?? c})`}${fix}`);
  }
  try {
    const st = fstatSync(fd);
    if (!st.isFile()) no(`${p} is not a regular file${fix}`);
    if (st.uid !== process.getuid?.()) no(`${p} belongs to another user${fix}`);
    const b = readCapped(fd, FILE_MAX);
    if (b.length > FILE_MAX) no(`${p} is over ${FILE_MAX} bytes${fix}`);
    let o: unknown;
    try { o = JSON.parse(utf8(b) ?? ""); } catch { return no(`${p} is not JSON${fix}`); }
    try { return parse(o); } catch (e) { if (e instanceof Refused) no(`${p} is not ${SCHEMA}: ${e.message.slice(9)}${fix}`); throw e; }
  } finally { closeSync(fd); }
}

function replace(path: Buffer, text: string): void {
  const i = path.lastIndexOf(0x2f) + 1;
  const tmp = Buffer.concat([path.subarray(0, i), Buffer.from("."), path.subarray(i), Buffer.from(`.${process.pid}.tmp`)]);
  const fd = openSync(tmp, "wx", 0o600);
  try {
    try { writeFileSync(fd, text); fsyncSync(fd); } finally { closeSync(fd); }
    renameSync(tmp, path);
  } catch (e) { try { unlinkSync(tmp); } catch {} throw e; }
}

export function set(path: Buffer, now: string, ls: string[]): string {
  const next = lines(ls), at = date(now, "the time"), cur = load(path);
  if (cur && cur.lines.length === next.length && cur.lines.every((l, i) => l === next[i])) return `summary unchanged since ${cur.since}\n`;
  replace(path, `${JSON.stringify({ schema: SCHEMA, since: at, lines: next })}\n`);
  return "summary set\n";
}

export function show(path: Buffer, now: string): string {
  const t = fromDateIso8601(date(now, "the time")) as number, s = load(path);
  if (!s) return "no summary\n";
  return `since ${s.since} (${age(Math.max(0, t - (fromDateIso8601(s.since) as number)))})\n${s.lines.map((l) => `  ${l}\n`).join("")}`;
}

if (import.meta.main) {
  const [op, path, now, ...rest] = await args();
  try {
    const t = utf8(now ?? Buffer.alloc(0)) ?? "", p = path ?? Buffer.alloc(0);
    const out = op?.toString() === "set" ? set(p, t, rest.map((b, i) => utf8(b) ?? no(`line ${i + 1} is not UTF-8`)))
      : op?.toString() === "show" && rest.length === 0 ? show(p, t) : no("usage: summary set <file> <now> <line> [<line>] | show <file> <now>");
    process.stdout.write(out);
  } catch (e) {
    const c = (e as { code?: string }).code;
    process.stderr.write(`${e instanceof Refused ? e.message : `refused: the summary store failed (${c ? STRERROR[c] ?? c : (e as Error).message})`}\n`);
    process.exitCode = 1;
  }
}
