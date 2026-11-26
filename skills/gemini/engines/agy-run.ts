// The review leg's one call of agy, headless: the prompt as one turn, the stream read to its end, the limit, the
// tripwires, the verdict and teardown, and one wrap-up turn after a spent limit. agy.ts starts it with every outside
// effect handed over; it never reads the key file and is given no key value.
import type { ChildProcess } from "node:child_process";
import { closeSync, openSync, realpathSync, writeFileSync, writeSync } from "node:fs";
import { join } from "node:path";
import {
  initOf, isObj, type Json, lines, modelDone, namesTool, type Outcome, outcomeOf, stepDone, stepIndex, textStep, toolDone, toolOutput, type Usage,
  UUID, userEvent, withOutput, withText,
} from "./agy-stream.ts";

const DEADLINE = 40 * 60_000;
const SILENCE = 12 * 60_000;
const LINE_MAX = 8 * 1024 * 1024;
const KEEP_MAX = 64 * 1024;
// What agy reports under --dangerously-skip-permissions.
const MODE = "always-proceed";
const WRAP_TEXT = "Your budget is spent. Answer now from what you have already read.";
// The edit tools only: a command can still write, so this is hardening, not a boundary.
const OPEN_DENY = ["write_file(*)"];
// command(*) and write_file(*) are shown to hold under the skip flag; read_file(*) is inferred from its path-scoped form.
const WRAP_DENY = ["command(*)", "write_file(*)", "read_file(*)"];
const CAP = /\b402\b|prepayment credits are depleted|RESOURCE_EXHAUSTED|\bquota|\bspend|\bbilling|\b429\b/i;

export type Reason = "mode" | "model" | "tool" | "denied" | "empty" | "usage" | "limit" | "timeout" | "cap" | "error";
const TRIPWIRES: Reason[] = ["mode", "model", "tool"];

export type Call = {
  dir: string; top: string; home: string; model: string; effort: string; limit: number; turn: number; conversation?: string; prompt: string;
  // Starts the pinned agy in the top level; it throws, nothing sent, when agy did not run from the approved file.
  spawn: (args: string[]) => Promise<ChildProcess>;
  sweep: () => Promise<void>;
  redact: (text: string) => string;
  // clock is monotonic and bounds the call; now only stamps the log.
  clock: () => number; now: () => number; poll: number;
  timers: { set: (fn: () => void, ms: number) => unknown; clear: (handle: unknown) => void };
  signals: (stop: (signal: string) => void) => void;
};

export const turnFile = (turn: number, name: string, ext: string) => (turn === 1 ? `${name}.${ext}` : `${name}.${turn}.${ext}`);

const ZERO: Usage = { input: 0, output: 0, cached: 0, counted: 0 };
const plus = (a: Usage, b: Usage): Usage => ({ input: a.input + b.input, output: a.output + b.output, cached: a.cached + b.cached, counted: a.counted + b.counted });
const head = (s: string, max: number) => Buffer.from(s).subarray(0, max).toString("utf8");
const flags = (c: Call, deny: string[], conversation?: string) => [
  "--dangerously-skip-permissions", "--input-format", "stream-json", "--output-format", "stream-json", "--model", c.model, "--effort", c.effort,
  "--settings", JSON.stringify({ modelProvider: "gemini", permissions: { deny } }), ...(conversation ? ["--conversation", conversation] : []),
];

// One agy process: the call's turn, or its wrap-up. end is set when the engine ended it before agy did.
type Shot = { steps: Usage; init: boolean; conversation?: string; result?: Outcome; end?: Reason };

// The failure, or undefined for an answer.
function verdict(s: Shot): Reason | undefined {
  if (s.end) return s.end;
  const r = s.result;
  if (!s.init || !r) return "error";
  if (r.status === "ERROR") return CAP.test(r.error) ? "cap" : "error";
  if (r.status !== "SUCCESS") return "error";
  if (r.response.trim() === "") return r.denied.length ? "denied" : "empty";
  return undefined;
}

class Run {
  private readonly start: number;
  private log = -1;
  private err = -1;
  private used = 0;
  private tools = 0;
  private unparsed = 0;
  private capped = 0;
  private stopped = false;
  private stop?: () => void;

  constructor(private readonly c: Call) {
    this.start = c.clock();
  }

