// Size budgets for this repo's shell code. A file may grow to its recorded size in budget.json, or to FILE_LINES
// when it has no record; a function likewise to FUNCTION_LINES; a function name lives in one file unless recorded.
// A record looser than the code also fails, so every shrink is banked: --write lowers or drops such entries and
// never raises or adds one; --base <rev> also fails any entry raised or added since that commit's record.
// Usage: bun checks/budget.ts [--write | --files | --base <rev>]
import { lstatSync, readFileSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";

export const FILE_LINES = 800;
export const FUNCTION_LINES = 80;

export type Budget = {
  files: Record<string, number>;
  functions: Record<string, Record<string, number>>;
  duplicates: Record<string, string[]>;
};
export type Fn = { name: string; line: number; lines: number };

// Paths and function names are data: keep them off Object.prototype ("constructor", "__proto__").
const dict = <T>() => Object.create(null) as Record<string, T>;
const own = <T>(o: Record<string, T> | undefined, k: string): T | undefined => (o && Object.hasOwn(o, k) ? o[k] : undefined);

export function isShell(path: string, text: string): boolean {
  if (/\.(sh|bash)$/.test(path)) return true;
  const [cmd, ...words] = /^#!(.*)/.exec(text.split("\n", 1)[0])?.[1].trim().split(/\s+/) ?? [];
  const args = words.map((a) => a.replace(/^(-S|--split-string=)(?=.)/, ""));
  let prog = cmd;
  if (cmd?.endsWith("/env")) {
    prog = undefined;
    for (let i = 0; i < args.length && prog === undefined; i++) {
      if (/^(-[uCP]|--unset|--chdir)$/.test(args[i])) i++;
      else if (!args[i].startsWith("-") && !args[i].includes("=")) prog = args[i];
    }
  }
  return /^(ba|da|k)?sh$/.test(prog?.split("/").pop() ?? "");
}

function lineCount(text: string): number {
  return text === "" ? 0 : text.split("\n").length - (text.endsWith("\n") ? 1 : 0);
}

type Frame = { k: "sub" | "bt" | "dq" | "param" | "sq" | "ansi" | "arith" | "index"; depth: number; word: boolean; inDq: boolean; line: number };
const HEREDOC = /^<<(-?)[ \t]*((?:'[^']*'|"[^"]*"|\\.|[^\s;&|<>()'"`\\])+)/;
// Bash reads name[ as an arithmetic subscript (so "<<" in it is a shift) only in an assignment that starts a command,
// alone or after others, and the line confirms it with ]= or ]+=. Elsewhere, local and declare included, "[" is text.
const ASSIGNEE = /(?:^|[;&|(){}])\s*(?:(?:then|do|else|elif|if|while|until|time|!)\s+)*(?:\S+=\S*\s+)*[A-Za-z_]\w*$/;

// The text with only shell syntax left, line for line: comments cut, quoted text, parameter expansions and
// arithmetic blanked to "_" (so a word stays one word), heredoc bodies emptied. A command substitution opens as ";" and closes as "x", so the braces
// inside it still pair up while its closing paren reads as part of a word, never as a boundary a "}" may follow.
// Throws when a quote, expansion or heredoc is still open at the end: everything after it would go unmeasured.
export function codeLines(text: string): string[] {
  const stack: Frame[] = [];
  const heredocs: { word: string; strip: boolean; line: number }[] = [];
  const lines = text.split("\n").map((s, n) => {
    if (heredocs.length) {
      const h = heredocs[0];
      if ((h.strip ? s.replace(/^\t+/, "") : s) === h.word) heredocs.shift();
      return "";
    }
    let o = "";
    let i = 0;
    const emit = (out: string) => { o += out; i += out.length; };
    const push = (k: Frame["k"], out: string, word = true) => {
      stack.push({ k, depth: 0, word, inDq: stack.at(-1)?.k === "dq", line: n + 1 });
      emit(out);
    };
    while (i < s.length) {
      const top = stack.at(-1);
      const k = top?.k ?? "code";
      const c = s[i];
      if (k === "sq" || k === "ansi") {
        if (k === "ansi" && c === "\\") emit("__");
        else if (c === "'") { stack.pop(); emit("'"); }
        else emit("_");
        continue;
      }
      if (c === "\\") { emit("__"); continue; }
      if (s.startsWith("$((", i)) { push("arith", "$__"); continue; }
      if (s.startsWith("$(", i)) { push("sub", " ;"); continue; }
      if (s.startsWith("${", i)) { push("param", "$_"); continue; }
      if (c === "`") { if (k === "bt") { stack.pop(); emit("x"); } else push("bt", ";"); continue; }
      if (k === "index") {
        if (c === "]") { stack.pop(); emit("]"); }
        else if (c === '"' || c === "'") push(c === '"' ? "dq" : "sq", c);
        else emit("_");
        continue;
      }
      if (k === "arith" && top) {
        if (c === "(") top.depth++;
        else if (c === ")" && top.depth > 0) top.depth--;
        else if (c === ")" && s[i + 1] === ")") { stack.pop(); emit(top.word ? "xx" : "))"); continue; }
        emit("_");
        continue;
      }
      if (k === "dq") { if (c === '"') { stack.pop(); emit('"'); } else emit("_"); continue; }
      if (c === '"') { push("dq", '"'); continue; }
      if (k === "param" && top) {
        if (c === "}") { stack.pop(); emit("x"); }
        else if (c === "'" && !top.inDq) push("sq", "'");
        else emit("_");
        continue;
      }
      if (c === "#" && (i === 0 || /[\s;&|()<>]/.test(s[i - 1]))) break;
      if (c === "'") { push("sq", "'"); continue; }
      if (s.startsWith("$'", i)) { push("ansi", "$'"); continue; }
      if (s.startsWith("((", i)) { push("arith", "  ", false); continue; }
      if (s.startsWith("<<<", i)) { emit("   "); continue; }
      if (c === "[" && ASSIGNEE.test(o) && /^\[.*?\]\+?=/.test(s.slice(i))) { push("index", "["); continue; }
      const h = HEREDOC.exec(s.slice(i));
      if (h) {
        heredocs.push({ word: h[2].replace(/'([^']*)'|"([^"]*)"|\\(.)/g, "$1$2$3"), strip: h[1] === "-", line: n + 1 });
        emit(" ".repeat(h[0].length));
        continue;
      }
      if (k === "sub" && top) {
        if (c === "(") top.depth++;
        else if (c === ")" && top.depth > 0) top.depth--;
        else if (c === ")") { stack.pop(); emit("x"); continue; }
      }
      emit(c);
    }
    return o;
  });
  if (heredocs.length) throw new Error(`line ${heredocs[0].line}: a heredoc never reaches its "${heredocs[0].word}" line`);
  if (stack.length) throw new Error(`line ${stack[0].line}: a quote or expansion never closes`);
  return lines;
}

const HEADER = /(?:^|[;&|(){}]|(?:\b(?:if|then|elif|else|while|until|do|time)|!)(?=[ \t]))[ \t]*(?:function[ \t]+([A-Za-z_][\w:.-]*)(?:[ \t]*\([ \t]*\))?|([A-Za-z_][\w:.-]*)[ \t]*\([ \t]*\))/gm;
const OPENS_AFTER = /(?:^|[;&|(){}!]|\b(?:if|then|else|elif|do|while|until|time)|\bfunction[ \t]+[A-Za-z_][\w:.-]*)$/;
const CLOSES_AFTER = /(?:^|[;&)}])$/;

// Every function in a script with its first line and length. Throws when the braces cannot be paired or a body is
// not a { } group: a check that cannot measure a function must not pass it.
export function functions(text: string): Fn[] {
  const src = codeLines(text).join("\n");
  const lineOf = (p: number) => src.slice(0, p).split("\n").length;
  const pair = new Map<number, number>();
  const open: number[] = [];
  for (let p = 0; p < src.length; p++) {
    const c = src[p];
    if (c !== "{" && c !== "}") continue;
    const before = src.slice(src.lastIndexOf("\n", p - 1) + 1, p).trimEnd();
    const next = src[p + 1] ?? "";
    if (c === "{" && /^\s?$/.test(next) && OPENS_AFTER.test(before)) open.push(p);
    else if (c === "}" && /^[\s;&|)<>]?$/.test(next) && CLOSES_AFTER.test(before)) {
      const o = open.pop();
      if (o === undefined) throw new Error(`line ${lineOf(p)}: a "}" closes nothing`);
      pair.set(o, p);
    }
  }
  if (open.length) throw new Error(`line ${lineOf(open[0])}: a "{" never closes`);
  const fns: Fn[] = [];
  for (const m of src.matchAll(HEADER)) {
    const name = m[1] ?? m[2];
    const at = m.index + m[0].indexOf(name);
    const after = m.index + m[0].length;
    const end = pair.get(after + (/^\s*/.exec(src.slice(after))?.[0].length ?? 0));
    if (end === undefined) throw new Error(`line ${lineOf(at)}: ${name}() has no { } body this check can measure`);
    fns.push({ name, line: lineOf(at), lines: lineOf(end) - lineOf(at) + 1 });
  }
  return fns;
}

