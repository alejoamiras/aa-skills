// Renders popscan candidates as before / at / after crop strips, one row per candidate, into one PNG.
//   bun popscan.ts <video> <cuts> | bun popcrops.ts <video> <out.png>
//   bun popcrops.ts <video> <out.png> <frame,x,y,shotStart,shotEnd> ...
// DRAWTEXT_FONT=<font file> labels the frames; without it ffmpeg's fontconfig default ("Sans") is used.
import { mkdtempSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { drawtextFont, probeVideo } from "./lib.ts";

const [video, out, ...args] = Bun.argv.slice(2);
if (!video || !out) throw new Error("usage: bun popcrops.ts <video> <out.png> [frame,x,y,shotStart,shotEnd ...]");
const font = drawtextFont();
const C = 384; // crop edge in source pixels

// `near` rows are one-frame edge jumps, shown as the frames either side instead of five away.
type Cand = { t: number; x: number; y: number; a: number; e: number; bw: number; bh: number; near: boolean };
function fromStdin(text: string) {
  const cands: Cand[] = [];
  let shots = 0;
  let range: [number, number] = [0, Number.POSITIVE_INFINITY];
  for (const line of text.split("\n")) {
    const shot = line.match(/^shot \d+ \[(\d+), (\d+)\)/);
    if (shot) [shots, range] = [shots + 1, [Number(shot[1]), Number(shot[2])]];
    const ev = line.match(/frame (\d+)\s+box x=(\d+) y=(\d+) \((\d+)x(\d+) px\)/);
    if (ev) cands.push({ t: +ev[1], x: +ev[2], y: +ev[3], a: range[0], e: range[1], bw: +ev[4], bh: +ev[5], near: line.includes("edge jump") });
  }
  return { cands, shots };
}
const piped = args.length ? undefined : fromStdin(await new Response(Bun.stdin.stream()).text());
const cands: Cand[] =
  piped?.cands ??
  args.map((c) => {
    const [t, x, y, a, e] = c.split(",").map(Number);
    return { t, x, y, a, e, bw: 96, bh: 96, near: false };
  });
if (!cands.length && piped?.shots) {
  console.log(`nothing to crop: the scan listed no candidates in ${piped.shots} shots`);
  process.exit(0);
}
if (!cands.length) throw new Error("no candidates: pass them as arguments or pipe popscan.ts output in");

const { width: W, height: H, frames: N } = probeVideo(video);
const bad = cands.find((c) => ![c.t, c.x, c.y, c.a].every(Number.isInteger) || c.t < 0 || c.t >= N);
if (bad) throw new Error(`candidate frame ${bad.t} is not a frame of ${video} (0..${N - 1})`);
// A directory of our own next to the output, so cleanup can never touch anything else.
const dir = mkdtempSync(join(dirname(resolve(out)), ".popcrops-"));

async function render() {
  const rows = await Promise.all(
    cands.map(async (c, i) => {
      const d = c.near ? 1 : 5;
      // select can't repeat a frame, so a candidate on a shot's last frame gets a two-panel strip.
      const frames = [...new Set([Math.max(c.a, c.t - d), c.t, Math.min(c.e - 1, N - 1, c.t + d)])];
      const cx = Math.min(W - C, Math.max(0, c.x + c.bw / 2 - C / 2));
      const cy = Math.min(H - C, Math.max(0, c.y + c.bh / 2 - C / 2));
      const f = join(dir, `row${String(i).padStart(2, "0")}.png`);
      const vf = [
        `select='${frames.map((n) => `eq(n,${n})`).join("+")}'`,
        `crop=${C}:${C}:${cx}:${cy}`,
        `drawbox=x=${c.x - cx}:y=${c.y - cy}:w=${c.bw}:h=${c.bh}:color=yellow@0.7:t=2`,
        "scale=256:256",
        `tile=${frames.length}x1`,
        // Every row pads to three panels' width, so strips of two and three frames stack.
        `pad=${3 * 256 + 150}:ih:0:0:black,drawtext=${font}:text='${frames.join(" ")}':x=w-146:y=10:fontsize=18:fontcolor=white`,
      ].join(",");
      await Bun.$`ffmpeg -hide_banner -v error -y -i ${video} -vf ${vf} -frames:v 1 ${f}`;
      return f;
    }),
  );
  const inputs = rows.flatMap((r) => ["-i", r]);
  const stack = rows.length > 1 ? `${rows.map((_, i) => `[${i}:v]`).join("")}vstack=inputs=${rows.length}` : "[0:v]null";
  await Bun.$`ffmpeg -hide_banner -v error -y ${inputs} -filter_complex ${stack} ${out}`;
}
try {
  await render();
} finally {
  rmSync(dir, { recursive: true });
}
console.log(out);