  async go(): Promise<number> {
    const c = this.c;
    c.signals(() => {
      this.stopped = true;
      this.stop?.();
    });
    let child: ChildProcess;
    try {
      child = await c.spawn(flags(c, OPEN_DENY, c.conversation));
    } catch (e) {
      await c.sweep();
      throw e;
    }
    try {
      this.write(turnFile(c.turn, "prompt", "md"), c.prompt);
      this.log = openSync(join(c.dir, turnFile(c.turn, "log", "ndjson")), "wx", 0o600);
      this.err = openSync(join(c.dir, turnFile(c.turn, "stderr", "txt")), "wx", 0o600);
      const first = await this.shot(child, c.prompt, false);
      const id = c.conversation ?? first.conversation;
      let wrap: Shot | undefined;
      if (first.end === "limit" && !this.stopped && id && this.used * 100 < c.limit * 115) {
        // A wrap-up that cannot start leaves the call ended limit.
        const next = await c.spawn(flags(c, WRAP_DENY, id)).catch(() => undefined);
        wrap = next && (await this.shot(next, WRAP_TEXT, true));
      }
      return this.finish(first, wrap, id);
    } catch (e) {
      await c.sweep();
      this.note({ failed: c.redact(e instanceof Error ? e.message : String(e)) });
      return 1;
    } finally {
      for (const fd of [this.log, this.err]) if (fd >= 0) closeSync(fd);
    }
  }

  // Ends at agy's exit with its stdout drained, or at the first event that decides the call; either way after sweep.
  private shot(child: ChildProcess, text: string, wrapup: boolean): Promise<Shot> {
    const c = this.c;
    const s: Shot = { steps: ZERO, init: false };
    const models = new Set<number>();
    const tools = new Set<number>();
    const texts = new Map<number, { parts: string[]; bytes: number; last: Json }>();
    // A wrap-up runs past the limit by design and is killed past 1.15 times it.
    const past = (used: number) => (wrapup ? used * 100 > c.limit * 115 : used > c.limit);
    let last = c.clock();
    let timer: unknown;
    let settled = false;
    this.note({ spawned: wrapup ? "wrap-up" : "turn" });

    // Never written fragment by fragment: a key split across deltas would pass the redactor piece by piece.
    const flush = (index: number, done?: Json) => {
      const b = texts.get(index);
      if (!b) return;
      texts.delete(index);
      if (b.bytes > KEEP_MAX) this.capped += b.bytes;
      this.agy(withText(done ?? b.last, b.bytes > KEEP_MAX ? `[${b.bytes} bytes of text, not kept]` : b.parts.join("")));
    };
    const buffer = (ev: Json, t: { index: number; text: string; done: boolean }) => {
      const b = texts.get(t.index) ?? { parts: [], bytes: 0, last: ev };
      b.last = ev;
      b.bytes += Buffer.byteLength(t.text);
      if (b.bytes > KEEP_MAX) b.parts.length = 0;
      else b.parts.push(t.text);
      texts.set(t.index, b);
      if (t.done) flush(t.index);
    };

    const event = (ev: Json): Reason | undefined => {
      const init = initOf(ev);
      if (init) {
        this.agy(ev);
        if (init.conversation && UUID.test(init.conversation)) s.conversation = init.conversation;
        if (init.mode !== MODE) return "mode";
        if (init.model !== c.model && init.model !== `${c.model}-${c.effort}`) return "model";
        if (!s.conversation) return "error";
        s.init = true;
        return undefined;
      }
      // A schedule step stays ACTIVE until killed.
      if (namesTool(ev, "schedule")) {
        this.agy(ev);
        return "tool";
      }
      const r = outcomeOf(ev);
      if (r) {
        this.agy(ev);
        s.result = r;
        return s.init ? undefined : "error";
      }
      const t = textStep(ev);
      const index = stepIndex(ev);
      if (t) buffer(ev, t);
      else if (index !== undefined && stepDone(ev) && texts.has(index)) flush(index, ev);
      else this.agy(ev);
      const tool = toolDone(ev);
      if (tool && !tools.has(tool.index)) {
        tools.add(tool.index);
        this.tools++;
      }
      const m = modelDone(ev);
      if (!m || (m.index !== undefined && models.has(m.index))) return undefined;
      if (m.index !== undefined) models.add(m.index);
      if (!m.usage) return "usage";
      s.steps = plus(s.steps, m.usage);
      this.used += m.usage.counted;
      return past(this.used) ? "limit" : undefined;
    };

    return new Promise<Shot>((resolve) => {
      const settle = async (reason?: Reason) => {
        if (settled) return;
        settled = true;
        s.end = reason;
        c.timers.clear(timer);
        this.stop = undefined;
        for (const index of [...texts.keys()]) flush(index);
        if (reason) this.note({ ended: reason });
        await c.sweep().catch(() => {});
        child.stdout?.destroy();
        child.stderr?.destroy();
        resolve(s);
      };
      const unparsed = (size: number) => {
        this.unparsed += size;
        this.note({ unparsed: size });
        void settle("error");
      };
      // An overlong line has already settled the shot when it crossed the bound.
      const line = (buf: Buffer, _over: boolean, size: number) => {
        if (settled) return;
        last = c.clock();
        const raw = buf.toString("utf8");
        if (raw.trim() === "") return;
        let ev: unknown;
        try {
          ev = JSON.parse(raw);
        } catch {
          return unparsed(size);
        }
        if (!isObj(ev) || typeof ev.event !== "string") return unparsed(size);
        try {
          const why = event(ev);
          if (why) void settle(why);
        } catch {
          void settle("error");
        }
      };
      let open = 2;
      const drained = () => {
        if (--open === 0) void settle();
      };
      this.stop = () => void settle("error");
      if (this.stopped) return void settle("error");
      child.once("close", drained);
      const crossed = (size: number) => {
        if (!settled) unparsed(size);
      };
      if (child.stdout) lines(child.stdout, line, drained, { max: LINE_MAX, crossed });
      else drained();
      // An overlong stderr line is kept by its length only: a cut could leave a fragment of a key the redactor misses.
      if (child.stderr) lines(child.stderr, (buf, over, size) => writeSync(this.err, `${over ? `[a line of ${size} bytes]` : c.redact(buf.toString("utf8"))}\n`));
      child.stdin?.on("error", () => {});
      child.stdin?.end(userEvent(text));
      const tick = () => {
        const now = c.clock();
        if (now - this.start >= DEADLINE || now - last >= SILENCE) return void settle("timeout");
        timer = c.timers.set(tick, c.poll);
      };
      timer = c.timers.set(tick, c.poll);
    });
  }

