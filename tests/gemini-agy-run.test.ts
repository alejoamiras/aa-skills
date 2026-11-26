// The review leg's one-shot run (engines/agy.ts run, engines/agy-run.ts), in-process, against a stand-in agy compiled
// from tests/fixtures/agy-stub.ts and driven by its scripts, with a temp home holding a pin, settings and a canary key:
// no real agy, no real key, no network. Key values are compared only as booleans, so a failing assertion never prints one.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  closeSync, existsSync, linkSync, mkdirSync, mkdtempSync, openSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, statSync, symlinkSync, unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { turnFile } from "../skills/gemini/engines/agy-run.ts";
import { LIMITS, type RunDeps, run } from "../skills/gemini/engines/agy.ts";

// Every third character is a capital, so no 5-character run of it occurs in timestamps, hex ids or plain words.
const CANARY = "AIzaQz1Rx2Sw3Tv4Uu5Vt6Ws7Xr8Yq9Zp0Ao1Bn2Cm3";
// A key the key file no longer holds: only the key-line check catches it.
const OLD = "fake-old-key-dddd-eeee-ffff";
// The stub's conversation id.
const CONVERSATION = "8766c9db-47ac-4645-97cc-bd1cbe524c30";
const UID = process.getuid?.() ?? 0;
const SHIMS = join(import.meta.dir, "..", "skills", "gemini", "shims");
const root = realpathSync(mkdtempSync(join(tmpdir(), "gemini-run-test-")));
const WORKER_ENV = {
  WORKER_PATH: "/usr/bin:/bin", WORKER_USER: "tester", WORKER_LOGNAME: "tester", WORKER_SHELL: "/bin/bash", WORKER_LANG: "C.UTF-8", WORKER_TMPDIR: root,
  SSH_AUTH_SOCK: "/run/agent.sock", WORKER_SSH_AUTH_SOCK: "/run/agent.sock",
};
const FLAGS = ["--dangerously-skip-permissions", "--input-format", "stream-json", "--output-format", "stream-json", "--model", "gemini-4-neon", "--effort", "high", "--settings"];
const OPEN = '{"modelProvider":"gemini","permissions":{"deny":["write_file(*)"]}}';
const WRAP = '{"modelProvider":"gemini","permissions":{"deny":["command(*)","write_file(*)","read_file(*)"]}}';
const ENV_NAMES = [
  "AGY_CLI_DISABLE_AUTO_UPDATE", "CREW_WORKER", "GEMINI_API_KEY", "GEMINI_WORKER", "GEMINI_WORKER_ID", "GIT_TERMINAL_PROMPT", "HOME", "LANG", "LOGNAME", "PATH",
  "SHELL", "TERM", "TMPDIR", "USER", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
];
const FINE = [{ answer: "fine" }, { result: "SUCCESS", response: "fine" }];
let stubBin = "";
let stubSha = "";

beforeAll(() => {
  stubBin = join(root, "agy-stub");
  const r = spawnSync(process.execPath, ["build", "--compile", "--outfile", stubBin, join(import.meta.dir, "fixtures", "agy-stub.ts")], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`the stub did not compile: ${r.stderr}`);
  stubSha = createHash("sha256").update(readFileSync(stubBin)).digest("hex");
}, 120_000);
// A failed test can leave a stub or its HUP- and TERM-ignoring child running; agy's TMPDIR, and so every process it
// starts, is inside a run dir under root.
afterAll(() => {
  for (const pid of readdirSync("/proc").filter((n) => /^[0-9]+$/.test(n) && Number(n) !== process.pid)) {
    try {
      if (statSync(`/proc/${pid}`).uid === UID && `\0${readFileSync(`/proc/${pid}/environ`, "latin1")}`.includes(`\0TMPDIR=${root}/`)) process.kill(Number(pid), "SIGKILL");
    } catch {
      // gone, or another user's
    }
  }
  rmSync(root, { recursive: true, force: true });
});

