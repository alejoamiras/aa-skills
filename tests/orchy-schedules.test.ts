import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  add, after, at, due, findings, line, next, parseWhen, type Reading, record, type Run, runs, type Schedule, schedules, set, slot, used, view,
} from "../skills/start-orchy/scripts/orchy/schedules.ts";

const SCRIPTS = join(import.meta.dir, "../skills/start-orchy/scripts");
const T = mkdtempSync(join(tmpdir(), "orchy-schedules-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));
// through ts_run, so its NUL framing and directory change are what runs
const SH = 'SCRIPTS=$1; . "$SCRIPTS/orchy/plumbing.sh"; shift; ts_run schedules "$@"';
const cli = (...a: string[]) => {
  const r = Bun.spawnSync(["bash", "-c", SH, "_", SCRIPTS, ...a], { cwd: T });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
};
const t = (s: string) => Date.parse(s);
const z = (s: number) => new Date(s).toISOString().replace(".000Z", "Z");
const sched = (o: Partial<Schedule> = {}): Schedule =>
  ({ id: "weekly", focus: "security", effort: "high", when: "mon 09:00 UTC", skip_filed: false, paused: false, since: "2026-10-01T00:00:00Z", ...o });
const KEY = "harden-security-202611090907";
const run = (o: Partial<Run> = {}): Run => ({ schema: "orchy.schedule-run/1", schedule: "weekly", slot: "2026-11-09T09:00:00Z", start: "2026-11-09T09:07:00Z",
  end: null, status: "started", reason: null, lane: "harden-security", key: KEY, account: "atlas", cost_usd: null, marker: null, detail: null,
  counts: null, window: null, ...o });
const NO_FACTS = { mode: null, hold: null, open: [] as string[], alive: [] as string[] };

describe("when and entries", () => {
  test("normalizes the day's case, the hour's width and the zone's spelling", () => {
    expect(parseWhen("Mon 9:00 europe/london").text).toBe("mon 09:00 Europe/London");
    expect(parseWhen("sun 23:59 America/Argentina/Buenos_Aires")).toMatchObject({ day: 0, hh: 23, mm: 59 });
  });
  test("refuses a day, a time or a zone outside the grammar, an offset included", () => {
    for (const w of ["mo 09:00 UTC", "mon 24:00 UTC", "mon 09:60 UTC", "mon 0900 UTC", "mon 09:00", "mon 09:00 UTC extra"])
      expect(() => parseWhen(w)).toThrow(/when is "<mon\.\.sun> <HH:MM> <zone>"/);
    for (const zone of ["+03:00", "Nope/Zone", "../etc"]) expect(() => parseWhen(`mon 09:00 ${zone}`)).toThrow("is not an IANA time zone");
  });
  test("refuses each malformed entry with what is wrong", () => {
    const cases: [Record<string, unknown>, RegExp][] = [
      [{ extra: 1 }, /unknown key extra/], [{ id: "-x" }, /an id is/], [{ focus: "speed" }, /focus is security, quality, bugs/],
      [{ effort: "huge" }, /effort is low/], [{ paused: "no" }, /skip_filed and paused are true or false/], [{ since: "yesterday" }, /since is not a time/]];
    for (const [o, m] of cases) expect(() => schedules([{ ...sched(), ...o }])).toThrow(m);
    const { since: _, ...lacking } = sched();
    expect(() => schedules([lacking])).toThrow("lacks since");
    expect(() => schedules([sched(), sched()])).toThrow("two schedules are named weekly");
    expect(() => schedules(Array.from({ length: 17 }, (_, i) => sched({ id: `s${i}` })))).toThrow("at most 16");
  });
  test("add stamps since and refuses a taken id; pause and resume change nothing twice, resume restarts the clock", () => {
    const now = t("2026-11-04T12:00:00Z");
    const a = add([], ["weekly", "quality", "medium", "Tue", "9:30", "UTC", "1"], now);
    expect(a.schedules).toEqual([{ id: "weekly", focus: "quality", effort: "medium", when: "tue 09:30 UTC", skip_filed: true, paused: false, since: "2026-11-04T12:00:00Z" }]);
    expect(a.message).toBe("schedule weekly added: harden quality medium, tue 09:30 UTC; next 2026-11-10T09:30:00Z");
    expect(() => add(a.schedules, ["weekly", "bugs", "low", "wed", "09:00", "UTC", "0"], now)).toThrow("a schedule weekly exists");
    const p = set(a.schedules, "weekly", "pause", now);
    expect([p.changed, set(p.schedules, "weekly", "pause", now).changed, set(a.schedules, "weekly", "resume", now + 1).changed]).toEqual([true, false, false]);
    expect(set(p.schedules, "weekly", "resume", t("2026-11-20T00:00:00Z")).schedules[0]).toMatchObject({ paused: false, since: "2026-11-20T00:00:00Z" });
    expect(set([...a.schedules, sched({ id: "other" })], "weekly", "remove", now).schedules.map((s) => s.id)).toEqual(["other"]);
    expect(() => set(a.schedules, "nope", "pause", now)).toThrow("no schedule nope");
  });
});

describe("slots", () => {
  const w = (s: string) => parseWhen(s);
  test("the week boundary: the slot is at or before now, the next one strictly after", () => {
    const mon = w("mon 09:00 UTC");
    expect(z(slot(mon, t("2026-11-09T08:59:59Z")))).toBe("2026-11-02T09:00:00Z");
    expect(z(after(mon, t("2026-11-08T23:59:59Z")))).toBe("2026-11-09T09:00:00Z");
    expect(z(slot(mon, t("2026-11-09T09:00:00Z")))).toBe("2026-11-09T09:00:00Z");
    expect(z(after(mon, t("2026-11-09T09:00:00Z")))).toBe("2026-11-16T09:00:00Z");
    expect(z(after(w("thu 10:00 UTC"), t("2026-12-31T10:00:01Z")))).toBe("2027-01-07T10:00:00Z");
  });
  test("the weekday is the zone's own date, west and east of UTC and across the date line", () => {
    expect(z(after(w("mon 09:00 America/Argentina/Buenos_Aires"), t("2026-11-02T17:00:00Z")))).toBe("2026-11-09T12:00:00Z");
    expect(z(after(w("mon 08:00 Pacific/Kiritimati"), t("2026-11-02T17:00:00Z")))).toBe("2026-11-08T18:00:00Z");
    expect(z(after(w("mon 00:30 Asia/Tokyo"), t("2026-11-02T17:00:00Z")))).toBe("2026-11-08T15:30:00Z");
  });
  test("a wall time the zone skips runs that much later (New York, London, Lord Howe's half hour)", () => {
    expect(z(after(w("sun 02:30 America/New_York"), t("2026-03-07T00:00:00Z")))).toBe("2026-03-08T07:30:00Z");
    expect(z(after(w("sun 01:30 Europe/London"), t("2026-03-28T00:00:00Z")))).toBe("2026-03-29T01:30:00Z");
    expect(z(after(w("sun 02:15 Australia/Lord_Howe"), t("2026-10-03T00:00:00Z")))).toBe("2026-10-03T15:45:00Z");
  });
  test("a wall time the zone repeats runs once, at its first occurrence", () => {
    const ny = w("sun 01:30 America/New_York");
    expect(z(after(ny, t("2026-10-31T00:00:00Z")))).toBe("2026-11-01T05:30:00Z");
    expect(z(slot(ny, t("2026-11-01T06:45:00Z")))).toBe("2026-11-01T05:30:00Z");
    expect(z(after(ny, t("2026-11-01T05:30:00Z")))).toBe("2026-11-08T06:30:00Z");
    expect(z(after(w("sun 01:30 Europe/London"), t("2026-10-24T00:00:00Z")))).toBe("2026-10-25T00:30:00Z");
    expect(z(after(w("sun 01:45 Australia/Lord_Howe"), t("2027-04-02T00:00:00Z")))).toBe("2027-04-03T14:45:00Z");
  });
  // biome-ignore lint/suspicious/noExplicitAny: Temporal has no types in this Bun
  const Temporal = (globalThis as { Temporal?: any }).Temporal;
  test.skipIf(!Temporal)("agrees with Temporal's compatible within three hours of every zone's transitions in 2026 and 2027", () => {
    const bad: string[] = [];
    let n = 0;
    for (const zone of Intl.supportedValuesOf("timeZone")) {
      for (let z0 = Temporal.ZonedDateTime.from({ timeZone: zone, year: 2026, month: 1, day: 1 }), tr; (tr = z0.getTimeZoneTransition("next")) && tr.year < 2028; z0 = tr) {
        const w0 = tr.toPlainDateTime().round({ smallestUnit: "minute", roundingMode: "floor" });
        for (let m = -180; m <= 180; m += 15, n++) {
          const p = w0.add({ minutes: m });
          if (at(p.year, p.month, p.day, p.hour, p.minute, zone) !== p.toZonedDateTime(zone).epochMilliseconds) bad.push(`${zone} ${p}`);
        }
      }
    }
    expect(bad).toEqual([]);
    expect(n).toBeGreaterThan(5000);
  });
});

describe("due", () => {
  const now = t("2026-11-09T09:05:00Z");
  test("the latest slot is due once: not before the schedule existed, not while paused, not once a record spent it", () => {
    expect(z(due(sched(), [], now) as number)).toBe("2026-11-09T09:00:00Z");
    expect(due(sched({ since: "2026-11-09T09:01:00Z" }), [], now)).toBeNull();
    expect(due(sched({ paused: true }), [], now)).toBeNull();
    expect(due(sched(), [run({ status: "skipped" })], now)).toBeNull();
    expect(due(sched(), [run({ slot: "2026-11-02T09:00:00Z" })], now)).not.toBeNull();
  });
  test("a slot missed while nobody ran is not backfilled: two weeks on, only the latest is due", () => {
    expect(z(due(sched(), [run({ slot: "2026-10-26T09:00:00Z" })], t("2026-11-10T00:00:00Z")) as number)).toBe("2026-11-09T09:00:00Z");
  });
  test("slots, as the wait caches them, carry each unpaused schedule's due slot and its next one", () => {
    const list = JSON.stringify([sched(), sched({ id: "off", paused: true })]);
    expect(cli("slots", join(T, "none"), list, "2026-11-09T09:05:00Z").out)
      .toBe("weekly 1794214800 2026-11-09T09:00:00Z\nweekly 1794819600 2026-11-16T09:00:00Z\n");
  });
  test("next is the first slot after now and after since, none while paused", () => {
    expect(z(next(sched(), now) as number)).toBe("2026-11-16T09:00:00Z");
    expect(z(next(sched({ since: "2026-11-20T00:00:00Z" }), now) as number)).toBe("2026-11-23T09:00:00Z");
    expect(next(sched({ paused: true }), now)).toBeNull();
  });
});

describe("records", () => {
  test("counts come from a FINDINGS line alone", () => {
    expect(findings("FINDINGS: none")).toEqual({});
    expect(findings("FINDINGS: critical=0 high=2 potential-high=1")).toEqual({ critical: 0, high: 2, "potential-high": 1 });
    for (const l of ["", "FINDINGS: High=2", "FINDINGS: high=2,low=1", "FINDINGS: high=-1", "findings: high=2"]) expect(findings(l)).toBeNull();
  });
  test("window use is the fall in headroom within one window, never across a reset or with no 5-hour window", () => {
    const a: Reading = { week_left_pct: 80, week_resets_at: 2e9, session_left_pct: 90, session_resets_at: 1.9e9, session_window: null, observed_at: 1e9 };
    const b: Reading = { ...a, week_left_pct: 71, week_resets_at: 2e9 + 120, session_left_pct: 40, observed_at: 1e9 + 3600 };
    expect([used(a, b, "week_left_pct"), used(a, b, "session_left_pct")]).toEqual([9, 50]);
    expect(used(a, { ...b, week_resets_at: 2e9 + 7 * 86400 }, "week_left_pct")).toBeNull();
    expect(used(a, { ...b, observed_at: a.observed_at }, "week_left_pct")).toBeNull();
    expect(used({ ...a, session_window: "none" }, b, "session_left_pct")).toBeNull();
    expect(used(a, null, "week_left_pct")).toBeNull();
  });
  test("a stored record is held to its shape: schema, owner, status, lane, names and one-line text", () => {
    const cases: [Partial<Run> | Record<string, unknown>, RegExp][] = [[{ schema: "x" }, /not an orchy.schedule-run\/1/],
      [{ schedule: "other" }, /a record of other, not weekly/], [{ status: "lost" }, /status is/], [{ lane: "x" }, /lane is harden/],
      [{ key: "../x" }, /key is a name/], [{ reason: "a‮b" }, /reason is not one line/], [{ cost_usd: -1 }, /not negative/], [{ start: "now" }, /start is not a time/]];
    for (const [o, m] of cases) expect(() => record({ ...run(), ...o }, "weekly")).toThrow(m);
    expect(record(run(), "weekly")).toEqual(run());
  });
  test("a start's record through ts_run: begun before anything runs, launched once, settled, then as each resume left it", () => {
    const root = join(T, "h1", "runs"), F = "20261109T090700Z.json";
    mkdirSync(join(T, "h1"));
    const reading = JSON.stringify({ week_left_pct: 80, week_resets_at: 2e9, session_left_pct: 90, session_resets_at: 1.9e9, observed_at: 1e9 });
    const B = ["begin", root, "weekly", "2026-11-09T09:00:00Z", "2026-11-09T09:07:00Z", KEY, "harden-security"];
    expect(cli(...B)).toEqual({ code: 0, out: `${F}\n`, err: "" });
    expect(cli(...B)).toMatchObject({ code: 1, err: `refused: runs/weekly/${F} exists\n` });
    expect(cli("launched", root, "weekly", F, "atlas", reading).out).toBe("atlas\n");
    for (const again of [["launched", root, "weekly", F, "beacon", "null"], ["skip", root, "weekly", "2026-11-09T09:00:00Z", "harden-security", "2026-11-09T09:08:00Z", "late", F]])
      expect(cli(...again).code).toBe(1);
    const seg = (cost_usd: number, ended: string) => ({ key: KEY, cost_usd, ended });
    const receipt = (...s: object[]) => JSON.stringify({ lanes: [{ lane: "harden-security", runs: [...s, { key: "harden-security-202611020907", cost_usd: 9, ended: "2026-11-02T10:00:00Z" }] }] });
    const end = JSON.stringify({ ...JSON.parse(reading), week_left_pct: 72, observed_at: 1e9 + 7200 });
    const settle = (marker: string, findings: string, r: string) => cli("settle", root, "weekly", F, marker, findings, r, "", end, "2026-11-09T11:00:00Z").out;
    const rec = () => JSON.parse(readFileSync(join(root, "weekly", F), "utf8"));
    expect(settle("LEAD_BLOCKED: the tree was dirty", "FINDINGS: high=1", receipt(seg(1.5, "2026-11-09T10:00:00Z")))).toBe(`weekly ${F} blocked\n`);
    expect(rec()).toMatchObject({ status: "blocked", account: "atlas", marker: "LEAD_BLOCKED", detail: "the tree was dirty", counts: { high: 1 }, cost_usd: 1.5,
      end: "2026-11-09T10:00:00Z", window: { week_used_pct: 8, session_used_pct: 0 } });
    const both = receipt(seg(1.5, "2026-11-09T10:00:00Z"), seg(0.25, "2026-11-09T10:40:00Z"));
    expect(settle("", "", both)).toBe(`weekly ${F} started\n`);
    expect(rec()).toMatchObject({ status: "started", marker: null, detail: null, counts: null, end: null, cost_usd: 1.75,
      window: { week_used_pct: null, session_used_pct: null } });
    expect(settle("LEAD_DONE", "FINDINGS: none", both)).toBe(`weekly ${F} done\n`);
    expect(rec()).toMatchObject({ status: "done", detail: null, counts: {}, cost_usd: 1.75, end: "2026-11-09T10:40:00Z", window: { week_used_pct: 8 } });
    for (let d = 10; d <= 16; d++) expect(cli("skip", root, "weekly", `2026-11-${d}T09:00:00Z`, "harden-security", `2026-11-${d}T09:01:00Z`, "no account").code).toBe(0);
    expect(readdirSync(join(root, "weekly")).sort()).toEqual([11, 12, 13, 14, 15, 16].map((d) => `202611${d}T090100Z.json`));
  });
  test("a start killed before learning its account settles with the one .started names; one that never launched becomes its skip", () => {
    const root = join(T, "h2", "runs"), S = "2026-11-09T09:00:00Z";
    mkdirSync(join(T, "h2"));
    const begin = (start: string, key: string) => cli("begin", root, "weekly", S, start, key, "harden-security").out.trim();
    const a = begin("2026-11-09T09:07:00Z", KEY), b = begin("2026-11-09T09:08:00Z", "harden-security-202611090908");
    cli("settle", root, "weekly", a, "LEAD_DONE", "", "null", "beacon", "null", "2026-11-09T11:00:00Z");
    expect(cli("skip", root, "weekly", S, "harden-security", "2026-11-09T09:09:00Z", "harden-security: install exit 1", b).out).toBe(`${b}\n`);
    const r = (f: string) => JSON.parse(readFileSync(join(root, "weekly", f), "utf8"));
    expect([r(a).status, r(a).account, r(a).end]).toEqual(["done", "beacon", "2026-11-09T11:00:00Z"]);
    expect(r(b)).toMatchObject({ status: "skipped", key: null, start: "2026-11-09T09:08:00Z", end: "2026-11-09T09:09:00Z", reason: "harden-security: install exit 1" });
    expect(cli("settle", root, "weekly", b, "LEAD_DONE", "", "null", "", "null", "2026-11-09T11:00:00Z").err).toBe(`refused: runs/weekly/${b} had no lead\n`);
  });
  test("a planted file is an error, never data, and a symlinked runs directory refuses", () => {
    const root = join(T, "h3", "runs");
    mkdirSync(join(root, "weekly"), { recursive: true });
    writeFileSync(join(root, "weekly", "20261101T000000Z.json"), JSON.stringify({ ...run(), status: "done", schedule: "other" }));
    expect(runs(root, "weekly").errors).toEqual([{ file: "runs/weekly/20261101T000000Z.json", error: "a record of other, not weekly" }]);
    const fake = join(T, "h4");
    mkdirSync(fake);
    symlinkSync(root, join(fake, "runs"));
    expect(() => runs(join(fake, "runs"), "weekly")).toThrow("must be a directory owned by this user, not a symlink");
  });
});

describe("view", () => {
  test("why a run would not start, in order, and the lines the snapshot prints", () => {
    const now = t("2026-11-09T09:05:00Z"), root = join(T, "none");
    const why = (s: Schedule, f = NO_FACTS) => view(root, [s], f, now).schedules[0].why;
    expect(why(sched({ paused: true }), { ...NO_FACTS, mode: "triage" })).toBe("paused");
    expect(why(sched(), { ...NO_FACTS, mode: "triage", hold: "other:peer-x" })).toBe("the program is in triage mode");
    expect(why(sched(), { ...NO_FACTS, hold: "other:peer-x", open: ["harden-security"] })).toBe("held by other:peer-x");
    expect(why(sched(), { ...NO_FACTS, open: ["harden-security"] })).toBe("the worktree harden-security is still open");
    const v = view(root, [sched(), sched({ id: "tue", focus: "quality", when: "tue 09:00 UTC", skip_filed: true, paused: true })], NO_FACTS, now);
    expect(v.schedules.map(line)).toEqual(["DUE weekly: harden security high, slot 2026-11-09T09:00:00Z; ORCHY schedule start weekly",
      "tue: harden quality high, skips filed, tue 09:00 UTC; paused"]);
    expect(v.schedules[0]).toMatchObject({ lane: "harden-security", due: "2026-11-09T09:00:00Z", next: "2026-11-16T09:00:00Z", will_start: true, runs: [] });
    const e = view(root, [sched({ id: "tue", when: "tue 09:00 UTC", since: "2026-11-09T00:00:00Z" })], NO_FACTS, now).schedules[0];
    const last = (r: Run, alive: boolean) => line({ ...e, runs: [{ ...r, alive }] });
    expect(last(run({ status: "blocked", detail: "the tree was dirty" }), true))
      .toBe(`tue: harden security high, tue 09:00 UTC; next 2026-11-10T09:00:00Z; last blocked 2026-11-09T09:07:00Z: the tree was dirty; running ${KEY} on atlas`);
    expect(last(run(), false)).toEndWith(`; last started 2026-11-09T09:07:00Z; ${KEY} has no live lead and no final marker`);
  });
});
