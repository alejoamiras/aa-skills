// The gemini worker pump's core, in-process, against a stand-in agy compiled from tests/fixtures/agy-stub.ts, in a temp
// git worktree with a temp home holding a pin, settings and a canary key: no real agy, no real key, no network. Key
// values are compared only as booleans, so a failing assertion never prints one.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, linkSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { conversationOf, isStep, paneParts, resultOf, toolDone, userEvent } from "../skills/gemini/engines/agy-stream.ts";
import { type Deps, LIMITS, type Limits, pump, type Spawn } from "../skills/gemini/engines/agy.ts";
import { RECORDED, toolStep } from "./fixtures/agy-stub.ts";

// Every third character is a capital, so no 5-character run of it occurs in timestamps, hex ids or plain words.
const CANARY = "AIzaQz1Rx2Sw3Tv4Uu5Vt6Ws7Xr8Yq9Zp0Ao1Bn2Cm3";
const SUBAGENT = "You are a subagent. Don't run memo.";
const SHIMS = join(import.meta.dir, "..", "skills", "gemini", "shims");
const FLAGS = ["--input-format", "stream-json", "--output-format", "stream-json", "--dangerously-skip-permissions", "--model", "gemini-4-carbon", "--effort", "low"];
const ENV_NAMES = ["AGY_CLI_DISABLE_AUTO_UPDATE", "CREW_WORKER", "GEMINI_API_KEY", "GEMINI_WORKER", "GEMINI_WORKER_ID", "GIT_TERMINAL_PROMPT", "HOME", "LANG", "LOGNAME", "PATH", "SHELL", "TERM", "TMPDIR", "USER"];
const UID = process.getuid?.() ?? 0;
const root = mkdtempSync(join(tmpdir(), "gemini-agy-test-"));
const WORKER_ENV = { WORKER_PATH: "/usr/bin:/bin", WORKER_USER: "tester", WORKER_LOGNAME: "tester", WORKER_SHELL: "/bin/bash", WORKER_LANG: "C.UTF-8", WORKER_TMPDIR: root };
// The test's own git ignores the owner's config, so no signing or hook of theirs runs.
const GIT_ENV = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };
let stubBin = "";
let stubSha = "";
const sha = (path: string) => createHash("sha256").update(readFileSync(path)).digest("hex");

beforeAll(() => {
  stubBin = join(root, "agy-stub");
  const r = spawnSync(process.execPath, ["build", "--compile", "--outfile", stubBin, join(import.meta.dir, "fixtures", "agy-stub.ts")], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`the stub did not compile: ${r.stderr}`);
  stubSha = sha(stubBin);
}, 120_000);
afterAll(() => rmSync(root, { recursive: true, force: true }));

let seq = 0;
type Home = { dir: string; bin: string };
// A hard link per home: a test that renames over its path leaves the others' stub alone.
function makeHome(): Home {
  const dir = join(root, `home${++seq}`);
  for (const d of [".agents", "bin", ".gemini/antigravity-cli", ".gemini/config", ".config/gemini"]) mkdirSync(join(dir, d), { recursive: true });
  const bin = join(dir, "bin", "agy");
  linkSync(stubBin, bin);
  writeFileSync(join(dir, ".agents", "gemini-agy"), `path=${bin}\nsha256=${stubSha}\nversion=1.5.15-stub\n`, { mode: 0o600 });
  writeFileSync(join(dir, ".gemini/antigravity-cli/settings.json"), '{ "modelProvider": "gemini" }\n');
  writeFileSync(join(dir, ".config/gemini/.env"), `GEMINI_API_KEY=${CANARY}\n`, { mode: 0o600 });
  return { dir, bin };
}

