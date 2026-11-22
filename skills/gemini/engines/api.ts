// The gemini skill's api engine, the only process that reads the Gemini key. Start it through engines/api only.
// Usage: api <absolute gemini-dir> <turn> submit|collect
// It writes only the turn's id file, answer and ended marker, each complete or not at all; its output is the turn's log.
import { randomBytes } from "node:crypto";
import { closeSync, constants, fstatSync, linkSync, lstatSync, openSync, readFileSync, rmSync, unlinkSync, writeFileSync, writeSync } from "node:fs";
import { userInfo } from "node:os";
import { join } from "node:path";

const ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/interactions";
const REVISION = "2026-05-20";
const DEFAULT_MODEL = "gemini-4-carbon";
const MAX_OUTPUT_TOKENS = 65_536;
const CALL_TIMEOUT = 60_000;
const WAIT = 30 * 60_000;
const FAILS = 5;
const ID = /^[A-Za-z0-9_-]{1,512}$/;
const MODEL = /^[a-z0-9][a-z0-9.-]*$/;
// JSON, percent and form encoding all leave these characters as they are, so an echoed key stays a literal match for
// the redactor.
const KEY_LINE = /^GEMINI_API_KEY=([A-Za-z0-9._-]+)\n?$/;
const EFFORTS = ["low", "medium", "high"];
const STATUSES = new Set(["in_progress", "completed", "failed", "cancelled", "incomplete", "requires_action", "requires_continuation"]);
// GET returns this turn's user_input too; any other step type (a tool call or result) withholds the answer.
const STEPS = new Set(["user_input", "thought", "model_output"]);

const NEXT = {
  notSent: "nothing was sent or billed; fix the cause and call again",
  rejected: "Google refused the submission with a 4xx, so no run started and failed requests bill no tokens; fix the cause and call again",
  gone: "no run started and nothing was billed; start a new conversation with run-gemini.sh",
  unknown: "it may be running and billed with no id to collect, and sending it again may be charged twice",
  terminal: "the run is billed for the work done, this turn is left out of later follow-ups, and sending the prompt again is a new charge",
  withheld: "the run completed and is billed; the answer is withheld for the reason above; do not resend it unchanged",
  wait: "the run may still finish at Google: run fetch-gemini.sh on this conversation to collect it without a new charge, and do not resend",
  local: "nothing was sent; fix the cause, then run fetch-gemini.sh on this conversation to collect the run without a new charge",
};

export type Fetch = (url: string, init: RequestInit) => Promise<Response>;
export type Deps = { keyPath: string; fetch: Fetch; uid: number; now: () => number; sleep: (ms: number) => Promise<void>; out: (line: string) => void };
type Json = Record<string, unknown>;
type Outcome = "not-sent" | "rejected" | "unknown" | "failed" | "cancelled" | "incomplete" | "requires_action" | "requires_continuation" | "withheld";

class Refusal extends Error {}

// Every line passes here: literal matches of the key and of the ids this call read are redacted, and control characters
// flattened, so no line splits the log.
class Log {
  private hidden: string[] = [];
  constructor(private readonly out: (line: string) => void) {}
  hide(secret: string) {
    if (secret && !this.hidden.includes(secret)) this.hidden = [...this.hidden, secret].sort((a, b) => b.length - a.length);
  }
  line(text: string) {
    this.out(this.flat(text));
  }
  // Never String() on a remote object, which can throw; redacted before the cut, so a secret straddling it leaves no fragment.
  field(value: unknown) {
    const text = typeof value === "string" ? value : typeof value === "number" || typeof value === "boolean" ? String(value) : value == null ? "" : "[non-text]";
    return Array.from(this.flat(text)).slice(0, 500).join("");
  }
  body(res: Response, text: string) {
    const cp = Array.from(this.redact(text));
    const ends = cp.length > 1000 ? `${cp.slice(0, 500).join("")}...${cp.slice(-500).join("")}` : cp.join("");
    this.line(`body: HTTP ${res.status} ${this.field(res.headers.get("content-type") ?? "no-content-type")} ${JSON.stringify(ends)}`);
  }
  private redact(text: string) {
    return this.hidden.reduce((t, s) => t.split(s).join("[redacted]"), text);
  }
  private flat(text: string) {
    return this.redact(text).replace(/[\x00-\x1f\x7f-\x9f\u2028\u2029]+/g, " ");
  }
}

