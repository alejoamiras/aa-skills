// The gemini skill's agy engine, which alone reads the key for agy: a worker's pump (one per worker, the process in its
// tmux pane, which owns agy's stdin and stdout, writes the log, and enforces the optional token cap and the watchdog),
// the owner's tui, and the review leg's one-shot run, whose call agy-run.ts makes. Start it only through engines/agy.
// Usage: agy <state dir> <worktree> <model> <effort> <cap, 0 for none> <director pid>
//        agy tui <state dir> [models | --conversation <uuid>]
//        agy run <run dir> <top level> <model> <effort> <limit> <turn> [<conversation id>], the prompt on stdin
import { type ChildProcess, execFile, type SpawnOptions, spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  closeSync, constants, fstatSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, realpathSync, renameSync, type Stats, statSync,
  unlinkSync, writeFileSync, writeSync,
} from "node:fs";
import { userInfo } from "node:os";
import { basename, join } from "node:path";
import { createInterface } from "node:readline";
import { Log, readKey } from "./api.ts";
import { call, turnFile } from "./agy-run.ts";
import {
  conversationOf, fit, isObj, isStep, type Json, lines, paneText, type Result, resultOf, stepDone, stepIndex, tail, textStep, toolDone, UUID, userEvent,
  withText,
} from "./agy-stream.ts";

const SUBAGENT = "You are a subagent. Don't run memo.";
const PREAMBLE = [
  "You are a Gemini worker driven by another agent. These rules hold for this whole conversation:",
  "- The memo lines in AGENTS.md and GEMINI.md do not apply to you.",
  "- Never commit, push, merge, publish or deploy.",
  "- Never start other agents or AI tools.",
  "- Never print your environment, and never read key files, ~/.ssh or ~/.config.",
  "- When a command is refused, report it and stop that line of work.",
  "- End each answer with the paths you changed, the commands you ran and what is left.",
].join("\n");
const MODEL = /^[a-z0-9][a-z0-9.-]*$/;
const EFFORTS = ["low", "medium", "high"];
const PIN = /^path=(\/[^\n]*)\nsha256=([0-9a-f]{64})\nversion=([^\n]+)\n?$/;
// send names a message $EPOCHREALTIME-$$, which sorts in send order, and a typed line takes the suffix -owner; any other
// name, a sender's temp file included, is not a message.
const INBOX_NAME = /^[0-9]+\.[0-9]{6}-(?:[0-9]+|owner)$/;
const QUEUE_MAX = 20;
const MESSAGE_MAX = 256 * 1024;
const ANSWER_MAX = 8000;
const TEXT_MAX = 256 * 1024;
const PATHS_MAX = 20;
const PATH_MAX = 512;
const SHIMS = join(import.meta.dir, "..", "shims");
const GIT_ENV = { PATH: "/usr/bin:/bin", GIT_TERMINAL_PROMPT: "0" };

const NEXT = {
  usage: "start workers only through worker-gemini.sh",
  start: "check the director and the worktree, then start again",
  pin: "the owner rewrites ~/.agents/gemini-agy and the live test reruns",
  settings: "the owner fixes agy's settings file as the gemini README says, then starts again",
  config: "a worker may have planted it: the owner reviews and removes it, then starts again",
  key: "the owner fixes the key file as the gemini README says; no agent reads it",
  early: "read the log's err lines, then start again",
  review: "review and commit the worktree's changes yourself; start a new worker to go on",
  cap: "the cap is spent: review the worktree's changes, then start a new worker with a higher --cap to go on",
  unreadable: "a capped worker cannot count this turn's tokens: read the log's last result and review the worktree before a new start",
  watchdog: "agy hung or stalled: review the worktree and the log's last lines, then start a new worker",
  bug: "read the log's last lines, run stop, and review the worktree",
  run: "call the engine only through run-agy.sh or resume-agy.sh; nothing was sent",
  unsent: "nothing was sent: fix the cause, then call again",
};

export const LIMITS = { silence: 15 * 60_000, turn: 30 * 60_000, director: 30_000, grace: 5_000, sweep: 10_000, git: 10_000, poll: 500 };
export type Limits = typeof LIMITS;
const capped = (l: Limits) => Object.fromEntries(Object.entries(LIMITS).map(([k, v]) => [k, Math.min(v, l[k as keyof Limits])])) as Limits;
export type Timers = { set: (fn: () => void, ms: number) => unknown; clear: (handle: unknown) => void };
export type Spawn = (file: string, args: string[], opts: SpawnOptions) => ChildProcess | Promise<ChildProcess>;
// Every outside effect but the filesystem, /proc, git and kill. Each limit is capped at its LIMITS value; env holds the
// launcher's WORKER_* values; input delivers the owner's typed lines.
export type Deps = {
  home: string; uid: number; now: () => number; timers: Timers; limits: Limits; spawn: Spawn;
  signals: (stop: (signal: string) => void) => void; input: (line: (text: string) => void) => void; out: (line: string) => void;
  env: Record<string, string | undefined>;
};
type From = "director" | "owner" | "agy";

class Refusal extends Error {
  constructor(message: string, readonly next: string, readonly code = 2) {
    super(message);
  }
}

const errText = (e: unknown) => (e instanceof Error ? e.message : typeof e === "string" ? e : "a non-error value");
const errCode = (e: unknown) => (isObj(e) && typeof e.code === "string" ? e.code : "error");
// For calls whose failure has one meaning: a process or file already gone, or text that is not JSON.
function attempt<T>(fn: () => T, fallback: T): T {
  try {
    return fn();
  } catch {
    return fallback;
  }
}
const parse = (text: string): unknown => attempt(() => JSON.parse(text), undefined);

// ---- Processes ----------------------------------------------------------------------------------------------------

