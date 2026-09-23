// Helpers shared by the scripts: the ledger (workspace, lock, validated fold) and FFmpeg input checks.
import { Database } from "bun:sqlite";
import { appendFileSync, existsSync, readFileSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";

// ---------- ledger ----------
export type Event = "reserved" | "submitted" | "done" | "failed" | "released";
export type Row = {
  ts: string;
  ref?: string;
  spot?: string;
  dir?: string;
  name?: string;
  model?: string;
  event?: Event;
  credits?: number;
  jobId?: string;
  pid?: number;
  host?: string;
  secs?: number;
  status?: string;
  file?: string;
  balance?: number;
  note?: string;
};
/**
 * One job. `credits` is what it commits against the cap: the quote from reservation until the job
 * fails or the reservation is released. "legacy" marks a row written on completion, before reservations.
 */
export type Entry = {
  ref: string;
  spot: string;
  dir?: string;
  name: string;
  model: string;
  quote: number;
  credits: number;
  state: Event | "legacy";
  jobId?: string;
  /** Submission time in ms; legacy rows back it out from `secs`. */
  since: number;
  /** The reserving process, which alone may still be submitting. */
  pid?: number;
  host?: string;
  anomaly?: string;
};

/** $HF_WORKSPACE, else the nearest ancestor of `from` that holds expenses.jsonl. */
export function workspaceFor(from: string) {
  if (process.env.HF_WORKSPACE) return realpathSync(process.env.HF_WORKSPACE);
  for (let d = from; ; d = dirname(d)) {
    if (existsSync(join(d, "expenses.jsonl"))) return d;
    if (dirname(d) === d) throw new Error(`no expenses.jsonl above ${from}: set HF_WORKSPACE to start a workspace`);
  }
}

export const ledgerPath = (ws: string) => join(ws, "expenses.jsonl");

export function readLedger(ws: string): Row[] {
  const f = ledgerPath(ws);
  if (!existsSync(f)) return [];
  return readFileSync(f, "utf8")
    .split("\n")
    .map((l, i) => {
      if (!l) return undefined;
      try {
        return JSON.parse(l) as Row;
      } catch {
        throw new Error(`${f} line ${i + 1} is not JSON`);
      }
    })
    .filter((r): r is Row => r !== undefined);
}

/** Appends one row. Call it inside withLock, so every transition is checked against the rows before it. */
export const appendRow = (ws: string, row: Omit<Row, "ts">) =>
  appendFileSync(ledgerPath(ws), `${JSON.stringify({ ts: new Date().toISOString(), ...row })}\n`);

/**
 * Runs `fn` holding an SQLite exclusive lock on `path`, which the OS drops when its holder dies. A crash
 * never wedges it and a paused holder is never robbed; waiters give up after a minute. Never nest it:
 * a second connection in one process waits on the first, and closing either drops both.
 */
export function withFileLock<T>(path: string, fn: () => T): T {
  const db = new Database(path, { create: true });
  try {
    db.exec("PRAGMA busy_timeout = 60000");
    try {
      db.exec("BEGIN EXCLUSIVE");
    } catch {
      throw new Error(`${path} has been locked for a minute: another run is paused or stuck`);
    }
    try {
      return fn();
    } finally {
      db.exec("COMMIT");
    }
  } finally {
    db.close();
  }
}

/** Runs `fn` holding the workspace's ledger lock. */
export const withLock = <T>(ws: string, fn: () => T): T => withFileLock(join(ws, ".ledger.lock"), fn);

/**
 * Folds the append-only rows into one entry per job, and throws on any row that breaks the event
 * order, names a job twice or carries a bad amount: an inconsistent ledger must not approve spend.
 */
export function foldLedger(rows: Row[]): Entry[] {
  const refs = new Map<string, Entry>();
  const jobs = new Map<string, string>();
  rows.forEach((r, i) => {
    const bad = (why: string): never => {
      throw new Error(`expenses.jsonl line ${i + 1}: ${why}`);
    };
    const own = (jobId: string, ref: string) => {
      const other = jobs.get(jobId);
      if (other !== undefined && other !== ref) bad(`job ${jobId} is recorded under both ${other} and ${ref}`);
      jobs.set(jobId, ref);
    };
    if (r.credits !== undefined && !(typeof r.credits === "number" && Number.isFinite(r.credits) && r.credits >= 0)) {
      bad(`credits must be a non-negative number, not ${JSON.stringify(r.credits)}`);
    }

    if (!r.event) {
      const ref = r.jobId ?? `row-${i + 1}`;
      if (refs.has(ref)) bad(`job ${ref} is recorded twice`);
      if (r.jobId) own(r.jobId, ref);
      const credits = r.status === "failed" ? 0 : (r.credits ?? 0);
      refs.set(ref, { ref, spot: r.spot ?? "?", name: r.name ?? "?", model: r.model ?? "?", quote: credits, credits, state: "legacy", jobId: r.jobId, since: Date.parse(r.ts) - (r.secs ?? 0) * 1000 });
      return;
    }

    const ref = r.ref ?? bad(`a ${r.event} row without a ref`);
    if (r.event === "reserved") {
      if (refs.has(ref)) bad(`ref ${ref} is reserved twice`);
      if (r.credits === undefined || !r.spot || r.dir === undefined || !r.name || !r.model) bad("a reservation needs credits, spot, dir, name and model");
      refs.set(ref, { ref, spot: r.spot, dir: r.dir, name: r.name, model: r.model, quote: r.credits, credits: r.credits, state: "reserved", since: Date.parse(r.ts), pid: r.pid, host: r.host });
      return;
    }
    const e = refs.get(ref);
    if (!e || e.state === "legacy") return bad(`${r.event} for ${ref}, which was never reserved`);
    if (r.jobId) {
      if (e.jobId && e.jobId !== r.jobId) bad(`${ref} names two jobs, ${e.jobId} and ${r.jobId}`);
      own(r.jobId, ref);
      e.jobId = r.jobId;
    }
    const from = e.state;
    if (r.event === "submitted") {
      if (!r.jobId) bad("submitted without a job id");
      // A release that raced the submission: the job exists, so it bills again.
      if (from === "released") e.anomaly = "released before its job was recorded";
      else if (from !== "reserved" && from !== "submitted") bad(`submitted after ${from}`);
    } else if (r.event === "done" || r.event === "failed") {
      if (!e.jobId) bad(`${r.event} without a job id`);
      if (from !== "submitted" && from !== r.event) bad(`${r.event} after ${from}`);
    } else if (r.event === "released") {
      if (e.jobId) bad("released a reservation that has a job");
      if (from !== "reserved" && from !== "released") bad(`released after ${from}`);
    } else {
      bad(`unknown event ${JSON.stringify(r.event)}`);
    }
    e.state = r.event;
    e.credits = r.event === "failed" || r.event === "released" ? 0 : e.quote;
  });
  return [...refs.values()];
}

export const isOpen = (e: Entry) => e.state === "reserved" || e.state === "submitted";

/** Whether `pid` names a live process. EPERM means it exists under another user. */
export function pidAlive(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

/** Runs the Higgsfield CLI with --json and returns the parsed output, or throws with its error text. */
export function hfJson(args: string[]): unknown {
  const p = Bun.spawnSync(["higgsfield", ...args, "--json", "--no-color"], { stdout: "pipe", stderr: "pipe" });
  const out = p.stdout.toString();
  if (p.exitCode === 0) {
    const parsed = parseJson(out);
    if (parsed !== undefined) return parsed;
  }
  throw new Error(`higgsfield ${args.slice(0, 2).join(" ")} failed: ${(p.stderr.toString() || out).trim().slice(0, 300)}`);
}

/** The JSON document in CLI output that may carry progress text before it; undefined when there is none. */
export function parseJson(text: string): unknown {
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "[" && text[i] !== "{") continue;
    if (i > 0 && text[i - 1] !== "\n") continue;
    try {
      return JSON.parse(text.slice(i));
    } catch {}
  }
  return undefined;
}

