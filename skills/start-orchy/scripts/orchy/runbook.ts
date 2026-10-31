// A runbook: the owner's steps, one per line, '- [ ] <step>' or '- [x] <step>', ending ' (proof: run <run-id>)' or
// ' (proof: release <tag>)' or not. Prints the steps as JSON [[done, text, proof kind, proof arg], ...].
// Usage: ts_run runbook <file> [--new]   (--new: every step starts unticked; exit 1 with the refusal on stderr)
import { readFileSync } from "node:fs";
import { args } from "./args.ts";
import { badChar, utf8 } from "./text.ts";

export type Step = [boolean, string, string, string];

// dotAll, as Python's . matches all but \n: a \r or a separator stays inside the line for the character check to name
const STEP = /^- \[( |x)\] (.+?)(?: \(proof: (run|release) ([^)]*)\))?$/su;
// str.isspace(): a step of these alone is blank
const BLANK = /^[\t\n\v\f\r\x1c-\x1f \x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]*$/u;

export function parseRunbook(raw: string, fresh: boolean): Step[] | string {
  const steps: Step[] = [];
  const lines = raw.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i], n = i + 1;
    if (!line) continue;
    const m = STEP.exec(line);
    if (!m) return `refused: line ${n} is not '- [ ] <step>', optionally ending ' (proof: run <run-id>)' or ' (proof: release <tag>)'`;
    const done = m[1] === "x", text = m[2], kind = m[3] ?? "", arg = m[4] ?? "";
    if (badChar(line)) return `refused: line ${n} carries a control, line separator or bidi character`;
    if (fresh && done) return `refused: line ${n} is ticked; a step starts unticked`;
    if (BLANK.test(text) || [...text].length > 160) return `refused: line ${n}: a step is 1 to 160 characters`;
    if (text.toLowerCase().includes("proof:")) return `refused: line ${n}: a proof is ' (proof: run <run-id>)' or ' (proof: release <tag>)', at the end`;
    if (kind === "run" && !/^[1-9][0-9]{0,19}$/.test(arg)) return `refused: line ${n}: a run proof names a run id`;
    if (kind === "release" && !(/^[A-Za-z0-9._/-]{1,100}$/.test(arg) && !arg.includes("..") && !"-/".includes(arg[0])))
      return `refused: line ${n}: a release proof names a tag`;
    steps.push([done, text, kind, arg]);
  }
  if (steps.length < 1 || steps.length > 20) return `refused: a runbook holds 1 to 20 steps, not ${steps.length}`;
  return steps;
}

// strerror(3)'s words for what a read can fail with, as Python's OSError carries them
const STRERROR: Record<string, string> = {
  ENOENT: "No such file or directory", EACCES: "Permission denied", EISDIR: "Is a directory", ENOTDIR: "Not a directory",
  ELOOP: "Too many levels of symbolic links", ENAMETOOLONG: "File name too long", EIO: "Input/output error",
  ENXIO: "No such device or address", EMFILE: "Too many open files", ENFILE: "Too many open files in system",
  ENOMEM: "Cannot allocate memory", EPERM: "Operation not permitted", EINVAL: "Invalid argument",
};

if (import.meta.main) {
  const [path, ...rest] = await args();
  let r: Step[] | string;
  try {
    const raw = utf8(readFileSync(path.length ? path : ""));   // an empty Buffer is a type error, not ENOENT
    r = raw === null ? "refused: the runbook is not UTF-8" : parseRunbook(raw, rest.length === 1 && rest[0].toString() === "--new");
  } catch (e) {
    const code = (e as { code?: string }).code ?? "";
    r = `refused: cannot read the runbook (${STRERROR[code] ?? code})`;
  }
  if (typeof r === "string") { process.stderr.write(`${r}\n`); process.exitCode = 1; }
  else process.stdout.write(`${JSON.stringify(r)}\n`);
}