type Proc = { pid: number; state: string; sid: number; start: string };
function procStat(pid: number): Proc | undefined {
  const s = attempt(() => readFileSync(`/proc/${pid}/stat`, "utf8"), "");
  // Fields from the third on; the command name before them may hold spaces and parentheses.
  const f = s.slice(s.lastIndexOf(")") + 2).split(" ");
  return s ? { pid, state: f[0], sid: Number(f[3]), start: f[19] } : undefined;
}

// Every live process of uid, and whether its environment holds entry exactly.
function processes(uid: number, entry: string): (Proc & { marked: boolean })[] {
  const out: (Proc & { marked: boolean })[] = [];
  for (const name of readdirSync("/proc")) {
    const p = /^[0-9]+$/.test(name) && attempt(() => statSync(`/proc/${name}`).uid === uid, false) ? procStat(Number(name)) : undefined;
    if (!p || p.state === "Z") continue;
    const env = attempt(() => readFileSync(`/proc/${name}/environ`, "latin1"), "");
    out.push({ ...p, marked: `\0${env}`.includes(`\0${entry}\0`) });
  }
  return out;
}

type Identity = { pid: number; sid: number; start: string };

// agy's session, unless its pid now names a process with another start time; every process of this uid holding the
// marker entry; every process an earlier scan returned that still has its start time; every member of a session holding
// one of those. Never the pump or the pump's own session.
function targets(uid: number, entry: string, kept: Map<number, string>, agy?: Identity): number[] {
  const all = processes(uid, entry);
  const live = new Map(all.map((p) => [p.pid, p]));
  for (const [pid, start] of kept) if (live.get(pid)?.start !== start) kept.delete(pid);
  const sids = new Set(all.filter((p) => p.marked || kept.has(p.pid)).map((p) => p.sid));
  if (agy) {
    const now = procStat(agy.pid);
    if (!now || now.start === agy.start) sids.add(agy.sid);
  }
  const own = procStat(process.pid)?.sid;
  if (own !== undefined) sids.delete(own);
  const out = all.filter((p) => p.pid !== process.pid && (p.marked || kept.has(p.pid) || sids.has(p.sid)));
  for (const p of out) kept.set(p.pid, p.start);
  return out.map((p) => p.pid);
}

// TERM, then KILL after the grace, rescanning until nothing is left or the sweep time is up. agy leads its own session,
// but each command it runs leads another, so the marker in agy's environment finds those and their sessions.
async function sweep(d: Deps, lim: Limits, entry: string, agy?: Identity) {
  // Kept across scans: TERM can kill a session's marked leader while a child that cleared its environment lives on.
  const kept = new Map<number, string>();
  const start = d.now();
  let termed = false;
  for (;;) {
    const left = targets(d.uid, entry, kept, agy);
    const elapsed = d.now() - start;
    if (!left.length || elapsed >= lim.sweep) return;
    const kill = elapsed >= lim.grace;
    if (kill || !termed) {
      for (const pid of left) attempt(() => process.kill(pid, kill ? "SIGKILL" : "SIGTERM"), false);
      termed = true;
    }
    await new Promise<void>((done) => d.timers.set(done, 50));
  }
}

// When spawn returns, the exec has happened, so /proc/<pid>/exe names the executed inode; an agy already gone has none.
const exeOf = (pid: number | undefined): Stats | undefined => (pid === undefined ? undefined : attempt(() => statSync(`/proc/${pid}/exe`), undefined));

// ---- Files ----------------------------------------------------------------------------------------------------------

// One no-follow, non-blocking open checked with fstat, so a swap after the open changes nothing and a FIFO cannot block.
function openChecked(path: string, next: string, rule?: (st: Stats) => string | undefined): number {
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (e) {
    throw new Refusal(`${path} cannot be opened (${errCode(e)}); it must be a regular file, not a symlink`, next);
  }
  const st = fstatSync(fd);
  const why = st.isFile() ? rule?.(st) : "is not a regular file";
  if (why) {
    closeSync(fd);
    throw new Refusal(`${path} ${why}`, next);
  }
  return fd;
}

function readChecked(path: string, next: string, rule?: (st: Stats) => string | undefined): string {
  const fd = openChecked(path, next, rule);
  try {
    return readFileSync(fd, "utf8");
  } finally {
    closeSync(fd);
  }
}

const noGroupWrite = (st: Pick<Stats, "mode">) => (st.mode & 0o022 ? "is writable by group or others" : undefined);
// Another user could rewrite a binary they own in place, under the pin.
export const binaryRule = (uid: number) => (st: Pick<Stats, "uid" | "mode">) =>
  st.uid !== uid && st.uid !== 0 ? `is owned by uid ${st.uid}, neither this user nor root` : noGroupWrite(st);

const fileHash = (path: string) => attempt(() => createHash("sha256").update(readFileSync(path)).digest("hex"), "unreadable");

type Bin = { fd: number; path: string; sha: string; version: string; dev: number; ino: number };
// The descriptor stays open: agy runs from it, so a file renamed over the path after the hash never runs.
function openPinned(home: string, uid: number): Bin {
  const pinPath = join(home, ".agents", "gemini-agy");
  const pin = readChecked(pinPath, NEXT.pin, (st) => (st.uid !== uid ? `is not owned by uid ${uid}` : noGroupWrite(st)));
  const m = PIN.exec(pin);
  if (!m) throw new Refusal(`${pinPath} must hold the lines path=<absolute path>, sha256=<64 hex> and version=<agy --version>`, NEXT.pin);
  const [, path, sha, version] = m;
  const fd = openChecked(path, NEXT.pin, binaryRule(uid));
  const st = fstatSync(fd);
  const hash = createHash("sha256");
  const buf = Buffer.alloc(1 << 20);
  for (let n = readSync(fd, buf, 0, buf.length, null); n > 0; n = readSync(fd, buf, 0, buf.length, null)) hash.update(buf.subarray(0, n));
  const actual = hash.digest("hex");
  if (actual !== sha) {
    closeSync(fd);
    throw new Refusal(`agy at ${path} is sha256 ${actual}; the approved one is ${sha} (${version})`, NEXT.pin);
  }
  return { fd, path, sha, version, dev: st.dev, ino: st.ino };
}