export type Job = { id: string; created_at: string; job_type?: string; status?: string; result_url?: string; params?: Record<string, unknown> };

/** The account's most recent jobs, newest first; the API caps `size` at 100 and has no paging. */
export function recentJobs(size: number): Job[] {
  const listed = hfJson(["generate", "list", "--size", String(size)]);
  if (!Array.isArray(listed) || listed.some((j) => typeof j?.id !== "string" || Number.isNaN(Date.parse(j?.created_at)))) {
    throw new Error("generate list returned an unexpected shape");
  }
  return listed as Job[];
}

// ---------- FFmpeg ----------
/** Returns `path` unchanged, or throws if FFmpeg's filtergraph parser would split or unquote it. */
export function filterPath(path: string): string {
  if (/[:,;'"\\[\]=\s]/.test(path)) throw new Error(`"${path}" has a character FFmpeg's filter parser treats specially; use a plain path`);
  return path;
}

/** The DRAWTEXT_FONT file as a drawtext option, else fontconfig's default face. */
export const drawtextFont = () => (process.env.DRAWTEXT_FONT ? `fontfile=${filterPath(process.env.DRAWTEXT_FONT)}` : "font=Sans");

/**
 * The first video stream's size, frame rate and frame count; throws when ffprobe can't read it.
 * `decode` counts decoded frames and fails on any decoder error, instead of trusting the container.
 */
export function probeVideo(file: string, { decode = false } = {}) {
  const count = decode ? ["-count_frames"] : ["-count_packets"];
  const field = decode ? "nb_read_frames" : "nb_read_packets";
  const p = Bun.spawnSync(
    ["ffprobe", "-v", "error", "-select_streams", "v:0", ...count, "-show_entries", `stream=width,height,r_frame_rate,${field}`, "-of", "json", file],
    { stdout: "pipe", stderr: "pipe" },
  );
  const err = p.stderr.toString().trim();
  if (decode && err) throw new Error(`decoding ${file} reported errors: ${err.slice(0, 300)}`);
  const s = p.exitCode === 0 ? JSON.parse(p.stdout.toString()).streams?.[0] : undefined;
  const [num, den] = String(s?.r_frame_rate ?? "").split("/").map(Number);
  const v = { width: Number(s?.width), height: Number(s?.height), fps: num / (den || 1), frames: Number(s?.[field]) };
  if (!(v.width > 0 && v.height > 0 && v.fps > 0 && v.frames > 0)) throw new Error(`ffprobe can't read a video stream in ${file}: ${err}`);
  return v;
}
