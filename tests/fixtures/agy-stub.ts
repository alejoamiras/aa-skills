// A stand-in for agy, compiled per test run with `bun build --compile`: the pump's inode self-check needs a native
// executable, and a script's exe is its interpreter. It speaks agy 1.5.15's stream-json shapes. $HOME/stub.json picks its
// behaviour; it records its argv, environment names, session and every message under $HOME/stub/, never the key's value.
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, readdirSync, readFileSync, readlinkSync, writeFileSync, writeSync } from "node:fs";
import { join } from "node:path";

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
type Config = { mode?: string; child?: boolean; delay?: number; tick?: number; turns?: Turn[] };

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

function stub() {
  const fds = descriptors();
  const home = process.env.HOME ?? "";
  const cfg: Config = JSON.parse(readFileSync(join(home, "stub.json"), "utf8"));
  const mode = cfg.mode ?? "answer";
  const dir = join(home, "stub");
  mkdirSync(dir, { recursive: true });
  const at = (ext: string) => join(dir, `${process.pid}${ext}`);
  const put = (v: unknown) => writeAll(1, `${typeof v === "string" ? v : JSON.stringify(v)}\n`);
  const key = process.env.GEMINI_API_KEY ?? "";
  const stat = readFileSync("/proc/self/stat", "utf8");
  const f = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
  // Ignores HUP and TERM in a session of its own, as a command agy started would.
  const child = cfg.child || mode === "child" ? spawn("/bin/sh", ["-c", "trap '' HUP TERM; while :; do sleep 1; done"], { detached: true, stdio: "ignore" }) : undefined;
  child?.unref();
  const keyFile = readFileSync(join(home, ".config", "gemini", ".env"), "utf8").trim().replace(/^GEMINI_API_KEY=/, "");
  writeFileSync(at(".json"), JSON.stringify({
    pid: process.pid, sid: Number(f[3]), tty: Number(f[4]), start: f[19], child: child?.pid, args: process.argv.slice(2), cwd: process.cwd(), fds,
    argv0: readFileSync("/proc/self/cmdline", "utf8").split("\0")[0], envNames: Object.keys(process.env).sort(), keyMatches: key !== "" && key === keyFile,
    env: Object.fromEntries(Object.entries(process.env).filter(([k]) => k !== "GEMINI_API_KEY")),
  }));
  const args = process.argv.slice(2);
  if (mode === "exit") process.exit(3);
  if (args[0] === "models") process.exit(0);
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
