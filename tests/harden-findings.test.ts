import { afterAll, describe, expect, test } from "bun:test";
import { cpSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Entry, check, diff, fingerprint, findingsLine, write } from "../skills/harden/scripts/findings.ts";
import { findings as orchyFindings } from "../skills/start-orchy/scripts/orchy/schedules.ts";

const M = join(import.meta.dir, "mocks/harden");
const RUN_SH = join(import.meta.dir, "../skills/harden/scripts/run.sh");
const T = mkdtempSync(join(tmpdir(), "harden-findings-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));
const BASE = "2026-10-26-0900-weekly", CUR = "2026-11-02-0900-weekly";
const PINNED = readFileSync(join(M, "findings.v1.json"), "utf8"), ENTRIES = JSON.parse(readFileSync(join(M, "entries.json"), "utf8"));
const BASE_DATA = JSON.parse(readFileSync(join(M, "repo/audit/security", BASE, "findings.json"), "utf8"));
let n = 0;
const tree = () => { const r = join(T, `t${n++}`); cpSync(join(M, "repo"), r, { recursive: true }); return r; };
const runDir = (r: string, name = CUR) => join(r, "audit/security", name);
const file = (v: unknown) => { const f = join(T, `e${n++}.json`); writeFileSync(f, typeof v === "string" ? v : JSON.stringify(v)); return f; };
const cli = (cwd: string, ...a: string[]) => {
  // a bounded child: a read that blocks (a FIFO opened without O_NONBLOCK) fails the test instead of hanging it
  const r = Bun.spawnSync([RUN_SH, ...a], { cwd, env: { ...process.env, MARK: join(cwd, "marker") }, timeout: 10_000 });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
};
// an earlier run beside the baseline: its findings.json is the baseline's, renamed and given other values
const plant = (r: string, name: string, o: Record<string, unknown> = {}) => {
  mkdirSync(runDir(r, name), { recursive: true });
  writeFileSync(join(runDir(r, name), "findings.json"), JSON.stringify({ ...BASE_DATA, run: name, ...o }));
};
const statuses = (r: string) => JSON.parse(readFileSync(join(runDir(r), "findings.json"), "utf8"));

describe("harden.findings/1", () => {
  test("write produces the pinned file, its FINDINGS line reads back through orchy, and check holds both runs", () => {
    const r = tree(), o = cli(T, "findings", "write", runDir(r), join(M, "entries.json"));
    expect(o).toMatchObject({ code: 0, err: "" });
    const [line, summary] = o.out.trimEnd().split("\n");
    expect(summary).toBe(`2 findings, 1 tracked: 1 new, 2 recurring; 1 gone since ${BASE}`);
    expect(readFileSync(join(runDir(r), "findings.json"), "utf8")).toBe(PINNED);
    expect(orchyFindings(line)).toEqual(JSON.parse(PINNED).counts);
    // the baseline's primary file was deleted since: history is never held to today's tree
    for (const d of [runDir(r), runDir(r, BASE)]) expect(cli(T, "findings", "check", d)).toMatchObject({ code: 0, out: "ok\n" });
  });

  test("the fingerprint ignores the run id, lines, title and later files, and nothing else", () => {
    const r = tree(), moved = runDir(r, "2026-11-02-1400-renamed");
    cpSync(runDir(r), moved, { recursive: true });
    write(moved, file(ENTRIES));
    const out = JSON.parse(readFileSync(join(moved, "findings.json"), "utf8")), pinned = JSON.parse(PINNED);
    expect(out.findings.map((e: Entry) => e.fingerprint)).toEqual(pinned.findings.map((e: Entry) => e.fingerprint));
    const fp = fingerprint("security", "CWE-22", "src/upload.ts", "join(UPLOAD_DIR, name)");
    expect(fp).toBe(pinned.findings[0].fingerprint);
    const others = [fingerprint("security", "CWE-23", "src/upload.ts", "join(UPLOAD_DIR, name)"), fingerprint("security", "CWE-22", "src/fs.ts", "join(UPLOAD_DIR, name)"),
      fingerprint("security", "CWE-22", "src/upload.ts", "writeBytes"), fingerprint("bugs", "CWE-22", "src/upload.ts", "join(UPLOAD_DIR, name)")];
    expect(new Set([fp, ...others]).size).toBe(5);
    expect(fingerprint("quality", "Feature Envy", "a.ts", "x")).toBe(fingerprint("quality", "feature-envy ", "a.ts", "x"));
  });

  test("two findings with one fingerprint pair equal titles first, then by id", () => {
    const e = (id: string, title: string) => ({ id, title, fingerprint: "0123456789abcdef" }) as Entry;
    const a = e("F-001", "Leak in the cache"), b = e("F-002", "Race in the cache"), old = e("F-007", "Race in the cache");
    const r = diff([a, b], [old]);
    expect([r.status.get(a), r.status.get(b), r.gone.length]).toEqual(["new", "recurring", 0]);
    expect(diff([], [old]).gone).toEqual([{ ...old, status: "gone" }]);
  });

  test("the baseline is the newest earlier run of equal coverage: later, symlinked and other-coverage runs are passed over", () => {
    const r = tree();
    plant(r, "2026-11-09-0900-weekly", { findings: [], counts: { critical: 0, high: 0, medium: 0, low: 0 } });
    plant(r, "2026-10-31-0900-src", { scope: ["src"] });
    plant(r, "2026-10-30-0900-novendor", { exclude: [] });
    plant(r, "elsewhere-unused");
    symlinkSync(runDir(r, "elsewhere-unused"), runDir(r, "2026-11-01-0900-weekly"));
    write(runDir(r), file(ENTRIES));
    expect(readFileSync(join(runDir(r), "findings.json"), "utf8")).toBe(PINNED);
  });

  test("no baseline marks everything new and says why: none, a malformed newest one, the read limit", () => {
    const allNew = (r: string, note: string | RegExp) => {
      write(runDir(r), file(ENTRIES));
      const d = statuses(r);
      expect([d.baseline, d.gone, [...d.findings, ...d.tracked].map((e: Entry) => e.status)]).toEqual([null, [], ["new", "new", "new"]]);
      expect(d.baseline_note).toMatch(note);
    };
    const none = tree();
    rmSync(runDir(none, BASE), { recursive: true });
    allNew(none, /^no earlier security run with this scope and exclusions carries findings\.json$/);
    const bad = tree();
    plant(bad, "2026-10-31-0900-weekly", { counts: { critical: 9, high: 0, medium: 0, low: 0 } });
    allNew(bad, /^2026-10-31-0900-weekly\/findings\.json refused: counts are not/);
    const many = tree();
    for (let d = 1; d <= 20; d++) plant(many, `2026-10-27-${String(d).padStart(2, "0")}00-src`, { scope: ["src"] });
    allNew(many, /^none of the newest 20 earlier security runs with findings\.json has this scope and exclusions/);
  });

  test("write refuses what the data, the report or the tree get wrong, with the reason", () => {
    const f1 = ENTRIES.findings[0], t1 = ENTRIES.tracked[0];
    const with1 = (o: Record<string, unknown>) => ({ ...ENTRIES, findings: [{ ...f1, ...o }, ENTRIES.findings[1]] });
    const cases: [unknown, RegExp][] = [
      [with1({ line: 8 }), /finding 1 has an unknown field "line"/], [with1({ id: "f1" }), /id is not like F-001/],
      [with1({ files: ["src/upload.ts:8"] }), /ends in a line number/], [with1({ files: ["/src/upload.ts"] }), /is not a repo-relative path/],
      [with1({ files: ["src/../src/upload.ts"] }), /is not a repo-relative path/], [with1({ symbol: "readFile(" }), /does not occur in its first file/],
      [with1({ symbol: "join‮" }), /carries a control, line separator or bidi character/], [with1({ category: "path traversal" }), /is not CWE-<n>/],
      [with1({ confidence: "certain" }), /confidence is high, moderate or low/], [with1({ files: ["src/upload.ts", "src/gone.ts"] }), /does not exist in the tree/],
      [{ ...ENTRIES, tracked: [{ ...t1, ref: undefined }] }, /ref is #<n> or a GHSA id/], [{ ...ENTRIES, tracked: [{ ...t1, id: "F-001" }] }, /F-001 appears twice/],
      [{ ...ENTRIES, scope: ["src", "."] }, /scope is \["\."\] alone/], [{ ...ENTRIES, scope: ["lib"] }, /scope entry "lib" does not exist/],
      [{ ...ENTRIES, findings: [f1] }, /line 17 heads F-002 under ## Findings, which the data lacks there/],
    ];
    const r = tree();
    for (const [v, re] of cases) expect(() => write(runDir(r), file(v))).toThrow(re);
    const report = readFileSync(join(runDir(r), "report.md"), "utf8");
    const edits: [string, string, RegExp][] = [
      ["### [High] F-001:", "### [Severe] F-001:", /F-001's label \[Severe\] is not critical, high, medium, low/],
      ["### [High] F-001: Upload", "### F-001 Upload", /a finding's heading is/],
      ["## Already tracked", "## Findings", /a second "## Findings" section/],
      ["### [Medium] F-003:", "### [Medium] F-001:", /F-001 is headed twice/],
      ["## Already tracked", "## Already Tracked", /F-003 has no "### \[<impact>\] F-003: <title>" heading under ## Already tracked/],
    ];
    for (const [from, to, re] of edits) {
      writeFileSync(join(runDir(r), "report.md"), report.replace(from, to));
      expect(() => write(runDir(r), file(ENTRIES))).toThrow(re);
    }
    writeFileSync(join(runDir(r), "report.md"), report);
    for (const [d, re] of [["audit/security/latest", /is not named <YYYY-MM-DD>-<id> with a real date/], ["audit/security/2026-02-30-x", /with a real date/],
      ["audit/speed/2026-11-02-x", /is not <repo>\/audit\/<security\|bugs\|quality>\/<run>/]] as const) {
      mkdirSync(join(r, d), { recursive: true });
      expect(() => write(join(r, d), file(ENTRIES))).toThrow(re);
    }
    expect(() => write("audit/security/" + CUR, file(ENTRIES))).toThrow(/must be an absolute path/);
    symlinkSync(runDir(r), runDir(r, "2026-11-03-0900-link"));
    expect(() => write(runDir(r, "2026-11-03-0900-link"), file(ENTRIES))).toThrow(/is not a directory \(a symlink is refused\)/);
  });

  test("a planted report link or FIFO refuses at once; a planted findings.json link is replaced, its target untouched", () => {
    const r = tree(), report = join(runDir(r), "report.md"), outside = join(T, `outside${n++}`);
    writeFileSync(outside, "keep");
    rmSync(report);
    symlinkSync(join(M, "repo/audit/security", CUR, "report.md"), report);
    expect(() => write(runDir(r), file(ENTRIES))).toThrow(/report\.md is a symlink/);
    rmSync(report);
    expect(Bun.spawnSync(["mkfifo", report]).exitCode).toBe(0);
    expect(cli(T, "findings", "write", runDir(r), file(ENTRIES))).toMatchObject({ code: 1, err: "report.md is not a regular file\n" });
    rmSync(report);
    cpSync(join(M, "repo/audit/security", CUR, "report.md"), report);
    symlinkSync(outside, join(runDir(r), "findings.json"));
    write(runDir(r), file(ENTRIES));
    expect([readFileSync(outside, "utf8"), lstatSync(join(runDir(r), "findings.json")).isSymbolicLink()]).toEqual(["keep", false]);
  });

  test("check refuses a file that disagrees with itself, its directory or its report; a gone heading is history", () => {
    const r = tree(), d = runDir(r), pinned = JSON.parse(PINNED);
    const cases: [Record<string, unknown>, RegExp][] = [
      [{ counts: { ...pinned.counts, low: 1 } }, /counts are not the findings' impacts/],
      [{ findings: [{ ...pinned.findings[0], fingerprint: "0".repeat(16) }, pinned.findings[1]] }, /F-001's fingerprint is not the one/],
      [{ findings: [{ ...pinned.findings[0], status: "gone" }, pinned.findings[1]] }, /F-001's status is new or recurring/],
      [{ findings: [{ ...pinned.findings[0], title: "Other" }, pinned.findings[1]] }, /F-001's heading, title and impact disagree/],
      [{ run: "2026-11-02-1000-other" }, /a file of run "2026-11-02-1000-other", not 2026-11-02-0900-weekly/],
      [{ focus: "bugs" }, /a bugs file, not security/], [{ extra: 1 }, /the file has an unknown field "extra"/],
      [{ tracked: [] }, /report\.md line \d+ heads F-003 under ## Already tracked, which the data lacks there/],
    ];
    for (const [o, re] of cases) {
      writeFileSync(join(d, "findings.json"), JSON.stringify({ ...pinned, ...o }));
      expect(() => check(d)).toThrow(re);
    }
    writeFileSync(join(d, "findings.json"), PINNED);
    expect(check(d).gone[0].heading).toBe("[Low] F-003: Error responses leak stack traces");
  });

  test("the FINDINGS line: none only when nothing was verified; tracked alone still reads every bucket at zero", () => {
    const one = { focus: "bugs" as const, counts: { blocker: 0, critical: 0, major: 0, minor: 0 }, findings: [] };
    expect(findingsLine({ ...one, tracked: [] })).toBe("FINDINGS: none");
    const t = findingsLine({ ...one, tracked: [{} as Entry] });
    expect([t, orchyFindings(t), orchyFindings("FINDINGS: none")]).toEqual(["FINDINGS: blocker=0 critical=0 major=0 minor=0", one.counts, {}]);
  });

  test("run.sh starts bun from its own directory: a bunfig preload planted in the working directory never runs", () => {
    const p = join(T, `planted${n++}`), r = tree();
    mkdirSync(p);
    writeFileSync(join(p, "bunfig.toml"), 'preload = ["./evil.ts"]\n');
    writeFileSync(join(p, "evil.ts"), 'require("node:fs").writeFileSync(process.env.MARK, "ran");\n');
    expect(cli(p, "findings", "write", runDir(r), join(M, "entries.json")).code).toBe(0);
    expect(() => lstatSync(join(p, "marker"))).toThrow();
    // the control: the same plant runs for a bun started there
    Bun.spawnSync(["bun", "-e", "0"], { cwd: p, env: { ...process.env, MARK: join(p, "marker") } });
    expect(readFileSync(join(p, "marker"), "utf8")).toBe("ran");
  });
});
