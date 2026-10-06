#!/usr/bin/env bun
// Narration client for the explainer skill: the ONLY process that ever holds ELEVENLABS_API_KEY.
// Launch narrated runs through scripts/narrate.sh, which strips the environment so no Bun preload,
// bunfig or dotenv file runs inside this process.
// Usage: tts.ts <narration.json> <out-dir> [--captions-only]
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

type Scene = { id: string; title: string; text: string };
type Narration = { scenes: Scene[]; voice_id?: string; model_id?: string };
type Alignment = {
  characters: string[];
  character_start_times_seconds: number[];
  character_end_times_seconds: number[];
};

const API = "https://api.elevenlabs.io";
const MAX_CHARS = 6000;
const SCENE_GAP = "\n\n";
// Captions-only pacing: 150 words a minute plus a beat between scenes.
const CHARS_PER_SECOND = 15;
const SCENE_PAUSE = 0.8;

function die(code: number, msg: string): never {
  const key = process.env.ELEVENLABS_API_KEY;
  console.error(`tts: ${key ? msg.split(key).join("[redacted]") : msg}`);
  process.exit(code);
}

function load(path: string): Narration {
  const n = JSON.parse(readFileSync(path, "utf8")) as Narration;
  if (!Array.isArray(n.scenes) || n.scenes.length === 0) die(1, "narration.scenes must be a non-empty array");
  const ids = new Set<string>();
  for (const s of n.scenes) {
    if (typeof s.id !== "string" || !/^[a-z0-9-]{1,32}$/.test(s.id) || ids.has(s.id)) die(1, `bad or duplicate scene id: ${s.id}`);
    if (typeof s.text !== "string" || !s.text.trim()) die(1, `scene ${s.id} has no text`);
    if (typeof s.title !== "string") die(1, `scene ${s.id} has no title`);
    ids.add(s.id);
  }
  return n;
}

// Offsets are in code points, the unit ElevenLabs' alignment.characters uses.
function joinScenes(scenes: Scene[]) {
  const chars: string[] = [];
  const spans = scenes.map((s, i) => {
    if (i > 0) chars.push(...SCENE_GAP);
    const start = chars.length;
    chars.push(...s.text.trim());
    return { id: s.id, title: s.title, text: s.text.trim(), start, end: chars.length };
  });
  return { chars, text: chars.join(""), spans };
}

function syntheticAlignment(chars: string[], spans: { start: number }[]): Alignment {
  const a: Alignment = { characters: [], character_start_times_seconds: [], character_end_times_seconds: [] };
  let t = 0;
  let next = 1;
  for (let i = 0; i < chars.length; i++) {
    if (next < spans.length && i === spans[next].start) {
      t += SCENE_PAUSE;
      next++;
    }
    a.characters.push(chars[i]);
    a.character_start_times_seconds.push(t);
    t += 1 / CHARS_PER_SECOND;
    a.character_end_times_seconds.push(t);
  }
  return a;
}

function validAlignment(a: Alignment | null | undefined, chars: string[]): a is Alignment {
  if (!a || !Array.isArray(a.characters)) return false;
  const { characters: c, character_start_times_seconds: s, character_end_times_seconds: e } = a;
  if (c.length !== chars.length || s?.length !== c.length || e?.length !== c.length) return false;
  let prev = 0;
  for (let i = 0; i < c.length; i++) {
    if (c[i] !== chars[i] || !Number.isFinite(s[i]) || !Number.isFinite(e[i]) || s[i] < prev || e[i] < s[i]) return false;
    prev = s[i];
  }
  return true;
}

function words(a: Alignment) {
  const out: { w: string; s: number; e: number }[] = [];
  let cur: { w: string; s: number; e: number } | null = null;
  for (let i = 0; i < a.characters.length; i++) {
    const c = a.characters[i];
    if (/\s/.test(c)) {
      if (cur) out.push(cur);
      cur = null;
    } else if (cur) {
      cur.w += c;
      cur.e = a.character_end_times_seconds[i];
    } else cur = { w: c, s: a.character_start_times_seconds[i], e: a.character_end_times_seconds[i] };
  }
  if (cur) out.push(cur);
  return out;
}

function mediaDuration(path: string): number | null {
  // Empty env: the media parser never sees the key.
  const bin = process.env.EXPLAINER_FFPROBE ?? "ffprobe";
  const r = spawnSync(bin, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path], { encoding: "utf8", env: {} });
  const d = Number(r.stdout?.trim());
  return r.status === 0 && Number.isFinite(d) && d > 0 ? d : null;
}

function atomicWrite(path: string, data: string | Buffer) {
  writeFileSync(`${path}.tmp`, data);
  renameSync(`${path}.tmp`, path);
}