const settingsPath = (home: string) => join(home, ".gemini", "antigravity-cli", "settings.json");

// Without modelProvider agy ignores the key and may run on the owner's Google sign-in, a consumer plan.
function readSettings(home: string): string {
  const text = readChecked(settingsPath(home), NEXT.settings);
  const s = parse(text);
  if (!isObj(s) || s.modelProvider !== "gemini") throw new Refusal(`${settingsPath(home)} must set "modelProvider": "gemini"`, NEXT.settings);
  return text;
}

// Home hooks and MCP servers run code with the key at every later start, the owner's own agy included, and a worker can
// plant them. agy creates an empty mcp_config.json itself.
function checkHomeConfig(home: string) {
  const dir = join(home, ".gemini", "config");
  const hooks = join(dir, "hooks.json");
  if (lstatSync(hooks, { throwIfNoEntry: false })) throw new Refusal(`${hooks} exists`, NEXT.config);
  const mcp = join(dir, "mcp_config.json");
  if (!lstatSync(mcp, { throwIfNoEntry: false })) return;
  const text = readChecked(mcp, NEXT.config);
  const v = text.trim() === "" ? {} : parse(text);
  if (!isObj(v) || Object.hasOwn(v, "mcpServers")) throw new Refusal(`${mcp} has an mcpServers entry or is not a JSON object`, NEXT.config);
}

type Checked = { bin: Bin; key: string; settings: string };
// The key is read only after the pin, the binary and the settings have passed.
function checkAll(d: Deps, log: Log): Checked {
  const bin = openPinned(d.home, d.uid);
  try {
    const settings = readSettings(d.home);
    checkHomeConfig(d.home);
    let key: string;
    try {
      key = readKey(join(d.home, ".config", "gemini", ".env"), d.uid);
    } catch (e) {
      throw new Refusal(log.field(errText(e)), NEXT.key);
    }
    log.hide(key);
    if (settings.includes(key)) throw new Refusal(`${settingsPath(d.home)} holds the API key`, NEXT.settings);
    return { bin, key, settings };
  } catch (e) {
    closeSync(bin.fd);
    throw e;
  }
}

function agyEnv(d: Deps, key: string, marker: string): Record<string, string> {
  const w = (name: string) => d.env[`WORKER_${name}`] || undefined;
  const env: Record<string, string | undefined> = {
    HOME: d.home, PATH: [SHIMS, w("PATH")].filter(Boolean).join(":"), USER: w("USER"), LOGNAME: w("LOGNAME"), SHELL: w("SHELL"), LANG: w("LANG"),
    TMPDIR: w("TMPDIR"), TERM: "dumb", GEMINI_API_KEY: key, AGY_CLI_DISABLE_AUTO_UPDATE: "true", GIT_TERMINAL_PROMPT: "0", GEMINI_WORKER: "1",
    CREW_WORKER: "1", GEMINI_WORKER_ID: marker,
  };
  return Object.fromEntries(Object.entries(env).filter((e): e is [string, string] => e[1] !== undefined));
}

// ---- The worker ---------------------------------------------------------------------------------------------------------

type Args = { state: string; worktree: string; model: string; effort: string; cap: number | null; director: number; slug: string };
type Snap = { files: Map<string, string>; head: string; config: string };

function parseArgs(argv: string[]): Args | string {
  const [state = "", worktree = "", model = "", effort = "", cap = "", director = "", ...extra] = argv;
  if (extra.length || !state.startsWith("/") || !worktree.startsWith("/")) {
    return "usage: agy <state dir> <worktree> <model> <effort> <cap, 0 for none> <director pid>, both paths absolute";
  }
  if (!MODEL.test(model)) return "the model must match ^[a-z0-9][a-z0-9.-]*$";
  if (!EFFORTS.includes(effort)) return "the effort must be low, medium or high";
  if (!/^(0|[1-9][0-9]*)$/.test(cap) || !Number.isSafeInteger(Number(cap))) return "the cap must be 0 or a positive whole number of tokens";
  if (!/^[1-9][0-9]*$/.test(director) || !Number.isSafeInteger(Number(director))) return "the director must be a pid";
  return { state, worktree, model, effort, cap: Number(cap) || null, director: Number(director), slug: basename(state) };
}

class Worker {
  private readonly lim: Limits;
  private readonly log: Log;
  private readonly sink = { line: "" };
  private readonly inbox: string;
  private readonly marker: string;
  private logFd = -1;
  private child?: ChildProcess;
  private id?: Identity;
  private key = "";
  private director = { pid: 0, start: "" };
  private conversation: string | null = null;
  private first = true;
  private inFlight: { n: number; from: From } | null = null;
  private background = false;
  private settling = false;
  private busySince: number | null = null;
  private lastOutput = 0;
  private directorChecked = 0;
  private prevTurns = 0;
  private total = 0;
  private turns = 0;
  private count = { tools: 0, toolErrors: 0, stderr: 0, steps: new Set<number>() };
  private texts = new Map<number, { parts: string[]; bytes: number; last: Json }>();
  private maxStep = -1;
  private settledStep = -1;
  private snap?: Snap;
  private gitConfig?: string;
  private lastTyped = 0;
  private timer: unknown;
  private chain: Promise<void> = Promise.resolve();
  private starting: Promise<void> = Promise.resolve();
  private ended = false;
  private resolve: (code: number) => void = () => {};
  private readonly finished = new Promise<number>((done) => {
    this.resolve = done;
  });

  constructor(
    private readonly a: Args,
    private readonly d: Deps,
  ) {
    this.lim = capped(d.limits);
    this.log = new Log((line) => {
      this.sink.line = line;
    });
    this.inbox = join(a.state, "inbox");
    this.marker = `${a.slug}.${randomBytes(16).toString("hex")}`;
  }

