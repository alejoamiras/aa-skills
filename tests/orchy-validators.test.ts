import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { calendarDate, dateIn } from "../skills/start-orchy/scripts/orchy/dates.ts";
import { fromDateIso8601, holds } from "../skills/start-orchy/scripts/orchy/holds.ts";
import { render } from "../skills/start-orchy/scripts/orchy/render.ts";
import { parseRunbook } from "../skills/start-orchy/scripts/orchy/runbook.ts";
import { textError } from "../skills/start-orchy/scripts/orchy/text.ts";

const MOD = join(import.meta.dir, "../skills/start-orchy/scripts/orchy");
const T = mkdtempSync(join(tmpdir(), "orchy-validators-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));
const cli = (mod: string, ...args: string[]) => {
  const r = Bun.spawnSync([process.execPath, join(MOD, `${mod}.ts`), ...args]);
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
};
const file = (name: string, body: string | Uint8Array) => { const p = join(T, name); writeFileSync(p, body); return p; };
const enc = (s: string) => new TextEncoder().encode(s);

describe("text", () => {
  test("accepts 1 to 160 code points, a BOM among them, and the characters just outside the banned ranges", () => {
    for (const t of ["a", "é".repeat(160), `﻿${"a".repeat(159)}`, "a b⁪c"]) expect(textError(enc(t))).toBeNull();
  });
  test("refuses bytes that are not UTF-8, a surrogate's or an overlong encoding among them", () => {
    for (const b of [[0xff], [0xed, 0xa0, 0x80], [0xc0, 0x80]]) expect(textError(new Uint8Array(b))).toBe("refused: the text is not UTF-8");
  });
  test("refuses a length outside 1 to 160 code points", () => {
    expect(textError(enc(""))).toBe("refused: the text is 0 characters; 1 to 160");
    expect(textError(enc(`﻿${"a".repeat(160)}`))).toBe("refused: the text is 161 characters; 1 to 160");
  });
  test("refuses a control, line separator or bidi character", () => {
    for (const t of ["a\tb", "\x7f", "\x85", " ", "؜", "‏", "‮", "⁩"])
      expect(textError(enc(t))).toBe("refused: the text carries a control, line separator or bidi character");
  });
});

describe("runbook", () => {
  test("parses ticked and unticked steps with either proof, skipping empty lines", () => {
    const raw = `- [ ] one\n\n- [x] two (proof: run 12345678901234567890)\n- [ ] ${"t".repeat(160)} (proof: release v1.2.0/rc_1)\n`;
    expect(parseRunbook(raw, false)).toEqual([[false, "one", "", ""], [true, "two", "run", "12345678901234567890"],
      [false, "t".repeat(160), "release", "v1.2.0/rc_1"]]);
  });
  test("refuses a line outside the format, a leading BOM included", () => {
    for (const l of ["* [ ] a", "- [X] a", "- [ ]a", "- [ ] ", "﻿- [ ] a"])
      expect(parseRunbook(l, false)).toMatch(/^refused: line 1 is not '- \[ \] <step>'/);
  });
  test("refuses a control, separator or bidi character: a \\r or \\u2028 stays inside its line", () => {
    for (const l of ["- [ ] a\rb", "- [ ] a b", "- [ ] a‮b"])
      expect(parseRunbook(`- [ ] ok\n${l}`, false)).toBe("refused: line 2 carries a control, line separator or bidi character");
  });
  test("refuses a ticked step in a new runbook", () => {
    expect(parseRunbook("- [ ] a\n- [x] b", true)).toBe("refused: line 2 is ticked; a step starts unticked");
  });
  test("refuses a step that is blank by str.isspace() or over 160 code points", () => {
    for (const l of ["- [ ]  ", "- [ ]  　", `- [ ] ${"é".repeat(161)}`])
      expect(parseRunbook(l, false)).toBe("refused: line 1: a step is 1 to 160 characters");
  });
  test("refuses proof: anywhere but a well-formed ending", () => {
    for (const l of ["- [ ] see PROOF: x", "- [ ] a (proof: tag v1)", "- [ ] a (proof: run 1) (proof: run 2)"])
      expect(parseRunbook(l, false)).toMatch(/^refused: line 1: a proof is /);
  });
  test("refuses a run proof that is not a run id", () => {
    for (const a of ["0", "01", "1".repeat(21), "1a", ""])
      expect(parseRunbook(`- [ ] a (proof: run ${a})`, false)).toBe("refused: line 1: a run proof names a run id");
  });
  test("refuses a release proof that is not a tag", () => {
    for (const a of ["a..b", "-x", "/x", "", "v 1", "t".repeat(101)])
      expect(parseRunbook(`- [ ] a (proof: release ${a})`, false)).toBe("refused: line 1: a release proof names a tag");
  });
  test("refuses fewer than 1 or more than 20 steps", () => {
    expect(parseRunbook("\n\n", false)).toBe("refused: a runbook holds 1 to 20 steps, not 0");
    expect(parseRunbook("- [ ] a\n".repeat(21), false)).toBe("refused: a runbook holds 1 to 20 steps, not 21");
  });
  test("names a read failure with strerror's words, and a file that is not UTF-8", () => {
    mkdirSync(join(T, "dir"));
    expect(cli("runbook", join(T, "missing.md"))).toEqual({ code: 1, out: "", err: "refused: cannot read the runbook (No such file or directory)\n" });
    expect(cli("runbook", join(T, "dir")).err).toBe("refused: cannot read the runbook (Is a directory)\n");
    expect(cli("runbook", file("latin1.md", new Uint8Array([0x2d, 0x20, 0x5b, 0x20, 0x5d, 0x20, 0xe9]))).err).toBe("refused: the runbook is not UTF-8\n");
  });
});

describe("dates", () => {
  test("finds each common form of a date", () => {
    for (const t of ["20260305", "2026-3-05", "5.3.2026", "03/05/2026", "due 3/5", "5/03", "Mar. 5th", "march, 05", "5th of march", "5 mar"])
      expect([t, dateIn(t, ["2026-03-05"])]).toEqual([t, true]);
  });
  test("ignores a yearless dotted or dashed form, and digits or letters that run on", () => {
    for (const t of ["v3.5", "3-5", "13/5", "3/55", "2026-03-055", "march 15", "marching 5", "summarch 5"])
      expect([t, dateIn(t, ["2026-03-05"])]).toEqual([t, false]);
  });
  test("reads digits, word characters and blanks as Python's Unicode classes do", () => {
    expect(dateIn("x٠3/5", ["2026-03-05"])).toBe(false);   // an Arabic-Indic digit runs on
    expect(dateIn("émarch 5", ["2026-03-05"])).toBe(false);   // é is a word character
    expect(dateIn("march\x1c5", ["2026-03-05"])).toBe(true);   // isspace(), unlike JavaScript's \s
    expect(dateIn("march﻿5", ["2026-03-05"])).toBe(false);   // JavaScript's \s, unlike isspace()
  });
  test("indexes months as a list does: 00 is december, past 12 throws", () => {
    expect(dateIn("december 5", ["2026-00-05"])).toBe(true);
    expect(() => dateIn("x", ["2026-13-05"])).toThrow();
  });
  test("accepts only calendar dates from year 1", () => {
    for (const d of ["2024-02-29", "2000-02-29", "0001-01-01", "9999-12-31"]) expect([d, calendarDate(d)]).toEqual([d, true]);
    for (const d of ["2023-02-29", "1900-02-29", "0000-01-01", "2026-13-01", "2026-00-10", "2026-04-31", "2026-04-00", "2026-1-01"])
      expect([d, calendarDate(d)]).toEqual([d, false]);
  });
});

describe("render", () => {
  test("replaces every token in argument order as plain text, and a key with no = by nothing", () => {
    expect(render("<A> <A> <B> <C>", "", ["A=$&|/\\1", "B=<C>", "C=x", "D"]).text).toBe("$&|/\\1 $&|/\\1 x x");
    expect(render("a<D>b", "", ["D"]).text).toBe("ab");
  });
  test("lists the tokens left, once each and sorted, except the kept ones", () => {
    expect(render("<ZED> <LANE> <AB> <ZED> <abc> <KEY>", "LANE,,KEY", []).left).toEqual(["<ZED>"]);
  });
  test("reads the template with universal newlines and a BOM kept, still printing when a token is left", () => {
    expect(cli("render", file("t.md", "﻿a\r\nb\rc <XX> <YYY>"), "", "XX=v"))
      .toEqual({ code: 1, out: "﻿a\nb\nc v <YYY>", err: "orchy: unrendered tokens: <YYY>\n" });
  });
});

describe("holds", () => {
  const WREF = "^(pr|issue):[1-9][0-9]{0,8}$|^page:(0|[1-9][0-9]{0,8})$|^ask:ask[0-9]{1,9}$|^lane:[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$|^other:[a-z0-9-]{1,32}$";
  const since = "2026-03-05T10:00:00Z";
  const rec = (hs: unknown[], extra = {}) => [{ schema: "orchy.holds/1", holds: hs, ...extra }];

  test("prints the record as jq -c does: its own fields only, DEL escaped", () => {
    const out = holds(rec([{ ref: "pr:12", scope: "all", since, x: 1 }, { scope: "trunk", ref: "lane:a.b", since: `${since} \x7f` }], { y: 2 }), WREF);
    expect(out).toBe(`{"schema":"orchy.holds/1","holds":[{"ref":"pr:12","scope":"all","since":"${since}"},{"ref":"lane:a.b","scope":"trunk","since":"${since} \\u007f"}]}`);
  });
  test("refuses anything but exactly one value", () => {
    for (const v of [[], [...rec([]), ...rec([])], rec([])[0]]) expect(holds(v, WREF)).toBeNull();
  });
  test("refuses another schema, or holds that are not an array", () => {
    for (const v of [[{ schema: "orchy.holds/2", holds: [] }], [{ schema: "orchy.holds/1" }], [{ schema: "orchy.holds/1", holds: {} }], [[]]])
      expect(holds(v, WREF)).toBeNull();
  });
  test("refuses a hold that is not an object of string ref, scope and since", () => {
    for (const h of ["x", null, { ref: 1, scope: "all", since }, { ref: "pr:1", scope: "all" }]) expect(holds(rec([h]), WREF)).toBeNull();
  });
  test("refuses a ref outside the grammar, a trailing newline included", () => {
    for (const ref of ["pr:0", "pr:1\n", "\npr:1", "lane:-x", "pr:1 "]) expect(holds(rec([{ ref, scope: "all", since }]), WREF)).toBeNull();
  });
  test("refuses a scope but all or trunk", () => {
    expect(holds(rec([{ ref: "pr:1", scope: "All", since }]), WREF)).toBeNull();
  });
  test("refuses a since that fromdateiso8601 cannot read", () => {
    expect(holds(rec([{ ref: "pr:1", scope: "all", since: "2026-03-05" }]), WREF)).toBeNull();
  });
  test("refuses a ref held twice", () => {
    expect(holds(rec([{ ref: "pr:1", scope: "all", since }, { ref: "pr:1", scope: "trunk", since }]), WREF)).toBeNull();
  });

  // glibc's strptime and timegm decide what jq reads, so the edges are checked against the jq on this host
  test.skipIf(!Bun.which("jq"))("reads a since exactly as jq's fromdateiso8601 does", () => {
    const edges = [since, ` ${since}`, "2026- 3-05T10:00:00Z", "2026-3-5T1:2:3Z", "99-01-01T00:00:00Z", "0-01-01T00:00:00Z",
      "12345-01-01T00:00:00Z", "+2026-03-05T10:00:00Z", "-2026-03-05T10:00:00Z", "2026-02-31T00:00:00Z", "2026-03-05T10:00:60Z",
      "2026-03-05T10:00:61Z", "2026-03-05T10:00:62Z", "2026-13-01T00:00:00Z", "2026-00-01T00:00:00Z", "2026-03-05T24:00:00Z",
      "2026-03-05T10:00:00Z junk", "2026-03-05T10:00:00Z\tjunk", "2026-03-05T10:00:00Zjunk", "2026-03-05T10:00:00Z\u0000x",
      "2026-03-05T10:00:00", "2026-03-05t10:00:00z", "2026-03-05T10:00:00.5Z", "2026-03-05T10:00:00 Z", "1969-12-31T23:59:59Z",
      "1969-12-31T23:59:58Z", "1969-12-31T23:59:57Z", "1970-01-01T00:00:00Z", "0000-02-29T00:00:00Z", "9999-12-31T23:59:59Z", "2026-0305T10:00:00Z", ""];
    const jq = Bun.spawnSync(["jq", "-c", "map(try fromdateiso8601 catch null)"], { stdin: Buffer.from(JSON.stringify(edges)) });
    expect(edges.map(fromDateIso8601)).toEqual(JSON.parse(jq.stdout.toString()));
  });
});
