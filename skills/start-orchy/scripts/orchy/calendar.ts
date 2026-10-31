// Whether YYYY-MM-DD is a calendar date, as Python's date.fromisoformat reads that form: year 1 to 9999, real days only.
// Usage: ts_run calendar <YYYY-MM-DD>   (exit 0 yes, 1 no)
import { args } from "./args.ts";

export function calendarDate(s: string): boolean {
  const m = /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/.exec(s);
  if (!m) return false;
  const [y, mo, d] = m.slice(1).map(Number);
  const leap = y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
  return y >= 1 && mo >= 1 && mo <= 12 && d >= 1 && d <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1];
}

if (import.meta.main) {
  const [s] = await args();
  process.exitCode = calendarDate(s?.toString() ?? "") ? 0 : 1;
}
