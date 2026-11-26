// A stand-in for agy, compiled per test run with `bun build --compile`: the pump's inode self-check needs a native
// executable, and a script's exe is its interpreter. It speaks agy 1.5.15's stream-json shapes. stub.json in the home its
// pinned binary sits in (<home>/bin/agy) picks its behaviour; it records its argv, environment names, session and every
// message under $HOME/stub/, never the key's value.
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, readdirSync, readFileSync, readlinkSync, writeFileSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";

// Lines recorded from real runs (cwd and the tool list cut down), plus agy's documented error result. The last two are a
// response that only calls a tool, so it has no text, and the step agy adds when a command it started finishes.
export const RECORDED = [
  '{"event":"init","conversation_id":"8766c9db-47ac-4645-97cc-bd1cbe524c30","init":{"model":"gemini-4-carbon-low","cwd":"/home/user/repo","tools":["run_command","write_to_file"],"permission_mode":"always-proceed"}}',
  '{"event":"step_update","step_update":{"conversation_id":"8766c9db-47ac-4645-97cc-bd1cbe524c30","step_index":0,"state":"DONE","step_type":"user_input"}}',
  '{"event":"step_update","step_update":{"conversation_id":"8766c9db-47ac-4645-97cc-bd1cbe524c30","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"sleep 900 \\u0026 echo $! \\u003e sleep.pid"}}}}',
  '{"event":"step_update","step_update":{"conversation_id":"8766c9db-47ac-4645-97cc-bd1cbe524c30","step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":8.628098787999999,"tool_info":{"name":"run_command","parameters":{"CommandLine":"sleep 900 \\u0026 echo $! \\u003e sleep.pid"},"output":"Created At: 2026-11-23T14:40:52Z\\nCompleted At: 2026-11-23T14:41:01Z\\nCommand exited with code 0.\\n\\nNo output from the command."}}}',
  '{"event":"step_update","step_update":{"conversation_id":"8766c9db-47ac-4645-97cc-bd1cbe524c30","step_index":3,"state":"DONE","step_type":"tool","tool_name":"write_file","duration_seconds":11.486998366,"tool_info":{"name":"write_file","parameters":{"Path":"/home/user/repo/a.txt"}}}}',
  '{"event":"step_update","step_update":{"conversation_id":"8766c9db-47ac-4645-97cc-bd1cbe524c30","step_index":11,"state":"DONE","step_type":"agent_response","text_delta":"ok\\n","duration_seconds":4.353453776,"usage":{"input_tokens":2336,"output_tokens":5,"thinking_tokens":0,"cache_read_tokens":7366,"total_tokens":2341}}}',
  '{"event":"result","result":{"conversation_id":"8766c9db-47ac-4645-97cc-bd1cbe524c30","status":"SUCCESS","response":"ok\\n","duration_seconds":115.525879628,"num_turns":1,"usage":{"input_tokens":17639,"output_tokens":324,"thinking_tokens":0,"cache_read_tokens":28319,"total_tokens":17963}}}',
  '{"event":"step_update","step_update":{"conversation_id":"8766c9db-47ac-4645-97cc-bd1cbe524c30","step_index":12,"state":"DONE","step_type":"user_input"}}',
  '{"event":"result","result":{"conversation_id":"8766c9db-47ac-4645-97cc-bd1cbe524c30","status":"SUCCESS","response":"alpha\\n","duration_seconds":120.040284501,"num_turns":2,"usage":{"input_tokens":19767,"output_tokens":329,"thinking_tokens":0,"cache_read_tokens":35972,"total_tokens":20096}}}',
  '{"event":"result","result":{"conversation_id":"4fae3a70-409d-42a4-86ea-9de206a49ff4","status":"ERROR","response":"","error":"/model is answered by the CLI itself and is unavailable with --input-format stream-json; run it as its own --print /model invocation","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0}}}',
  '{"event":"step_update","step_update":{"conversation_id":"5fbaa1db-b4df-4c8f-8022-7dd8eacb8606","step_index":1,"state":"DONE","step_type":"agent_response","duration_seconds":16.949451019,"usage":{"input_tokens":8728,"output_tokens":52,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":8780}}}',
  '{"event":"step_update","step_update":{"conversation_id":"5fbaa1db-b4df-4c8f-8022-7dd8eacb8606","step_index":4,"state":"DONE","step_type":"system_message","duration_seconds":0.000163904}}',
];

