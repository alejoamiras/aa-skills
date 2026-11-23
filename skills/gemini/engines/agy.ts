// The gemini skill's worker pump, one per worker and the process in its tmux pane. It alone reads the key, owns agy's
// stdin and stdout, writes the log, and enforces the optional token cap and the watchdog. Start it only through engines/agy.
// Usage: agy <state dir> <worktree> <model> <effort> <cap, 0 for none> <director pid>
//        agy tui <state dir> [models | --conversation <uuid>]
import { type ChildProcess, execFile, type SpawnOptions, spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
  closeSync, constants, fstatSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, renameSync, type Stats, statSync, unlinkSync,
  writeFileSync, writeSync,
} from "node:fs";
import { userInfo } from "node:os";
import { basename, join } from "node:path";
import { createInterface } from "node:readline";
import { Log, readKey } from "./api.ts";
import { conversationOf, fit, isObj, isStep, type Json, lines, paneText, type Result, resultOf, tail, toolDone, userEvent } from "./agy-stream.ts";

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
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PIN = /^path=(\/[^\n]*)\nsha256=([0-9a-f]{64})\nversion=([^\n]+)\n?$/;
// send names a message $EPOCHREALTIME-$$, which sorts in send order, and a typed line takes the suffix -owner; any other
// name, a sender's temp file included, is not a message.
const INBOX_NAME = /^[0-9]+\.[0-9]{6}-(?:[0-9]+|owner)$/;
const QUEUE_MAX = 20;
const MESSAGE_MAX = 256 * 1024;
const ANSWER_MAX = 8000;
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
};

export const LIMITS = { silence: 15 * 60_000, turn: 30 * 60_000, director: 30_000, grace: 5_000, sweep: 10_000, git: 10_000, poll: 500 };
export type Limits = typeof LIMITS;
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

const noGroupWrite = (st: Stats) => (st.mode & 0o022 ? "is writable by group or others" : undefined);

const fileHash = (path: string) => attempt(() => createHash("sha256").update(readFileSync(path)).digest("hex"), "unreadable");