const isObj = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);
const errCode = (e: unknown) => (isObj(e) && typeof e.code === "string" ? e.code : "error");
const exists = (path: string) => lstatSync(path, { throwIfNoEntry: false }) !== undefined;
const count = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? String(v) : "?");
const errText = (e: unknown) => (e instanceof Error ? `${e.name}: ${e.message}` : typeof e === "string" ? e : "a non-error value");
// A usage value of an unexpected kind counts as use: the tool check fails closed.
const used = (v: unknown) =>
  v == null ? false : typeof v === "number" ? v > 0 : Array.isArray(v) ? v.length > 0 : isObj(v) ? Object.keys(v).length > 0 : true;

function parse(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function apiError(text: string) {
  const b = parse(text);
  const e = isObj(b) && isObj(b.error) ? b.error : undefined;
  const code = typeof e?.code === "string" || typeof e?.code === "number" ? String(e.code) : "unknown";
  return e && typeof e.message === "string" ? { code, message: e.message } : undefined;
}

function turnFiles(turn: number) {
  const s = turn === 0 ? "" : `-${turn}`;
  return { prompt: turn === 0 ? "prompt.md" : `followup-${turn}.md`, id: `id${s}.txt`, response: `response${s}.md`, ended: `ended${s}.txt` };
}

// The checks and the read use one no-follow, non-blocking descriptor, so a swap after the open changes nothing, and a symlink
// or FIFO is refused.
function readOwned(path: string, uid: number, secret: boolean): string {
  let fd: number;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (e) {
    throw new Refusal(`${path} cannot be opened (${errCode(e)}); it must be a file, not a symlink`);
  }
  try {
    const st = fstatSync(fd);
    if (!st.isFile()) throw new Refusal(`${path} is not a regular file`);
    if (st.uid !== uid) throw new Refusal(`${path} is not owned by uid ${uid}`);
    if (secret && st.mode & 0o077) throw new Refusal(`${path} is open to group or others; chmod 600 it`);
    return readFileSync(fd, "utf8");
  } finally {
    closeSync(fd);
  }
}

function readId(path: string, uid: number): string {
  const id = readOwned(path, uid, false);
  if (!ID.test(id)) throw new Refusal(`${path} does not hold a valid interaction id`);
  return id;
}

// An ended turn is never chained onto: its run holds no answer the conversation should build on.
function chainedId(dir: string, turn: number, uid: number): string {
  for (let k = turn - 1; k >= 0; k--) {
    const f = turnFiles(k);
    if (exists(join(dir, f.response))) return readId(join(dir, f.id), uid);
  }
  throw new Refusal("no earlier turn has an answer to follow up on");
}

function readKey(path: string, uid: number): string {
  const m = KEY_LINE.exec(readOwned(path, uid, true));
  if (!m) throw new Refusal(`${path} must hold one line GEMINI_API_KEY=<letters, digits and . _ - only>`);
  return m[1];
}

// The final name appears complete and is never replaced.
function publish(dir: string, name: string, data: string): boolean {
  const tmp = join(dir, `.${name}.${randomBytes(8).toString("hex")}`);
  try {
    writeFileSync(tmp, data, { flag: "wx", mode: 0o600 });
  } catch (e) {
    // EEXIST means the name was someone else's; any other failure may have left ours half-written.
    if (errCode(e) !== "EEXIST") rmSync(tmp, { force: true });
    throw e;
  }
  try {
    linkSync(tmp, join(dir, name));
    return true;
  } catch (e) {
    if (errCode(e) === "EEXIST") return false;
    throw e;
  } finally {
    unlinkSync(tmp);
  }
}

// The requested ID, or that ID with a version suffix such as -001; Google reroutes retired IDs to other models.
const servedAs = (served: string, model: string) =>
  served === model || (served.startsWith(`${model}-`) && /^[0-9][0-9.-]*$/.test(served.slice(model.length + 1)));

type Turn = { deps: Deps; log: Log; dir: string; turn: number; model: string; key: string; end: (o: Outcome | undefined, error: string, next: string) => number };

async function submitTurn(t: Turn, effort: string, input: string, parent: string): Promise<string | number> {
  const { deps, log, dir, turn, end } = t;
  const body = {
    model: t.model,
    input,
    generation_config: { thinking_level: effort, max_output_tokens: MAX_OUTPUT_TOKENS },
    store: true,
    background: true,
    ...(parent ? { previous_interaction_id: parent } : {}),
  };
  let res: Response;
  let text: string;
  try {
    res = await deps.fetch(ENDPOINT, {
      method: "POST",
      headers: { "x-goog-api-key": t.key, "content-type": "application/json", "Api-Revision": REVISION },
      body: JSON.stringify(body),
      redirect: "error",
      signal: AbortSignal.timeout(CALL_TIMEOUT),
    });
    text = await res.text();
  } catch (e) {
    return end("unknown", `the submission got no reply (${log.field(errText(e))})`, NEXT.unknown);
  }
  if (!res.ok) {
    const err = apiError(text);
    if (!err) log.body(res, text);
    const detail = `HTTP ${res.status}${err ? ` ${log.field(err.code)}: ${log.field(err.message)}` : ""}`;
    // Only a 4xx other than a timeout (408) or a cancellation (499) proves no run started: a gateway can fail after acceptance.
    if (res.status < 400 || res.status >= 500 || res.status === 408 || res.status === 499) return end("unknown", `the submission's outcome is unknown: ${detail}`, NEXT.unknown);
    if (turn > 0 && (res.status === 404 || err?.code === "not_found")) {
      return end("rejected", "the conversation is no longer stored at Google; start a new one with run-gemini.sh", NEXT.gone);
    }
    return end("rejected", `Google rejected the submission: ${detail}`, NEXT.rejected);
  }
  const reply = parse(text);
  const id = isObj(reply) ? reply.id : undefined;
  if (typeof id === "string") log.hide(id);
  if (typeof id !== "string" || !ID.test(id)) {
    log.body(res, text);
    return end("unknown", "the submission's reply holds no valid interaction id", NEXT.unknown);
  }
  if (id.includes(t.key)) return end("unknown", "the submission's reply id holds the API key, so it is neither saved nor polled", NEXT.unknown);
  if (!publish(dir, turnFiles(turn).id, id)) throw new Error(`${join(dir, turnFiles(turn).id)} appeared while submitting`);
  log.line("submitted");
  return id;
}

// Transient failures are retried; a timeout or exhausted retries leave the turn pending.
async function collect(t: Turn, id: string): Promise<number> {
  const { deps, log, end } = t;
  const url = `${ENDPOINT}/${encodeURIComponent(id)}`;
  const start = deps.now();
  let fails = 0;
  for (let n = 1; ; n++) {
    let res: Response | undefined;
    let text = "";
    try {
      res = await deps.fetch(url, {
        method: "GET",
        headers: { "x-goog-api-key": t.key, "Api-Revision": REVISION },
        redirect: "error",
        signal: AbortSignal.timeout(CALL_TIMEOUT),
      });
      text = await res.text();
    } catch {
      res = undefined;
    }
    if (!res || res.status === 404 || res.status === 429 || res.status >= 500) {
      log.line(`poll ${n}: ${res?.status ?? "no reply"}`);
      if (++fails >= FAILS) return end(undefined, `${FAILS} polls in a row failed`, NEXT.wait);
    } else if (!res.ok) {
      log.line(`poll ${n}: ${res.status}`);
      const err = apiError(text);
      if (!err) log.body(res, text);
      const auth = res.status === 401 || res.status === 403 ? "check the key and its restriction first; " : "";
      return end(undefined, `Google refused the poll: HTTP ${res.status}${err ? ` ${log.field(err.code)}: ${log.field(err.message)}` : ""}`, auth + NEXT.wait);
    } else {
      const r = parse(text);
      // Before any excerpt: another interaction's id is not hidden, so its body never reaches the log.
      if (isObj(r) && typeof r.id === "string" && r.id !== id) {
        log.line(`poll ${n}: another interaction`);
        return end(undefined, "Google returned another interaction than the one this turn saved; nothing was published",
          "do not resend; if fetch-gemini.sh keeps reporting this, abandon the turn and start a new conversation with run-gemini.sh");
      }
      if (!isObj(r) || typeof r.id !== "string" || typeof r.status !== "string" || !STATUSES.has(r.status)) {
        log.line(`poll ${n}: unexpected body`);
        log.body(res, text);
        return end(undefined, "a poll returned an unexpected body", NEXT.wait);
      }
      log.line(`poll ${n}: ${r.status}`);
      if (r.status !== "in_progress") return finish(t, r);
      fails = 0;
    }
    const waited = deps.now() - start;
    if (waited >= WAIT) return end(undefined, "no terminal status after 30 minutes", NEXT.wait);
    await deps.sleep(waited < 60_000 ? 5_000 : 15_000);
  }
}

function finish(t: Turn, r: Json): number {
  const { log, dir, turn, model, end } = t;
  const served = typeof r.model === "string" ? r.model : "";
  const steps = Array.isArray(r.steps) ? r.steps : [];
  const types = steps.map((s) => (isObj(s) && typeof s.type === "string" ? s.type : "untyped"));
  log.line(`served: ${log.field(served || "none")}`);
  log.line(`steps: ${types.map((s) => log.field(s)).join(" ") || "none"}`);
  switch (r.status) {
    case "failed": {
      const errors = Array.isArray(r.errors) ? r.errors.filter(isObj).map((e) => `${log.field(e.code ?? "unknown")}: ${log.field(e.message)}`) : [];
      return end("failed", `the run failed at Google${errors.length ? `: ${errors.join("; ")}` : ""}`, NEXT.terminal);
    }
    case "cancelled":
      return end("cancelled", "the run was cancelled at Google", NEXT.terminal);
    case "incomplete":
      return end("incomplete", `the run ended incomplete, which can mean the output cap of ${MAX_OUTPUT_TOKENS} tokens, thinking included`, `${NEXT.terminal}; if the output cap stopped it, the answer did not fit`);
    case "requires_action":
      return end("requires_action", "the run paused for a client action, which a tool-free consult never offers", NEXT.terminal);
    case "requires_continuation":
      return end("requires_continuation", "the run stopped at a decode hop and asks for a continuation, which this client does not send", NEXT.terminal);
  }
  const withhold = (why: string) => end("withheld", why, NEXT.withheld);
  if (!servedAs(served, model)) {
    return withhold(`Google served ${served ? log.field(served) : "no model"} for the requested ${model}; the answer is withheld and retrying is not worth it: pass a concrete model ID`);
  }
  const odd = types.find((s) => !STEPS.has(s));
  if (odd !== undefined) return withhold(`the response holds a ${log.field(odd)} step, so a tool may have run`);
  const textOnly = steps.every(
    (s) => s.type !== "model_output" || (Array.isArray(s.content) && s.content.every((c: unknown) => isObj(c) && c.type === "text" && typeof c.text === "string")),
  );
  if (!textOnly) return withhold("a model_output item is not text");
  const usage = isObj(r.usage) ? r.usage : {};
  if (used(usage.total_tool_use_tokens) || used(usage.tool_use_tokens_by_modality) || used(usage.grounding_tool_count)) {
    return withhold("the response reports tool use");
  }
  // A GET may also carry earlier turns: only the steps after the last user_input belong to this one.
  const answer = steps
    .slice(types.lastIndexOf("user_input") + 1)
    .flatMap((s) => (s.type === "model_output" ? (s.content as Json[]).map((c) => c.text as string) : []))
    .join("");
  if (!answer.trim()) return withhold("the answer is empty");
  if (answer.includes(t.key)) return withhold("the answer holds the API key, so it is not published");
  if (!publish(dir, turnFiles(turn).response, answer)) log.line("response: another collector published it first; left as it is");
  const u = (k: string) => count(usage[k]);
  log.line(`OK: ${log.field(served)} in=${u("total_input_tokens")} cached=${u("total_cached_tokens")} thought=${u("total_thought_tokens")} out=${u("total_output_tokens")} total=${u("total_tokens")}`);
  return 0;
}

async function consult(argv: string[], deps: Deps, log: Log): Promise<number> {
  const [dir = "", turnArg = "", mode = "", ...extra] = argv;
  if (extra.length || !dir.startsWith("/") || !/^(0|[1-9][0-9]{0,8})$/.test(turnArg) || (mode !== "submit" && mode !== "collect")) {
    log.line("ERROR: usage: api <absolute gemini-dir> <turn> submit|collect");
    log.line("NEXT: nothing was sent or billed; call it only through run-gemini.sh, resume-gemini.sh or fetch-gemini.sh");
    return 2;
  }
  const turn = Number(turnArg);
  const files = turnFiles(turn);
  const at = (name: string) => join(dir, name);
  const submit = mode === "submit";
  const end = (outcome: Outcome | undefined, error: string, next: string) => {
    log.line(`ERROR: ${error}`);
    log.line(`NEXT: ${next}`);
    if (outcome) publish(dir, files.ended, `${outcome}\n`);
    return 1;
  };
  // Before the POST a refusal ends the turn; while collecting it leaves the run collectable.
  const refuse = (error: string) => (submit ? end("not-sent", error, NEXT.notSent) : end(undefined, error, NEXT.local));

  let effort: string;
  let model: string;
  let input = "";
  let parent = "";
  let id = "";
  let key: string;
  try {
    effort = readOwned(at("effort"), deps.uid, false);
    model = readOwned(at("model"), deps.uid, false) || DEFAULT_MODEL;
    if (!EFFORTS.includes(effort)) return refuse(`${at("effort")} must hold low, medium or high`);
    if (!MODEL.test(model)) return refuse(`${at("model")} must hold a model ID such as ${DEFAULT_MODEL}`);
    log.line(`model: ${model}`);
    if (submit) {
      const taken = [files.id, files.response, files.ended].find((name) => exists(at(name)));
      if (taken) return end(undefined, `turn ${turn} already has ${taken}`, "nothing was sent; this turn belongs to another call");
      input = readOwned(at(files.prompt), deps.uid, false);
      if (turn > 0) parent = chainedId(dir, turn, deps.uid);
      log.hide(parent);
    } else {
      id = readId(at(files.id), deps.uid);
      log.hide(id);
    }
    key = readKey(deps.keyPath, deps.uid);
    log.hide(key);
  } catch (e) {
    return refuse(e instanceof Refusal ? e.message : `a local check failed: ${log.field(errText(e))}`);
  }
  // The wrappers copy whatever the prompt path names, so a link or alias to the key file arrives here as text.
  if (submit && input.includes(key)) {
    return end("not-sent", "the prompt holds the API key, so it is not sent", `nothing was sent or billed; ${at(files.prompt)} holds a copy of the key: delete it`);
  }
  const t: Turn = { deps, log, dir, turn, model, key, end };
  if (submit) {
    const sent = await submitTurn(t, effort, input, parent);
    if (typeof sent === "number") return sent;
    id = sent;
  }
  return collect(t, id);
}

export async function main(argv: string[], deps: Deps): Promise<number> {
  const log = new Log(deps.out);
  try {
    return await consult(argv, deps, log);
  } catch (e) {
    log.line(`ERROR: the engine stopped unexpectedly: ${log.field(errText(e))}`);
    log.line("NEXT: run fetch-gemini.sh on this conversation to see what was recorded; sending the prompt again may be charged twice");
    return 1;
  }
}

if (import.meta.main) {
  process.exitCode = await main(process.argv.slice(2), {
    keyPath: join(userInfo().homedir, ".config", "gemini", ".env"),
    fetch: (url, init) => fetch(url, init),
    uid: process.getuid?.() ?? -1,
    now: () => Date.now(),
    sleep: (ms) => new Promise((done) => setTimeout(done, ms)),
    out: (line) => {
      writeSync(1, `${line}\n`);
    },
  });
}
