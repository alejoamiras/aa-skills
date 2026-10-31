// Renders a template: each K=V argument replaces every <K> with V, then any <TOKEN> left that the keep list does not name
// fails. The template reads as Python's text mode read it (strict UTF-8, \r\n and a lone \r as \n); the arguments read as
// Python's argv did, each byte outside UTF-8 a lone surrogate U+DC80-DCFF that prints as that byte again.
// Usage: ts_run render <template> <K,K,...> K=V...   (the rendering on stdout; exit 1 on a token left over)
import { readFileSync } from "node:fs";
import { args } from "./args.ts";
import { pyOSError } from "./strerror.ts";

const STRICT = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

// the length of the well-formed UTF-8 sequence at b[i], or 0
function seq(b: Buffer, i: number): number {
  const c = (k: number, lo = 0x80, hi = 0xbf) => i + k < b.length && b[i + k] >= lo && b[i + k] <= hi;
  const x = b[i];
  if (x < 0x80) return 1;
  if (x >= 0xc2 && x <= 0xdf) return c(1) ? 2 : 0;
  if (x >= 0xe0 && x <= 0xef) return c(1, x === 0xe0 ? 0xa0 : 0x80, x === 0xed ? 0x9f : 0xbf) && c(2) ? 3 : 0;
  if (x >= 0xf0 && x <= 0xf4) return c(1, x === 0xf0 ? 0x90 : 0x80, x === 0xf4 ? 0x8f : 0xbf) && c(2) && c(3) ? 4 : 0;
  return 0;
}

export function escapedDecode(b: Buffer): string {
  let s = "";
  for (let i = 0; i < b.length; ) {
    const n = seq(b, i);
    s += n ? STRICT.decode(b.subarray(i, i + n)) : String.fromCharCode(0xdc00 + b[i]);
    i += n || 1;
  }
  return s;
}

export function escapedEncode(s: string): Buffer {
  // only an unpaired low surrogate can be an escape: no decoded text holds a high one alone
  return Buffer.concat(s.split(/((?<![\ud800-\udbff])[\udc80-\udcff])/).map((p, i) => (i % 2 ? Buffer.from([p.charCodeAt(0) - 0xdc00]) : Buffer.from(p))));
}

export function render(template: string, keep: string, kvs: string[]): { text: string; left: string[] } {
  let t = template.replace(/\r\n?/g, "\n");
  for (const kv of kvs) {
    const i = kv.indexOf("=");
    // split and join, never replace(): a value's $& or $1 stays literal
    t = t.split(`<${i < 0 ? kv : kv.slice(0, i)}>`).join(i < 0 ? "" : kv.slice(i + 1));
  }
  const kept = new Set(keep.split(",").filter(Boolean).map((k) => `<${k}>`));
  return { text: t, left: [...new Set(t.match(/<[A-Z_]{3,}>/g) ?? [])].filter((x) => !kept.has(x)).sort() };
}

if (import.meta.main) {
  const [path, keep, ...kvs] = await args();
  const { text, left } = render(STRICT.decode(readFileSync(path)), escapedDecode(keep), kvs.map(escapedDecode));
  const out = escapedEncode(text), err = left.length ? `orchy: unrendered tokens: ${left.join(" ")}\n` : "";
  // where both streams meet, the order Python's stdout buffer gave: it reached the descriptor before the stderr line
  // only from 8 KiB, or on a terminal when the text held a line end
  const outFirst = out.length >= 8192 || (process.stdout.isTTY && /[\n\r]/.test(text));
  if (!outFirst) process.stderr.write(err);
  try {
    await Bun.write(Bun.stdout, out);
    if (outFirst) process.stderr.write(err);
    if (err) process.exitCode = 1;
  } catch (e) {
    // Python raised a failed write it had made at once, and only reported, with 120, one its exit flush made
    process.stderr.write(outFirst ? `Traceback (most recent call last):\n  File "<stdin>", line 5, in <module>\n${pyOSError(e)}\n`
      : `Exception ignored in: <_io.TextIOWrapper name='<stdout>' mode='w' encoding='utf-8'>\n${pyOSError(e)}\n`);
    process.exitCode = outFirst ? 1 : 120;
  }
}
