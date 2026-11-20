// The gemini api engine's core against a scripted fetch, an injected clock and sleep, and a temp key file with a fake
// value: no port, no real key. Key values are compared only as booleans, so a failing assertion never prints one.
import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { main } from "../skills/gemini/engines/api.ts";

const KEY = "fake-gem-key-aaaa-bbbb-cccc";
const ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/interactions";
const ID = "int-abc_123";
const UID = process.getuid?.() ?? 0;
const root = mkdtempSync(join(tmpdir(), "gemini-api-test-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

let seq = 0;
type Conv = { dir: string; keyPath: string };
function conv(records: { effort?: string; model?: string } = {}): Conv {
  const dir = join(root, `c${++seq}`);
  mkdirSync(dir, { mode: 0o700 });
  writeFileSync(join(dir, "effort"), records.effort ?? "high");
  writeFileSync(join(dir, "model"), records.model ?? "");
  writeFileSync(join(dir, "prompt.md"), "the prompt\n");
  const keyPath = join(root, `key${seq}.env`);
  writeFileSync(keyPath, `GEMINI_API_KEY=${KEY}\n`, { mode: 0o600 });
  return { dir, keyPath };
}

type Reply = Response | Error;
type Call = { url: string; init: RequestInit; idSaved: boolean };
type Opts = { turn?: number; mode?: "submit" | "collect"; keyPath?: string; sleep?: (ms: number) => Promise<void> };
async function run(c: Conv, replies: Reply[] | ((call: Call) => Reply), opts: Opts = {}) {
  const turn = opts.turn ?? 0;
  const idFile = join(c.dir, turn === 0 ? "id.txt" : `id-${turn}.txt`);
  const calls: Call[] = [];
  const lines: string[] = [];
  const sleeps: number[] = [];
  let clock = 0;
  const code = await main([c.dir, String(turn), opts.mode ?? "submit"], {
    keyPath: opts.keyPath ?? c.keyPath,
    uid: UID,
    now: () => clock,
    sleep:
      opts.sleep ??
      (async (ms) => {
        sleeps.push(ms);
        clock += ms;
      }),
    out: (line) => lines.push(line),
    fetch: async (url, init) => {
      const call = { url, init, idSaved: existsSync(idFile) };
      calls.push(call);
      const r = typeof replies === "function" ? replies(call) : replies.shift();
      if (r instanceof Error) throw r;
      return r ?? new Response("unscripted", { status: 418 });
    },
  });
  const file = (name: string) => (existsSync(join(c.dir, name)) ? readFileSync(join(c.dir, name), "utf8") : undefined);
  return { code, lines, log: lines.join("\n"), calls, sleeps, file };
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const running = () => json({ id: ID, status: "in_progress" });
const error = (status: number, code: string, message: string) => json({ error: { code, message } }, status);
const done = (over: Record<string, unknown> = {}) =>
  json({
    id: ID,
    status: "completed",
    model: "gemini-4-carbon",
    steps: [
      { type: "user_input", content: [{ type: "text", text: "the prompt" }] },
      { type: "thought", signature: "sig" },
      { type: "model_output", content: [{ type: "text", text: "Hello, " }] },
      { type: "model_output", content: [{ type: "text", text: "world." }] },
    ],
    usage: { total_input_tokens: 10, total_cached_tokens: 4, total_thought_tokens: 7, total_output_tokens: 3, total_tokens: 20 },
    ...over,
  });
const header = (init: RequestInit, name: string) => new Headers(init.headers).get(name);
// Any 5-character run of the key in the log counts as a leak.
const leaks = (log: string) => Array.from({ length: KEY.length - 4 }, (_, i) => KEY.slice(i, i + 5)).some((w) => log.includes(w));

describe("submit", () => {
  test("one POST to the fixed URL with three headers and the body fields; the id is saved before the first GET", async () => {
    const r = await run(conv(), [running(), running(), done()]);
    expect(r.code).toBe(0);
    const [post, ...gets] = r.calls;
    expect(post.url).toBe(ENDPOINT);
    expect(post.init.method).toBe("POST");
    expect(post.init.redirect).toBe("error");
    expect(post.init.signal instanceof AbortSignal).toBe(true);
    expect([...new Headers(post.init.headers).keys()].sort()).toEqual(["api-revision", "content-type", "x-goog-api-key"]);
    expect(header(post.init, "x-goog-api-key") === KEY).toBe(true);
    expect(header(post.init, "api-revision")).toBe("2026-05-20");
    expect(JSON.parse(post.init.body as string)).toEqual({
      model: "gemini-4-carbon",
      input: "the prompt\n",
      generation_config: { thinking_level: "high", max_output_tokens: 65536 },
      store: true,
      background: true,
    });
    expect(gets.length).toBe(2);
    for (const g of gets) {
      expect(g.url).toBe(`${ENDPOINT}/${ID}`);
      expect(g.idSaved).toBe(true);
      expect(g.init.method).toBe("GET");
      expect(g.init.redirect).toBe("error");
      expect(header(g.init, "x-goog-api-key") === KEY).toBe(true);
    }
    expect(r.calls.some((c) => c.url.includes("key=") || c.url.includes(KEY))).toBe(false);
    expect(r.file("id.txt")).toBe(ID);
    expect(r.file("response.md")).toBe("Hello, world.");
    expect(r.lines.at(-1)).toBe("OK: gemini-4-carbon in=10 cached=4 thought=7 out=3 total=20");
  });

  test("a follow-up chains onto the newest answered turn, skipping an ended one, and re-sends generation_config", async () => {
    const c = conv({ effort: "low", model: "gemini-4-carbon" });
    writeFileSync(join(c.dir, "id.txt"), "int-turn0");
    writeFileSync(join(c.dir, "response.md"), "a0");
    writeFileSync(join(c.dir, "followup-1.md"), "f1");
    writeFileSync(join(c.dir, "id-1.txt"), "int-turn1");
    writeFileSync(join(c.dir, "ended-1.txt"), "failed\n");
    writeFileSync(join(c.dir, "followup-2.md"), "second follow-up\n");
    const r = await run(c, [running(), done()], { turn: 2 });
    expect(r.code).toBe(0);
    expect(JSON.parse(r.calls[0].init.body as string)).toEqual({
      model: "gemini-4-carbon",
      input: "second follow-up\n",
      generation_config: { thinking_level: "low", max_output_tokens: 65536 },
      store: true,
      background: true,
      previous_interaction_id: "int-turn0",
    });
    expect(r.file("response-2.md")).toBe("Hello, world.");
    expect(r.log.includes("int-turn0")).toBe(false);
  });

  test.each([
    ["a lost reply", () => new TypeError("socket closed")],
    ["a 504", () => error(504, "deadline_exceeded", "late")],
    ["a reply with a bad id shape", () => json({ id: "bad/id", status: "in_progress" })],
  ])("%s leaves unknown, its NEXT line and no GET", async (_, reply) => {
    const r = await run(conv(), [reply()]);
    expect(r.calls.length).toBe(1);
    expect(r.file("ended.txt")).toBe("unknown\n");
    expect(r.file("id.txt")).toBeUndefined();
    expect(r.lines.at(-1)).toMatch(/^NEXT: it may be running and billed with no id to collect, and sending it again may be charged twice$/);
  });

  test.each([
    ["a 400 safety block", 0, error(400, "safety", "blocked"), /Google rejected the submission: HTTP 400 safety: blocked/],
    ["a follow-up whose parent expired", 1, error(404, "not_found", "Result not found."), /no longer stored at Google; start a new one with run-gemini.sh/],
    ["a follow-up whose error quotes the parent id", 1, error(400, "invalid_request", "int-parent-7 is in_progress"), /invalid_request: \[redacted\] is in_progress/],
  ])("%s is rejected with no id file", async (_, turn, reply, line) => {
    const c = conv();
    if (turn) {
      writeFileSync(join(c.dir, "id.txt"), "int-parent-7");
      writeFileSync(join(c.dir, "response.md"), "a0");
      writeFileSync(join(c.dir, "followup-1.md"), "f1");
    }
    const r = await run(c, [reply], { turn });
    expect(r.calls.length).toBe(1);
    expect(r.file(turn ? "ended-1.txt" : "ended.txt")).toBe("rejected\n");
    expect(r.file(turn ? "id-1.txt" : "id.txt")).toBeUndefined();
    expect(r.lines.find((l) => l.startsWith("ERROR: "))).toMatch(line);
    expect(turn && r.log.includes("int-parent-7")).toBeFalsy();
  });

  test("a non-JSON body is logged as one escaped line", async () => {
    const r = await run(conv(), [new Response("<html>\n<b>busy</b>\n</html>", { status: 200, headers: { "content-type": "text/html" } })]);
    const bodies = r.lines.filter((l) => l.startsWith("body: "));
    expect(bodies).toEqual(['body: HTTP 200 text/html "<html>\\n<b>busy</b>\\n</html>"']);
    expect(r.file("ended.txt")).toBe("unknown\n");
  });
});

describe("collect", () => {
  test("a 404, a 404, then a completed resource answers", async () => {
    const r = await run(conv(), [running(), error(404, "not_found", "x"), error(404, "not_found", "x"), done()]);
    expect(r.code).toBe(0);
    expect(r.file("response.md")).toBe("Hello, world.");
  });

  test.each(["submit", "collect"] as const)("five 404s in a row leave the %s turn pending, with no marker", async (mode) => {
    const c = conv();
    if (mode === "collect") writeFileSync(join(c.dir, "id.txt"), ID);
    const replies: Reply[] = mode === "submit" ? [running()] : [];
    for (let i = 0; i < 5; i++) replies.push(error(404, "not_found", "x"));
    const r = await run(c, replies, { mode });
    expect(r.calls.filter((call) => call.init.method === "GET").length).toBe(5);
    expect(r.calls.length).toBe(mode === "submit" ? 6 : 5);
    expect([r.file("ended.txt"), r.file("response.md"), r.file("id.txt")]).toEqual([undefined, undefined, ID]);
  });

  test("a 401 ends the wait at once with no marker", async () => {
    const r = await run(conv(), [running(), error(401, "authentication", "bad key")]);
    expect(r.calls.length).toBe(2);
    expect([r.code, r.file("ended.txt"), r.file("response.md")]).toEqual([1, undefined, undefined]);
  });

  test("the clock passing 30 minutes leaves no response and no marker; collect then answers", async () => {
    const c = conv();
    const r = await run(c, () => running());
    expect(r.sleeps.slice(0, 12).every((ms) => ms === 5000)).toBe(true);
    expect(r.sleeps.slice(12).every((ms) => ms === 15000)).toBe(true);
    expect(r.sleeps.reduce((a, b) => a + b, 0)).toBe(30 * 60_000);
    expect([r.file("ended.txt"), r.file("response.md")]).toEqual([undefined, undefined]);
    expect(r.lines.at(-2)).toBe("ERROR: no terminal status after 30 minutes");
    const again = await run(c, [done()], { mode: "collect" });
    expect(again.calls.map((call) => call.init.method)).toEqual(["GET"]);
    expect(again.file("response.md")).toBe("Hello, world.");
  });

  test("poll lines hold neither the id nor remote text", async () => {
    const r = await run(conv(), [running(), error(503, "service_unavailable", "remote words"), json({ id: ID, status: "in_progress", note: "remote words" }), done()]);
    expect(r.lines.filter((l) => l.startsWith("poll "))).toEqual(["poll 1: 503", "poll 2: in_progress", "poll 3: completed"]);
    expect(r.log.includes(ID)).toBe(false);
    expect(r.log.includes("remote words")).toBe(false);
  });

  test("a bad id file fails before any GET and leaves no marker", async () => {
    const c = conv();
    writeFileSync(join(c.dir, "id.txt"), "bad/id");
    const r = await run(c, [done()], { mode: "collect" });
    expect([r.calls.length, r.file("ended.txt")]).toEqual([0, undefined]);
  });
});

describe("terminal resources", () => {
  test("incomplete ends the turn with its marker and the output-cap NEXT line", async () => {
    const r = await run(conv(), [running(), done({ status: "incomplete" })]);
    expect([r.file("ended.txt"), r.file("response.md")]).toEqual(["incomplete\n", undefined]);
    expect(r.lines.at(-1)).toMatch(/the answer did not fit the output cap$/);
  });

  test("failed prints its errors[] redacted", async () => {
    const errors = [{ code: "safety", message: `blocked ${KEY} after int-abc_123` }];
    const r = await run(conv(), [running(), done({ status: "failed", errors })]);
    expect([r.file("ended.txt"), r.file("response.md")]).toEqual(["failed\n", undefined]);
    expect(r.lines.find((l) => l.startsWith("ERROR: "))).toBe("ERROR: the run failed at Google: safety: blocked [redacted] after [redacted]");
    expect(leaks(r.log)).toBe(false);
  });

  test.each([
    ["an unexpected step type", { steps: [{ type: "google_search_call" }, { type: "model_output", content: [{ type: "text", text: "x" }] }] }, "google_search_call step"],
    ["a non-text model_output item", { steps: [{ type: "model_output", content: [{ type: "image", data: "AAAA" }] }] }, "not text"],
    ["a positive total_tool_use_tokens", { usage: { total_tool_use_tokens: 12 } }, "tool use"],
    ["a non-empty grounding_tool_count", { usage: { grounding_tool_count: [{ type: "google_search", count: 1 }] } }, "tool use"],
    ["a model mismatch", { model: "gemini-3.8-flash" }, "served gemini-3.8-flash for the requested gemini-4-carbon; the answer is withheld and retrying is not worth it: pass a concrete model ID"],
    ["an empty answer", { steps: [{ type: "model_output", content: [{ type: "text", text: "" }] }] }, "empty"],
  ])("%s withholds the answer", async (_, over, why) => {
    const r = await run(conv(), [running(), done(over)]);
    expect([r.file("ended.txt"), r.file("response.md")]).toEqual(["withheld\n", undefined]);
    expect(r.lines.find((l) => l.startsWith("ERROR: "))).toContain(why);
  });

  test("a resource with another id publishes nothing and leaves no marker", async () => {
    const r = await run(conv(), [running(), done({ id: "int-other" })]);
    expect([r.code, r.file("ended.txt"), r.file("response.md")]).toEqual([1, undefined, undefined]);
  });

  test("earlier turns' steps in the resource give only this turn's answer", async () => {
    const steps = [
      { type: "user_input", content: [{ type: "text", text: "q1" }] },
      { type: "model_output", content: [{ type: "text", text: "old answer" }] },
      { type: "user_input", content: [{ type: "text", text: "q2" }] },
      { type: "thought", signature: "s" },
      { type: "model_output", content: [{ type: "text", text: "new answer" }] },
    ];
    const r = await run(conv(), [running(), done({ steps })]);
    expect(r.file("response.md")).toBe("new answer");
  });

  test("an answer another collector published is left alone, with no marker", async () => {
    const c = conv();
    writeFileSync(join(c.dir, "id.txt"), ID);
    writeFileSync(join(c.dir, "response.md"), "theirs");
    const r = await run(c, [done()], { mode: "collect" });
    expect([r.code, r.file("response.md"), r.file("ended.txt")]).toEqual([0, "theirs", undefined]);
  });

  test("an empty model record means gemini-4-carbon, and a -001 served suffix passes", async () => {
    const r = await run(conv(), [running(), done({ model: "gemini-4-carbon-001" })]);
    expect(JSON.parse(r.calls[0].init.body as string).model).toBe("gemini-4-carbon");
    expect(r.file("response.md")).toBe("Hello, world.");
  });
});

describe("the key", () => {
  test("a 403 placing the key across character 500 leaves no part of it, and no newline, in the log", async () => {
    const r = await run(conv(), [error(403, "permission_denied", `${"m".repeat(495)}${KEY}\nmore`)]);
    expect(r.file("ended.txt")).toBe("rejected\n");
    expect(leaks(r.log)).toBe(false);
    expect(r.lines.every((l) => !/[\n\r]/.test(l))).toBe(true);
  });

  test("a throw inside main is printed through the redactor", async () => {
    const sleep = async () => {
      throw new Error(`sleep failed holding ${KEY}`);
    };
    const r = await run(conv(), [running(), running()], { sleep });
    expect(r.code).toBe(1);
    expect(r.lines.at(-2)).toBe("ERROR: the engine stopped unexpectedly: Error: sleep failed holding [redacted]");
    expect(leaks(r.log)).toBe(false);
  });

  const line = `GEMINI_API_KEY=${KEY}\n`;
  test.each([
    ["missing", "cannot be opened (ENOENT)", (p: string) => p],
    ["a symlink", "cannot be opened (ELOOP)", (p: string) => (writeFileSync(`${p}.real`, line, { mode: 0o600 }), symlinkSync(`${p}.real`, p), p)],
    ["a FIFO", "is not a regular file", (p: string) => (Bun.spawnSync(["mkfifo", "-m", "600", p]), p)],
    ["mode 644", "is open to group or others", (p: string) => (writeFileSync(p, line), chmodSync(p, 0o644), p)],
    ["owned by another uid", "is not owned by uid", () => (statSync("/etc/passwd").uid === UID ? "" : "/etc/passwd")],
    ["without a key line", "must hold one line GEMINI_API_KEY=", (p: string) => (writeFileSync(p, "OTHER=1\n", { mode: 0o600 }), p)],
    ["a value with a U+200B", "must hold one line GEMINI_API_KEY=", (p: string) => (writeFileSync(p, `GEMINI_API_KEY=${KEY}\u200b\n`, { mode: 0o600 }), p)],
  ])("a key file %s is refused by path and reason, nothing sent", async (_, why, make) => {
    const keyPath = make(join(root, `refused${++seq}.env`));
    expect(keyPath).not.toBe("");
    const r = await run(conv(), [], { keyPath });
    expect(r.calls.length).toBe(0);
    expect(r.file("ended.txt")).toBe("not-sent\n");
    expect(r.lines.find((l) => l.startsWith("ERROR: "))).toStartWith(`ERROR: ${keyPath} ${why}`);
    expect(leaks(r.log)).toBe(false);
  });
});