export type Measured = { files: Record<string, number>; functions: Record<string, Record<string, number>> };

export function measure(sources: Record<string, string>): Measured {
  const m: Measured = { files: dict(), functions: dict() };
  for (const [path, text] of Object.entries(sources)) {
    m.files[path] = lineCount(text);
    let fns: Fn[];
    try { fns = functions(text); } catch (e) { throw new Error(`${path}: ${(e as Error).message}`); }
    for (const f of fns) (m.functions[path] ??= dict())[f.name] = Math.max(m.functions[path][f.name] ?? 0, f.lines);
  }
  return m;
}

function definers(m: Measured): Map<string, string[]> {
  const by = new Map<string, string[]>();
  for (const [path, fns] of Object.entries(m.functions)) for (const name of Object.keys(fns)) by.set(name, [...(by.get(name) ?? []), path]);
  return by;
}

export function check(m: Measured, b: Budget): { errors: string[]; stale: string[] } {
  const errors: string[] = [];
  const stale: string[] = [];
  const over = (what: string, n: number, recorded: number | undefined, fallback: number, fix: string) => {
    if (n > (recorded ?? fallback)) errors.push(`${what}: ${n} lines, over its ${recorded === undefined ? "default" : "recorded"} budget of ${recorded ?? fallback}; ${fix}`);
  };
  const looser = (what: string, n: number | undefined, recorded: number) => {
    if (n === undefined) stale.push(`${what}: recorded at ${recorded} lines, no longer here`);
    else if (n < recorded) stale.push(`${what}: ${n} lines, recorded at ${recorded}`);
  };
  for (const [path, n] of Object.entries(m.files)) over(path, n, own(b.files, path), FILE_LINES, "split it");
  for (const [path, recorded] of Object.entries(b.files)) looser(path, own(m.files, path), recorded);
  for (const [path, fns] of Object.entries(m.functions))
    for (const [name, n] of Object.entries(fns)) over(`${path}: ${name}()`, n, own(own(b.functions, path), name), FUNCTION_LINES, "split it into smaller functions");
  for (const [path, fns] of Object.entries(b.functions))
    for (const [name, recorded] of Object.entries(fns)) looser(`${path}: ${name}()`, own(own(m.functions, path), name), recorded);
  const by = definers(m);
  for (const [name, paths] of by) {
    const extra = paths.filter((p) => !(own(b.duplicates, name) ?? []).includes(p));
    if (paths.length > 1 && extra.length) errors.push(`${name}(): defined in ${paths.join(", ")}; keep one definition in a library the others source`);
  }
  for (const [name, paths] of Object.entries(b.duplicates)) {
    const gone = paths.filter((p) => !(by.get(name) ?? []).includes(p));
    if (gone.length || paths.length < 2) stale.push(`${name}(): recorded in ${paths.join(", ")}, no longer defined in ${gone.join(", ") || "a second file"}`);
  }
  return { errors, stale };
}