  async run(): Promise<number> {
    try {
      const st = lstatSync(this.a.state);
      if (!st.isDirectory() || st.uid !== this.d.uid) throw new Error("it is not a directory owned by this user");
      try {
        mkdirSync(this.inbox, { mode: 0o700 });
      } catch (e) {
        if (errCode(e) !== "EEXIST") throw e;
      }
      const flags = constants.O_WRONLY | constants.O_APPEND | constants.O_CREAT | constants.O_NOFOLLOW;
      this.logFd = openSync(join(this.a.state, "log.ndjson"), flags, 0o600);
    } catch (e) {
      this.d.out(this.scrub(`ERROR: the state dir ${this.a.state} is unusable: ${this.log.field(errText(e))}`));
      this.d.out(`NEXT: ${NEXT.usage}`);
      return 2;
    }
    this.d.out("Ctrl-C stops this worker; a typed line plus Enter messages it.");
    this.d.signals((signal) => this.end(`stopped by ${signal}`, NEXT.review, 0));
    this.starting = this.start();
    try {
      await this.starting;
    } catch (e) {
      const r = e instanceof Refusal ? e : new Refusal(`the pump could not start agy: ${this.log.field(errText(e))}`, NEXT.bug, 1);
      this.end(r.message, r.next, r.code);
      return this.finished;
    }
    if (!this.ended) {
      this.d.input((line) => this.guard(() => this.typed(line)));
      this.guard(() => this.tick());
    }
    return this.finished;
  }