  // Only the first turn of a new conversation reports its result's usage, and only when it failed with more counted
  // there than in its steps: every other result also counts the conversation's earlier turns.
  private finish(first: Shot, wrap: Shot | undefined, id: string | undefined): number {
    const c = this.c;
    const reason = verdict(wrap ?? first);
    const failed = reason !== undefined || wrap !== undefined;
    const r = first.result?.usage;
    const own = c.turn === 1 && failed && r && r.counted > first.steps.counted ? r : first.steps;
    const usage = wrap ? plus(own, wrap.steps) : own;
    const response = reason ? null : turnFile(c.turn, "response", "md");
    const answer = (wrap ?? first).result?.response ?? "";
    if (response) this.write(response, c.redact(this.relative(c.redact(answer))));
    if (c.turn === 1 && id) this.write("session_id", `${id}\n`);
    const last = wrap?.result ?? first.result;
    this.write(turnFile(c.turn, "result", "json"), `${JSON.stringify({
      verdict: reason ? "unavailable" : "answered", reason: reason ?? null, tripwire: reason && TRIPWIRES.includes(reason) ? reason : null,
      model: c.model, effort: c.effort, turn: c.turn, in: usage.input, out: usage.output, cached: usage.cached, counted: usage.counted,
      agy_usage: this.clean(last?.raw ?? null), tools: this.tools, seconds: Math.round((c.clock() - this.start) / 1000),
      denied_actions: (last?.denied ?? []).map((a) => c.redact(a)), unparsed_bytes: this.unparsed, capped_bytes: this.capped, response,
    }, null, 2)}\n`);
    return reason ? 1 : 0;
  }

  // The top level first, so a top level under the home stays repo-relative; agy links each file it names as
  // file://<absolute path>. Each prefix is matched as given and resolved.
  private relative(text: string): string {
    const forms = (p: string) => [...new Set([p, realpathSync(p)])];
    let t = text;
    for (const top of forms(this.c.top)) t = t.split(`file://${top}/`).join("").split(`${top}/`).join("");
    for (const home of forms(this.c.home)) t = t.split(`${home}/`).join("~/");
    return t;
  }

  // The output is redacted whole before the cut, so a key straddling it leaves no fragment.
  private agy(ev: Json) {
    const out = toolOutput(ev);
    const bytes = out === undefined ? 0 : Buffer.byteLength(out);
    if (out !== undefined && bytes > KEEP_MAX) this.capped += bytes;
    const kept = out !== undefined && bytes > KEEP_MAX ? withOutput(ev, head(this.c.redact(out), KEEP_MAX), bytes) : ev;
    this.note({ src: "agy", ev: kept });
  }

  private note(body: Json) {
    const entry = { t: new Date(this.c.now()).toISOString(), src: "run", ...body };
    if (this.log >= 0) writeSync(this.log, `${JSON.stringify(this.clean(entry))}\n`);
  }

  private clean(v: unknown): unknown {
    if (typeof v === "string") return this.c.redact(v);
    if (Array.isArray(v)) return v.map((x) => this.clean(x));
    if (isObj(v)) return Object.fromEntries(Object.entries(v).map(([k, x]) => [this.c.redact(k), this.clean(x)]));
    return v;
  }

  private write(name: string, data: string) {
    writeFileSync(join(this.c.dir, name), data, { flag: "wx", mode: 0o600 });
  }
}

// Exit 0 answered, 1 sent with no answer kept; a failure to start agy throws, with nothing sent or written.
export const call = (c: Call): Promise<number> => new Run(c).go();
