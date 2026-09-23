// Machine checks on a spot's deliverables before anyone reviews them. Each video must carry the cut's
// frame count at its frame rate and one AAC track whose loudness and true peak, measured on the final
// file, sit on target. Each SRT must have ordered, non-overlapping cues. Exits 1 on any failure.
//   bun qc.ts --frames <N> [--fps 24] [--lufs -16] [--tp -1] [--cues N] <file.mp4|file.srt> ...
// Digital silence longer than 0.3 s is reported, not failed: a spot may hold one on purpose.
import { probeVideo } from "./lib.ts";

const args = Bun.argv.slice(2);
const opt = (k: string, d?: number) => {
  const i = args.indexOf(`--${k}`);
  const v = i >= 0 ? Number(args.splice(i, 2)[1]) : d;
  if (v !== undefined && !Number.isFinite(v)) throw new Error(`--${k} needs a number`);
  return v;
};
const FRAMES = opt("frames");
const FPS = opt("fps", 24) as number;
const LUFS = opt("lufs", -16) as number;
const TP = opt("tp", -1) as number;
const CUES = opt("cues");
if (FRAMES === undefined || !args.length) throw new Error("usage: bun qc.ts --frames <N> [--fps 24] [--lufs -16] [--tp -1] [--cues N] <files...>");

let failed = false;
const report = (f: string, problems: string[], notes: string[]) => {
  failed ||= problems.length > 0;
  console.log(`${problems.length ? "FAIL" : "PASS"} ${f}  ${[...problems, ...notes].join(" · ")}`);
};

function checkVideo(f: string) {
  const [problems, notes] = [[] as string[], [] as string[]];
  const v = probeVideo(f, { decode: true });
  if (v.frames !== FRAMES) problems.push(`${v.frames} decoded frames, want ${FRAMES}`);
  if (Math.abs(v.fps - FPS) > 0.01) problems.push(`${v.fps.toFixed(3)} fps, want ${FPS}`);
  const a = Bun.spawnSync(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=codec_name,sample_rate", "-of", "csv=p=0", f]).stdout.toString().trim();
  if (a !== "aac,48000") problems.push(`audio "${a || "none"}", want one aac,48000 track`);
  const m = Bun.spawnSync(["ffmpeg", "-hide_banner", "-nostats", "-i", f, "-map", "0:a:0", "-af", "ebur128=peak=true,silencedetect=n=-70dB:d=0.3", "-f", "null", "-"], { stderr: "pipe" });
  const log = m.stderr.toString();
  const summary = log.slice(log.lastIndexOf("Summary:"));
  const i = Number(summary.match(/I:\s+(-?[\d.]+) LUFS/)?.[1]);
  const tp = Number(summary.match(/True peak:\s+Peak:\s+(-?[\d.]+|-inf) dBFS/)?.[1]);
  const lra = summary.match(/LRA:\s+([\d.]+) LU/)?.[1];
  if (m.exitCode !== 0 || !Number.isFinite(i)) problems.push("no loudness reading");
  else if (Math.abs(i - LUFS) > 0.5) problems.push(`${i} LUFS, want ${LUFS} ± 0.5`);
  if (!Number.isFinite(tp)) problems.push("no true-peak reading");
  else if (tp > TP) problems.push(`true peak ${tp} dBTP, want ≤ ${TP}`);
  notes.push(`${i} LUFS, ${tp} dBTP, LRA ${lra} LU`);
  const silences = [...log.matchAll(/silence_start: (-?[\d.]+)[\s\S]*?silence_end: ([\d.]+)/g)].map((s) => `${Number(s[1]).toFixed(2)}–${Number(s[2]).toFixed(2)} s`);
  if (silences.length) notes.push(`digital silence at ${silences.join(", ")}`);
  report(f, problems, notes);
}

async function checkSrt(f: string) {
  const problems: string[] = [];
  const t = (s: string) => {
    const [h, m, rest] = s.split(":");
    const [sec, ms] = rest.split(",");
    return Number(h) * 3600 + Number(m) * 60 + Number(sec) + Number(ms) / 1000;
  };
  const cues = [...(await Bun.file(f).text()).matchAll(/(\d\d:\d\d:\d\d,\d{3}) --> (\d\d:\d\d:\d\d,\d{3})/g)].map((c) => [t(c[1]), t(c[2])]);
  if (!cues.length) problems.push("no cues");
  cues.forEach(([a, b], k) => {
    if (b <= a) problems.push(`cue ${k + 1} ends before it starts`);
    if (k > 0 && a < cues[k - 1][1]) problems.push(`cue ${k + 1} overlaps cue ${k}`);
    if (b > FRAMES! / FPS + 0.001) problems.push(`cue ${k + 1} runs past the end`);
  });
  if (CUES !== undefined && cues.length !== CUES) problems.push(`${cues.length} cues, want ${CUES}`);
  report(f, problems, [`${cues.length} cues`]);
}

for (const f of args) {
  try {
    if (f.endsWith(".srt")) await checkSrt(f);
    else checkVideo(f);
  } catch (e) {
    report(f, [(e as Error).message], []);
  }
}
if (failed) process.exit(1);
