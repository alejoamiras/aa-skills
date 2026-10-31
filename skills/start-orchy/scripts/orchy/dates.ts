// A goal's date: whether a text writes one in a common form, and whether YYYY-MM-DD is a calendar date at all.
// Usage: bun dates.ts in <text> <YYYY-MM-DD>...  |  bun dates.ts valid <YYYY-MM-DD>   (exit 0 yes, 1 no)

const MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
// Python's Unicode classes, so a date in another script's digits or after a non-Latin letter reads as it did: \d any
// decimal digit, \w a letter, number or _, \s what str.isspace() calls space
const D = "\\p{Nd}";
const W = "[\\p{L}\\p{N}_]";
const B = `(?:(?<=${W})(?!${W})|(?<!${W})(?=${W}))`;
const SP = "\\t\\n\\v\\f\\r\\x1c-\\x1f \\x85\\xa0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000";

function forms(date: string): RegExp[] {
  const parts = date.split("-");
  if (parts.length !== 3 || !parts.every((p) => /^[0-9]+$/.test(p))) throw new Error(`not a date: ${date}`);
  const [y, m, dd] = parts, mi = Number(m), di = Number(dd);
  // a list index: month 00 reads as december, past 12 fails, as Python's M[mi - 1] does
  if (mi > 12) throw new Error(`no month ${m}`);
  const name = MONTHS.at(mi - 1) as string;
  const mon = `(?:${name}|${name.slice(0, 3)}\\.?)`, day = `0?${di}(?:st|nd|rd|th)?`;
  // without its year only a slashed form counts: a dotted or dashed one is also a version or a range (1.15, 1-15)
  return [`${y}${m}${dd}`, `(?<!${D})${y}[-/.]0?${mi}[-/.]0?${di}(?!${D})`, `(?<!${D})0?${di}[-/.]0?${mi}[-/.]${y}(?!${D})`,
    `(?<!${D})0?${mi}[-/.]0?${di}[-/.]${y}(?!${D})`, `(?<!${D})0?${mi}/0?${di}(?!${D})`, `(?<!${D})0?${di}/0?${mi}(?!${D})`,
    `${B}${mon}[${SP},-]*${day}${B}`, `${B}${day}(?:[${SP}]+of)?[${SP},-]*${mon}${B}`].map((f) => new RegExp(f, "u"));
}

export function dateIn(text: string, dates: string[]): boolean {
  const t = text.toLowerCase();
  return dates.some((d) => forms(d).some((f) => f.test(t)));
}

export function calendarDate(s: string): boolean {
  const m = /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/.exec(s);
  if (!m) return false;
  const [y, mo, d] = m.slice(1).map(Number);
  const leap = y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
  return y >= 1 && mo >= 1 && mo <= 12 && d >= 1 && d <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1];
}

if (import.meta.main) {
  const [how, s, ...dates] = process.argv.slice(2);
  process.exitCode = (how === "in" ? dateIn(s, dates) : how === "valid" && calendarDate(s)) ? 0 : 1;
}
