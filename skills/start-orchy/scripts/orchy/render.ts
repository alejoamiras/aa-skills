// Renders a template: each K=V argument replaces every <K> with V, then any <TOKEN> left that the keep list does not name
// fails. The template reads as Python's text mode read it (strict UTF-8, \r\n and a lone \r as \n); keys and values are
// bytes, so one outside UTF-8 passes through as Python's surrogateescape passed it.
// Usage: ts_run render <template> <K,K,...> K=V...   (the rendering on stdout; exit 1 on a token left over)
import { readFileSync } from "node:fs";
import { args } from "./args.ts";

function replaceAll(t: Buffer, find: Buffer, by: Buffer): Buffer {
  const parts: Buffer[] = [];
  let i = 0;
  for (let j = t.indexOf(find); j >= 0; i = j + find.length, j = t.indexOf(find, i)) parts.push(t.subarray(i, j), by);
  parts.push(t.subarray(i));
  return Buffer.concat(parts);
}

export function render(template: string, keep: string, kvs: Buffer[]): { out: Buffer; left: string[] } {
  let t = Buffer.from(template.replace(/\r\n?/g, "\n"));
  for (const kv of kvs) {
    const i = kv.indexOf("=");
    const k = i < 0 ? kv : kv.subarray(0, i), v = i < 0 ? Buffer.alloc(0) : kv.subarray(i + 1);
    t = replaceAll(t, Buffer.concat([Buffer.from("<"), k, Buffer.from(">")]), v);
  }
  const kept = new Set(keep.split(",").filter(Boolean).map((k) => `<${k}>`));
  // latin1 maps each byte to one character, so an ASCII token matches only its own bytes
  const found = t.toString("latin1").match(/<[A-Z_]{3,}>/g) ?? [];
  return { out: t, left: [...new Set(found)].filter((x) => !kept.has(x)).sort() };
}

if (import.meta.main) {
  const [path, keep, ...kvs] = await args();
  const raw = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(readFileSync(path));
  const { out, left } = render(raw, keep.toString("latin1"), kvs);
  await Bun.write(Bun.stdout, out);
  if (left.length) { process.stderr.write(`orchy: unrendered tokens: ${left.join(" ")}\n`); process.exitCode = 1; }
}