let seq = 0;
type Home = { dir: string; bin: string };
// A hard link per home to the one compiled stub; stub.json in it drives the stub.
function makeHome(settings: object = { modelProvider: "gemini" }): Home {
  const dir = join(root, `home${++seq}`);
  for (const d of [".agents", "bin", ".gemini/antigravity-cli", ".gemini/config", ".config/gemini"]) mkdirSync(join(dir, d), { recursive: true });
  const bin = join(dir, "bin", "agy");
  linkSync(stubBin, bin);
  writeFileSync(join(dir, ".agents", "gemini-agy"), `path=${bin}\nsha256=${stubSha}\nversion=1.5.15-stub\n`, { mode: 0o600 });
  writeFileSync(join(dir, ".gemini/antigravity-cli/settings.json"), JSON.stringify(settings));
  writeFileSync(join(dir, ".config/gemini/.env"), `GEMINI_API_KEY=${CANARY}\n`, { mode: 0o600 });
  return { dir, bin };
}

type Ctx = { home: Home; top: string; dir: string };
function setup(o: { home?: Home; top?: string } = {}): Ctx {
  const home = o.home ?? makeHome();
  const top = o.top ?? join(root, `top${++seq}`);
  mkdirSync(top, { recursive: true });
  mkdirSync(join(home.dir, ".cache", "gemini-leg"), { recursive: true });
  const dir = join(home.dir, ".cache", "gemini-leg", `run${++seq}`);
  mkdirSync(dir, { mode: 0o700 });
  return { home, top, dir };
}

const walk = (dir: string): string[] =>
  readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : e.isFile() ? [join(dir, e.name)] : []));
const listing = (x: Ctx) => walk(x.dir).map((f) => `${relative(x.dir, f)} ${statSync(f).size}`).sort();
const leaks = (text: string) => Array.from({ length: CANARY.length - 4 }, (_, i) => CANARY.slice(i, i + 5)).some((w) => text.includes(w));
// biome-ignore lint/suspicious/noExplicitAny: the stub's own records
const records = (x: Ctx): Record<string, any>[] => {
  const dir = join(x.dir, "home", "stub");
  if (!existsSync(dir)) return [];
  const all = readdirSync(dir).filter((f) => /^[0-9]+\.json$/.test(f)).map((f) => JSON.parse(readFileSync(join(dir, f), "utf8")));
  return all.sort((a, b) => Number(a.start) - Number(b.start) || a.pid - b.pid);
};
const received = (x: Ctx, pid: number) => readFileSync(join(x.dir, "home", "stub", `${pid}.in.ndjson`), "utf8");

// Every live process holding the marker or in one of sids.
function leftovers(marker: string, sids: number[]): number[] {
  const out: number[] = [];
  for (const name of readdirSync("/proc").filter((n) => /^[0-9]+$/.test(n))) {
    try {
      const stat = readFileSync(`/proc/${name}/stat`, "utf8");
      const f = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      if (f[0] === "Z") continue;
      const env = readFileSync(`/proc/${name}/environ`, "latin1");
      if (sids.includes(Number(f[3])) || `\0${env}`.includes(`\0GEMINI_WORKER_ID=${marker}\0`)) out.push(Number(name));
    } catch {
      // gone, or another user's
    }
  }
  return out;
}

// whole: a run whose stub prints the key split inside one string, which the log keeps; no file may hold it whole.
// late: agy starts as a bun child that execs the stub that many ms after the spawn returns.
type Opts = { cfg?: object; prompt?: string; turn?: number; conversation?: string; clock?: () => number; whole?: boolean; late?: number };
// One engine run. After it: no run-dir file holds a piece of the canary, and nothing a stub started is left.
async function go(x: Ctx, o: Opts = {}) {
  writeFileSync(join(x.home.dir, "stub.json"), JSON.stringify(o.cfg ?? { script: FINE }));
  const turn = o.turn ?? 1;
  const out: string[] = [];
  // Counted here: a stub swept as it starts never writes its record.
  let spawns = 0;
  const deps: RunDeps = {
    home: x.home.dir, uid: UID, now: () => Date.now(), timers: { set: (fn, ms) => setTimeout(fn, ms), clear: (h) => clearTimeout(h as ReturnType<typeof setTimeout>) },
    limits: { ...LIMITS, grace: 300, poll: 20 },
    spawn: (file, args, opts) => {
      spawns++;
      if (o.late === undefined) return spawn(file, args, opts);
      return spawn(process.execPath, [join(import.meta.dir, "fixtures", "exec-later.ts"), String(o.late), x.home.bin, ...args], { ...opts, argv0: process.execPath });
    },
    signals: () => {}, input: () => {},
    out: (line) => out.push(line), env: WORKER_ENV, stdin: async () => Buffer.from(o.prompt ?? "Review the repository."), clock: o.clock ?? (() => performance.now()),
  };
  const code = await run([x.dir, x.top, "gemini-4-neon", "high", "100000", String(turn), ...(turn > 1 ? [o.conversation ?? CONVERSATION] : [])], deps);
  const holds = o.whole ? (text: string) => text.includes(CANARY) : leaks;
  for (const f of walk(x.dir)) expect([relative(x.dir, f), holds(readFileSync(f, "latin1"))]).toEqual([relative(x.dir, f), false]);
  for (const r of records(x)) expect(leftovers(r.env.GEMINI_WORKER_ID, [r.sid, r.child].filter(Boolean))).toEqual([]);
  const read = (name: string, ext: string) => {
    const p = join(x.dir, turnFile(turn, name, ext));
    return existsSync(p) ? readFileSync(p, "utf8") : undefined;
  };
  const result = read("result", "json");
  // biome-ignore lint/suspicious/noExplicitAny: result.json and log entries are free-form JSON
  const log: Record<string, any>[] = (read("log", "ndjson") ?? "").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  return { code, out, result: result === undefined ? undefined : JSON.parse(result), response: read("response", "md"), log, spawns };
}