type Repo = { wt: string; config: string };
function makeRepo(): Repo {
  const repo = join(root, `repo${++seq}`);
  const wt = join(root, `wt${seq}`);
  const git = (...a: string[]) => {
    const r = spawnSync("git", a, { encoding: "utf8", env: GIT_ENV });
    if (r.status !== 0) throw new Error(`git ${a.join(" ")}: ${r.stderr}`);
  };
  git("init", "-q", repo);
  writeFileSync(join(repo, "README"), "x\n");
  git("-C", repo, "add", ".");
  git("-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-qm", "init");
  git("-C", repo, "worktree", "add", "-q", wt);
  return { wt, config: join(repo, ".git", "config") };
}

type Opts = { cfg?: object | ((r: Repo) => object); cap?: number; limits?: Partial<Limits>; spawn?: Spawn; director?: number; home?: Home };
const makeDeps = (home: Home, pane: string[], o: Opts, signals: Deps["signals"] = () => {}): Deps => ({
  home: home.dir, uid: UID, now: () => Date.now(), timers: { set: (fn, ms) => setTimeout(fn, ms), clear: (h) => clearTimeout(h as ReturnType<typeof setTimeout>) },
  limits: { ...LIMITS, grace: 300, poll: 20, ...o.limits }, spawn: o.spawn ?? ((file, args, opts) => spawn(file, args, opts)), signals,
  input: () => {}, out: (line) => pane.push(line), env: WORKER_ENV,
});
type Worker = Awaited<ReturnType<typeof start>>;
async function start(o: Opts = {}) {
  const home = o.home ?? makeHome();
  const repo = makeRepo();
  writeFileSync(join(home.dir, "stub.json"), JSON.stringify(typeof o.cfg === "function" ? o.cfg(repo) : (o.cfg ?? {})));
  const state = join(root, `state${++seq}`, "w");
  mkdirSync(state, { recursive: true, mode: 0o700 });
  const pane: string[] = [];
  let stop = (_signal: string) => {};
  const deps = makeDeps(home, pane, o, (fn) => {
    stop = fn;
  });
  const done = pump([state, repo.wt, "gemini-4-carbon", "low", String(o.cap ?? 0), String(o.director ?? process.pid)], deps);
  return { home, repo, state, pane, done, stop: () => stop("SIGINT") };
}

