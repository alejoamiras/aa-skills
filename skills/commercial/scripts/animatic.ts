// A timed animatic: each keyframe held for its shot's length and labelled with its shot number, with
// scratch audio laid on the timeline. Watch it muted, then with sound, before any shot is paid for:
// does the turn read in 2 s, does the timing work, does the action sit where the crops need it?
//   bun animatic.ts <out.mp4> <image>@<seconds> ... [--audio <file>@<start seconds> ...]
import { drawtextFont } from "./lib.ts";

const FPS = 24;
const [out, ...rest] = Bun.argv.slice(2);
const cut = rest.indexOf("--audio");
const [shotArgs, audioArgs] = cut < 0 ? [rest, []] : [rest.slice(0, cut), rest.slice(cut + 1)];
const parse = (a: string) => {
  const at = a.lastIndexOf("@");
  const [file, n] = [a.slice(0, at), Number(a.slice(at + 1))];
  if (at < 1 || !Number.isFinite(n) || n < 0) throw new Error(`"${a}" is not <file>@<seconds>`);
  return { file, n };
};
const shots = shotArgs.map(parse);
const audio = audioArgs.map(parse);
if (!out || !shots.length) throw new Error("usage: bun animatic.ts <out.mp4> <image>@<seconds> ... [--audio <file>@<start> ...]");

const frames = shots.map((s) => Math.round(s.n * FPS));
if (frames.some((f) => f < 1)) throw new Error("every shot needs at least one frame");
const dur = frames.reduce((a, b) => a + b, 0) / FPS;
const font = drawtextFont();
const inputs: string[] = [];
const chains: string[] = [];
shots.forEach((s, i) => {
  inputs.push("-loop", "1", "-framerate", String(FPS), "-t", String(frames[i] / FPS + 1), "-i", s.file);
  chains.push(
    `[${i}:v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=${FPS},trim=end_frame=${frames[i]},setpts=PTS-STARTPTS,` +
      `drawtext=${font}:text='S${i + 1}  ${s.n}s':x=24:y=24:fontsize=36:fontcolor=white:box=1:boxcolor=black@0.5,format=yuv420p[v${i}]`,
  );
});
chains.push(`${shots.map((_, i) => `[v${i}]`).join("")}concat=n=${shots.length}:v=1:a=0[v]`);
audio.forEach((a, j) => {
  inputs.push("-i", a.file);
  chains.push(`[${shots.length + j}:a]aresample=48000,aformat=channel_layouts=stereo,adelay=${Math.round(a.n * 1000)}:all=1[a${j}]`);
});
if (audio.length) chains.push(`${audio.map((_, j) => `[a${j}]`).join("")}amix=inputs=${audio.length}:normalize=0,apad,atrim=0:${dur}[a]`);

const maps = audio.length ? ["-map", "[v]", "-map", "[a]", "-c:a", "aac", "-b:a", "160k"] : ["-map", "[v]"];
await Bun.$`ffmpeg -hide_banner -v error -y ${inputs} -filter_complex ${chains.join(";")} ${maps} -c:v libx264 -crf 20 -pix_fmt yuv420p -t ${dur} -movflags +faststart ${out}`;
console.log(`${out}: ${shots.length} shots, ${dur.toFixed(2)} s`);
