// Onset, peak and integrated loudness of an audio file, for placing a sound on a frame. Put the event
// you want on the cue, usually the onset and sometimes the peak, and confirm it by listening:
// start on the timeline = cue − (event time − trim-in).
//   bun transient.ts <audio file>
const f = Bun.argv[2];
if (!f) throw new Error("usage: bun transient.ts <audio file>");
const p = Bun.spawnSync(
  ["ffmpeg", "-v", "info", "-i", f, "-af", "aresample=48000,astats=metadata=1:reset=1:length=0.01,ametadata=print:key=lavfi.astats.Overall.Peak_level:file=-,ebur128=framelog=quiet", "-f", "null", "-"],
  { stdout: "pipe", stderr: "pipe" },
);
const out = p.stdout.toString();
const err = p.stderr.toString();
if (p.exitCode !== 0) throw new Error(`ffmpeg can't read ${f}: ${err.trim().split("\n").at(-1)}`);
const rows = [...out.matchAll(/pts_time:([\d.]+)[\s\S]*?Peak_level=(-?[\d.]+|-inf)/g)].map((m) => [Number(m[1]), Number(m[2])] as const);
const levels = rows.filter(([, db]) => Number.isFinite(db));
if (!levels.length) throw new Error(`${f} has no measurable level: silent or unreadable`);
const peak = levels.reduce((a, b) => (b[1] > a[1] ? b : a));
const onset = levels.find(([, db]) => db > peak[1] - 12)?.[0] ?? peak[0];
const lufs = err.match(/I:\s+(-?[\d.]+) LUFS/)?.[1];
if (lufs === undefined) throw new Error(`no integrated loudness for ${f}`);
const dur = Number(Bun.spawnSync(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f]).stdout.toString());
console.log(`${f.padEnd(18)} dur ${dur.toFixed(2)}s  onset ${onset.toFixed(3)}s  peak ${peak[1].toFixed(1)}dB @${peak[0].toFixed(3)}s  I ${lufs} LUFS`);
