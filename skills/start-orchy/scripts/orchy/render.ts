// Renders a template: each K=V argument replaces every <K> with V as plain text, then any <TOKEN> left that the keep list
// does not name fails. The template reads as Python's text mode read it: strict UTF-8, \r\n and a lone \r as \n.
// Usage: bun render.ts <template> <K,K,...> K=V...   (the rendering on stdout; exit 1 on a token left over)
import { readFileSync } from "node:fs";

export function render(template: string, keep: string, kvs: string[]): { text: string; left: string[] } {
  let t = template;
  for (const kv of kvs) {
    const i = kv.indexOf("=");
    // split and join, never replace(): a value's $& or $1 stays literal
    t = t.split(`<${i < 0 ? kv : kv.slice(0, i)}>`).join(i < 0 ? "" : kv.slice(i + 1));
  }
  const kept = new Set(keep.split(",").filter(Boolean).map((k) => `<${k}>`));
  return { text: t, left: [...new Set(t.match(/<[A-Z_]{3,}>/g) ?? [])].filter((x) => !kept.has(x)).sort() };
}

if (import.meta.main) {
  const [path, keep, ...kvs] = process.argv.slice(2);
  const raw = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(readFileSync(path));
  const { text, left } = render(raw.replace(/\r\n?/g, "\n"), keep ?? "", kvs);
  await Bun.write(Bun.stdout, text);
  if (left.length) { process.stderr.write(`orchy: unrendered tokens: ${left.join(" ")}\n`); process.exitCode = 1; }
}