// The record with each entry lowered to what the code now measures, or dropped once the default covers it.
export function tighten(m: Measured, b: Budget): Budget {
  const files = Object.fromEntries(Object.entries(b.files).flatMap(([p, r]) => {
    const n = own(m.files, p);
    return n === undefined || n <= FILE_LINES ? [] : [[p, Math.min(r, n)]];
  }));
  const functions = Object.fromEntries(Object.entries(b.functions).flatMap(([p, fns]) => {
    const kept = Object.fromEntries(Object.entries(fns).flatMap(([name, r]) => {
      const n = own(own(m.functions, p), name);
      return n === undefined || n <= FUNCTION_LINES ? [] : [[name, Math.min(r, n)]];
    }));
    return Object.keys(kept).length ? [[p, kept]] : [];
  }));
  const by = definers(m);
  const duplicates = Object.fromEntries(Object.entries(b.duplicates).flatMap(([name, paths]) => {
    const kept = paths.filter((p) => (by.get(name) ?? []).includes(p));
    return kept.length > 1 ? [[name, kept]] : [];
  }));
  return { files, functions, duplicates };
}

// Entries the record gained or loosened against an earlier record, so a change cannot grow code by editing the record.
export function raised(base: Budget, b: Budget): string[] {
  const out: string[] = [];
  const cmp = (what: string, was: number | undefined, now: number) => {
    if (was === undefined) out.push(`${what}: newly recorded at ${now} lines`);
    else if (now > was) out.push(`${what}: record raised from ${was} to ${now} lines`);
  };
  for (const [p, n] of Object.entries(b.files)) cmp(p, own(base.files, p), n);
  for (const [p, fns] of Object.entries(b.functions)) for (const [name, n] of Object.entries(fns)) cmp(`${p}: ${name}()`, own(own(base.functions, p), name), n);
  for (const [name, paths] of Object.entries(b.duplicates)) {
    const added = paths.filter((p) => !(own(base.duplicates, name) ?? []).includes(p));
    if (added.length) out.push(`${name}(): newly recorded in ${added.join(", ")}`);
  }
  return out;
}