type Bin = { fd: number; path: string; sha: string; version: string; dev: number; ino: number };
// The descriptor stays open: agy runs from it, so a file renamed over the path after the hash never runs.
function openPinned(home: string, uid: number): Bin {
  const pinPath = join(home, ".agents", "gemini-agy");
  const pin = readChecked(pinPath, NEXT.pin, (st) => (st.uid !== uid ? `is not owned by uid ${uid}` : noGroupWrite(st)));
  const m = PIN.exec(pin);
  if (!m) throw new Refusal(`${pinPath} must hold the lines path=<absolute path>, sha256=<64 hex> and version=<agy --version>`, NEXT.pin);
  const [, path, sha, version] = m;
  const fd = openChecked(path, NEXT.pin, noGroupWrite);
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

type Checked = { bin: Bin; key: string };
// In this order: the pin, the binary's hash, modelProvider, the home config, the key, then settings without the key.
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
    return { bin, key };
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
  private id?: { pid: number; sid: number; start: string };
  private director = { pid: 0, start: "" };
  private conversation: string | null = null;
  private first = true;
  private dispatched = 0;
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
    this.lim = Object.fromEntries(Object.entries(LIMITS).map(([k, v]) => [k, Math.min(v, d.limits[k as keyof Limits])])) as Limits;
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
    if (child.stdout) lines(child.stdout, (buf, over) => this.guard(() => this.onOut(buf, over)), ended);
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

  private onOut(buf: Buffer, over: boolean) {
    this.lastOutput = this.d.now();
    const text = buf.toString("utf8");
    if (!over && text.trim() === "") return;
    const ev = over ? text : (parse(text) ?? text);
    this.chain = this.chain.then(() => this.event(ev)).catch((e) => this.fail(e));
  }

  private busy() {
    return this.inFlight !== null || this.background;
  }

  private async event(ev: unknown) {
    if (this.ended) return;
    this.write("agy", { ev });
    this.conversation ??= conversationOf(ev) ?? null;
    const r = resultOf(ev);
    if (r) return this.finish(r);
    if (!isStep(ev)) return;
    // Any step after the last result, asked for or not, is a turn the watchdog bounds.
    if (!this.busy()) this.busySince = this.d.now();
    this.background = true;
    const t = toolDone(ev);
    if (t && !this.count.steps.has(t.index)) {
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
    if (this.a.cap !== null && tokens === null) return this.end("usage unreadable", NEXT.unreadable, 1);
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
        text = this.frame(raw);
      } catch (e) {
        refused = errText(e);
      }
      this.write("in", { from, name, text, ...(refused === undefined ? {} : { refused }) });
      if (lstatSync(path, { throwIfNoEntry: false })) unlinkSync(path);
      if (text === null) continue;
      this.inFlight = { n: ++this.dispatched, from };
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

  // Every exit path: the gone line, then agy's teardown, then the code.
  private end(reason: string, next: string, code: number) {
    if (this.ended) return;
    this.ended = true;
    if (this.timer !== undefined) this.d.timers.clear(this.timer);
    const dropped = attempt(() => this.queue(), []);
    // An unwritable log must not stop the teardown.
    attempt(() => this.write("gw", { type: "gone", reason, next, code, dropped }), undefined);
    void (async () => {
      await this.starting.catch(() => {});
      if (this.child) await this.teardown();
      attempt(() => closeSync(this.logFd), undefined);
    })().finally(() => this.resolve(code));
  }

  // TERM, then KILL after the grace, rescanning until nothing is left or the sweep time is up. agy leads its own session,
  // but each command it runs leads another, so the marker in agy's environment finds those and their sessions.
  private async teardown() {
    attempt(() => this.child?.stdin?.end(), undefined);
    const entry = `GEMINI_WORKER_ID=${this.marker}`;
    const start = this.d.now();
    let termed = false;
    for (;;) {
      const left = this.targets(entry);
      const elapsed = this.d.now() - start;
      if (!left.length || elapsed >= this.lim.sweep) return;
      const kill = elapsed >= this.lim.grace;
      if (kill || !termed) {
        for (const pid of left) attempt(() => process.kill(pid, kill ? "SIGKILL" : "SIGTERM"), false);
        termed = true;
      }
      await new Promise<void>((done) => this.d.timers.set(done, 50));
    }
  }

  // agy's session, unless its pid now names a process with another start time; every process of this uid holding the
  // marker; every member of a session holding one. Never the pump or the pump's own session.
  private targets(entry: string): number[] {
    const all = processes(this.d.uid, entry);
    const sids = new Set(all.filter((p) => p.marked).map((p) => p.sid));
    if (this.id) {
      const now = procStat(this.id.pid);
      if (!now || now.start === this.id.start) sids.add(this.id.sid);
    }
    const own = procStat(process.pid)?.sid;
    if (own !== undefined) sids.delete(own);
    return all.filter((p) => p.pid !== process.pid && (p.marked || sids.has(p.sid))).map((p) => p.pid);
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

// The owner's own terminal: the pinned agy, checked as for a worker, with no permission flag.
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
  // agy owns the terminal: Ctrl-C is its to handle.
  d.signals(() => {});
  let c: Checked;
  try {
    c = checkAll(d, log);
  } catch (e) {
    say(`ERROR: ${e instanceof Refusal ? e.message : log.field(errText(e))}`);
    say(`NEXT: ${e instanceof Refusal ? e.next : NEXT.bug}`);
    return 2;
  }
  let child: ChildProcess;
  try {
    const env = agyEnv(d, c.key, `tui.${randomBytes(16).toString("hex")}`);
    child = await d.spawn(`/proc/self/fd/${c.bin.fd}`, rest, { argv0: c.bin.path, cwd: state, env, stdio: "inherit" });
  } finally {
    closeSync(c.bin.fd);
  }
  const exited = new Promise<number>((done) => child.on("close", (code) => done(code ?? 1)));
  const exe = exeOf(child.pid);
  if (exe && exe.dev === c.bin.dev && exe.ino === c.bin.ino) return exited;
  attempt(() => child.kill("SIGKILL"), false);
  say(`ERROR: ${exe ? "agy did not run from the approved file" : "agy exited before it could be checked"}`);
  say(`NEXT: ${exe ? NEXT.pin : NEXT.early}`);
  return exe ? 2 : 4;
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
  const code = await pump(process.argv.slice(2), {
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
  });
  process.exit(code);
}
