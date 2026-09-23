// Flags sudden, persistent local changes inside a shot: objects that pop in or vanish, the commonest
// video-model slop. A region scores when it is steady for W frames, changes within 2*GAP+1 frames and
// is steady again. Feet and hands that move then hold score too, so this ranks candidates rather than
// judging them: pipe the output to popcrops.ts and look. Slow morphs escape it entirely; diff each
// shot's first and last frame for those. Each shot's first and last frame pair is also measured
// against its median pair, and one that jumps over 2x gets a crop row too.
//   bun popscan.ts <video> <cut frames, comma-separated> [top N per shot, default 6]
// W=<frames> (env) sets the steadiness window, default 6; 10 cuts noise on shots with walking.
import { probeVideo } from "./lib.ts";

const [video, cutsArg = "", topArg = "6"] = Bun.argv.slice(2);
if (!video) throw new Error("usage: bun popscan.ts <video> <cuts> [top]");
const W = Number(process.env.W ?? 6);
const TOP = Number(topArg);
if (!Number.isInteger(W) || W < 1 || !Number.isInteger(TOP) || TOP < 1) throw new Error("W and top must be positive integers");
const GAP = 1;
const [w, h] = [320, 180];
const P = w * h;
const B = 16; // block edge in scan pixels
const NOISE = 16; // grain variance floor
const T = 16; // step^2 / variance threshold per pixel
const EDGE = 2; // an edge pair changing this many times the shot's median pair gets a crop

const { width: srcW, height: srcH, frames } = probeVideo(video);
const proc = Bun.spawn(["ffmpeg", "-v", "error", "-i", video, "-vf", `scale=${w}:${h},format=gray`, "-f", "rawvideo", "-"], { stdout: "pipe", stderr: "pipe" });
const buf = new Uint8Array(await new Response(proc.stdout).arrayBuffer());
if ((await proc.exited) !== 0) throw new Error(`decoding ${video} failed: ${(await new Response(proc.stderr).text()).trim()}`);
const n = buf.length / P;
// A decoder failure must never read as "no events", so the scan refuses a short or ragged decode.
if (!Number.isInteger(n) || n !== frames) throw new Error(`decoded ${n} frames of ${video}, ffprobe counts ${frames}`);
// Takes the interior cut frames, or a build's whole cut list with its 0 and end frame.
const given = cutsArg.split(",").filter(Boolean).map(Number);
const cuts = [0, ...given.filter((c, i) => !(i === 0 && c === 0) && !(i === given.length - 1 && c === n)), n];
if (cuts.some((c, i) => !Number.isInteger(c) || (i > 0 && c <= cuts[i - 1]))) throw new Error(`cuts must be ascending frame numbers inside 1..${n - 1}`);

type Hit = { t: number; bx: number; by: number; frac: number; step: number };
const bw = w / B;
const bh = Math.floor(h / B);

function scanFrame(t: number, a: number, e: number, hits: Hit[]) {
  // Windows shrink to 3 frames next to a cut, where keyframe-driven pops cluster.
  const k0 = Math.min(W, t - GAP - a, e - 1 - GAP - t);
  const cnt = new Float64Array(bw * bh);
  const stp = new Float64Array(bw * bh);
  for (let y = 0; y < bh * B; y++) {
    for (let x = 0; x < w; x++) {
      const p = y * w + x;
      let s1 = 0, q1 = 0, s2 = 0, q2 = 0;
      for (let k = 1; k <= k0; k++) {
        const u = buf[(t - GAP - k) * P + p], v = buf[(t + GAP + k) * P + p];
        s1 += u; q1 += u * u; s2 += v; q2 += v * v;
      }
      const m1 = s1 / k0, m2 = s2 / k0;
      const d = m2 - m1;
      const score = (d * d) / (q1 / k0 - m1 * m1 + q2 / k0 - m2 * m2 + NOISE);
      if (score > T) {
        const b = Math.floor(y / B) * bw + Math.floor(x / B);
        cnt[b]++;
        stp[b] += Math.abs(d);
      }
    }
  }
  for (let b = 0; b < cnt.length; b++) {
    const frac = cnt[b] / (B * B);
    if (frac > 0.12) hits.push({ t, bx: b % bw, by: Math.floor(b / bw), frac, step: stp[b] / cnt[b] });
  }
}

// Change from frame t to t+1: the mean over the frame, and the block that changed most.
function pairChange(t: number) {
  const sums = new Float64Array(bw * bh);
  for (let y = 0; y < bh * B; y++) {
    for (let x = 0; x < w; x++) {
      const p = y * w + x;
      sums[Math.floor(y / B) * bw + Math.floor(x / B)] += Math.abs(buf[(t + 1) * P + p] - buf[t * P + p]);
    }
  }
  let top = 0;
  for (let b = 1; b < sums.length; b++) if (sums[b] > sums[top]) top = b;
  return { mean: sums.reduce((m, v) => m + v, 0) / (sums.length * B * B), bx: top % bw, by: Math.floor(top / bw) };
}

for (let s = 0; s < cuts.length - 1; s++) {
  const [a, e] = [cuts[s], cuts[s + 1]];
  const hits: Hit[] = [];
  for (let t = a + GAP + 3; t < e - GAP - 3; t++) scanFrame(t, a, e, hits);
  // The step scan needs steady frames on both sides, so it can't see a shot's edges; report the first
  // and last frame pairs against the shot's median pair instead (frame 0 is the start keyframe).
  const pairs = Array.from({ length: Math.max(0, e - a - 1) }, (_, k) => pairChange(a + k));
  const median = [...pairs.map((q) => q.mean)].sort((x, y) => x - y)[Math.floor(pairs.length / 2)] || 1e-9;
  const edges = pairs.length > 2 ? [{ t: a + 1, q: pairs[0] }, { t: e - 1, q: pairs.at(-1)! }] : [];
  // One event per block per run of consecutive frames, kept at its peak.
  const events: Hit[] = [];
  for (const hit of hits.sort((x, y) => x.by - y.by || x.bx - y.bx || x.t - y.t)) {
    const last = events.at(-1);
    if (last && last.bx === hit.bx && last.by === hit.by && hit.t - last.t <= 3) {
      if (hit.frac > last.frac) Object.assign(last, hit);
    } else events.push({ ...hit });
  }
  const top = events.sort((x, y) => y.frac * y.step - x.frac * x.step).slice(0, TOP);
  const ratios = edges.map((d) => d.q.mean / median);
  console.log(`shot ${s + 1} [${a}, ${e}): ${events.length} events · first and last pair ${ratios.map((r) => `${r.toFixed(1)}x`).join(" / ") || "—"} the median change`);
  const [sx, sy] = [srcW / w, srcH / h];
  edges.forEach((d, k) => {
    if (ratios[k] <= EDGE) return;
    const [x, y] = [Math.round(d.q.bx * B * sx), Math.round(d.q.by * B * sy)];
    console.log(`  frame ${d.t}  box x=${x} y=${y} (${Math.round(B * sx)}x${Math.round(B * sy)} px)  edge jump ${ratios[k].toFixed(1)}x`);
  });
  for (const ev of top) {
    const [x, y] = [Math.round(ev.bx * B * sx), Math.round(ev.by * B * sy)];
    console.log(`  frame ${ev.t}  box x=${x} y=${y} (${Math.round(B * sx)}x${Math.round(B * sy)} px)  ${(ev.frac * 100).toFixed(0)}% of block, step ${ev.step.toFixed(0)}`);
  }
}
