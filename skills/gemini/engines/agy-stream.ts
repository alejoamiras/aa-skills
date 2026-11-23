// agy's stream-json protocol as the worker pump reads it, and the pump's log-line shapes: pure functions over events,
// strings and byte streams. Every read of an agy event lives here; nothing here touches the key, files or processes.
import type { Readable } from "node:stream";

export type Json = Record<string, unknown>;
export const isObj = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);
const safe = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;
const RAW_MAX = 1024 * 1024;
const ENTRY_MAX = 64 * 1024;

// Shapes recorded from agy 1.5.15.
export const userEvent = (text: string) => `${JSON.stringify({ event: "user", message: { content: text } })}\n`;
const payload = (ev: unknown, name: string) => (isObj(ev) && ev.event === name && isObj(ev[name]) ? (ev[name] as Json) : undefined);
export const isStep = (ev: unknown) => payload(ev, "step_update") !== undefined;
export const conversationOf = (ev: unknown) => (isObj(ev) && ev.event === "init" && typeof ev.conversation_id === "string" ? ev.conversation_id : undefined);

export type Result = { status: string; answer: string | null; turns: number | undefined; total: number | undefined };
// usage and num_turns count the whole session. total_tokens leaves cached reads out, so the total adds them back.
export function resultOf(ev: unknown): Result | undefined {
  const r = payload(ev, "result");
  if (!r) return undefined;
  const u = isObj(r.usage) ? r.usage : {};
  const sum = safe(u.total_tokens) && safe(u.cache_read_tokens) ? u.total_tokens + u.cache_read_tokens : undefined;
  return {
    status: typeof r.status === "string" ? r.status : "?",
    answer: typeof r.response === "string" ? r.response : null,
    turns: safe(r.num_turns) ? r.num_turns : undefined,
    total: safe(sum) ? sum : undefined,
  };
}

// agy streams a response as short ACTIVE text_delta steps, then a DONE, so a key it repeats can straddle events.
export function textStep(ev: unknown): { index: number; text: string; done: boolean } | undefined {
  const s = payload(ev, "step_update");
  if (!s || typeof s.text_delta !== "string") return undefined;
  return { index: safe(s.step_index) ? s.step_index : -1, text: s.text_delta, done: s.state === "DONE" };
}
export const withText = (ev: Json, text: string): Json => ({ ...ev, step_update: { ...(ev.step_update as Json), text_delta: text } });
export const stepDone = (ev: unknown) => payload(ev, "step_update")?.state === "DONE";
export function stepIndex(ev: unknown): number | undefined {
  const s = payload(ev, "step_update");
  return s && safe(s.step_index) ? s.step_index : undefined;
}

// A tool step counts once, on DONE. Names are never matched: the stream says write_file where init.tools says write_to_file.
export function toolDone(ev: unknown): { index: number; error: boolean } | undefined {
  const s = payload(ev, "step_update");
  if (!s || s.step_type !== "tool" || s.state !== "DONE" || !safe(s.step_index)) return undefined;
  return { index: s.step_index, error: isObj(s.tool_info) && s.tool_info.error != null };
}

export function paneParts(ev: unknown): string[] {
  if (!isObj(ev) || typeof ev.event !== "string") return ["raw", (typeof ev === "string" ? ev : JSON.stringify(ev)).slice(0, 300)];
  const p = isObj(ev[ev.event]) ? (ev[ev.event] as Json) : {};
  const tool = isObj(p.tool_info) ? p.tool_info : {};
  const params = tool.parameters === undefined ? undefined : JSON.stringify(tool.parameters);
  const text = [p.text_delta, p.response, p.error, tool.output, params].find((s) => typeof s === "string" && s !== "") as string | undefined;
  return [ev.event, p.state, p.step_type, p.tool_name, text?.slice(0, 300)].filter((s): s is string => typeof s === "string" && s !== "");
}

// Serialized JSON is never cut: an oversize entry keeps the redacted event's start as a string, shrunk until the line fits.
export function fit(t: string, src: string, body: Json): string {
  const line = JSON.stringify({ t, src, ...body });
  if (Buffer.byteLength(line) < ENTRY_MAX) return line;
  let head = (typeof body.ev === "string" ? body.ev : JSON.stringify(body.ev ?? body)).slice(0, ENTRY_MAX);
  for (;;) {
    const cut = JSON.stringify({ t, src, cut: true, head });
    if (Buffer.byteLength(cut) < ENTRY_MAX) return cut;
    head = head.slice(0, Math.floor(head.length * 0.7));
  }
}

export function paneText(src: string, b: Json): string {
  if (src === "agy") return paneParts(b.ev).join(" ");
  if (src === "err") return String(b.ev).slice(0, 300);
  if (src === "in") return `from=${b.from} ${b.name} ${String(b.text ?? b.refused).slice(0, 300)}`;
  return Object.entries(b).map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`).join(" ");
}

export const tail = (s: string, max: number) => {
  const b = Buffer.from(s);
  return b.length <= max ? s : b.subarray(b.length - max).toString("utf8");
};

// Splits a byte stream into lines; a line past RAW_MAX keeps only its start and is reported as over, with its full size.
export function lines(stream: Readable, each: (line: Buffer, over: boolean, size: number) => void, end?: () => void) {
  let parts: Buffer[] = [];
  let size = 0;
  const take = (b: Buffer) => {
    const kept = b.subarray(0, Math.max(0, RAW_MAX + 1 - size));
    if (kept.length) parts.push(kept);
    size += b.length;
  };
  const flush = () => {
    each(Buffer.concat(parts), size > RAW_MAX, size);
    parts = [];
    size = 0;
  };
  stream.on("data", (chunk: Buffer) => {
    let at = 0;
    for (let nl = chunk.indexOf(10); nl !== -1; nl = chunk.indexOf(10, at)) {
      take(chunk.subarray(at, nl));
      flush();
      at = nl + 1;
    }
    take(chunk.subarray(at));
  });
  stream.on("end", () => {
    if (size) flush();
    end?.();
  });
}