// Whether the run's log comes to hold text within 5 s; polled every 5 ms, so it answers within one of the sweep's 50 ms waits.
async function logged(x: Ctx, text: string): Promise<boolean> {
  const log = join(x.dir, "log.ndjson");
  for (const end = Date.now() + 5000; Date.now() < end; await Bun.sleep(5)) if (existsSync(log) && readFileSync(log, "utf8").includes(text)) return true;
  return false;
}

// Makes the engine's next write to the run's file name fail as on a full disk, once the log holds after. The engine
// runs in this process: its descriptor, once closed, is the lowest free number, so opening /dev/full until one lands
// there swaps it in place.
async function full(x: Ctx, name: string, after: string): Promise<boolean> {
  if (!(await logged(x, after))) return false;
  const target = join(x.dir, name);
  const fd = readdirSync("/proc/self/fd").map(Number).find((n) => {
    try {
      return readlinkSync(`/proc/self/fd/${n}`) === target;
    } catch {
      return false;
    }
  });
  if (fd === undefined) return false;
  closeSync(fd);
  const spare: number[] = [];
  for (let got = openSync("/dev/full", "w"); got !== fd; got = openSync("/dev/full", "w")) spare.push(got);
  for (const n of spare) closeSync(n);
  return true;
}

describe("run", () => {
  test("agy runs with the open flags in the top level, the private home's environment and nothing of the caller's; every file is private", async () => {
    const x = setup();
    const r = await go(x, { cfg: { script: [{ answer: "fine", usage: [1000, 10, 500] }, { result: "SUCCESS", response: "fine" }] }, prompt: "Review it." });
    expect([r.code, r.response, r.result.verdict, r.result.reason, r.result.response]).toEqual([0, "fine", "answered", null, "response.md"]);
    expect([r.result.in, r.result.out, r.result.cached, r.result.counted]).toEqual([1000, 10, 500, 1510]);
    const [rec, ...more] = records(x);
    const priv = join(x.dir, "home");
    expect([more.length, rec.args, rec.cwd, rec.argv0, rec.keyMatches, rec.envNames]).toEqual([0, [...FLAGS, OPEN], x.top, x.home.bin, true, ENV_NAMES]);
    const e = rec.env;
    expect([e.HOME, e.TMPDIR, e.XDG_CONFIG_HOME, e.XDG_DATA_HOME, e.XDG_STATE_HOME, e.XDG_CACHE_HOME, e.AGY_CLI_DISABLE_AUTO_UPDATE, e.PATH]).toEqual([
      priv, join(priv, "tmp"), join(priv, ".config"), join(priv, ".local/share"), join(priv, ".local/state"), join(priv, ".cache"), "true", `${SHIMS}:/usr/bin:/bin`,
    ]);
    expect(received(x, rec.pid)).toBe(`${JSON.stringify({ event: "user", message: { content: "Review it." } })}\n`);
    const text = (p: string) => readFileSync(join(x.dir, p), "utf8");
    expect([text("prompt.md"), text("session_id"), text("home/.gemini/antigravity-cli/settings.json")]).toEqual(["Review it.", `${CONVERSATION}\n`, '{"modelProvider":"gemini"}\n']);
    const mode = (p: string) => (statSync(join(x.dir, p)).mode & 0o777).toString(8);
    const files = ["prompt.md", "response.md", "log.ndjson", "stderr.txt", "result.json", "session_id", "home/.gemini/antigravity-cli/settings.json"];
    expect(files.map(mode)).toEqual(files.map(() => "600"));
    expect(["home", "home/tmp", "home/.gemini", "home/.gemini/antigravity-cli"].map(mode)).toEqual(["700", "700", "700", "700"]);
  }, 30_000);

  test("a tripwire, or an init or a line the engine cannot trust, withholds the answer, also after the result, and leaves nothing running", async () => {
    // A schedule step that waited for the 12-minute silence clock would outlast this test's timeout.
    const cases: [string, object, string | null, string | null, number][] = [
      ["another permission mode", { init: { mode: "request-review" }, script: FINE }, "mode", "mode", 0],
      ["another model", { init: { model: "gemini-4-carbon" }, script: FINE }, "model", "model", 0],
      ["the model with the effort as its suffix", { init: { model: "gemini-4-neon-high" }, script: FINE }, null, null, 0],
      ["no init", { init: false, script: FINE }, "error", null, 0],
      ["a schedule step left ACTIVE", { child: true, script: [{ tool: "schedule", state: "ACTIVE" }, { hold: true }] }, "tool", "tool", 0],
      ["a schedule step after the result", { script: [...FINE, { sleep: 300 }, { tool: "schedule", state: "ACTIVE" }] }, "tool", "tool", 0],
      ["a malformed line after the result", { script: [...FINE, { raw: "MALFORMED {" }] }, "error", null, 11],
    ];
    for (const [label, cfg, reason, tripwire, unparsed] of cases) {
      const x = setup();
      const r = await go(x, { cfg });
      expect([label, r.code, r.result.reason, r.result.tripwire, r.result.unparsed_bytes, r.response === undefined]).toEqual([
        label, reason ? 1 : 0, reason, tripwire, unparsed, reason !== null,
      ]);
      expect(walk(x.dir).some((f) => readFileSync(f, "utf8").includes("MALFORMED"))).toBe(false);
    }
  }, 60_000);

  test("a line past 8 MiB ends the call as it crosses, newline or not; a tool output past 64 KiB is kept capped with its length", async () => {
    const over = 8 * 1024 * 1024 + 1;
    const x = setup();
    const r = await go(x, { cfg: { script: [{ answer: "partial", usage: [1000, 10, 500] }, { bytes: over }, ...FINE] } });
    expect([r.code, r.result.reason, r.response, r.result.response, r.result.in, r.result.out, r.result.cached]).toEqual([1, "error", undefined, null, 1000, 10, 500]);
    expect(r.result.unparsed_bytes).toBeGreaterThan(over - 1);
    expect(readdirSync(x.dir).sort()).toEqual(["home", "log.ndjson", "prompt.md", "result.json", "session_id", "stderr.txt"]);
    // Held open with no newline, only the bound can end it before the clocks.
    const held = await go(setup(), { cfg: { script: [{ bytes: over, newline: false }, { hold: true }] } });
    expect([held.code, held.result.reason]).toEqual([1, "error"]);
    const big = await go(setup(), { cfg: { script: [{ tool: "run_command", output: "y".repeat(100 * 1024) }, ...FINE] } });
    const info = big.log.find((e) => e.ev?.step_update?.tool_info?.output_bytes)?.ev.step_update.tool_info;
    expect([big.code, info.output, info.output_bytes, big.result.capped_bytes, big.result.tools]).toEqual([0, "y".repeat(64 * 1024), 100 * 1024, 100 * 1024, 1]);
  }, 60_000);

  test("the key printed plain, JSON-escaped, on stderr or split across deltas reaches no file; the response cites paths repo-relative", async () => {
    const home = makeHome();
    const x = setup({ home, top: join(home.dir, "repo") });
    const half = CANARY.length >> 1;
    const escaped = [...CANARY].map((ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, "0")}`).join("");
    const step = { event: "step_update", step_update: { step_index: 9, state: "DONE", step_type: "tool", tool_name: "run_command", tool_info: { name: "run_command", output: "ESCAPED" } } };
    const answer = `one ${CANARY} two; see file://${x.top}/a/b.ts, ${x.top}/a/b.ts and ${home.dir}/x`;
    const script = [
      { tool: "run_command", output: `GEMINI_API_KEY=${CANARY}` }, { raw: JSON.stringify(step).replace("ESCAPED", escaped) }, { err: `leaked ${CANARY}` },
      { delta: `one ${CANARY.slice(0, half)}` }, { delta: `${CANARY.slice(half)} two;` }, { answer: " see" }, { result: "SUCCESS", response: answer },
    ];
    const r = await go(x, { cfg: { script } });
    expect([r.code, r.response]).toEqual([0, "one [redacted] two; see a/b.ts, a/b.ts and ~/x"]);
    expect(walk(x.dir).some((f) => readFileSync(f, "utf8").includes(escaped))).toBe(false);
    expect(readFileSync(join(x.dir, "stderr.txt"), "utf8")).toBe("leaked [redacted]\n");
    // Whole only once the top level's prefix is cut out of the response; the log keeps it split, as agy sent it.
    const y = setup({ home, top: join(home.dir, "repo2") });
    const joined = await go(y, { whole: true, cfg: { script: [{ answer: "x" }, { result: "SUCCESS", response: `${CANARY.slice(0, half)}${y.top}/${CANARY.slice(half)}` }] } });
    expect(joined.response).toBe("[redacted]");
    for (const prompt of [`use ${CANARY}`, `notes\nGEMINI_API_KEY=${OLD}\n`]) {
      const y = setup();
      const k = await go(y, { prompt });
      expect([k.code, k.out, records(y).length, readdirSync(y.dir)]).toEqual([2, ["ERROR: the prompt holds the Gemini key: stop and tell the owner"], 0, []]);
    }
  }, 30_000);

  test("a crossing under 1.15 times the limit gets the wrap-up; its cumulative result and a step after the kill are not counted", async () => {
    const x = setup();
    const cfg = {
      script: [{ answer: "a", usage: [60_000, 0, 0] }, { answer: "b", usage: [50_000, 0, 0] }, { answer: "c", usage: [1, 0, 0] }, { hold: true }],
      resume: [{ answer: "wrapped", usage: [2_000, 0, 0] }, { result: "SUCCESS", response: "wrapped", usage: [500_000, 0, 0] }],
    };
    const r = await go(x, { cfg });
    expect([r.code, r.response, r.result.in, r.result.counted]).toEqual([0, "wrapped", 112_000, 112_000]);
    const [, wrap] = records(x);
    expect(wrap.args).toEqual([...FLAGS, WRAP, "--conversation", CONVERSATION]);
    expect(JSON.parse(received(x, wrap.pid)).message.content).toBe("Your budget is spent. Answer now from what you have already read.");
  }, 30_000);

  test("a wrap-up is killed at its first step past 1.15 times the limit, and a crossing already past that gets none", async () => {
    const x = setup();
    const resume = [{ answer: "b", usage: [3_000, 0, 0] }, { answer: "c", usage: [3_000, 0, 0] }, { answer: "d", usage: [1, 0, 0] }, { hold: true }];
    const r = await go(x, { cfg: { script: [{ answer: "a", usage: [110_000, 0, 0] }, { hold: true }], resume } });
    expect([r.code, r.result.reason, r.result.in, records(x).length, r.response]).toEqual([1, "limit", 116_000, 2, undefined]);
    const y = setup();
    const s = await go(y, { cfg: { script: [{ answer: "a", usage: [120_000, 0, 0] }, { hold: true }], resume: FINE } });
    expect([s.code, s.result.reason, s.result.in, records(y).length]).toEqual([1, "limit", 120_000, 1]);
  }, 30_000);

  test("a turn bound to another conversation is withheld: by a resume's or a wrap-up's init, a later init, or the result", async () => {
    const other = "0b7c2f5e-3d1a-4e8b-9c6f-2a4d8e1b7c3f";
    const moved = { resumeAs: other };
    const x = setup();
    expect((await go(x)).code).toBe(0);
    const r = await go(x, { turn: 2, cfg: { script: FINE, ...moved } });
    expect([r.code, r.result.reason, r.response]).toEqual([1, "error", undefined]);
    const y = setup();
    const w = await go(y, { cfg: { script: [{ answer: "a", usage: [101_000, 0, 0] }, { hold: true }], resume: FINE, ...moved } });
    expect([w.code, w.result.reason, records(y).length, w.response]).toEqual([1, "error", 2, undefined]);
    // A failed result naming no conversation keeps its own reason: no failed result of agy's has been seen to name one.
    const unnamed = { event: "init", init: { model: "gemini-4-neon", permission_mode: "always-proceed" } };
    const cases: [string, object[], string | null][] = [
      ["a later init naming none", [{ raw: JSON.stringify(unnamed) }, ...FINE], "error"],
      ["a result naming another", [{ answer: "fine" }, { result: "SUCCESS", response: "fine", conversation: other }], "error"],
      ["a SUCCESS result naming none", [{ answer: "fine" }, { result: "SUCCESS", response: "fine", conversation: false }], "error"],
      ["a failed result naming null", [{ answer: "" }, { result: "ERROR", error: "Error 402: prepayment credits are depleted", conversation: null }], "cap"],
    ];
    for (const [label, script, reason] of cases) {
      const z = await go(setup(), { cfg: { script } });
      expect([label, z.code, z.result.reason, z.response]).toEqual([label, reason ? 1 : 0, reason, reason ? undefined : "fine"]);
    }
  }, 30_000);

  test("one 40-minute deadline covers the call and its wrap-up, which never starts past it; 12 minutes with no event but blank lines end the call", async () => {
    // 400 times real time: the deadline is 6 s, the silence 1.8 s.
    const fast = () => {
      const t0 = performance.now();
      return () => (performance.now() - t0) * 400;
    };
    const x = setup();
    const cfg = { script: [{ tick: 100, for: 2500 }, { answer: "a", usage: [110_000, 0, 0] }, { hold: true }], resume: [{ tick: 100 }] };
    const clock = fast();
    const r = await go(x, { clock, cfg });
    const took = clock() / 1000;
    // A deadline per turn would have ended the wrap-up near 3,400 s.
    expect([r.code, r.result.reason, records(x).length, took >= 2400 && took < 2700, r.result.seconds <= took]).toEqual([1, "timeout", 2, true, true]);
    const quiet = fast();
    const s = await go(setup(), { clock: quiet, cfg: { script: [{ tick: 100, blank: true }] } });
    const waited = quiet() / 1000;
    expect([s.result.reason, waited >= 720 && waited < 900]).toEqual(["timeout", true]);
    // The clock reaches the deadline once the limit is logged, while the sweep waits on the held stub.
    let t = 0;
    const y = setup();
    const jump = logged(y, '"ended":"limit"').then((seen) => {
      if (seen) t = 40 * 60_000;
    });
    const late = await go(y, { clock: () => t, cfg: { script: [{ answer: "a", usage: [101_000, 0, 0] }, { hold: true }], resume: FINE } });
    await jump;
    expect([late.code, late.result.reason, records(y).length]).toEqual([1, "limit", 1]);
  }, 30_000);

  test("a log or stderr write that fails, as on a full disk, ends the call error and leaves nothing running", async () => {
    const rows: [string, string, string, object[]][] = [
      ["an event's log line", "log.ndjson", '"user_input"', [{ sleep: 300 }, { answer: "a" }, { hold: true }]],
      ["an unparsed line's log line", "log.ndjson", '"user_input"', [{ sleep: 300 }, { raw: "MALFORMED {" }, { hold: true }]],
      ["a stderr line", "stderr.txt", '"user_input"', [{ sleep: 300 }, { err: "notice" }, ...FINE]],
      ["a text flushed as agy's exit settles the call", "log.ndjson", '"SUCCESS"', [{ delta: "partial" }, { result: "SUCCESS", response: "x" }, { sleep: 300 }]],
    ];
    for (const [label, name, after, script] of rows) {
      const x = setup();
      const swapped = full(x, name, after);
      // A call left open by a lost write would otherwise hold the test until its timeout.
      const r = await Promise.race([go(x, { cfg: { script } }), Bun.sleep(5000).then(() => undefined)]);
      expect([label, await swapped, r?.code, r?.result.reason, r?.response]).toEqual([label, true, 1, "error", undefined]);
    }
  }, 30_000);

  test("a lost write keeps the mode tripwire, so the resume it bars stays barred", async () => {
    // The init comes after the swap; the stderr line only once the sweep's TERM arrives.
    const tripped = { event: "init", conversation_id: CONVERSATION, init: { model: "gemini-4-neon", permission_mode: "request-review" } };
    const cfg = { init: false, onTerm: "stopping", script: [{ sleep: 300 }, { raw: JSON.stringify(tripped) }, { hold: true }] };
    for (const [label, name] of [["the init's own log line", "log.ndjson"], ["a stderr line during the sweep", "stderr.txt"]]) {
      const x = setup();
      const swapped = full(x, name, '"user_input"');
      const r = await go(x, { cfg });
      const resumed = await go(x, { cfg: { script: FINE }, turn: 2 });
      expect([label, await swapped, r.code, r.result.reason, r.result.tripwire, resumed.code]).toEqual([label, true, 1, "mode", "mode", 2]);
    }
  }, 30_000);

  test("after a lost write no later line is handled and no wrap-up starts, though the step in hand keeps its reason", async () => {
    const usage = { input_tokens: 101_000, output_tokens: 0, thinking_tokens: 0, cache_read_tokens: 0, total_tokens: 101_000 };
    const crossing = { event: "step_update", step_update: { step_index: 8, state: "DONE", step_type: "agent_response", text_delta: "a", usage } };
    const tool = { event: "step_update", step_update: { step_index: 7, state: "DONE", step_type: "tool", tool_name: "run_command", tool_info: { name: "run_command", output: "ok" } } };
    const rows: [string, object[], string][] = [
      // One write, so one chunk: the tool step's log line fails and the crossing step comes in the same handler call.
      ["a crossing after the lost write", [{ sleep: 300 }, { raw: `${JSON.stringify(tool)}\n${JSON.stringify(crossing)}` }, { hold: true }], "error"],
      ["a crossing whose own write is lost", [{ sleep: 300 }, { raw: JSON.stringify(crossing) }, { hold: true }], "limit"],
    ];
    for (const [label, script, reason] of rows) {
      const x = setup();
      const swapped = full(x, "log.ndjson", '"user_input"');
      const r = await go(x, { cfg: { script, resume: FINE } });
      expect([label, await swapped, r.code, r.result.reason, r.spawns]).toEqual([label, true, 1, reason, 1]);
    }
  }, 30_000);

  test("verdicts: empty, denied, cap and error, and a step without usage; a failed first turn reports one whole usage tuple", async () => {
    const spent = "agent executor error: generating and executing: Error 402, Message: Your prepayment credits are depleted. Status: RESOURCE_EXHAUSTED";
    const steps = { answer: "", usage: [1000, 900, 0] };
    // Mixing fields would give 5000/900/100 and 1500/900/100.
    const cases: [string, object[], string, number[] | null, string[]][] = [
      ["empty", [{ answer: "" }, { result: "SUCCESS", response: "" }], "empty", null, []],
      ["denied", [{ answer: "" }, { result: "SUCCESS", response: "", denied: ["read_file"] }], "denied", null, ["read_file"]],
      ["cap, the result counting more", [steps, { result: "ERROR", error: spent, usage: [5000, 10, 100] }], "cap", [5000, 10, 100], []],
      ["cap, the steps counting more", [steps, { result: "ERROR", error: spent, usage: [1500, 10, 100] }], "cap", [1000, 900, 0], []],
      ["another error", [steps, { result: "ERROR", error: "agent executor error: no route" }], "error", [1000, 900, 0], []],
      ["a step without usage", [{ answer: "x", usage: null }, { result: "SUCCESS", response: "x" }], "usage", [0, 0, 0], []],
    ];
    for (const [label, script, reason, usage, denied] of cases) {
      const r = await go(setup(), { cfg: { script } });
      const got = [r.result.in, r.result.out, r.result.cached];
      expect([label, r.code, r.result.reason, r.response, usage ?? got, r.result.denied_actions]).toEqual([label, 1, reason, undefined, got, denied]);
    }
  }, 60_000);

  test("agy's file is checked once its exec has happened, though the spawn returned before it", async () => {
    const r = await go(setup(), { late: 300 });
    expect([r.code, r.out, r.response]).toEqual([0, [], "fine"]);
  }, 30_000);

  test("a run dir not directly under the engine's home's own .cache/gemini-leg/ is refused before the key file is opened", async () => {
    const x = setup();
    const leg = (h: Home) => join(h.dir, ".cache", "gemini-leg");
    const elsewhere = join(x.home.dir, ".cache", "elsewhere", "run");
    mkdirSync(elsewhere, { recursive: true, mode: 0o700 });
    // A home whose run root links to x's, under which x.dir resolves.
    const linked = makeHome();
    mkdirSync(join(linked.dir, ".cache"));
    symlinkSync(leg(x.home), leg(linked));
    const cases: [Ctx, string][] = [
      [{ ...x, dir: elsewhere }, `${elsewhere} is not directly under ${leg(x.home)}`],
      [{ ...x, home: linked }, `${leg(linked)} must be a real directory, not a link`],
    ];
    for (const [ctx, error] of cases) {
      // A FIFO in the key file's place: its writer finishes opening, and leaves the marker, only once a reader opens it.
      const key = join(ctx.home.dir, ".config/gemini/.env");
      unlinkSync(key);
      expect(spawnSync("mkfifo", ["-m", "600", key]).status).toBe(0);
      const opened = join(root, `opened${++seq}`);
      const writer = spawn("/bin/sh", ["-c", ': > "$0" && : > "$1"', key, opened], { stdio: "ignore" });
      const r = await go(ctx);
      await Bun.sleep(300);
      writer.kill("SIGKILL");
      expect([r.code, r.out[0], readdirSync(ctx.dir), existsSync(opened)]).toEqual([2, `ERROR: ${error}`, [], false]);
    }
  }, 30_000);

  test("a source settings file that grants access is refused before agy runs; trustedWorkspaces is accepted and not carried", async () => {
    const granted = [{ permissions: { allow: ["command(*)"] } }, { permissions: { ask: [] } }, { allowNonWorkspaceAccess: true }, { toolPermission: {} }, { hooks: {} }, { mcpServers: {} }];
    for (const extra of granted) {
      const x = setup({ home: makeHome({ modelProvider: "gemini", ...extra }) });
      const r = await go(x);
      expect([Object.keys(extra)[0], r.code, records(x).length, readdirSync(x.dir)]).toEqual([Object.keys(extra)[0], 4, 0, []]);
    }
    const x = setup({ home: makeHome({ modelProvider: "gemini", trustedWorkspaces: [root], permissions: { deny: ["command(rm)"] } }) });
    expect((await go(x)).code).toBe(0);
    expect(readFileSync(join(x.dir, "home/.gemini/antigravity-cli/settings.json"), "utf8")).toBe('{"modelProvider":"gemini"}\n');
  }, 30_000);

  test("a resume needs a clean private home, a UUID and a last turn not ended mode or model; it counts its own steps in numbered files", async () => {
    const second = { resume: [{ answer: "second", usage: [2000, 20, 1000] }, { result: "SUCCESS", response: "second", usage: [9000, 90, 4000] }] };
    for (const init of [{ mode: "request-review" }, { model: "gemini-4-carbon" }]) {
      const x = setup();
      expect((await go(x, { cfg: { init, script: FINE } })).code).toBe(1);
      const before = listing(x);
      expect([(await go(x, { cfg: second, turn: 2 })).code, listing(x)]).toEqual([2, before]);
    }
    const x = setup();
    expect((await go(x, { cfg: { script: [{ tool: "schedule", state: "ACTIVE" }, { hold: true }] } })).result.reason).toBe("tool");
    const config = join(x.dir, "home/.gemini/config");
    mkdirSync(config, { recursive: true });
    for (const [name, text] of [["hooks.json", "{}"], ["mcp_config.json", '{"mcpServers":{}}']]) {
      writeFileSync(join(config, name), text);
      const before = listing(x);
      expect([name, (await go(x, { cfg: second, turn: 2 })).code, listing(x)]).toEqual([name, 2, before]);
      unlinkSync(join(config, name));
    }
    const before = listing(x);
    expect([(await go(x, { cfg: second, turn: 2, conversation: "not-a-uuid" })).code, listing(x)]).toEqual([2, before]);
    const r = await go(x, { cfg: second, turn: 2 });
    expect([r.code, r.response, r.result.in, r.result.out, r.result.cached, r.result.response]).toEqual([0, "second", 2000, 20, 1000, "response.2.md"]);
    expect(r.result.agy_usage).toEqual({ input_tokens: 9000, output_tokens: 90, thinking_tokens: 0, cache_read_tokens: 4000, total_tokens: 9090 });
    expect(records(x).at(-1)?.args.slice(-2)).toEqual(["--conversation", CONVERSATION]);
    const turn2 = readdirSync(x.dir).filter((f) => f.includes(".2."));
    expect(turn2.sort()).toEqual(["log.2.ndjson", "prompt.2.md", "response.2.md", "result.2.json", "stderr.2.txt"]);
    expect(readFileSync(join(x.dir, "session_id"), "utf8")).toBe(`${CONVERSATION}\n`);
  }, 30_000);
});
