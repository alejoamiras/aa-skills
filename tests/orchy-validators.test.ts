import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { calendarDate } from "../skills/start-orchy/scripts/orchy/calendar.ts";
import { fromDateIso8601, holds } from "../skills/start-orchy/scripts/orchy/holds.ts";
import { render } from "../skills/start-orchy/scripts/orchy/render.ts";
import { parseRunbook } from "../skills/start-orchy/scripts/orchy/runbook.ts";
import { textError } from "../skills/start-orchy/scripts/orchy/text.ts";

const SCRIPTS = join(import.meta.dir, "../skills/start-orchy/scripts");
const T = mkdtempSync(join(tmpdir(), "orchy-validators-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));
// through ts_run, so its NUL framing and directory change are what runs; printf %b lets an argument carry any byte
const SH = 'SCRIPTS=$1; . "$SCRIPTS/orchy/plumbing.sh"; m=$2; shift 2; a=(); for x in "$@"; do a+=("$(printf %b "$x")"); done; ts_run "$m" "${a[@]}"';
const cli = (mod: string, ...args: string[]) => {
  const r = Bun.spawnSync(["bash", "-c", SH, "_", SCRIPTS, mod, ...args], { cwd: T });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString(), bytes: [...r.stdout] };
};
const file = (name: string | Buffer, body: string | Uint8Array) => {
  const p = Buffer.concat([Buffer.from(`${T}/`), Buffer.from(name)]);
  writeFileSync(p, body);
  return p.toString();
};
const enc = (s: string) => new TextEncoder().encode(s);

describe("text", () => {
  test("accepts 1 to 160 code points, a BOM among them, and the characters just outside the banned ranges", () => {
    for (const t of ["a", "é".repeat(160), `\ufeff${"a".repeat(159)}`, "a b⁪c"]) expect(textError(enc(t))).toBeNull();
  });
  test("refuses bytes that are not UTF-8, a surrogate's or an overlong encoding among them", () => {
    for (const b of [[0xff], [0xed, 0xa0, 0x80], [0xc0, 0x80]]) expect(textError(new Uint8Array(b))).toBe("refused: the text is not UTF-8");
    expect(cli("text", "a\\xffb")).toMatchObject({ code: 1, err: "refused: the text is not UTF-8\n" });
  });
  test("refuses a length outside 1 to 160 code points", () => {
    expect(textError(enc(""))).toBe("refused: the text is 0 characters; 1 to 160");
    expect(textError(enc(`\ufeff${"a".repeat(160)}`))).toBe("refused: the text is 161 characters; 1 to 160");
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
    for (const l of ["* [ ] a", "- [X] a", "- [ ]a", "- [ ] ", "\ufeff- [ ] a"])
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
  test("reads a path outside UTF-8, and names a read failure with strerror's words", () => {
    file(Buffer.from([0x61, 0xff, 0x2e, 0x6d, 0x64]), "- [x] a\n");
    expect(cli("runbook", `${T}/a\\xff.md`, "--new")).toMatchObject({ code: 1, err: "refused: line 1 is ticked; a step starts unticked\n" });
    expect(cli("runbook", `${T}/a\\xff.md`)).toMatchObject({ code: 0, out: '[[true,"a","",""]]\n' });
    mkdirSync(join(T, "dir"));
    for (const [p, why] of [[join(T, "missing.md"), "No such file or directory"], ["", "No such file or directory"], [join(T, "dir"), "Is a directory"]])
      expect(cli("runbook", p)).toEqual({ code: 1, out: "", err: `refused: cannot read the runbook (${why})\n`, bytes: [] });
    expect(cli("runbook", file("latin1.md", new Uint8Array([0x2d, 0x20, 0x5b, 0x20, 0x5d, 0x20, 0xe9]))).err).toBe("refused: the runbook is not UTF-8\n");
  });
  test("abs_path anchors a relative path at the physical working directory, whatever PWD names, and keeps an absolute or empty one", () => {
    const sh = `. "$1/orchy/plumbing.sh"; a=x; b=/y; c=; abs_path a; abs_path b; abs_path c; printf '%s|' "$a" "$b" "$c"`;
    const r = Bun.spawnSync(["bash", "-c", sh, "_", SCRIPTS], { cwd: T, env: { ...process.env, PWD: "/proc/self/cwd" } });
    expect(r.stdout.toString()).toBe(`${realpathSync(T)}/x|/y||`);
  });
});

describe("calendar", () => {
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
    expect(cli("render", file("t.md", "\ufeffa\r\nb\rc <XX> <YYY>"), "", "XX=v"))
      .toMatchObject({ code: 1, out: "\ufeffa\nb\nc v <YYY>", err: "orchy: unrendered tokens: <YYY>\n" });
  });
  test("puts the leftover line where Python's 8 KiB stdout buffer put it in a merged stream", () => {
    const merged = (body: string) => {
      const sh = SH.replace('ts_run "$m"', 'ts_run "$m" 2>&1');
      return Bun.spawnSync(["bash", "-c", sh, "_", SCRIPTS, "render", file("m.md", body), ""]).stdout.toString();
    };
    expect(merged(`${"é".repeat(4092)}<YYY>`)).toStartWith("orchy: unrendered tokens: <YYY>\n");   // 8189 bytes
    expect(merged(`${"é".repeat(4094)}<YYY>`)).toEndWith("<YYY>orchy: unrendered tokens: <YYY>\n");   // 8193 bytes
  });
  test("reads a template through /proc/self/cwd, directly or by a relative link, as the caller's directory", () => {
    file("p.md", "hello <X>");
    symlinkSync("/proc/self/cwd/p.md", join(T, "plink.md"));
    const sh = '. "$1/orchy/plumbing.sh"; . "$1/orchy/text.sh"; SCRIPTS=$1; shift; orchy_render "$@"';
    for (const t of ["/proc/self/cwd/p.md", "plink.md"])
      expect(Bun.spawnSync(["bash", "-c", sh, "_", SCRIPTS, t, "X=v"], { cwd: T }).stdout.toString()).toBe("hello v");
  });
  test("exits 120 with Python's report when its buffered stdout cannot be flushed", () => {
    const r = Bun.spawnSync(["bash", "-c", `${SH} >/dev/full`, "_", SCRIPTS, "render", file("full.md", "x"), ""]);
    expect([r.exitCode, r.stderr.toString()]).toEqual([120,
      "Exception ignored in: <_io.TextIOWrapper name='<stdout>' mode='w' encoding='utf-8'>\nOSError: [Errno 28] No space left on device\n"]);
  });
  test("passes bytes outside UTF-8 through as Python's argv did, never joining two into a character", () => {
    expect(cli("render", file("f.md", "<FOO>!"), "", "FOO=\\xff")).toMatchObject({ code: 0, bytes: [0xff, 0x21] });
    expect(cli("render", file("g.md", "<A><B>"), "", "A=<\\xc3", "B=\\xa9>", "é=no")).toMatchObject({ code: 0, bytes: [0x3c, 0xc3, 0xa9, 0x3e] });
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
      "1969-12-31T23:59:58Z", "1969-12-31T23:59:57Z", "1970-01-01T00:00:00Z", "0000-02-29T00:00:00Z", "9999-12-31T23:59:59Z",
      "2026-0305T10:00:00Z", ""];
    const jq = Bun.spawnSync(["jq", "-c", "map(try fromdateiso8601 catch null)"], { stdin: Buffer.from(JSON.stringify(edges)) });
    expect(edges.map(fromDateIso8601)).toEqual(JSON.parse(jq.stdout.toString()));
  });
});
