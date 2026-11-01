// orchy.holds/1: exactly one value, each hold a ref in the waiting grammar, a scope of all or trunk, and a since that jq's
// fromdateiso8601 reads. Its input is `jq -sc .` of the file, so jq's parser still decides what parses.
// Usage: ts_run holds <ref-regex> <values>   (the record, normalized as jq -c prints it; exit 1 when it is not orchy.holds/1)
import { args } from "./args.ts";

const SPACE = new Set([" ", "\t", "\n", "\v", "\f", "\r"]);   // isspace(3) in the C locale

/** What jq's `try fromdateiso8601 catch null` gives on glibc: strptime("%Y-%m-%dT%H:%M:%SZ") skips blanks before each
 *  number, takes up to 4 digits for the year and 2 for the rest (seconds to 61), stops at a NUL and ignores whatever
 *  follows one blank; timegm then normalizes (February 31 is March 3), and jq's mktime takes -1 and -2 for errors. */
export function fromDateIso8601(input: string): number | null {
  const s = input.split("\0")[0];
  let i = 0;
  const num = (from: number, to: number, n: number): number | null => {
    while (SPACE.has(s[i])) i++;
    if (!(s[i] >= "0" && s[i] <= "9")) return null;
    let v = 0;
    do v = v * 10 + s.charCodeAt(i++) - 48; while (--n > 0 && v * 10 <= to && s[i] >= "0" && s[i] <= "9");
    return v < from || v > to ? null : v;
  };
  const f: number[] = [];
  for (const [from, to, n, sep] of [[0, 9999, 4, "-"], [1, 12, 2, "-"], [1, 31, 2, "T"], [0, 23, 2, ":"], [0, 59, 2, ":"], [0, 61, 2, "Z"]] as const) {
    const v = num(from, to, n);
    if (v === null || s[i] !== sep) return null;
    f.push(v); i++;
  }
  if (i < s.length && !SPACE.has(s[i])) return null;
  const [y0, mo, d, h, mi, sec] = f;
  // days from 1970-01-01 in the proleptic Gregorian calendar; a day past its month runs on, as timegm's does
  const y = mo <= 2 ? y0 - 1 : y0, era = Math.floor(y / 400), yoe = y - era * 400;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + Math.floor((153 * (mo > 2 ? mo - 3 : mo + 9) + 2) / 5) + d - 1;
  const t = (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + sec;
  return t === -1 || t === -2 ? null : t;
}

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

export function holds(values: unknown, wref: string): string | null {
  if (!Array.isArray(values) || values.length !== 1) return null;
  const o = values[0];
  if (!isObj(o) || o.schema !== "orchy.holds/1" || !Array.isArray(o.holds)) return null;
  const re = new RegExp(wref);   // its anchors are the string's ends, so a ref with a newline never matches
  const hs = o.holds as unknown[];
  const ok = hs.every((h) => isObj(h) && typeof h.ref === "string" && typeof h.scope === "string" && typeof h.since === "string"
    && re.test(h.ref) && (h.scope === "all" || h.scope === "trunk") && fromDateIso8601(h.since) !== null);
  if (!ok) return null;
  const rows = hs as { ref: string; scope: string; since: string }[];
  if (new Set(rows.map((h) => h.ref)).size !== rows.length) return null;
  // jq -c escapes DEL, which JSON.stringify leaves raw
  return JSON.stringify({ schema: o.schema, holds: rows.map(({ ref, scope, since }) => ({ ref, scope, since })) }).replace(/\x7f/g, "\\u007f");
}

if (import.meta.main) {
  const [wref, values] = await args();
  const out = holds(JSON.parse(values.toString()), wref.toString());
  if (out === null) process.exitCode = 1;
  else process.stdout.write(`${out}\n`);
}
