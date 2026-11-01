// A waiting record's text: one line of 1 to 160 code points. Strict UTF-8 with the BOM kept, as Python's decoder reads it.
// Usage: ts_run text <text>   (exit 1 with the refusal on stderr)
import { args } from "./args.ts";

const span = (a: number, b: number) => Array.from({ length: b - a }, (_, i) => a + i);
// C0, DEL and C1 controls, the line and paragraph separators, and every Bidi_Control character
const BAD = new Set([...span(0, 0x20), ...span(0x7f, 0xa0), 0x2028, 0x2029, 0x61c, 0x200e, 0x200f, ...span(0x202a, 0x202f), ...span(0x2066, 0x206a)]);
export const badChar = (s: string) => [...s].some((c) => BAD.has(c.codePointAt(0) as number));

const STRICT = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
export function utf8(bytes: Uint8Array): string | null {
  try { return STRICT.decode(bytes); } catch { return null; }
}

export function textError(bytes: Uint8Array): string | null {
  const t = utf8(bytes);
  if (t === null) return "refused: the text is not UTF-8";
  const n = [...t].length;
  if (n < 1 || n > 160) return `refused: the text is ${n} characters; 1 to 160`;
  if (badChar(t)) return "refused: the text carries a control, line separator or bidi character";
  return null;
}

if (import.meta.main) {
  const [t] = await args();
  const e = textError(t ?? new Uint8Array());
  if (e) { process.stderr.write(`${e}\n`); process.exitCode = 1; }
}