  private async start() {
    const dir = procStat(this.a.director);
    if (!dir) throw new Refusal(`the director, pid ${this.a.director}, is not running`, NEXT.start);
    this.director = { pid: dir.pid, start: dir.start };
    if (!statSync(this.a.worktree, { throwIfNoEntry: false })?.isDirectory()) throw new Refusal(`${this.a.worktree} is not a directory`, NEXT.start);
    if (this.ended) return;
    const c = checkAll(this.d, this.log);
    this.key = c.key;
    const flags = ["--input-format", "stream-json", "--output-format", "stream-json", "--dangerously-skip-permissions", "--model", this.a.model, "--effort", this.a.effort];
    let child: ChildProcess;
    try {
      child = await this.d.spawn(`/proc/self/fd/${c.bin.fd}`, flags, {
        argv0: c.bin.path,
        cwd: this.a.worktree,
        env: agyEnv(this.d, c.key, this.marker),
        detached: true,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } finally {
      closeSync(c.bin.fd);
    }
    this.child = child;
    // A spawn failure leaves no process, which the checks below report.
    child.on("error", () => {});
    if (this.ended) return;
    const p = child.pid === undefined ? undefined : procStat(child.pid);
    if (!p || p.state === "Z") throw new Refusal("agy exited before it could be checked", NEXT.early, 4);
    this.id = { pid: p.pid, sid: p.sid, start: p.start };
    this.write("gw", { type: "spawned", ...this.id, marker: this.marker });
    const exe = exeOf(p.pid);
    if (!exe) throw new Refusal("agy exited before it could be checked", NEXT.early, 4);
    if (exe.dev !== c.bin.dev || exe.ino !== c.bin.ino) throw new Refusal("agy did not run from the approved file", NEXT.pin);
    this.wire(child);
    this.lastOutput = this.directorChecked = this.d.now();
    this.snap = (await this.snapshot()) ?? undefined;
    if (this.ended) return;
    const { worktree, model, effort, cap } = this.a;
    this.write("gw", {
      type: "ready", worktree, model, effort, cap, sha256: c.bin.sha, version: c.bin.version, director: this.director, ...this.id, marker: this.marker,
      conversation: this.conversation,
    });
  }

  private wire(child: ChildProcess) {
    // A dead agy shows as the end of its output.
    child.stdin?.on("error", () => {});
    const ended = () => {
      this.chain = this.chain.then(() => this.end(this.busy() ? "agy exited without a result" : "agy exited", NEXT.review, 1));
    };
    if (child.stdout) lines(child.stdout, (buf, over, size) => this.guard(() => this.onOut(buf, over, size)), ended);
    if (child.stderr) {
      lines(child.stderr, (buf) =>
        this.guard(() => {
          this.lastOutput = this.d.now();
          this.count.stderr++;
          this.write("err", { ev: buf.toString("utf8") });
        }),
      );
    }
  }

  private onOut(buf: Buffer, over: boolean, size: number) {
    this.lastOutput = this.d.now();
    const text = buf.toString("utf8");
    if (!over && text.trim() === "") return;
    // An excerpt of an unparsed line could hold part of a key.
    const ev = over ? `[an unparsed line of ${size} bytes]` : (parse(text) ?? text);
    this.chain = this.chain.then(() => this.event(ev)).catch((e) => this.fail(e));
  }

  private busy() {
    return this.inFlight !== null || this.background;
  }

  private async event(ev: unknown) {
    if (this.ended) return;
    this.conversation ??= conversationOf(ev) ?? null;
    const r = resultOf(ev);
    if (r) {
      this.flushTexts();
      this.write("agy", { ev });
      this.settledStep = this.maxStep;
      return this.finish(r);
    }
    const text = textStep(ev);
    const index = stepIndex(ev);
    if (text) this.buffer(ev as Json, text);
    else if (index !== undefined && stepDone(ev) && this.texts.has(index)) this.flushText(index, ev as Json);
    else this.write("agy", { ev });
    if (!isStep(ev)) return;
    if (index !== undefined) this.maxStep = Math.max(this.maxStep, index);
    // step_index rises across the conversation, so a step at or below the last result's highest is that turn's late DONE.
    // Any later step, asked for or not, is a turn the watchdog bounds.
    if (index === undefined || index > this.settledStep) {
      if (!this.busy()) this.busySince = this.d.now();
      this.background = true;
    }
    const t = toolDone(ev);
    if (t && t.index > this.settledStep && !this.count.steps.has(t.index)) {
      this.count.steps.add(t.index);
      this.count.tools++;
      if (t.error) this.count.toolErrors++;
    }
  }

  // A result answers message n only when its num_turns is n and above every earlier result's; any other is from agy.
  private async finish(r: Result) {
    const n = this.inFlight?.n;
    const from: From = this.inFlight && r.turns === n && r.turns > this.prevTurns ? this.inFlight.from : "agy";
    if (from !== "agy") this.inFlight = null;
    if (r.turns !== undefined) this.prevTurns = Math.max(this.prevTurns, r.turns);
    let tokens: number | null = null;
    if (r.total !== undefined && r.total >= this.total) {
      tokens = r.total - this.total;
      this.total = r.total;
    }
    this.background = false;
    if (!this.busy()) this.busySince = null;
    this.settling = true;
    const prev = this.snap;
    const snap = await this.snapshot();
    if (this.ended) return;
    // Taken after git, so a stderr line written before the result, on its own pipe, still counts for this turn.
    const counts = this.count;
    this.count = { tools: 0, toolErrors: 0, stderr: 0, steps: new Set() };
    if (snap) this.snap = snap;
    const paths = snap ? [...snap.files].filter(([p, sig]) => prev?.files.get(p) !== sig).map(([p]) => p) : null;
    this.write("gw", {
      type: "turn", n: ++this.turns, from, status: r.status, tokens, total: this.total, cap: this.a.cap, tools: counts.tools,
      tool_errors: counts.toolErrors, stderr: counts.stderr, changed: paths?.length ?? null,
      paths: (paths ?? []).slice(0, PATHS_MAX).map((p) => this.scrubString(p).slice(0, PATH_MAX)),
      head: snap && prev ? (snap.head === prev.head ? "same" : "moved") : "unknown",
      gitconfig: snap && prev ? (snap.config === prev.config ? "same" : "changed") : "unknown",
      // Redacted before the cut, so a key straddling it leaves no fragment.
      answer: r.answer === null ? null : tail(this.scrubString(r.answer), ANSWER_MAX),
    });
    this.settling = false;
    // num_turns 0 is agy's session-ending error, whose zero usage is no reading; agy exits next.
    if (this.a.cap !== null && tokens === null && r.turns !== 0) return this.end("usage unreadable", NEXT.unreadable, 1);
    if (this.a.cap !== null && this.total >= this.a.cap) return this.end("cap", NEXT.cap, 1);
    this.dispatch();
  }

  private git(args: string[]): Promise<string | null> {
    const opts = { cwd: this.a.worktree, env: GIT_ENV, timeout: this.lim.git, killSignal: "SIGKILL" as const, maxBuffer: 1 << 26, encoding: "utf8" as const };
    return new Promise((done) => execFile("git", args, opts, (e, out) => done(e ? null : out)));
  }

  // Each dirty path with its status, size and mtime, so a file edited in two turns shows in both.
  private async snapshot(): Promise<Snap | null> {
    if (this.gitConfig === undefined) {
      const common = (await this.git(["rev-parse", "--path-format=absolute", "--git-common-dir"]))?.trim();
      if (common) this.gitConfig = join(common, "config");
    }
    const [status, head] = await Promise.all([
      this.git(["--no-optional-locks", "-c", "core.fsmonitor=false", "status", "--porcelain", "-z"]),
      this.git(["rev-parse", "--verify", "-q", "HEAD"]),
    ]);
    if (status === null) return null;
    const files = new Map<string, string>();
    const parts = status.split("\0");
    for (let i = 0; i < parts.length; i++) {
      const [xy, path] = [parts[i].slice(0, 2), parts[i].slice(3)];
      if (!path) continue;
      // A rename or copy entry is followed by its source path.
      if (/[RC]/.test(xy)) i++;
      const st = lstatSync(join(this.a.worktree, path), { throwIfNoEntry: false });
      files.set(path, st ? `${xy} ${st.size} ${st.mtimeMs}` : `${xy} gone`);
    }
    return { files, head: head?.trim() ?? "", config: this.gitConfig ? fileHash(this.gitConfig) : "unknown" };
  }

  private queue(): string[] {
    return readdirSync(this.inbox)
      .filter((n) => INBOX_NAME.test(n))
      .sort();
  }

  // Only when idle: the head message is logged and deleted before agy reads it, so it is never sent twice.
  private dispatch() {
    if (this.ended || this.settling || this.busy() || !this.child?.stdin) return;
    for (const name of this.queue()) {
      const path = join(this.inbox, name);
      const from: From = name.endsWith("-owner") ? "owner" : "director";
      let text: string | null = null;
      let refused: string | undefined;
      try {
        const raw = readChecked(path, "", (st) => (st.uid !== this.d.uid ? `is not owned by uid ${this.d.uid}` : st.size > MESSAGE_MAX ? `is over ${MESSAGE_MAX} bytes` : undefined));
        if (this.key && raw.includes(this.key)) throw new Error("it holds the API key");
        text = this.frame(raw);
      } catch (e) {
        refused = errText(e);
      }
      this.write("in", { from, name, text, ...(refused === undefined ? {} : { refused }) });
      if (lstatSync(path, { throwIfNoEntry: false })) unlinkSync(path);
      if (text === null) continue;
      // num_turns counts agy's turns, those no message asked for included.
      this.inFlight = { n: this.prevTurns + 1, from };
      this.busySince = this.lastOutput = this.d.now();
      this.child.stdin.write(userEvent(text));
      return;
    }
  }

  private frame(text: string): string {
    const body = text.startsWith(SUBAGENT) ? text.slice(SUBAGENT.length).replace(/^\r?\n/, "") : text;
    const first = this.first;
    this.first = false;
    return [SUBAGENT, ...(first ? [PREAMBLE, ""] : []), body].join("\n");
  }

  private typed(line: string) {
    if (line.trim() === "") return;
    if (this.key && line.includes(this.key)) return this.d.out("refused: that line holds the API key; nothing was sent");
    if (this.queue().length >= QUEUE_MAX) return this.d.out("queue full: wait for a turn to end, then type it again");
    const us = Math.max(this.d.now() * 1000, this.lastTyped + 1);
    this.lastTyped = us;
    const name = `${Math.floor(us / 1e6)}.${String(us % 1e6).padStart(6, "0")}-owner`;
    const tmp = join(this.inbox, `.typed-${randomBytes(6).toString("hex")}`);
    writeFileSync(tmp, line, { flag: "wx", mode: 0o600 });
    renameSync(tmp, join(this.inbox, name));
    this.write("gw", { type: "queued", from: "owner", name });
    this.dispatch();
  }

  private tick() {
    const now = this.d.now();
    if (now - this.directorChecked >= this.lim.director) {
      this.directorChecked = now;
      const p = procStat(this.director.pid);
      if (!p || p.state === "Z" || p.start !== this.director.start) return this.end("director gone", NEXT.review, 1);
    }
    const secs = (ms: number) => `${Math.round(ms / 1000)} s`;
    if (this.busySince !== null && now - this.lastOutput >= this.lim.silence) return this.end(`watchdog: no output from agy for ${secs(this.lim.silence)}`, NEXT.watchdog, 1);
    if (this.busySince !== null && now - this.busySince >= this.lim.turn) return this.end(`watchdog: the turn ran past ${secs(this.lim.turn)}`, NEXT.watchdog, 1);
    this.dispatch();
    this.timer = this.d.timers.set(() => this.guard(() => this.tick()), this.lim.poll);
  }

  private guard(fn: () => void) {
    if (this.ended) return;
    try {
      fn();
    } catch (e) {
      this.fail(e);
    }
  }

  private fail(e: unknown) {
    this.end(`the pump failed: ${this.log.field(errText(e))}`, NEXT.bug, 1);
  }

  // The gone line is written before teardown starts, so wait can report the end while agy's processes are still dying.
  private end(reason: string, next: string, code: number) {
    if (this.ended) return;
    this.ended = true;
    if (this.timer !== undefined) this.d.timers.clear(this.timer);
    const dropped = attempt(() => this.queue(), []);
    attempt(() => this.flushTexts(), undefined);
    // An unwritable log must not stop the teardown.
    attempt(() => this.write("gw", { type: "gone", reason, next, code, dropped }), undefined);
    void (async () => {
      await this.starting.catch(() => {});
      if (this.child) await this.teardown();
      attempt(() => closeSync(this.logFd), undefined);
    })().finally(() => this.resolve(code));
  }

  private async teardown() {
    attempt(() => this.child?.stdin?.end(), undefined);
    await sweep(this.d, this.lim, `GEMINI_WORKER_ID=${this.marker}`, this.id);
  }

  // Never written fragment by fragment: a key split across deltas would pass the redactor piece by piece.
  private buffer(ev: Json, t: { index: number; text: string; done: boolean }) {
    const b = this.texts.get(t.index) ?? { parts: [], bytes: 0, last: ev };
    b.last = ev;
    b.bytes += Buffer.byteLength(t.text);
    if (b.bytes > TEXT_MAX) b.parts.length = 0;
    else b.parts.push(t.text);
    this.texts.set(t.index, b);
    if (t.done) this.flushText(t.index);
  }

  private flushText(index: number, done?: Json) {
    const b = this.texts.get(index);
    if (!b) return;
    this.texts.delete(index);
    this.write("agy", { ev: withText(done ?? b.last, b.bytes > TEXT_MAX ? `[${b.bytes} bytes of text, not kept]` : b.parts.join("")) });
  }

  private flushTexts() {
    for (const index of [...this.texts.keys()]) this.flushText(index);
  }

  private scrub(text: string): string {
    this.log.line(text);
    return this.sink.line;
  }

  // Passed JSON-escaped, so the redactor's flattening spares newlines; a key never needs escaping, so it still matches.
  private scrubString(s: string): string {
    const v = parse(this.scrub(JSON.stringify(s)));
    return typeof v === "string" ? v : "[redacted]";
  }

  private scrubDeep(v: unknown): unknown {
    if (typeof v === "string") return this.scrubString(v);
    if (Array.isArray(v)) return v.map((x) => this.scrubDeep(x));
    if (isObj(v)) return Object.fromEntries(Object.entries(v).map(([k, x]) => [this.scrubString(k), this.scrubDeep(x)]));
    return v;
  }

  private write(src: "agy" | "err" | "in" | "gw", body: Json) {
    const clean = this.scrubDeep(body) as Json;
    const t = new Date(this.d.now()).toISOString();
    writeSync(this.logFd, `${fit(t, src, clean)}\n`);
    this.d.out(this.scrub(`${t.slice(11, 19)} ${src} ${paneText(src, clean)}`));
  }
}

// The owner's own terminal: the pinned agy, checked as for a worker, with no permission flag. What it leaves running is
// swept by its own marker once it exits.
async function tui(argv: string[], d: Deps): Promise<number> {
  const sink = { line: "" };
  const log = new Log((line) => {
    sink.line = line;
  });
  const say = (text: string) => {
    log.line(text);
    d.out(sink.line);
  };
  const [state = "", ...rest] = argv;
  const ok = rest.length === 0 || (rest.length === 1 && rest[0] === "models") || (rest.length === 2 && rest[0] === "--conversation" && UUID.test(rest[1]));
  if (!state.startsWith("/") || !ok) {
    say("ERROR: usage: agy tui <state dir> [models | --conversation <uuid>]");
    say(`NEXT: ${NEXT.usage}`);
    return 2;
  }
  let child: ChildProcess | undefined;
  // Ctrl-C is the terminal's, and agy handles it; a TERM or HUP for this process is meant for agy too.
  d.signals((signal) => {
    if (signal !== "SIGINT") attempt(() => child?.kill(signal as NodeJS.Signals), false);
  });
  let c: Checked;
  try {
    c = checkAll(d, log);
  } catch (e) {
    say(`ERROR: ${e instanceof Refusal ? e.message : log.field(errText(e))}`);
    say(`NEXT: ${e instanceof Refusal ? e.next : NEXT.bug}`);
    return 2;
  }
  const marker = `tui.${randomBytes(16).toString("hex")}`;
  let proc: ChildProcess;
  try {
    proc = await d.spawn(`/proc/self/fd/${c.bin.fd}`, rest, { argv0: c.bin.path, cwd: state, env: agyEnv(d, c.key, marker), stdio: "inherit" });
  } finally {
    closeSync(c.bin.fd);
  }
  child = proc;
  const exited = new Promise<number>((done) => proc.on("close", (code) => done(code ?? 1)));
  const exe = exeOf(proc.pid);
  let code: number;
  if (exe && exe.dev === c.bin.dev && exe.ino === c.bin.ino) code = await exited;
  else {
    attempt(() => proc.kill("SIGKILL"), false);
    say(`ERROR: ${exe ? "agy did not run from the approved file" : "agy exited before it could be checked"}`);
    say(`NEXT: ${exe ? NEXT.pin : NEXT.early}`);
    code = exe ? 2 : 4;
  }
  await sweep(d, capped(d.limits), `GEMINI_WORKER_ID=${marker}`);
  return code;
}

// ---- The review leg's one-shot run --------------------------------------------------------------------------------

// The prompt arrives on stdin; clock is monotonic and bounds the call.
export type RunDeps = Deps & { stdin: (max: number) => Promise<Buffer>; clock: () => number };
const RUN_MODELS = ["gemini-4-neon", "gemini-4-carbon"];
const PROMPT_MAX = 2 * 1024 * 1024;
// The key file's line anywhere in the prompt: the file may hold another key than the one just read.
const KEY_LINE = /^GEMINI_API_KEY=[A-Za-z0-9._-]+\r?$/m;
// Each grants access the skip flag does not, or runs code; setup writes none of them.
const REFUSED = ["allowNonWorkspaceAccess", "toolPermission", "hooks", "mcpServers"];

type RunArgs = { dir: string; top: string; model: string; effort: string; limit: number; turn: number; conversation?: string };
function parseRun(argv: string[], uid: number): RunArgs | string {
  const [dir = "", top = "", model = "", effort = "", limit = "", turn = "", conversation, ...extra] = argv;
  if (extra.length || !dir.startsWith("/") || !top.startsWith("/")) {
    return "usage: agy run <run dir> <top level> <model> <effort> <limit> <turn> [<conversation id>], both paths absolute";
  }
  const st = lstatSync(dir, { throwIfNoEntry: false });
  if (!st?.isDirectory() || st.uid !== uid || st.mode & 0o077) return `${dir} must be a directory of uid ${uid} with mode 700`;
  if (!statSync(top, { throwIfNoEntry: false })?.isDirectory()) return `${top} is not a directory`;
  if (!RUN_MODELS.includes(model)) return `the model must be ${RUN_MODELS.join(" or ")}`;
  if (!EFFORTS.includes(effort)) return "the effort must be low, medium or high";
  if (!/^[1-9][0-9]{5,6}$/.test(limit) || Number(limit) > 4_000_000) return "the limit must be 100000 to 4000000 tokens";
  if (!/^[1-9][0-9]{0,3}$/.test(turn)) return "the turn must be a whole number from 1";
  if ((turn === "1") !== (conversation === undefined)) return "a conversation id goes with every turn after the first, and only with those";
  if (conversation !== undefined && !UUID.test(conversation)) return "the conversation id must be a UUID";
  return { dir, top: realpathSync(top), model, effort, limit: Number(limit), turn: Number(turn), conversation };
}

// A turn runs once. A later one needs the private home free of hooks and MCP servers, and an earlier result that did
// not end on mode or model, which say agy itself ran otherwise than the engine expects.
function turnRefusal(a: RunArgs, priv: string): string | undefined {
  if (lstatSync(join(a.dir, turnFile(a.turn, "prompt", "md")), { throwIfNoEntry: false })) return `turn ${a.turn} has already run in ${a.dir}`;
  const home = lstatSync(priv, { throwIfNoEntry: false });
  if (a.turn === 1) return home ? `${priv} exists before the first turn` : undefined;
  if (!home?.isDirectory()) return `${priv} is not a directory`;
  checkHomeConfig(priv);
  const last = join(a.dir, turnFile(a.turn - 1, "result", "json"));
  const r = attempt(() => parse(readChecked(last, NEXT.run)), undefined);
  if (!isObj(r)) return `${last} is missing or not a JSON object`;
  if (r.tripwire === "mode" || r.tripwire === "model") return `turn ${a.turn - 1} ended on the ${r.tripwire} tripwire, which bars a resume`;
  return undefined;
}

function refusedSetting(text: string): string | undefined {
  const s = parse(text);
  if (!isObj(s)) return "a value that is not an object";
  const p = s.permissions;
  if (p !== undefined && (!isObj(p) || Object.hasOwn(p, "allow") || Object.hasOwn(p, "ask"))) return "permissions allow or ask rules";
  return REFUSED.find((k) => Object.hasOwn(s, k));
}

// modelProvider alone: the data-use choice made at setup reached no local file, so there is nothing else to carry.
function makeHome(priv: string) {
  mkdirSync(priv, { mode: 0o700 });
  for (const sub of ["tmp", join(".gemini", "antigravity-cli")]) mkdirSync(join(priv, sub), { recursive: true, mode: 0o700 });
  writeFileSync(settingsPath(priv), '{"modelProvider":"gemini"}\n', { flag: "wx", mode: 0o600 });
}

export async function run(argv: string[], d: RunDeps): Promise<number> {
  const sink = { line: "" };
  const log = new Log((line) => {
    sink.line = line;
  });
  const say = (text: string) => {
    log.line(text);
    d.out(sink.line);
  };
  const refuse = (message: string, next: string, code: number) => {
    say(`ERROR: ${message}`);
    say(`NEXT: ${next}`);
    return code;
  };
  const why = (e: unknown) => (e instanceof Refusal ? e.message : log.field(errText(e)));
  const a = parseRun(argv, d.uid);
  if (typeof a === "string") return refuse(a, NEXT.run, 2);
  const raw = await d.stdin(PROMPT_MAX);
  if (raw.length > PROMPT_MAX) return refuse(`the prompt is over ${PROMPT_MAX} bytes`, NEXT.run, 2);
  const prompt = raw.toString("utf8");
  const priv = join(a.dir, "home");
  try {
    const refused = turnRefusal(a, priv);
    if (refused) return refuse(refused, NEXT.run, 2);
  } catch (e) {
    return refuse(why(e), e instanceof Refusal ? e.next : NEXT.run, 2);
  }
  let checked: Checked;
  try {
    checked = checkAll(d, log);
  } catch (e) {
    return refuse(why(e), e instanceof Refusal ? e.next : NEXT.unsent, 4);
  }
  const c = checked;
  try {
    const setting = refusedSetting(c.settings);
    if (setting) return refuse(`${settingsPath(d.home)} holds ${setting}, which grants access or runs code`, NEXT.settings, 4);
    if (prompt.includes(c.key) || KEY_LINE.test(prompt)) {
      say("ERROR: the prompt holds the Gemini key: stop and tell the owner");
      return 2;
    }
    if (a.turn === 1) makeHome(priv);
    const lim = capped(d.limits);
    const marker = `run.${randomBytes(16).toString("hex")}`;
    // agy's own state stays in the run dir and never reaches ~/.gemini, which a worker starts from.
    const env = {
      ...agyEnv(d, c.key, marker), HOME: priv, TMPDIR: join(priv, "tmp"), XDG_CONFIG_HOME: join(priv, ".config"),
      XDG_DATA_HOME: join(priv, ".local", "share"), XDG_STATE_HOME: join(priv, ".local", "state"), XDG_CACHE_HOME: join(priv, ".cache"),
    };
    let id: Identity | undefined;
    const start = async (args: string[]) => {
      const child = await d.spawn(`/proc/self/fd/${c.bin.fd}`, args, { argv0: c.bin.path, cwd: a.top, env, detached: true, stdio: ["pipe", "pipe", "pipe"] });
      // A spawn failure leaves no process, which the checks below report.
      child.on("error", () => {});
      const p = child.pid === undefined ? undefined : procStat(child.pid);
      if (p) id = { pid: p.pid, sid: p.sid, start: p.start };
      const exe = p && p.state !== "Z" ? exeOf(p.pid) : undefined;
      if (!exe) throw new Refusal("agy exited before it could be checked", NEXT.unsent, 4);
      if (exe.dev !== c.bin.dev || exe.ino !== c.bin.ino) throw new Refusal("agy did not run from the approved file", NEXT.pin, 4);
      return child;
    };
    // Passed JSON-escaped, so the redactor's flattening spares newlines; a key never needs escaping, so it still matches.
    const redact = (text: string) => {
      log.line(JSON.stringify(text));
      const v = parse(sink.line);
      return typeof v === "string" ? v : "[redacted]";
    };
    return await call({
      ...a, home: d.home, prompt, spawn: start, sweep: () => sweep(d, lim, `GEMINI_WORKER_ID=${marker}`, id), redact, clock: d.clock, now: d.now,
      poll: lim.poll, timers: d.timers, signals: d.signals,
    });
  } catch (e) {
    return refuse(why(e), e instanceof Refusal ? e.next : NEXT.unsent, 4);
  } finally {
    closeSync(c.bin.fd);
  }
}

// Stops past max, so an oversize prompt is refused without being read whole.
async function readStdin(max: number): Promise<Buffer> {
  const parts: Buffer[] = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    parts.push(chunk);
    size += chunk.length;
    if (size > max) break;
  }
  return Buffer.concat(parts);
}

export async function pump(argv: string[], d: Deps): Promise<number> {
  if (argv[0] === "tui") return tui(argv.slice(1), d);
  const a = parseArgs(argv);
  if (typeof a === "string") {
    d.out(`ERROR: ${a}`);
    d.out(`NEXT: ${NEXT.usage}`);
    return 2;
  }
  return new Worker(a, d).run();
}

if (import.meta.main) {
  const deps: Deps = {
    home: userInfo().homedir,
    uid: process.getuid?.() ?? -1,
    now: () => Date.now(),
    timers: { set: (fn, ms) => setTimeout(fn, ms), clear: (h) => clearTimeout(h as ReturnType<typeof setTimeout>) },
    limits: LIMITS,
    spawn: (file, args, opts) => spawn(file, args, opts),
    signals: (stop) => {
      for (const s of ["SIGINT", "SIGHUP", "SIGTERM"] as const) process.on(s, () => stop(s));
    },
    input: (line) => {
      createInterface({ input: process.stdin, terminal: false }).on("line", line);
    },
    // A closed pane loses only the view: the log records everything.
    out: (line) => attempt(() => writeSync(1, `${line}\n`), 0),
    env: process.env,
  };
  const argv = process.argv.slice(2);
  const code = argv[0] === "run" ? await run(argv.slice(1), { ...deps, stdin: readStdin, clock: () => performance.now() }) : await pump(argv, deps);
  process.exit(code);
}
