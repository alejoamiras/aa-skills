// A cut, unpacked for a frame-level review: every frame as a 960 px JPEG named by frame number, and
// one contact sheet per second with frame numbers burned in. Reviewers find defects on the sheets,
// then open the single frames; they need no ffmpeg of their own.
//   bun reviewpack.ts <video> <out dir>
// DRAWTEXT_FONT=<font file> for the frame numbers; without it ffmpeg's fontconfig default is used.
import { mkdirSync } from "node:fs";
import { drawtextFont, probeVideo } from "./lib.ts";

const [video, out] = Bun.argv.slice(2);
if (!video || !out) throw new Error("usage: bun reviewpack.ts <video> <out dir>");
const { fps, frames } = probeVideo(video);
const font = drawtextFont();
mkdirSync(`${out}/frames`, { recursive: true });
mkdirSync(`${out}/sheets`, { recursive: true });

// A sheet holds exactly one second, so its grid must divide the frame rate: 24 → 6x4, 25 → 5x5, 30 → 6x5.
const perSheet = Math.round(fps);
const cols = [6, 5, 8, 4, 10, 3].find((c) => perSheet % c === 0) ?? perSheet;
const label = `drawtext=${font}:text='%{n}':x=4:y=4:fontsize=18:fontcolor=yellow:box=1:boxcolor=black@0.6`;
await Promise.all([
  Bun.$`ffmpeg -hide_banner -v error -y -i ${video} -vf scale=960:-2 -q:v 3 -start_number 0 ${`${out}/frames/f%03d.jpg`}`,
  Bun.$`ffmpeg -hide_banner -v error -y -i ${video} -vf ${`scale=320:-2,${label},tile=${cols}x${perSheet / cols}`} -start_number 0 ${`${out}/sheets/sheet-%02d.png`}`,
]);
console.log(`${out}/frames: f000.jpg to f${String(frames - 1).padStart(3, "0")}.jpg`);
console.log(`${out}/sheets: sheet k holds frames ${perSheet}k to ${perSheet}k+${perSheet - 1}`);