export function format(b: Budget): string {
  return `${JSON.stringify(b, null, 2).replace(/\[\n\s+([^\]]*?)\n\s+\]/g, (_, list: string) => `[${list.split(/,\n\s+/).join(", ")}]`)}\n`;
}

// Shell files git would commit here: tracked or untracked-but-not-ignored, regular files only (no symlinks or submodules).
export function shellSources(root: string): Record<string, string> {
  const ls = Bun.spawnSync(["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]);
  if (ls.exitCode !== 0) throw new Error(`git ls-files failed: ${ls.stderr.toString()}`);
  const out = dict<string>();
  for (const path of [...new Set(ls.stdout.toString().split("\0").filter(Boolean))].sort()) {
    const full = join(root, path);
    try { if (!lstatSync(full).isFile()) continue; } catch { continue; }
    const text = readFileSync(full, "utf8");
    if (isShell(path, text)) out[path] = text;
  }
  return out;
}

// Budgets must be whole numbers: a nonnumeric string would coerce to NaN and pass every comparison.
function parse(json: string): Budget {
  const b: Budget = { files: {}, functions: {}, duplicates: {}, ...JSON.parse(json) };
  const len = (n: unknown) => Number.isSafeInteger(n) && (n as number) >= 0;
  const names = (v: unknown) => Array.isArray(v) && v.every((p) => typeof p === "string");
  const ok = Object.values(b.files).every(len) && Object.values(b.functions).every((f) => typeof f === "object" && f !== null && Object.values(f).every(len))
    && Object.values(b.duplicates).every(names);
  if (!ok) throw new Error("budget record: every budget must be a whole number of lines, every duplicate a list of paths");
  return b;
}

// The record as committed at <rev>, or undefined when that commit has none; a <rev> git cannot resolve throws.
function recordAt(root: string, rev: string, path: string): Budget | undefined {
  const git = (...a: string[]) => Bun.spawnSync(["git", "-C", root, ...a]);
  if (git("rev-parse", "--verify", "-q", `${rev}^{commit}`).exitCode !== 0) throw new Error(`--base ${rev}: no such commit here`);
  const show = git("show", `${rev}:${path}`);
  return show.exitCode === 0 ? parse(show.stdout.toString()) : undefined;
}

export function run(root: string, record: string, mode: "check" | "write" | "files", base?: string): { code: number; out: string[] } {
  const sources = shellSources(root);
  if (mode === "files") return { code: 0, out: Object.keys(sources) };
  const m = measure(sources);
  let b = parse(readFileSync(record, "utf8"));
  if (mode === "write") {
    b = tighten(m, b);
    writeFileSync(record, format(b));
  }
  const { errors, stale } = check(m, b);
  const was = base === undefined ? undefined : recordAt(root, base, relative(root, record));
  const up = was ? raised(was, b) : [];
  const out = [...errors, ...up];
  if (up.length) out.push(`${relative(root, record)} may only lower or drop the entries ${base} has`);
  if (stale.length) out.push(...stale, `${stale.length} record(s) looser than the code: lower them with \`bun checks/budget.ts --write\` and commit ${relative(root, record)}`);
  return { code: out.length ? 1 : 0, out };
}

if (import.meta.main) {
  const [arg, base, ...extra] = process.argv.slice(2);
  const ok = arg === undefined || ((arg === "--write" || arg === "--files") && base === undefined) || (arg === "--base" && base !== undefined);
  if (!ok || extra.length) {
    console.error("usage: bun checks/budget.ts [--write | --files | --base <rev>]");
    process.exit(2);
  }
  const mode = arg === "--write" ? "write" : arg === "--files" ? "files" : "check";
  try {
    const { code, out } = run(join(import.meta.dir, ".."), join(import.meta.dir, "budget.json"), mode, arg === "--base" ? base : undefined);
    if (code) console.error(out.join("\n"));
    else console.log(mode === "files" ? out.join("\n") : "budget: ok");
    process.exit(code);
  } catch (e) {
    console.error(`budget: ${(e as Error).message}`);
    process.exit(1);
  }
}