const CONVERSATION = "8766c9db-47ac-4645-97cc-bd1cbe524c30";
const step = (index: number, body: object) => ({ event: "step_update", step_update: { conversation_id: CONVERSATION, step_index: index, ...body } });
// The documented shape of a failed tool step: tool_info.error with type and message.
export const toolStep = (index: number, state: "ACTIVE" | "DONE", error?: string) =>
  step(index, {
    state, step_type: "tool", tool_name: "run_command",
    tool_info: { name: "run_command", parameters: { CommandLine: "true" }, ...(state === "DONE" ? { output: "Command exited with code 0." } : {}), ...(error ? { error: { type: "EXEC_ERROR", message: error } } : {}) },
  });
const usageAt = (n: number) => ({ input_tokens: 1000 * n, output_tokens: 10 * n, thinking_tokens: 0, cache_read_tokens: 500 * n, total_tokens: 1010 * n });
const result = (turns: number, response: string, usage: unknown) => ({
  event: "result", result: { conversation_id: CONVERSATION, status: "SUCCESS", response, duration_seconds: 1.5, num_turns: turns, ...(usage === undefined ? {} : { usage }) },
});

type Turn = { answer?: string; tools?: number; toolErrors?: number; stderr?: number; write?: string[]; editConfig?: string; usage?: unknown };
// One line of a one-shot script. answer: a finished model step, with usage [input, output, cached] (default
// [1000, 10, 500]; null for none); delta: a text delta of the next model step; tool: a tool step, which first appends a
// line to write in the cwd; result: the result, its usage by default this run's steps' sum, naming conversation (none
// when false) instead of the init's; raw: a line as written;
// err: a line on stderr; bytes: that many bytes, with no newline when newline is false; tick: a delta (a blank line
// when blank) every tick ms, for that long or forever; hold: stdout stays open and nothing more is written.
type Item = {
  answer?: string; usage?: [number, number, number] | null; delta?: string; tool?: string; output?: string; state?: "ACTIVE" | "DONE"; write?: string;
  result?: string; response?: string; error?: string; denied?: string[]; conversation?: string | null | false; raw?: string; err?: string; bytes?: number;
  newline?: boolean; sleep?: number; tick?: number; for?: number; blank?: boolean; hold?: boolean;
};
// script is the one-shot stream after the user_input step, resume replaces it when argv carries --conversation; init
// false sends no init event; resumeAs is the conversation id the init names when argv carries --conversation; onTerm is
// a line written on stderr when TERM arrives, before exiting.
type Config = {
  mode?: string; child?: boolean | "cleared"; split?: boolean; delay?: number; tick?: number; turns?: Turn[]; script?: Item[]; resume?: Item[];
  init?: false | { model?: string; mode?: string }; resumeAs?: string; onTerm?: string;
};

function writeAll(fd: number, text: string) {
  const buf = Buffer.from(text);
  for (let off = 0; off < buf.length; ) {
    try {
      off += writeSync(fd, buf, off);
    } catch (e) {
      if ((e as { code?: string }).code !== "EAGAIN") throw e;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
    }
  }
}

// Each open descriptor and what it names, read before the stub opens anything; the listing's own descriptor is closed
// by the time its link is read, so it drops out.
function descriptors(): { fd: number; target: string }[] {
  return readdirSync("/proc/self/fd").flatMap((n) => {
    try {
      return [{ fd: Number(n), target: readlinkSync(`/proc/self/fd/${n}`) }];
    } catch {
      return [];
    }
  });
}

const usage3 = ([input, output, cached]: [number, number, number]) => ({
  input_tokens: input, output_tokens: output, thinking_tokens: 0, cache_read_tokens: cached, total_tokens: input + output,
});
const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));