// One paid request per cache key, ever, unless the owner clears the pending marker by hand.
async function synthesize(text: string, voice: string, model: string, cacheBase: string) {
  const key = process.env.ELEVENLABS_API_KEY;
  if (!key) die(3, "ELEVENLABS_API_KEY is not set; run through scripts/narrate.sh or use --captions-only");
  const pending = `${cacheBase}.pending`;
  try {
    closeSync(openSync(pending, "wx"));
  } catch {
    die(4, `${pending} exists: an earlier request is in flight or its outcome is unknown. Check the ElevenLabs history, then delete the file to retry.`);
  }
  let audio: Buffer;
  let alignment: unknown;
  let requestId: string | null;
  try {
    const res = await fetch(`${API}/v1/text-to-speech/${encodeURIComponent(voice)}/with-timestamps?output_format=mp3_44100_128`, {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(180_000),
      headers: { "xi-api-key": key, "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ text, model_id: model }),
    });
    requestId = res.headers.get("request-id");
    if (!res.ok) {
      // An unreadable body throws to the outer catch, which keeps the marker: fail closed.
      const body = (await res.text()).slice(0, 600);
      // Only a 4xx is a confirmed rejection that generated nothing; a 5xx may still have been billed.
      if (res.status >= 400 && res.status < 500) {
        rmSync(pending);
        die(2, `HTTP ${res.status}: ${body}`);
      }
      die(4, `HTTP ${res.status}, outcome unknown, may be billed; ${pending} kept so nothing resubmits: ${body}`);
    }
    const json = (await res.json()) as { audio_base64?: string; alignment?: unknown };
    if (!json.audio_base64) throw new Error("response has no audio_base64");
    audio = Buffer.from(json.audio_base64, "base64");
    alignment = json.alignment ?? null;
  } catch (err) {
    die(4, `outcome unknown, may be billed; ${pending} kept so nothing resubmits: ${String(err)}`);
  }
  // Persist what was paid for before anything can fail on it.
  atomicWrite(`${cacheBase}.mp3`, audio);
  atomicWrite(`${cacheBase}.json`, JSON.stringify({ alignment, requestId }));
  rmSync(pending);
}

async function main() {
  const args = process.argv.slice(2);
  const captionsOnly = args.includes("--captions-only");
  const positional = args.filter((a) => a !== "--captions-only");
  if (positional.length !== 2 || positional.some((a) => a.startsWith("-"))) die(1, "usage: tts.ts <narration.json> <out-dir> [--captions-only]");
  const out = resolve(positional[1]);
  mkdirSync(join(out, "cache"), { recursive: true });

  const n = load(resolve(positional[0]));
  const { chars, text, spans } = joinScenes(n.scenes);
  if (chars.length > MAX_CHARS) die(1, `narration is ${chars.length} characters, over the ${MAX_CHARS} cap`);
  const voice = n.voice_id ?? process.env.ELEVENLABS_VOICE_ID ?? "";
  const model = n.model_id ?? "eleven_multilingual_v2";
  if (!/^[a-z0-9_]{1,40}$/.test(model)) die(1, `bad model_id: ${model}`);

  let alignment: Alignment;
  let approx = false;
  let requestId: string | null = null;
  let duration: number;

  if (captionsOnly) {
    alignment = syntheticAlignment(chars, spans);
    duration = alignment.character_end_times_seconds.at(-1) ?? 0;
  } else {
    if (!/^[A-Za-z0-9]{8,40}$/.test(voice)) die(1, "set voice_id in narration.json or ELEVENLABS_VOICE_ID");
    const cacheBase = join(out, "cache", createHash("sha256").update(JSON.stringify({ text, voice, model })).digest("hex").slice(0, 32));
    if (existsSync(`${cacheBase}.mp3`) && existsSync(`${cacheBase}.json`)) console.log("tts: cache hit, no request sent");
    else await synthesize(text, voice, model, cacheBase);
    const cached = JSON.parse(readFileSync(`${cacheBase}.json`, "utf8")) as { alignment: Alignment | null; requestId: string | null };
    requestId = cached.requestId;
    atomicWrite(join(out, "narration.mp3"), readFileSync(`${cacheBase}.mp3`));
    const media = mediaDuration(join(out, "narration.mp3"));
    if (validAlignment(cached.alignment, chars)) {
      alignment = cached.alignment;
      duration = Math.max(media ?? 0, alignment.character_end_times_seconds.at(-1) ?? 0);
    } else {
      // Scene times scaled over the audio; no word cues, because invented ones would drift.
      if (!media) die(2, "alignment unusable and ffprobe cannot read the audio length; rerun with --captions-only");
      approx = true;
      const synth = syntheticAlignment(chars, spans);
      const k = media / (synth.character_end_times_seconds.at(-1) ?? 1);
      alignment = { ...synth, character_start_times_seconds: synth.character_start_times_seconds.map((t) => t * k) };
      duration = media;
    }
  }

  const starts = alignment.character_start_times_seconds;
  const scenes = spans.map((s, i) => ({
    id: s.id,
    title: s.title,
    text: s.text,
    start: i === 0 ? 0 : starts[s.start],
    end: i === spans.length - 1 ? duration : starts[spans[i + 1].start],
  }));
  const timings = { audio: captionsOnly ? null : "narration.mp3", duration, model: captionsOnly ? null : model, approx, requestId, scenes, words: approx ? [] : words(alignment) };
  // `<` escaped so the file can be pasted inside <script type="application/json"> verbatim.
  atomicWrite(join(out, "timings.json"), JSON.stringify(timings).replace(/</g, "\\u003c"));
  console.log(`tts: ${scenes.length} scenes, ${duration.toFixed(1)} s, ${chars.length} characters${approx ? ", approximate scene timing, no word cues" : ""}`);
}

await main();
