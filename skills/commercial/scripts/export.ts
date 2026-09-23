// Publishes a spot's deliverables into <exports>/<spot>/ without overwriting anything. The whole plan
// is checked before the folder is touched; the new set is staged and verified beside it, and only then
// does the set already there move into v<N>/ (N from its VERSION file) and the new one take its place.
//   bun export.ts <exports dir> <spot> <version> <src>[=<dest>] ...
// <dest> is a path inside the export (e.g. work/alt-b-16x9.mp4=alternates/spot-b-16x9.mp4); it
// defaults to the source's file name. Dotfiles in the folder are ignored.
import { constants, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, normalize, sep } from "node:path";
import { withFileLock } from "./lib.ts";

const [exportsDir, spot, version, ...files] = Bun.argv.slice(2);
if (!exportsDir || !spot || !version || !files.length) throw new Error("usage: bun export.ts <exports dir> <spot> <version> <src>[=<dest>] ...");
if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(spot) || !/^[1-9]\d*$/.test(version)) throw new Error("spot must be a plain name and version a positive integer");
const target = join(exportsDir, spot);
const next = Number(version);

const plan = files.map((f) => {
  const parts = f.split("=");
  if (parts.length > 2) throw new Error(`"${f}" has more than one "="`);
  const [src, dest = basename(src)] = parts;
  const rel = normalize(dest);
  const reserved = ["VERSION", "SHASUMS256.txt"].includes(rel) || /^v\d+(\/|$)/.test(rel) || rel.split(sep).some((s) => s.startsWith("."));
  if (isAbsolute(rel) || rel === ".." || rel.startsWith(`..${sep}`) || reserved) throw new Error(`destination ${dest} must be a plain path inside the export`);
  if (!existsSync(src) || !statSync(src).isFile()) throw new Error(`${src} is not a file`);
  return { src, rel };
});
const dupe = plan.find((p, i) => plan.findIndex((q) => q.rel === p.rel) !== i);
if (dupe) throw new Error(`two files go to ${dupe.rel}`);

const sha = async (f: string) => new Bun.CryptoHasher("sha256").update(await Bun.file(f).arrayBuffer()).digest("hex");
mkdirSync(target, { recursive: true });

// The lock lives beside the spot folders, so it never travels with a fetched export.
await withFileLock(join(exportsDir, ".export.lock"), async () => {
  const names = readdirSync(target);
  const leftover = names.find((f) => f.startsWith(".staging-"));
  if (leftover) throw new Error(`${join(target, leftover)} is left from a publish that died midway: compare it with the folder, finish or undo the moves by hand, then delete it`);
  const current = names.filter((f) => !f.startsWith(".") && !/^v\d+$/.test(f));
  const archived = names.filter((f) => /^v\d+$/.test(f)).map((f) => Number(f.slice(1)));
  let prev: number | undefined;
  if (current.length) {
    const v = existsSync(join(target, "VERSION")) ? readFileSync(join(target, "VERSION"), "utf8").trim() : "";
    if (!/^[1-9]\d*$/.test(v)) throw new Error(`${target} has files but no VERSION: move them into v<N>/ by hand first`);
    prev = Number(v);
    if (existsSync(join(target, `v${prev}`))) throw new Error(`${target} publishes v${prev}, and v${prev}/ already exists`);
  }
  const newest = Math.max(prev ?? 0, ...archived);
  if (next <= newest) throw new Error(`v${next} is not newer than v${newest}: pick v${newest + 1}`);

  // Stage and verify the whole set before anything published moves.
  const stage = mkdtempSync(join(target, ".staging-"));
  try {
    const sums: string[] = [];
    for (const { src, rel } of plan) {
      mkdirSync(dirname(join(stage, rel)), { recursive: true });
      copyFileSync(src, join(stage, rel), constants.COPYFILE_EXCL);
      const [a, b] = await Promise.all([sha(src), sha(join(stage, rel))]);
      if (a !== b) throw new Error(`copy of ${src} does not match its source`);
      sums.push(`${b}  ${rel}`);
    }
    writeFileSync(join(stage, "SHASUMS256.txt"), `${sums.sort((x, y) => x.slice(66).localeCompare(y.slice(66))).join("\n")}\n`);
    writeFileSync(join(stage, "VERSION"), `${next}\n`);
  } catch (e) {
    rmSync(stage, { recursive: true });
    throw e;
  }

  // Promote: a few renames on one filesystem. The staging folder goes last, so a crash here leaves it
  // behind as the marker the next run refuses on.
  if (prev !== undefined) {
    mkdirSync(join(target, `v${prev}`));
    for (const f of current) renameSync(join(target, f), join(target, `v${prev}`, f));
  }
  for (const f of readdirSync(stage)) renameSync(join(stage, f), join(target, f));
  rmSync(stage, { recursive: true });
});
console.log(`published v${next}: ${plan.length} files in ${target} (verify: cd ${target} && sha256sum -c SHASUMS256.txt)`);