// init, one user event recorded, then the script; it exits when the script ends.
async function oneShot(script: Item[], cfg: Config, put: (v: unknown) => void, at: (ext: string) => string) {
  const args = process.argv.slice(2);
  const i = cfg.init;
  const conversation = (args.includes("--conversation") && cfg.resumeAs) || CONVERSATION;
  if (i !== false) {
    const init = { model: i?.model ?? args[args.indexOf("--model") + 1], cwd: process.cwd(), tools: ["run_command"], permission_mode: i?.mode ?? "always-proceed" };
    put({ event: "init", conversation_id: conversation, init });
  }
  const line = await new Promise<string>((done) => {
    let buf = "";
    process.stdin.on("data", (chunk: Buffer) => {
      buf += chunk.toString("utf8");
      if (buf.includes("\n")) done(buf.slice(0, buf.indexOf("\n")));
    });
  });
  appendFileSync(at(".in.ndjson"), `${line}\n`);
  let s = 0;
  const sum: [number, number, number] = [0, 0, 0];
  put(step(s++, { state: "DONE", step_type: "user_input" }));
  for (const it of script) {
    if (it.answer !== undefined) {
      const u = it.usage === undefined ? ([1000, 10, 500] as [number, number, number]) : it.usage;
      for (let k = 0; u && k < 3; k++) sum[k] += u[k];
      put(step(s++, { state: "DONE", step_type: "agent_response", text_delta: it.answer, ...(u ? { usage: usage3(u) } : {}) }));
    } else if (it.delta !== undefined) put(step(s, { state: "ACTIVE", step_type: "agent_response", text_delta: it.delta }));
    else if (it.tool !== undefined) {
      if (it.write) appendFileSync(join(process.cwd(), it.write), "stub edit\n");
      const info = { name: it.tool, parameters: {}, ...(it.output === undefined ? {} : { output: it.output }) };
      put(step(s++, { state: it.state ?? "DONE", step_type: "tool", tool_name: it.tool, tool_info: info }));
    } else if (it.result !== undefined) {
      const u = it.usage === undefined ? sum : it.usage;
      const denied = it.denied ? { denied_actions: it.denied.map((action) => ({ action })) } : {};
      const id = it.conversation === false ? {} : { conversation_id: it.conversation === undefined ? conversation : it.conversation };
      const body = { ...id, status: it.result, response: it.response ?? "", ...(it.error ? { error: it.error } : {}), num_turns: 1, ...denied };
      put({ event: "result", result: { ...body, ...(u ? { usage: usage3(u) } : {}) } });
    } else if (it.raw !== undefined) writeAll(1, `${it.raw}\n`);
    else if (it.err !== undefined) writeAll(2, `${it.err}\n`);
    else if (it.bytes !== undefined) {
      for (let left = it.bytes; left > 0; left -= 1 << 20) writeAll(1, "x".repeat(Math.min(left, 1 << 20)));
      if (it.newline !== false) writeAll(1, "\n");
    } else if (it.sleep !== undefined) await sleep(it.sleep);
    else if (it.tick !== undefined) {
      for (const end = Date.now() + (it.for ?? Infinity); Date.now() < end; await sleep(it.tick)) {
        if (it.blank) writeAll(1, "\n");
        else put(step(s, { state: "ACTIVE", step_type: "agent_response", text_delta: "." }));
      }
    } else if (it.hold) await new Promise(() => setInterval(() => {}, 1 << 30));
  }
  process.exit(0);
}

