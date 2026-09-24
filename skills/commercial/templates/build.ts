// Spot build: a ducked, two-pass-normalised mix and a graded, text-free picture base, then the
// deliverables (16:9 captioned, 16:9 clean, 1:1 captioned), an SRT, and a 16:9 review cut for each
// alternate punch-line take. Copy into the spot folder, then replace every TODO with the spot's data.
//   bun build.ts [--only=audio,base,text] [--take=<name>]
// Alternates: `bun build.ts --take=<name> --only=audio,text`. The base stage rewrites the shared
// work/base.mov, so never run it for two takes at once.
// Every boundary is a frame number at 24 fps, and every cue is a time relative to a named segment.
import { mkdirSync } from "node:fs";
import { resolve } from "node:path";

const dir = import.meta.dir;
const p = (f: string) => resolve(dir, f);
const FPS = 24;
const SPOT = "spot"; // TODO: deliverable file prefix, e.g. "my-spot" -> my-spot-16x9.mp4
const WORK = "work";
mkdirSync(p(`${WORK}/text`), { recursive: true });
const only = Bun.argv.find((a) => a.startsWith("--only="))?.split("=")[1].split(",");
const stage = (s: string) => !only || only.includes(s);

// FFmpeg's filter parser splits option values on ':' and ',' and unquotes "'", so a path carrying one
// would silently point somewhere else.
const plain = (f: string) => {
  if (/[:,;'"\\[\]=\s]/.test(f)) throw new Error(`"${f}" has a character FFmpeg's filter parser treats specially; move it to a plain path`);
  return f;
};

// TODO: point at the machine's fonts (these are Debian's fonts-inter paths).
const FONT = {
  cap: plain("/usr/share/fonts/opentype/inter/Inter-SemiBold.otf"),
  med: plain("/usr/share/fonts/opentype/inter/InterDisplay-Medium.otf"),
  bold: plain("/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf"),
};

// ---------- timeline ----------
// A "shot" plays runs of source frames ([first, last] inclusive, or one frame). Runs must ascend:
// select drops frames, it can't repeat or reorder them. A "still" holds an image and pushes in by
// `push`. A "freeze" holds the last frame of the shot before it; to hold a still, give it more
// frames. `x` is the left edge of the 1:1 crop on the 1920-wide frame; it is set per segment, so the
// crop only jumps on cuts.
type Run = readonly [number, number?];
type Seg =
  | { id: string; kind: "shot"; src: string; runs: readonly Run[]; grade?: string; x: number }
  | { id: string; kind: "still"; src: string; frames: number; push: number; grade?: string; x: number }
  | { id: string; kind: "freeze"; frames: number; push: number; x: number };

// TODO: the edit, in order. Skip source frame 0 when it pops against frame 1 (it is the exact
// keyframe), start after anything that materialises, and end before duplicates appear.
const TIMELINE: readonly Seg[] = [
  { id: "s1", kind: "shot", src: "shots/s1-t1.mp4", runs: [[0, 101]], x: 500 },
  // Starts at source frame 30 because an object forms in frames 27-29. The six frames went to the
  // end of shot 1, so every cue inside this shot keeps its time.
  { id: "s2", kind: "shot", src: "shots/s2-t1.mp4", runs: [[30, 119]], grade: "colorbalance=gm=0.02:gh=0.01,eq=gamma=0.98", x: 440 },
  // A frame map for a fall the model drifts over ten frames: hold, drop on three accelerating
  // frames, land on the original landing frame so its sound cue stays put.
  { id: "s3", kind: "shot", src: "shots/s3-t1.mp4", runs: [[2, 53], [57], [61], [64], [65, 77]], x: 420 },
  { id: "s4", kind: "shot", src: "shots/s4-t1.mp4", runs: [[0, 83]], grade: "eq=saturation=0.94", x: 660 },
  { id: "s5", kind: "shot", src: "shots/s5-t1.mp4", runs: [[0, 83]], grade: "colorbalance=rm=0.025:bm=-0.02,eq=brightness=-0.015:gamma=0.97", x: 420 },
  { id: "still", kind: "still", src: "kf/still.png", frames: 58, push: 0.045, grade: "eq=saturation=0.94", x: 480 },
  { id: "s6", kind: "shot", src: "shots/s6-t1.mp4", runs: [[0, 105]], grade: "colorbalance=gm=0.015,eq=gamma=0.98", x: 385 },
  // The last frame holds under the super until the sting has rung out, then fades out.
  { id: "end", kind: "freeze", frames: 110, push: 0.045, x: 385 },
];
const FADE = { d: 0.5, black: 0.25 };

const lastFrame = (s: Extract<Seg, { kind: "shot" }>) => {
  const [a, b] = s.runs.at(-1)!;
  return b ?? a;
};
const runsExpr = (runs: readonly Run[]) => runs.map(([a, b]) => (b === undefined ? `eq(n,${a})` : `between(n,${a},${b})`)).join("+");
const segFrames = (s: Seg) => (s.kind === "shot" ? s.runs.reduce((n, [a, b]) => n + (b === undefined ? 1 : b - a + 1), 0) : s.frames);

const ids = new Set<string>();
TIMELINE.forEach((s, i) => {
  if (ids.has(s.id)) throw new Error(`segment id "${s.id}" repeats`);
  ids.add(s.id);
  if (s.kind === "freeze" && TIMELINE[i - 1]?.kind !== "shot") throw new Error(`freeze "${s.id}" must follow a shot`);
  if (s.kind !== "shot") return;
  let prev = -1;
  for (const [a, b = a] of s.runs) {
    if (!Number.isInteger(a) || !Number.isInteger(b) || a <= prev || b < a) throw new Error(`${s.id}: runs must be ascending, non-overlapping frame numbers`);
    prev = b;
  }
});

const starts = TIMELINE.reduce<number[]>((acc, s, i) => [...acc, acc[i] + segFrames(s)], [0]);
// Cues are offsets into segments, so they follow their segment when an earlier cut moves. Trimming a
// segment's own head shifts its action under its cues: recheck those. CUTS pins the edit, so every
// boundary change is a deliberate one. TODO: paste the printed boundaries here once the edit is locked.
const CUTS = [0, 102, 192, 260, 344, 428, 486, 592, 702];
if (starts.join() !== CUTS.join()) throw new Error(`cuts moved: ${starts.join(" ")}, want ${CUTS.join(" ")}`);
const DUR = starts.at(-1)! / FPS;
/** Start of segment `id` in seconds. */
const at = (id: string) => {
  const i = TIMELINE.findIndex((s) => s.id === id);
  if (i < 0) throw new Error(`no segment "${id}"`);
  return starts[i] / FPS;
};
/** `s` seconds into segment `id`, on the millisecond grid the mix and the SRT use. */
const cue = (id: string, s: number) => Math.round((at(id) + s) * 1000) / 1000;
// TODO: the turn. The music bed stops, the sting starts, and the super and its scrim land here.
const tTurn = at("end");
const tFade = DUR - FADE.black - FADE.d;

// The default take ships in the deliverables; any other renders as a 16:9 review cut beside them.
// End each trim after the line's final release burst: a sentence-final stop ("bite", "date") is a
// closure, then a burst 50-100 ms later that silence detection reads as the line already over.
const TAKES = {
  a: { f: "audio/vo5-a.mp3", trim: 1.98, at: cue("still", 0.1167), text: "TODO punch line A.", cap: [cue("still", 0.0667), cue("still", 2.3167)] },
  b: { f: "audio/vo5-b.mp3", trim: 1.54, at: cue("still", 0.3667), text: "TODO punch line B.", cap: [cue("still", 0.3167), cue("still", 2.3167)] },
} as const;
const DEFAULT_TAKE = "a";
const take = (Bun.argv.find((a) => a.startsWith("--take="))?.split("=")[1] ?? DEFAULT_TAKE) as keyof typeof TAKES;
if (!(take in TAKES)) throw new Error(`unknown take "${take}": use ${Object.keys(TAKES).join(", ")}`);
const alt = take === DEFAULT_TAKE ? "" : `-${take}`;

// TODO: one caption per VO line; they carry the spot for muted autoplay.
const captions = [
  { a: cue("s1", 0.35), b: cue("s1", 3.95), text: "TODO line 1." },
  { a: cue("s2", 0.3), b: cue("s2", 2.6), text: "TODO line 2." },
  { a: cue("s3", 0.15), b: cue("s3", 2.25), text: "TODO line 3." },
  { a: cue("s4", 0.8167), b: cue("s4", 3.4167), text: "TODO line 4." },
  { a: TAKES[take].cap[0], b: TAKES[take].cap[1], text: TAKES[take].text },
];
const SUPER = ["TODO super, line 1.", "TODO super, line 2."];

// ---------- audio ----------
const vo = [
  { f: "audio/vo1.mp3", at: cue("s1", 0.4) },
  { f: "audio/vo2.mp3", at: cue("s2", 0.35) },
  { f: "audio/vo3.mp3", at: cue("s3", 0.2) },
  { f: "audio/vo4.mp3", at: cue("s4", 0.8667) },
  { f: TAKES[take].f, at: TAKES[take].at, trim: TAKES[take].trim },
];
// Foley: trim-in a, trim-out b, gain g, and where the trimmed file starts on the timeline:
// cue − (event time − a), with the event's time from scripts/transient.ts, confirmed by ear.
const foley = [
  { f: "audio/fx-1.wav", a: 0.5, b: 3.3, g: 2.0, at: cue("s1", 0.7) },
  { f: "audio/fx-2.wav", a: 0.05, b: 0.4, g: 0.5, at: cue("s2", 0.6) - 0.12 },
  { f: "audio/fx-3.wav", a: 0, b: 0.9, g: 1.0, at: cue("s3", 2.3) - 0.085 },
  { f: "audio/fx-4.wav", a: 0, b: 0.88, g: 0.4, at: cue("s6", 0.375) - 0.17 },
];
// Ambience cuts with the picture: exterior outside, room tone inside, silence on the freeze.
const amb = [
  { f: "audio/amb-exterior.wav", a: 0, at: 0, len: at("s4"), g: 3.2, fadeIn: 0.3 },
  { f: "audio/amb-room.wav", a: 0.2, at: at("s4"), len: at("s5") - at("s4"), g: 1.3 },
  { f: "audio/amb-exterior.wav", a: 1.0, at: at("s5"), len: at("still") - at("s5"), g: 3.2 },
  { f: "audio/amb-room.wav", a: 4.0, at: at("still"), len: at("s6") - at("still"), g: 1.3 },
  { f: "audio/amb-exterior.wav", a: 6.0, at: at("s6"), len: tTurn - at("s6"), g: 4.5 },
];
// A bed that thins out before the reveal can read as a dropout; lift it over a short ramp.
const LIFT = { from: cue("s5", 2.4667), to: cue("s5", 2.9667), gain: 1.778 }; // TODO or set gain: 1

// A shorter or re-cut timeline can strand a cue past the end or tangle the captions.
for (const t of [...captions.flatMap((c) => [c.a, c.b]), ...vo.map((v) => v.at), ...foley.map((x) => x.at), LIFT.from, LIFT.to]) {
  if (!(t >= 0 && t <= DUR)) throw new Error(`a cue at ${t} s falls outside the ${DUR} s timeline`);
}
captions.forEach((c, i) => {
  if (!(c.b > c.a) || (i > 0 && c.a < captions[i - 1].b)) throw new Error(`caption ${i + 1} ends before it starts or overlaps the one before`);
});

const ms = (s: number) => Math.round(s * 1000);
const norm = "aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo";

async function ff(args: string[], label: string) {
  const proc = Bun.spawn(["ffmpeg", "-hide_banner", "-v", "error", "-y", ...args], { stdout: "pipe", stderr: "pipe" });
  const [code, err] = [await proc.exited, await new Response(proc.stderr).text()];
  if (code !== 0) throw new Error(`${label} failed (${code}):\n${err.slice(-3000)}`);
  return err;
}

function frameCount(f: string) {
  const n = Number(Bun.spawnSync(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets", "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", f]).stdout.toString());
  if (!(n > 0)) throw new Error(`can't count the frames of ${f}`);
  return n;
}

async function buildAudio() {
  const inputs: string[] = [];
  const chains: string[] = [];
  const add = (f: string) => (inputs.push("-i", p(f)), inputs.length / 2 - 1);

  vo.forEach((v, i) => {
    const n = add(v.f);
    const trim = "trim" in v ? `,atrim=0:${v.trim},afade=t=out:st=${v.trim - 0.06}:d=0.06` : "";
    chains.push(`[${n}:a]${norm}${trim},highpass=f=80,acompressor=threshold=0.1:ratio=2.5:attack=8:release=120:makeup=1.3,adelay=${ms(v.at)}:all=1[vo${i}]`);
  });
  chains.push(`${vo.map((_, i) => `[vo${i}]`).join("")}amix=inputs=${vo.length}:normalize=0,apad=whole_dur=${DUR},asplit=2[vo][vosc]`);

  const mus = add("audio/music-bed.m4a");
  const [span, rise] = [(LIFT.to - LIFT.from).toFixed(4), (LIFT.gain - 1).toFixed(4)];
  const lift = `volume='if(lt(t,${LIFT.from}),1,if(lt(t,${LIFT.to}),1+(t-${LIFT.from})/${span}*${rise},${LIFT.gain}))':eval=frame`;
  chains.push(`[${mus}:a]${norm},atrim=0:${tTurn},afade=t=in:d=0.4,afade=t=out:st=${(tTurn - 0.07).toFixed(3)}:d=0.07,volume=0.30,${lift},apad=whole_dur=${DUR}[mus0]`);
  chains.push(`[mus0][vosc]sidechaincompress=threshold=0.04:ratio=6:attack=25:release=400[mus]`);

  // A generated sting usually fades its last chord in a fraction of a second. A 1.8 s hall tail
  // (decaying pink-noise IR, wet 9 LU under the dry) lets it ring out under the freeze. gtype=none:
  // afir's default peak auto-gain leaves a long IR about 50 dB down, and its dry= is input gain.
  const sting = add("audio/sting.m4a");
  chains.push(`anoisesrc=d=1.9:c=pink:r=48000:a=0.8:seed=7[irl];anoisesrc=d=1.9:c=pink:r=48000:a=0.8:seed=11[irr];[irl][irr]join=inputs=2:channel_layout=stereo,aeval=exprs='val(0)*exp(-3.8*t)|val(1)*exp(-3.8*t)':channel_layout=stereo,adelay=18:all=1[ir]`);
  chains.push(`[${sting}:a]${norm},volume=0.36,apad=pad_dur=2.2,asplit=2[stgd][stgw]`);
  chains.push(`[stgw][ir]afir=gtype=none,highpass=f=180,lowpass=f=5500,volume=0.0157[stgr]`);
  chains.push(`[stgd][stgr]amix=inputs=2:normalize=0,adelay=${ms(tTurn)}:all=1[stg]`);

  const bus = ["[vo]", "[mus]", "[stg]"];
  amb.forEach((m, i) => {
    const n = add(m.f);
    const fi = "fadeIn" in m ? m.fadeIn : 0.03;
    chains.push(`[${n}:a]${norm},atrim=${m.a}:${(m.a + m.len).toFixed(4)},asetpts=PTS-STARTPTS,afade=t=in:d=${fi},afade=t=out:st=${(m.len - 0.03).toFixed(4)}:d=0.03,volume=${m.g},adelay=${ms(m.at)}:all=1[amb${i}]`);
    bus.push(`[amb${i}]`);
  });
  foley.forEach((x, i) => {
    const n = add(x.f);
    chains.push(`[${n}:a]${norm},atrim=${x.a}:${x.b},asetpts=PTS-STARTPTS,afade=t=out:st=${(x.b - x.a - 0.03).toFixed(3)}:d=0.03,volume=${x.g},adelay=${ms(x.at)}:all=1[fx${i}]`);
    bus.push(`[fx${i}]`);
  });
  chains.push(`${bus.join("")}amix=inputs=${bus.length}:normalize=0:duration=longest,atrim=0:${DUR},volume=1.7,alimiter=limit=0.8:level=false,afade=t=out:st=${(DUR - 0.3).toFixed(3)}:d=0.3[mix]`);

  await ff([...inputs, "-filter_complex", chains.join(";\n"), "-map", "[mix]", "-c:a", "pcm_s24le", p(`${WORK}/mix${alt}.wav`)], "mix");

  // Two-pass loudnorm: measure, then apply linearly so the mix keeps its dynamics. The gain into the
  // limiter above keeps the linear pass under the true-peak ceiling; without that headroom loudnorm
  // silently falls back to dynamic mode, so anything but linear fails the build.
  const target = "I=-16:TP=-1.5:LRA=11";
  const m1 = await ff(["-v", "info", "-i", p(`${WORK}/mix${alt}.wav`), "-af", `loudnorm=${target}:print_format=json`, "-f", "null", "-"], "loudnorm measure");
  const j = JSON.parse(m1.slice(m1.lastIndexOf("{"), m1.lastIndexOf("}") + 1));
  const second = `loudnorm=${target}:measured_I=${j.input_i}:measured_TP=${j.input_tp}:measured_LRA=${j.input_lra}:measured_thresh=${j.input_thresh}:offset=${j.target_offset}:linear=true:print_format=json`;
  const m2 = await ff(["-v", "info", "-i", p(`${WORK}/mix${alt}.wav`), "-af", `${second},aresample=48000`, "-c:a", "pcm_s24le", p(`${WORK}/mix-norm${alt}.wav`)], "loudnorm apply");
  const k = JSON.parse(m2.slice(m2.lastIndexOf("{"), m2.lastIndexOf("}") + 1));
  console.log(`mix: in ${j.input_i} LUFS / ${j.input_tp} dBTP -> out ${k.output_i} LUFS / ${k.output_tp} dBTP, ${k.normalization_type}`);
  if (k.normalization_type !== "linear") throw new Error("loudnorm fell back to dynamic mode: raise the pre-limiter gain or lower the ceiling");
}

// ---------- picture ----------
async function buildBase() {
  const inputs: string[] = [];
  const chains: string[] = [];
  const add = (args: string[]) => (inputs.push(...args), inputs.filter((x) => x === "-i").length - 1);
  const fit = `fps=${FPS},scale=1920:1080:flags=lanczos,setsar=1`;
  const grade = (s: { grade?: string }) => (s.grade ? `,${s.grade}` : "");
  // Push-ins run on a 4K upscale so zoompan's integer crop steps are invisible at 1080p.
  const push = (z: number, n: number) =>
    `scale=3840:2160:flags=lanczos:force_original_aspect_ratio=increase,crop=3840:2160,zoompan=z='1+${z}*on/${n - 1}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=${FPS},setsar=1`;
  const still = (src: string, n: number) => add(["-loop", "1", "-framerate", String(FPS), "-t", String(n / FPS + 0.5), "-i", p(src)]);

  for (const s of TIMELINE) {
    if (s.kind === "shot" && lastFrame(s) >= frameCount(p(s.src))) throw new Error(`${s.id} uses frame ${lastFrame(s)}, past the end of ${s.src}`);
  }
  const labels = TIMELINE.map((s, i) => {
    if (s.kind === "shot") {
      const n = add(["-i", p(s.src)]);
      chains.push(`[${n}:v]select='${runsExpr(s.runs)}',setpts=N/${FPS}/TB,${fit}${grade(s)},format=yuv420p[v${i}]`);
    } else if (s.kind === "still") {
      const n = still(s.src, s.frames);
      chains.push(`[${n}:v]trim=end_frame=${s.frames},setpts=PTS-STARTPTS,${push(s.push, s.frames)}${grade(s)},format=yuv420p[v${i}]`);
    } else {
      const prev = TIMELINE[i - 1] as Extract<Seg, { kind: "shot" }>;
      const [n, one] = [add(["-i", p(prev.src)]), lastFrame(prev)];
      chains.push(`[${n}:v]trim=start_frame=${one}:end_frame=${one + 1},setpts=PTS-STARTPTS,loop=loop=${s.frames - 1}:size=1:start=0,setpts=N/${FPS}/TB,${push(s.push, s.frames)}${grade(prev)},format=yuv420p[v${i}]`);
    }
    return `[v${i}]`;
  });

  // One look over everything, then grain under the clean text the text pass adds. Keep grain off any
  // flat colour card: the platform's re-encode turns grain on a solid field into blocks.
  chains.push(`${labels.join("")}concat=n=${labels.length}:v=1:a=0,eq=contrast=1.035:saturation=0.97,colorbalance=rh=0.012:bh=-0.012,vignette=angle=0.45,noise=c0s=5:c0f=t:c0_seed=5,format=yuv420p[vout]`);

  await ff([...inputs, "-filter_complex", chains.join(";\n"), "-map", "[vout]", "-t", String(DUR), "-r", String(FPS),
    "-c:v", "libx264", "-preset", "slow", "-crf", "12", "-pix_fmt", "yuv420p", p(`${WORK}/base.mov`)], "base");
  if (frameCount(p(`${WORK}/base.mov`)) !== starts.at(-1)) throw new Error(`base.mov has ${frameCount(p(`${WORK}/base.mov`))} frames, want ${starts.at(-1)}`);
}

// ---------- text ----------
type Layout = { w: number; cap: number; capY: number; supA: number; supB: number; supY: number };
const L169: Layout = { w: 1920, cap: 52, capY: 96, supA: 62, supB: 94, supY: 776 };
const L11: Layout = { w: 1080, cap: 42, capY: 92, supA: 48, supB: 72, supY: 800 };

const fade = (a: number, b: number, f: number) =>
  `if(lt(t,${a}),0,if(lt(t,${a + f}),(t-${a})/${f},if(lt(t,${b - f}),1,if(lt(t,${b}),(${b}-t)/${f},0))))`;

// drawtext reads each line from a file with expansion off: inline text breaks on ' and :, and % starts
// an expansion, so a caption like "100% yours" would fail or render wrong.
let textFiles = 0;
async function textFile(text: string) {
  const f = plain(p(`${WORK}/text/${String(textFiles++).padStart(3, "0")}.txt`));
  await Bun.write(f, text);
  return f;
}

async function textLayer(L: Layout, withCaptions: boolean) {
  const d: string[] = [];
  const dt = async (font: string, size: number, color: string, text: string, y: string, a: number, b: number, f: number) =>
    d.push(`drawtext=fontfile=${font}:textfile=${await textFile(text)}:expansion=none:fontsize=${size}:fontcolor=${color}:x=(w-text_w)/2:y='${y}':alpha='${fade(a, b, f)}':enable='between(t,${a},${b})'`);
  if (withCaptions) for (const c of captions) await dt(FONT.cap, L.cap, "white", c.text, `h-${L.capY}-text_h`, c.a, c.b, 0.12);
  // The super stays up to the end; the closing fade takes it out with the picture.
  await dt(FONT.med, L.supA, "white@0.9", SUPER[0], `${L.supY}`, tTurn + 0.13, DUR + 1, 0.25);
  await dt(FONT.bold, L.supB, "white", SUPER[1], `${L.supY + Math.round(L.supA * 1.3)}`, tTurn + 0.43, DUR + 1, 0.25);
  return `color=c=black@0:s=${L.w}x1080:r=${FPS}:d=${DUR},format=rgba,${d.join(",")}`;
}

async function buildText(out: string, L: Layout, pre: string, withCaptions: boolean) {
  const shadow = "colorchannelmixer=rr=0:rg=0:rb=0:gr=0:gg=0:gb=0:br=0:bg=0:bb=0";
  const g = [
    `[0:v]${pre}setsar=1,format=yuv420p[b]`,
    // A scrim under the super only, as one geq frame looped: the gradients source rotates over time
    // and swaps an endpoint on the frame edge for a random row, so every render drew a different scrim.
    `color=c=black:s=${L.w}x1080:r=${FPS}:d=1,trim=end_frame=1,format=rgba,geq=r='0':g='0':b='0':a='158*pow(clip((Y-600)/479,0,1),1.6)',loop=loop=${starts.at(-1)! - 1}:size=1:start=0,setpts=N/${FPS}/TB,fade=t=in:st=${tTurn}:d=0.3:alpha=1[scrim]`,
    `[b][scrim]overlay=enable='gte(t,${tTurn})'[b1]`,
    `${await textLayer(L, withCaptions)},split=2[t1][t2]`,
    `[t2]${shadow}:aa=0.7,gblur=sigma=6[sh]`,
    `[b1][sh]overlay=0:3[b2]`,
    `[b2][t1]overlay=0:0,fade=t=out:st=${tFade.toFixed(3)}:d=${FADE.d},format=yuv420p[v]`,
  ];
  await ff(["-i", p(`${WORK}/base.mov`), "-i", p(`${WORK}/mix-norm${alt}.wav`), "-filter_complex", g.join(";\n"), "-map", "[v]", "-map", "1:a", "-t", String(DUR),
    "-c:v", "libx264", "-preset", "slow", "-crf", "17", "-maxrate", "16M", "-bufsize", "32M", "-profile:v", "high", "-level", "4.1",
    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-movflags", "+faststart", p(out)], out);
  if (frameCount(p(out)) !== starts.at(-1)) throw new Error(`${out} has ${frameCount(p(out))} frames, want ${starts.at(-1)}`);
}

// The square crop follows each segment's `x` and only jumps on cuts. It switches on the frame number:
// a rounded time threshold ((106/24).toFixed(4) is 4.4167) kept the old crop on a new shot's first frame.
const squareX = TIMELINE.slice(0, -1).reduceRight((acc, s, i) => `if(lt(n,${starts[i + 1]}),${s.x},${acc})`, String(TIMELINE.at(-1)!.x));

function srt() {
  const ts = (s: number) => {
    const t = Math.round(s * 1000), h = Math.floor(t / 3600000), m = Math.floor(t / 60000) % 60, sec = Math.floor(t / 1000) % 60;
    return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")},${String(t % 1000).padStart(3, "0")}`;
  };
  return captions.map((c, i) => `${i + 1}\n${ts(c.a)} --> ${ts(c.b)}\n${c.text}\n`).join("\n");
}

if (stage("audio")) await buildAudio();
if (stage("base")) await buildBase();
if (stage("text") && alt) await buildText(`${WORK}/alt${alt}-16x9.mp4`, L169, "", true);
if (stage("text") && !alt) {
  await Promise.all([
    buildText(`${SPOT}-16x9.mp4`, L169, "", true),
    buildText(`${SPOT}-16x9-clean.mp4`, L169, "", false),
    buildText(`${SPOT}-1x1.mp4`, L11, `crop=1080:1080:'${squareX}':0,`, true),
  ]);
  await Bun.write(p(`${SPOT}.srt`), srt());
}
console.log("segment starts (s):", TIMELINE.map((s, i) => `${s.id} ${(starts[i] / FPS).toFixed(3)}`).join(" · "), `| ${starts.at(-1)} frames`);