// biome-ignore lint/suspicious/noExplicitAny: log entries are free-form JSON
type Entry = Record<string, any>;
const entries = (w: Worker): Entry[] =>
  existsSync(join(w.state, "log.ndjson")) ? readFileSync(join(w.state, "log.ndjson"), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
const gw = (w: Worker, type: string) => entries(w).filter((e) => e.src === "gw" && e.type === type);
async function until<T>(fn: () => T | undefined | false, ms = 15_000): Promise<T> {
  for (const end = Date.now() + ms; ; await Bun.sleep(20)) {
    const v = fn();
    if (v) return v;
    if (Date.now() > end) throw new Error("timed out");
  }
}
const ready = (w: Worker) => until(() => gw(w, "ready")[0]);
const turns = (w: Worker, n: number) => until(() => gw(w, "turn").length >= n && gw(w, "turn"));

let clock = 1_700_000_000_000_000;
function send(w: Worker, text: string) {
  const us = ++clock;
  const tmp = join(w.state, "inbox", `.tmp-${us}`);
  writeFileSync(tmp, text);
  renameSync(tmp, join(w.state, "inbox", `${Math.floor(us / 1e6)}.${String(us % 1e6).padStart(6, "0")}-${process.pid}`));
}

// biome-ignore lint/suspicious/noExplicitAny: the stub's own records
const records = (h: Home): Record<string, any>[] =>
  existsSync(join(h.dir, "stub")) ? readdirSync(join(h.dir, "stub")).filter((f) => f.endsWith(".json")).map((f) => JSON.parse(readFileSync(join(h.dir, "stub", f), "utf8"))) : [];
const stubFile = (h: Home, ext: string) => readFileSync(join(h.dir, "stub", `${records(h)[0].pid}${ext}`), "utf8");
const leaks = (text: string) => Array.from({ length: CANARY.length - 4 }, (_, i) => CANARY.slice(i, i + 5)).some((w) => text.includes(w));

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

// After any end: the log parses line by line, neither it nor the pane holds a canary run, and nothing agy started is left.
async function finished(w: Worker) {
  const code = await w.done;
  const raw = readFileSync(join(w.state, "log.ndjson"), "utf8");
  for (const line of raw.split("\n").filter(Boolean)) {
    expect(Buffer.byteLength(line)).toBeLessThan(64 * 1024);
    JSON.parse(line);
  }
  expect(leaks(raw)).toBe(false);
  expect(leaks(w.pane.join("\n"))).toBe(false);
  // An agy gone before its spawned line leaves no marker in the log; its recorded sessions still count.
  const marker = gw(w, "spawned")[0]?.marker ?? records(w.home)[0]?.env.GEMINI_WORKER_ID ?? "none";
  const sids = records(w.home).flatMap((r) => [r.sid, r.child].filter(Boolean));
  expect(leftovers(marker, sids)).toEqual([]);
  const gone = gw(w, "gone");
  expect(gone.length).toBe(1);
  expect(entries(w).at(-1)).toEqual(gone[0]);
  return { code, gone: gone[0], turns: gw(w, "turn") };
}

describe("schema", () => {
  test("reads the recorded events: cumulative totals with cached reads, tool steps once on DONE, the init id", () => {
    const evs = RECORDED.map((l) => JSON.parse(l));
    const results = evs.map(resultOf).filter(Boolean);
    expect(results).toEqual([
      { status: "SUCCESS", answer: "ok\n", turns: 1, total: 17963 + 28319 },
      { status: "SUCCESS", answer: "alpha\n", turns: 2, total: 20096 + 35972 },
      { status: "ERROR", answer: "", turns: 0, total: 0 },
    ]);
    expect(evs.map(toolDone).filter(Boolean)).toEqual([
      { index: 2, error: false },
      { index: 3, error: false },
    ]);
    expect(toolDone(toolStep(7, "DONE", "exit status 1"))).toEqual({ index: 7, error: true });
    expect(conversationOf(evs[0])).toBe("8766c9db-47ac-4645-97cc-bd1cbe524c30");
    expect(evs.filter(isStep).length).toBe(8);
    expect(paneParts(evs[3]).slice(0, 4)).toEqual(["step_update", "DONE", "tool", "run_command"]);
    expect(paneParts(evs[10])).toEqual(["step_update", "DONE", "agent_response"]);
    expect(JSON.parse(userEvent("hi"))).toEqual({ event: "user", message: { content: "hi" } });
    const usage = (u: object) => resultOf({ event: "result", result: { status: "SUCCESS", num_turns: 1, usage: u } })?.total;
    expect([usage({ total_tokens: 5 }), usage({ total_tokens: -1, cache_read_tokens: 0 }), usage({ total_tokens: 1.5, cache_read_tokens: 0 })]).toEqual([undefined, undefined, undefined]);
  });
});

describe("worker", () => {
  test("agy runs from the pinned descriptor with the flag list, exactly the listed environment, in its own session", async () => {
    const w = await start({ cfg: { child: true } });
    const r = await ready(w);
    const spawned = gw(w, "spawned")[0];
    const at = (type: string) => entries(w).findIndex((e) => e.type === type);
    expect(at("spawned")).toBeGreaterThan(-1);
    expect(at("spawned")).toBeLessThan(at("ready"));
    const rec = await until(() => records(w.home)[0]);
    expect([spawned.pid, spawned.sid, spawned.start]).toEqual([rec.pid, rec.sid, rec.start]);
    expect([r.pid, r.sid, r.start, r.marker, r.sha256, r.cap]).toEqual([rec.pid, rec.sid, rec.start, spawned.marker, stubSha, null]);
    expect(rec.args).toEqual(FLAGS);
    expect(rec.argv0).toBe(w.home.bin);
    expect(rec.envNames).toEqual(ENV_NAMES);
    expect(rec.keyMatches).toBe(true);
    expect(rec.env.GEMINI_WORKER_ID).toBe(spawned.marker);
    expect([rec.env.HOME, rec.env.TERM, rec.env.PATH]).toEqual([w.home.dir, "dumb", `${SHIMS}:/usr/bin:/bin`]);
    const ownSid = Number(readFileSync("/proc/self/stat", "utf8").split(") ")[1].split(" ")[3]);
    expect(rec.sid).toBe(rec.pid);
    expect(rec.sid).not.toBe(ownSid);
    expect(rec.tty).toBe(0);
    // Inherited: the three pipes only. After the exec, Bun's own runtime opens at most one descriptor of each other kind.
    const fds: { fd: number; target: string }[] = rec.fds;
    expect(fds.filter((d) => d.fd <= 2).map((d) => /^(pipe|socket):\[[0-9]+\]$/.test(d.target))).toEqual([true, true, true]);
    const runtime = ["anon_inode:[eventpoll]", "anon_inode:[eventfd]", "/dev/urandom", `/proc/${rec.pid}/statm`];
    const rest = fds.filter((d) => d.fd > 2).map((d) => d.target);
    expect(rest.filter((t) => !runtime.includes(t))).toEqual([]);
    expect(new Set(rest).size).toBe(rest.length);
    for (const name of ["memo", "env-exec", "send-to-mac", "claude", "codex"]) expect(spawnSync(join(SHIMS, name)).status).toBe(1);
    w.stop();
    const f = await finished(w);
    expect([f.code, f.gone.reason, f.gone.code]).toEqual([0, "stopped by SIGINT", 0]);
  }, 30_000);

  test("two messages sent during one slow turn reach agy one per result, in order, framed, the preamble only first", async () => {
    const w = await start({ cfg: { mode: "slow", delay: 400 } });
    await ready(w);
    send(w, "first task");
    send(w, `${SUBAGENT}\nsecond task`);
    const t = await turns(w, 2);
    expect(t.map((x) => [x.n, x.from, x.status, x.answer, x.tokens, x.total])).toEqual([
      [1, "director", "SUCCESS", "answer 1", 1510, 1510],
      [2, "director", "SUCCESS", "answer 2", 1510, 3020],
    ]);
    expect(stubFile(w.home, ".order")).toBe("in 1\nresult 1\nin 2\nresult 2\n");
    const sent = stubFile(w.home, ".in.ndjson").trim().split("\n").map((l) => JSON.parse(l));
    expect(sent.map((e) => e.event)).toEqual(["user", "user"]);
    const [one, two] = sent.map((e) => e.message.content as string);
    expect(one.startsWith(`${SUBAGENT}\nYou are a Gemini worker driven by another agent.`)).toBe(true);
    expect(one.endsWith("\n\nfirst task")).toBe(true);
    expect(two).toBe(`${SUBAGENT}\nsecond task`);
    w.stop();
    await finished(w);
  }, 30_000);

  test("a duplicate result is a turn from agy that counts its usage and consumes no message", async () => {
    const w = await start({ cfg: { mode: "duplicate" } });
    await ready(w);
    send(w, "one");
    send(w, "two");
    const t = await turns(w, 4);
    expect(t.map((x) => [x.from, x.tokens, x.total, x.answer])).toEqual([
      ["director", 1510, 1510, "answer 1"],
      ["agy", 100, 1610, "answer 1"],
      ["director", 1410, 3020, "answer 2"],
      ["agy", 100, 3120, "answer 2"],
    ]);
    expect(stubFile(w.home, ".in.ndjson").trim().split("\n").length).toBe(2);
    w.stop();
    await finished(w);
  }, 30_000);

  test("a stale result after the next message's start is from agy, and num_turns ties the next result to its message", async () => {
    const w = await start({ cfg: { mode: "late-duplicate" } });
    await ready(w);
    send(w, "A");
    send(w, "B");
    const t = await turns(w, 3);
    expect(t.map((x) => [x.from, x.answer])).toEqual([
      ["director", "answer 1"],
      ["agy", "answer 1"],
      ["director", "answer 2"],
    ]);
    w.stop();
    await finished(w);
  }, 30_000);

  test("steps after a result, with no message, make an idle worker busy and so under the watchdog", async () => {
    const w = await start({ cfg: { mode: "background", delay: 1500, child: true }, limits: { silence: 1000 } });
    await ready(w);
    send(w, "one");
    const f = await finished(w);
    expect(f.gone.reason).toBe("watchdog: no output from agy for 1 s");
    // Idle for 1.5 s with a 1 s silence limit, so only the unasked step can have started the clock.
    const es = entries(w);
    const unasked = es.findIndex((e) => e.src === "agy" && e.ev?.step_update?.text_delta === "unasked");
    expect(unasked).toBeGreaterThan(es.findIndex((e) => e.type === "turn"));
    expect(f.turns.length).toBe(1);
  }, 30_000);

  test("the canary printed plain, unicode-escaped, on stderr and in an answer reaches neither log nor pane", async () => {
    const w = await start({ cfg: { mode: "leak-key" } });
    await ready(w);
    send(w, "leak");
    const [t] = await turns(w, 1);
    expect(t.answer).toBe("answer 1 [redacted]");
    const es = entries(w);
    expect(es.some((e) => e.src === "agy" && e.ev === "[redacted]")).toBe(true);
    expect(es.some((e) => e.src === "agy" && e.ev?.step_update?.text_delta === "[redacted]")).toBe(true);
    expect(es.some((e) => e.src === "err" && e.ev === "leaked [redacted]")).toBe(true);
    w.stop();
    await finished(w);
  }, 30_000);

  test("a 2 MiB line and a 100 KiB event are logged as parseable cut entries", async () => {
    const w = await start({ cfg: { mode: "huge" } });
    await ready(w);
    send(w, "big");
    await turns(w, 1);
    const cut = entries(w).filter((e) => e.cut === true);
    expect(cut.length).toBe(2);
    expect(cut.every((e) => e.src === "agy" && e.head.startsWith(cut[0] === e ? "[redacted]" : '{"event"'))).toBe(true);
    w.stop();
    await finished(w);
  }, 30_000);

  test("a capped worker ends after the crossing turn and drops the queue; an uncapped one survives a huge total", async () => {
    const w = await start({ cfg: { mode: "slow", delay: 300, child: true }, cap: 2000 });
    expect((await ready(w)).cap).toBe(2000);
    for (const m of ["one", "two", "three"]) send(w, m);
    const f = await finished(w);
    expect(f.turns.map((x) => x.total)).toEqual([1510, 3020]);
    expect([f.gone.reason, f.gone.code, f.gone.dropped.length]).toEqual(["cap", 1, 1]);
    const big = await start({ cfg: { turns: [{ usage: { total_tokens: 4e15, cache_read_tokens: 4e15 } }] } });
    await ready(big);
    send(big, "one");
    expect((await turns(big, 1))[0].tokens).toBe(8e15);
    big.stop();
    expect((await finished(big)).gone.reason).toBe("stopped by SIGINT");
  }, 30_000);

  test("with a cap, missing, partial, negative or fractional usage ends the worker; without one the turn shows null", async () => {
    const bad = [{ mode: "no-usage" }, { mode: "partial-usage" }, { turns: [{ usage: { total_tokens: -1, cache_read_tokens: 0 } }] }, { turns: [{ usage: { total_tokens: 1.5, cache_read_tokens: 0 } }] }];
    for (const cfg of bad) {
      const w = await start({ cfg: { ...cfg, child: true }, cap: 1_000_000 });
      await ready(w);
      send(w, "one");
      const f = await finished(w);
      expect([f.turns.length, f.turns[0].tokens, f.gone.reason]).toEqual([1, null, "usage unreadable"]);
    }
    const w = await start({ cfg: { mode: "no-usage" } });
    await ready(w);
    send(w, "one");
    send(w, "two");
    const t = await turns(w, 2);
    expect(t.map((x) => [x.tokens, x.total])).toEqual([
      [null, 0],
      [null, 0],
    ]);
    w.stop();
    expect((await finished(w)).gone.reason).toBe("stopped by SIGINT");
  }, 60_000);

  test("agy's output ending without a result ends the worker", async () => {
    const w = await start({ cfg: { mode: "eof", child: true } });
    await ready(w);
    send(w, "one");
    expect((await finished(w)).gone.reason).toBe("agy exited without a result");
  }, 30_000);

  test("the silence limit and the turn limit each end a hung agy", async () => {
    const silent = await start({ cfg: { mode: "hang", child: true }, limits: { silence: 1000 } });
    await ready(silent);
    send(silent, "one");
    expect((await finished(silent)).gone.reason).toBe("watchdog: no output from agy for 1 s");
    const busy = await start({ cfg: { mode: "hang", tick: 100, child: true }, limits: { silence: 1000, turn: 1000 } });
    await ready(busy);
    send(busy, "one");
    expect((await finished(busy)).gone.reason).toBe("watchdog: the turn ran past 1 s");
  }, 30_000);

  test("a director that is gone ends the worker", async () => {
    const director = spawn("sleep", ["30"]);
    const w = await start({ cfg: { child: true }, director: director.pid, limits: { director: 50 } });
    await ready(w);
    director.kill("SIGKILL");
    expect((await finished(w)).gone.reason).toBe("director gone");
  }, 30_000);

  test("a changed binary, a symlinked pin, bad settings or a planted home config refuse before agy runs", async () => {
    const cases: [string, (h: Home) => void, string][] = [
      ["changed binary", (h) => {
        copyFileSync(stubBin, `${h.bin}.new`);
        writeFileSync(`${h.bin}.new`, "x", { flag: "a" });
        renameSync(`${h.bin}.new`, h.bin);
      }, `the approved one is ${stubSha} (1.5.15-stub)`],
      ["symlinked pin", (h) => {
        const pin = join(h.dir, ".agents", "gemini-agy");
        renameSync(pin, `${pin}.real`);
        symlinkSync(`${pin}.real`, pin);
      }, "it must be a regular file, not a symlink"],
      ["no modelProvider", (h) => writeFileSync(join(h.dir, ".gemini/antigravity-cli/settings.json"), "{}\n"), 'must set "modelProvider": "gemini"'],
      ["settings with the key", (h) => writeFileSync(join(h.dir, ".gemini/antigravity-cli/settings.json"), JSON.stringify({ modelProvider: "gemini", k: CANARY })), "holds the API key"],
      ["home hooks", (h) => writeFileSync(join(h.dir, ".gemini/config/hooks.json"), "{}"), "hooks.json exists"],
      ["home MCP servers", (h) => writeFileSync(join(h.dir, ".gemini/config/mcp_config.json"), '{"mcpServers":{}}'), "has an mcpServers entry"],
    ];
    for (const [, change, says] of cases) {
      const home = makeHome();
      change(home);
      const w = await start({ home });
      const f = await finished(w);
      expect([f.code, f.gone.code, f.gone.reason.includes(says)]).toEqual([2, 2, true]);
      expect(gw(w, "spawned").length + records(home).length).toBe(0);
    }
    const home = makeHome();
    writeFileSync(join(home.dir, ".gemini/config/mcp_config.json"), "");
    const w = await start({ home });
    await ready(w);
    w.stop();
    await finished(w);
  }, 60_000);

  test("a file renamed over the pinned path after the hash never runs, and the next start refuses it", async () => {
    const home = makeHome();
    const marker = join(root, `marker${++seq}`);
    writeFileSync(join(home.dir, "evil"), `#!/bin/sh\ntouch '${marker}'\n`, { mode: 0o755 });
    const w = await start({
      home,
      spawn: (file, args, opts) => {
        renameSync(join(home.dir, "evil"), home.bin);
        return spawn(file, args, opts);
      },
    });
    expect((await ready(w)).sha256).toBe(stubSha);
    send(w, "one");
    await turns(w, 1);
    w.stop();
    await finished(w);
    const again = await start({ home });
    const f = await finished(again);
    expect([f.gone.code, f.gone.reason.includes("the approved one is")]).toEqual([2, true]);
    expect(existsSync(marker)).toBe(false);
  }, 30_000);

  test("agy spawned by path from another inode fails the self-check", async () => {
    const home = makeHome();
    const w = await start({
      home,
      cfg: { child: true },
      spawn: (_file, args, opts) => {
        copyFileSync(stubBin, `${home.bin}.copy`);
        renameSync(`${home.bin}.copy`, home.bin);
        return spawn(home.bin, args, opts);
      },
    });
    const f = await finished(w);
    expect([f.code, f.gone.reason]).toEqual([2, "agy did not run from the approved file"]);
  }, 30_000);

  test("agy gone before the self-check gives code 4, and the marker still finds the command it left", async () => {
    const w = await start({
      cfg: { mode: "exit", child: true },
      spawn: (file, args, opts) =>
        new Promise<ChildProcess>((done) => {
          const child = spawn(file, args, opts);
          child.on("exit", () => done(child));
        }),
    });
    const f = await finished(w);
    expect([f.code, f.gone.reason]).toEqual([4, "agy exited before it could be checked"]);
    expect(records(w.home)[0].child).toBeGreaterThan(0);
  }, 30_000);

  test("tui runs the pinned agy with only an accepted argument, the listed environment, and the state dir as cwd", async () => {
    const tui = async (home: Home, args: string[]) => {
      writeFileSync(join(home.dir, "stub.json"), "{}");
      const state = join(root, `tui${++seq}`);
      mkdirSync(state, { recursive: true });
      const pane: string[] = [];
      const code = await pump(["tui", state, ...args], makeDeps(home, pane, {}));
      expect(leaks(pane.join("\n"))).toBe(false);
      return { code, state, pane, ran: records(home) };
    };
    const home = makeHome();
    const ok = await tui(home, ["models"]);
    expect(ok.code).toBe(0);
    const rec = ok.ran[0];
    expect([rec.args, rec.argv0, rec.cwd, rec.envNames, rec.keyMatches]).toEqual([["models"], home.bin, realpathSync(ok.state), ENV_NAMES, true]);
    expect(rec.env.GEMINI_WORKER_ID.startsWith("tui.")).toBe(true);
    const changed = makeHome();
    copyFileSync(stubBin, `${changed.bin}.new`);
    writeFileSync(`${changed.bin}.new`, "x", { flag: "a" });
    renameSync(`${changed.bin}.new`, changed.bin);
    const refused = await tui(changed, ["models"]);
    expect([refused.code, refused.ran.length, refused.pane.some((l) => l.includes(`the approved one is ${stubSha}`))]).toEqual([2, 0, true]);
    for (const args of [["--dangerously-skip-permissions"], ["--conversation", "not-a-uuid"], ["models", "extra"]]) {
      const bad = makeHome();
      const r = await tui(bad, args);
      expect([r.code, r.ran.length]).toEqual([2, 0]);
    }
  }, 30_000);

  test("a turn line counts tool steps, tool errors and stderr, and lists only that turn's paths and config change", async () => {
    const w = await start({
      cfg: (r) => ({ turns: [{ write: ["a.txt"], tools: 2, toolErrors: 1, stderr: 1 }, { write: ["b.txt"], editConfig: r.config }] }),
    });
    await ready(w);
    send(w, "one");
    send(w, "two");
    const t = await turns(w, 2);
    const pick = (x: Entry) => [x.tools, x.tool_errors, x.stderr, x.changed, x.paths, x.head, x.gitconfig];
    expect(t.map(pick)).toEqual([
      [2, 1, 1, 1, ["a.txt"], "same", "same"],
      [0, 0, 0, 1, ["b.txt"], "same", "changed"],
    ]);
    w.stop();
    await finished(w);
  }, 30_000);
});