function stub() {
  const fds = descriptors();
  const argv0 = readFileSync("/proc/self/cmdline", "utf8").split("\0")[0];
  // A one-shot run gives agy a private HOME; config and key stay in the home whose bin/ holds the pinned binary.
  const owner = dirname(dirname(argv0));
  const home = process.env.HOME ?? "";
  const cfg: Config = JSON.parse(readFileSync(join(owner, "stub.json"), "utf8"));
  const mode = cfg.mode ?? "answer";
  const dir = join(home, "stub");
  mkdirSync(dir, { recursive: true });
  const at = (ext: string) => join(dir, `${process.pid}${ext}`);
  const put = (v: unknown) => writeAll(1, `${typeof v === "string" ? v : JSON.stringify(v)}\n`);
  const key = process.env.GEMINI_API_KEY ?? "";
  const stat = readFileSync("/proc/self/stat", "utf8");
  const f = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
  // Ignores HUP and TERM in a session of its own, as a command agy started would. "cleared": that session's marked leader
  // dies on TERM, and its child, with an empty environment, ignores both.
  const loop = "trap '' HUP TERM; while :; do /bin/sleep 1; done";
  const script = cfg.child === "cleared" ? `/usr/bin/env -i /bin/sh -c "${loop}" & wait` : loop;
  const child = cfg.child || mode === "child" ? spawn("/bin/sh", ["-c", script], { detached: true, stdio: "ignore" }) : undefined;
  child?.unref();
  const keyFile = readFileSync(join(owner, ".config", "gemini", ".env"), "utf8").trim().replace(/^GEMINI_API_KEY=/, "");
  writeFileSync(at(".json"), JSON.stringify({
    pid: process.pid, sid: Number(f[3]), tty: Number(f[4]), start: f[19], child: child?.pid, args: process.argv.slice(2), cwd: process.cwd(), fds,
    argv0, envNames: Object.keys(process.env).sort(), keyMatches: key !== "" && key === keyFile,
    env: Object.fromEntries(Object.entries(process.env).filter(([k]) => k !== "GEMINI_API_KEY")),
  }));
  const args = process.argv.slice(2);
  if (mode === "exit") process.exit(3);
  if (args[0] === "models") process.exit(0);
  if (cfg.onTerm) {
    const line = cfg.onTerm;
    process.on("SIGTERM", () => {
      writeAll(2, `${line}\n`);
      process.exit(143);
    });
  }
  const shot = args.includes("--conversation") && cfg.resume ? cfg.resume : cfg.script;
  if (shot) return void oneShot(shot, cfg, put, at);
  put({ event: "init", conversation_id: CONVERSATION, init: { model: args[args.indexOf("--model") + 1], cwd: process.cwd(), tools: ["run_command"], permission_mode: "always-proceed" } });
  let s = 0;
  let n = 0;
  let last: unknown;

  async function turn() {
    const t = cfg.turns?.[n] ?? {};
    n++;
    appendFileSync(at(".order"), `in ${n}\n`);
    put(step(s++, { state: "DONE", step_type: "user_input" }));
    if (mode === "eof") process.exit(0);
    if (mode === "error-second" && n === 2) {
      put(RECORDED[9]);
      process.exit(1);
    }
    if (mode === "late-duplicate" && n === 2) put(last);
    if (mode === "hang") {
      if (cfg.tick) setInterval(() => put(step(s, { state: "ACTIVE", step_type: "agent_response", text_delta: "." })), cfg.tick);
      return new Promise<void>(() => {});
    }
    for (const name of t.write ?? []) writeFileSync(join(process.cwd(), name), `turn ${n}\n`);
    if (t.editConfig) appendFileSync(t.editConfig, "[gemini-stub]\n\tedited = true\n");
    for (let i = 0; i < (t.tools ?? 0); i++, s++) {
      put(toolStep(s, "ACTIVE"));
      put(toolStep(s, "DONE", i < (t.toolErrors ?? 0) ? "exit status 1" : undefined));
    }
    for (let i = 0; i < (t.stderr ?? 0); i++) writeAll(2, `stub notice ${i}\n`);
    // The key split across two ACTIVE deltas of one step, across an ACTIVE and its DONE, then across two ACTIVE deltas
    // of a step whose DONE carries no text.
    if (cfg.split) {
      const half = key.length >> 1;
      put(step(s, { state: "ACTIVE", step_type: "agent_response", text_delta: `one ${key.slice(0, half)}` }));
      put(step(s, { state: "ACTIVE", step_type: "agent_response", text_delta: key.slice(half) }));
      put(step(s++, { state: "DONE", step_type: "agent_response", text_delta: " two" }));
      put(step(s, { state: "ACTIVE", step_type: "agent_response", text_delta: key.slice(0, half) }));
      put(step(s++, { state: "DONE", step_type: "agent_response", text_delta: `${key.slice(half)} three` }));
      put(step(s, { state: "ACTIVE", step_type: "agent_response", text_delta: `four ${key.slice(0, half)}` }));
      put(step(s, { state: "ACTIVE", step_type: "agent_response", text_delta: key.slice(half) }));
      put(step(s++, { state: "DONE", step_type: "agent_response" }));
    }
    const late = mode === "late-done" && n === 1 ? s++ : undefined;
    if (late !== undefined) put(toolStep(late, "ACTIVE"));
    if (mode === "leak-key") {
      put(key);
      const escaped = [...key].map((c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`).join("");
      put(`{"event":"step_update","step_update":{"step_index":${s++},"state":"ACTIVE","step_type":"agent_response","text_delta":"${escaped}"}}`);
      writeAll(2, `leaked ${key}\n`);
    }
    if (mode === "huge") {
      put(`${key}${"x".repeat(2 * 1024 * 1024)}${key}`);
      put(step(s++, { state: "ACTIVE", step_type: "agent_response", text_delta: `${key}${"y".repeat(100 * 1024)}${key}` }));
    }
    const answer = t.answer ?? (mode === "leak-key" ? `answer ${n} ${key}` : `answer ${n}`);
    put(step(s++, { state: "DONE", step_type: "agent_response", text_delta: answer, usage: usageAt(1) }));
    if (mode === "slow") await new Promise((done) => setTimeout(done, cfg.delay ?? 300));
    const usage = "usage" in t ? (t.usage ?? undefined) : mode === "no-usage" ? undefined : mode === "partial-usage" ? { total_tokens: 1010 * n } : usageAt(n);
    last = result(n, answer, usage);
    put(last);
    appendFileSync(at(".order"), `result ${n}\n`);
    const bumped = { ...usageAt(n), total_tokens: 1010 * n + 100 };
    if (mode === "duplicate") put(result(n, answer, bumped));
    if (mode === "late-duplicate") last = result(n, answer, bumped);
    if (mode === "background" && n === 1) setTimeout(() => put(step(s++, { state: "ACTIVE", step_type: "agent_response", text_delta: "unasked" })), cfg.delay ?? 100);
    if (late !== undefined) setTimeout(() => put(toolStep(late, "DONE", "exit status 1")), cfg.delay ?? 100);
    // A turn no message asked for: num_turns moves on without one.
    if (mode === "unasked-turn" && n === 1) {
      setTimeout(() => {
        n++;
        put(step(s++, { state: "DONE", step_type: "agent_response", text_delta: "unasked" }));
        put(result(n, "unasked", usageAt(n)));
      }, cfg.delay ?? 100);
    }
  }

  // Like agy, input that arrives mid-turn runs after the current turn; closing stdin ends the session once idle.
  let queue = Promise.resolve();
  let buffered = "";
  let pending = 0;
  let closed = false;
  process.stdin.on("data", (chunk: Buffer) => {
    buffered += chunk.toString("utf8");
    for (let nl = buffered.indexOf("\n"); nl !== -1; nl = buffered.indexOf("\n")) {
      const line = buffered.slice(0, nl);
      buffered = buffered.slice(nl + 1);
      appendFileSync(at(".in.ndjson"), `${line}\n`);
      const ev = JSON.parse(line) as { event?: string };
      if (ev.event !== "user") {
        writeAll(2, `warning: ignoring unsupported stream input message event "${ev.event}"\n`);
        continue;
      }
      pending++;
      queue = queue.then(turn).then(() => {
        if (--pending === 0 && closed) process.exit(0);
      });
    }
  });
  process.stdin.on("end", () => {
    closed = true;
    if (pending === 0) process.exit(0);
  });
}

if (import.meta.main) stub();
