import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { gateLine, judge, plan, type Row, roster } from "../skills/harden/scripts/headroom.ts";

const T = mkdtempSync(join(tmpdir(), "harden-headroom-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));
const NOW = 1_800_000_000;
const row = (account: string, o: Partial<Row> = {}, now = NOW): Row => ({ account, email: `${account}@example.com`, session_left_pct: 80,
  session_window: "present", week_left_pct: 90, premium_model: "Fable", premium_left_pct: 70, observed_at: now - 240, session_resets_at: now + 3600,
  week_resets_at: now + 86400, premium_resets_at: now + 86400, note: "", ...o });
// keys differ from labels, as a roster's directory names may
const LIST = "main           /x/slot\natlas          /x/acct/k-atlas  (token, 300d left)\nbeacon         /x/acct/k-beacon\ncedar          /x/acct/k-cedar\ndelta          /x/acct/k-delta\n";
const ROSTER = roster(LIST);
const NAMES = /atlas|beacon|cedar|delta/;

describe("headroom", () => {
  test("judge holds every applicable bucket to its floor; a spent bucket, a note or an unknown value fails", () => {
    const cases: [Partial<Row> | null, string, string | null][] = [
      [{}, "sonnet", null], [null, "sonnet", "no reading in the snapshot"],
      [{ week_left_pct: 24 }, "sonnet", "24% of the week left, under the 25% floor"],
      [{ session_left_pct: 29 }, "sonnet", "29% of the 5-hour window left, under the 30% floor"],
      [{ session_left_pct: 10, session_resets_at: NOW - 1 }, "sonnet", null],
      [{ session_window: "none", session_left_pct: null }, "sonnet", null],
      [{ session_window: "none", session_left_pct: null, week_left_pct: 20 }, "sonnet", "20% of the week left, under the 25% floor"],
      [{ session_window: "unknown", session_left_pct: null }, "sonnet", "its 5-hour window headroom is unknown"],
      [{ observed_at: NOW - 7201 }, "sonnet", "the latest reading is 2 h old"],
      [{ week_resets_at: NOW - 1 }, "sonnet", "its week reset after the latest reading"],
      [{ week_left_pct: 0, observed_at: NOW - 99_999 }, "sonnet", "its week is spent"],
      [{ week_left_pct: null }, "sonnet", "its week headroom is unknown"],
      [{ note: "logged out" }, "sonnet", "claude-usage notes logged out"],
      [{ premium_left_pct: 20 }, "fable", "20% of the Fable week left, under the 25% floor"], [{ premium_left_pct: 20 }, "opus", null],
      [{ premium_model: "-", premium_left_pct: null }, "fable", "its Fable week headroom is unknown"],
      [{ premium_left_pct: 5, premium_resets_at: NOW - 1 }, "fable", null],
    ];
    for (const [o, model, why] of cases) expect([o, model, judge(o === null ? undefined : row("atlas", o), model, NOW)]).toEqual([o, model, why]);
  });

  test("the gate's line names the reading and the floors, or why it stops", () => {
    const line = (o: Partial<Row> | null, model = "sonnet") => gateLine(o === null ? undefined : row("cedar", o), model, NOW).line;
    expect(line({})).toBe("ok: 90% of the week and 80% of the 5-hour window left (floors 25% and 30%), read 4 min ago");
    expect(line({ session_window: "none", session_left_pct: null })).toBe("ok: 90% of the week left (floor 25%; no 5-hour window), read 4 min ago");
    expect(line({}, "fable")).toBe("ok: 90% of the week, 80% of the 5-hour window and 70% of the Fable week left (floors 25%, 30% and 25%), read 4 min ago");
    expect(line({ session_left_pct: 18 })).toBe("stop: 18% of the 5-hour window left, under the 30% floor (read 4 min ago)");
    expect(line({ observed_at: NOW - 3 * 3600 })).toBe("stop: the latest reading is 3 h old; run claude-usage to take one");
    expect(line(null)).toBe("stop: this session's account has no reading in the snapshot; run claude-usage to take one");
  });

  test("fanout deals eligible others in rank order, this session last, and skips exclusions, aliases and accounts under a floor", () => {
    const keys = (rows: Row[], never: string[] | null = [], model = "sonnet", clusters = ["a", "b", "c"]) =>
      plan({ rows, roster: ROSTER, current: "cedar", never, model, clusters, passes: 1, now: NOW }).slots.map((s) => s.key);
    const all = [row("beacon"), row("atlas"), row("cedar")];
    expect(keys(all)).toEqual(["k-beacon", "k-atlas", null]);
    expect([keys(all, ["atlas"]), keys(all, ["k-atlas"])]).toEqual([["k-beacon", null, "k-beacon"], ["k-beacon", null, "k-beacon"]]);
    // excluded, the caller takes nothing while another account can
    expect(keys(all, ["cedar"])).toEqual(["k-beacon", "k-atlas", "k-beacon"]);
    expect(keys([row("beacon", { email: "CEDAR@example.com" }), row("atlas"), row("cedar")])).toEqual(["k-atlas", null, "k-atlas"]);
    expect(keys([row("beacon", { email: "x@example.com" }), row("atlas", { email: "x@example.com" }), row("cedar")])).toEqual(["k-beacon", null, "k-beacon"]);
    expect(keys([row("beacon", { email: "-" }), row("atlas", { email: "" }), row("cedar", { email: "-" })])).toEqual(["k-beacon", "k-atlas", null]);
    expect(keys([row("beacon", { premium_left_pct: 20 }), row("atlas", { premium_model: "-" }), row("cedar"), row("delta")], [], "fable"))
      .toEqual(["k-delta", null, "k-delta"]);
    expect(keys([row("beacon", { week_left_pct: 10 }), row("cedar")])).toEqual([null, null, null]);
    expect(keys(all, null)).toEqual([null, null, null]);
  });

  test("two passes go to different accounts, and the methodology maps each slot to a letter, never a name", () => {
    const p = plan({ rows: [row("atlas", { observed_at: NOW - 600 }), row("beacon"), row("cedar")], roster: ROSTER, current: "cedar", never: [],
      model: "opus", clusters: ["auth", "ui"], passes: 2, now: NOW });
    expect(p.slots).toEqual([{ cluster: "auth", pass: 1, key: "k-atlas" }, { cluster: "auth", pass: 2, key: "k-beacon" },
      { cluster: "ui", pass: 1, key: null }, { cluster: "ui", pass: 2, key: "k-atlas" }]);
    expect(p.methodology).toBe("Claude cluster agents spread over 2 other roster accounts (letters, not names): A took auth, ui pass 2; B took auth pass 2; "
      + "this session took ui. Readings at most 10 min old; floors 25% of the week and 30% of a 5-hour window.");
    const none = plan({ rows: [row("cedar")], roster: ROSTER, current: "cedar", never: [], model: "fable", clusters: ["auth"], passes: 1, now: NOW });
    expect(none.methodology).toBe("every Claude cluster agent ran in this session: no other roster account passed the floors (25% of the week, 30% of a "
      + "5-hour window and 25% of the Fable week) on a reading under 2 h old.");
    expect(`${p.methodology}${none.methodology}`).not.toMatch(NAMES);
  });

  test("the CLI reads the cached snapshot only, honours an exclusion file, and stops or stays in session without a snapshot", () => {
    const cuDir = join(T, "cu"), bin = join(T, "bin"), now = Math.floor(Date.now() / 1000);
    mkdirSync(cuDir);
    mkdirSync(bin);
    symlinkSync(process.execPath, join(bin, "bun"));
    writeFileSync(join(cuDir, "list.txt"), LIST);
    writeFileSync(join(cuDir, "current.txt"), "cedar\n");
    writeFileSync(join(cuDir, "rows.json"), JSON.stringify([row("atlas", {}, now), row("beacon", { week_left_pct: 10 }, now), row("cedar", {}, now)]));
    writeFileSync(join(T, "never.json"), JSON.stringify({ never: ["atlas"] }));
    const mocks = join(import.meta.dir, "mocks/orchy"), run = join(import.meta.dir, "../skills/harden/scripts/run.sh");
    const cli = (path: string, ...a: string[]) => {
      const r = Bun.spawnSync([run, "headroom", ...a], { env: { ...process.env, PATH: path, MOCK_CU: cuDir }, timeout: 20_000 });
      return { code: r.exitCode, out: r.stdout.toString() };
    };
    // the mock fails any `--json` without `--cached`
    const withCu = `${mocks}:${dirname(process.execPath)}:/usr/bin:/bin`, without = `${bin}:/usr/bin:/bin`;
    const fan = cli(withCu, "fanout", "--model", "sonnet", "auth", "ui");
    expect(fan.out.split("\n").slice(0, 2)).toEqual(["auth 1 =k-atlas", "ui 1 session"]);
    expect(fan.out).toMatch(/^methodology: Claude cluster agents spread over 1 other roster account .*A took auth; this session took ui\./m);
    expect(fan.out.split("\n")[2]).not.toMatch(NAMES);
    expect(cli(withCu, "fanout", "--model", "sonnet", "--exclude-from", join(T, "never.json"), "auth").out).toStartWith("auth 1 session\n");
    expect(cli(withCu, "gate", "--model", "opus")).toEqual({ code: 0, out: "ok: 90% of the week and 80% of the 5-hour window left (floors 25% and 30%), read 4 min ago\n" });
    expect(cli(without, "gate", "--model", "opus").out).toStartWith("stop: claude-usage is not on PATH");
    rmSync(join(cuDir, "rows.json"));
    expect(cli(withCu, "gate", "--model", "opus")).toEqual({ code: 1, out: "stop: claude-usage has no snapshot to read; run claude-usage once\n" });
    expect(cli(withCu, "fanout", "--model", "opus", "auth").out).toStartWith("auth 1 session\nmethodology: every Claude cluster agent ran in this session");
    expect(cli(withCu, "fanout", "--model", "opus", "../auth").code).toBe(2);
  });
});
