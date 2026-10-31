import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Budget, check, functions, isShell, type Measured, raised, run, shellSources, tighten } from "../checks/budget.ts";

const T = mkdtempSync(join(tmpdir(), "budget-test-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));
const record = (b: Partial<Budget> = {}): Budget => ({ files: {}, functions: {}, duplicates: {}, ...b });
const bash = (args: string[], stdin = "") => Bun.spawnSync(["bash", ...args], { stdin: Buffer.from(stdin) });

// Braces that are not syntax; b() sits in a heredoc and c() in an awk program, so bash defines a, d, e, f and g only.
const TRICKY = `a() {
  echo "}" '}' $'\\'}' "$(printf '%s' "}")" \`echo }\` # a } in a comment
  x=\${y%%) }}; echo \${#x} $# "\${x:-"}"}"; a[1<<2]=x
  cat <<EOF
}
b() {
EOF
  cat <<-'END' > /dev/null; cat <<< '}'; cat <<E"OF"
\t}
\tEND
}
EOF
  (( n = 1 << 2 ))
  echo $(( (n) << 1 )) }
  awk 'function c(x) { return x }'
}
d ( ) { :; }; e()
{
  [[ $x == {a,b} ]] && { echo; }
}
if true; then f() { :; }; fi
! g ( ) { :; }; while false; do :; done; a[i]=1; x=1 a[1<<$#]=2; declare -A m; m["]"]=3
`;

test("isShell: a .sh name or a sh-family shebang, nothing else", () => {
  for (const s of ["#!/usr/bin/env bash", "#!/bin/sh -e", "#!/usr/bin/env -S dash -e", "#!/usr/bin/env -S A=1 -u B bash", "#!/usr/bin/env -Sbash", "#!/usr/bin/env --split-string=bash"]) expect(isShell("bin/x", `${s}\n`)).toBe(true);
  for (const s of ["#!/usr/bin/env zsh", "#!/usr/bin/env bun", "#!/usr/bin/env node --x-sh", "echo\n#!/bin/sh"]) expect(isShell("bin/x", `${s}\n`)).toBe(false);
  expect(isShell("lib/x.sh", "")).toBe(true);
  expect(isShell("bin/x.md", "#!/bin/bash\n")).toBe(true);
});

test("functions: the definitions bash sees, past quotes, expansions, subscripts, heredocs, comments and arithmetic", () => {
  expect(bash(["-c", `${TRICKY}declare -F`]).stdout.toString()).toBe("declare -f a\ndeclare -f d\ndeclare -f e\ndeclare -f f\ndeclare -f g\n");
  expect(functions(TRICKY)).toEqual([
    { name: "a", line: 1, lines: 16 },
    { name: "d", line: 17, lines: 1 },
    { name: "e", line: 17, lines: 4 },
    { name: "f", line: 21, lines: 1 },
    { name: "g", line: 22, lines: 1 },
  ]);
  expect(functions('echo "$(( $(h() { :; }; h) ))"\n')).toEqual([{ name: "h", line: 1, lines: 1 }]);
  expect(functions("f() { echo file[; }\necho a[; g() {\n:\necho a[; }\n")).toEqual([{ name: "f", line: 1, lines: 1 }, { name: "g", line: 2, lines: 3 }]);
  expect(functions("echo a[<<E]=x\n}\nE]=x\nh() { :; }\n")).toEqual([{ name: "h", line: 4, lines: 1 }]);
});

test("functions: braces it cannot pair, or a body it cannot measure, throw instead of passing", () => {
  expect(() => functions("f() {\n  echo\n")).toThrow(/never closes/);
  expect(() => functions("echo; }\n")).toThrow(/closes nothing/);
  expect(() => functions("f() ( echo )\n")).toThrow(/no \{ \} body/);
  expect(() => functions("cat <<EOF\nf() {\n:\n}\n")).toThrow(/heredoc never reaches/);
  expect(() => functions('echo "x\nf() {\n:\n}\n')).toThrow(/never closes/);
});

test("no function measured in this repo is cut short: each span parses on its own", () => {
  const broken: string[] = [];
  for (const [path, text] of Object.entries(shellSources(join(import.meta.dir, "..")))) {
    const lines = text.split("\n");
    for (const f of functions(text))
      if (bash(["-n"], `${lines.slice(f.line - 1, f.line - 1 + f.lines).join("\n")}\n`).exitCode !== 0) broken.push(`${path}:${f.line} ${f.name}`);
  }
  expect(broken).toEqual([]);
});

test("check: growth past a record, or past the default without one, fails whatever the name; a rename gets the default", () => {
  const m: Measured = {
    files: { big: 900, fresh: 801, ok: 800, constructor: 801 },
    functions: { big: { grown: 121, kept: 120, renamed: 178, short: 80, ["__proto__"]: 81 } },
  };
  const { errors, stale } = check(m, record({ files: { big: 899 }, functions: { big: { grown: 120, kept: 120, original: 178 } } }));
  expect(errors).toEqual([
    "big: 900 lines, over its recorded budget of 899; split it",
    "fresh: 801 lines, over its default budget of 800; split it",
    "constructor: 801 lines, over its default budget of 800; split it",
    "big: grown(): 121 lines, over its recorded budget of 120; split it into smaller functions",
    "big: renamed(): 178 lines, over its default budget of 80; split it into smaller functions",
    "big: __proto__(): 81 lines, over its default budget of 80; split it into smaller functions",
  ]);
  expect(stale).toEqual(["big: original(): recorded at 178 lines, no longer here"]);
});

test("check: a name defined in a second file fails unless that file is recorded for it", () => {
  const m: Measured = { files: { a: 1, b: 1, c: 1 }, functions: { a: { die: 1 }, b: { die: 1 }, c: { die: 1, only: 1 } } };
  expect(check(m, record({ duplicates: { die: ["a", "b"] } })).errors).toEqual(["die(): defined in a, b, c; keep one definition in a library the others source"]);
  expect(check(m, record({ duplicates: { die: ["a", "b", "c"] } })).errors).toEqual([]);
});

test("tighten: a looser record is stale until lowered or dropped, and is never raised or added to", () => {
  const m: Measured = { files: { big: 850, small: 700, grew: 1200 }, functions: { big: { f: 60, g: 150, h: 200, dup: 1 }, small: { dup: 1 } } };
  const b = record({
    files: { big: 900, small: 900, gone: 900, grew: 1000 },
    functions: { big: { f: 100, g: 120 } },
    duplicates: { dup: ["big", "small", "gone"], solo: ["big", "small"] },
  });
  expect(check(m, b).stale).toHaveLength(6);
  const t = tighten(m, b);
  expect(t).toEqual({ files: { big: 850, grew: 1000 }, functions: { big: { g: 120 } }, duplicates: { dup: ["big", "small"] } });
  const after = check(m, t);
  expect(after.stale).toEqual([]);
  expect(after.errors.map((e) => e.slice(0, e.indexOf(" lines")))).toEqual(["grew: 1200", "big: g(): 150", "big: h(): 200"]);
});

test("raised: an entry the base record lacks or holds lower fails; lowering or dropping one does not", () => {
  const base = record({ files: { a: 900, b: 900 }, functions: { a: { f: 100 } }, duplicates: { die: ["a", "b"] } });
  expect(raised(base, record({ files: { a: 850 }, duplicates: { die: ["a", "b"] } }))).toEqual([]);
  expect(raised(base, record({ files: { a: 901, c: 900 }, functions: { a: { f: 100, g: 90 } }, duplicates: { die: ["a", "b", "c"] } }))).toEqual([
    "a: record raised from 900 to 901 lines",
    "c: newly recorded at 900 lines",
    "a: g(): newly recorded at 90 lines",
    "die(): newly recorded in c",
  ]);
});

test("run: tracked and untracked shell files, no symlink or ignored one; --write banks a shrink; --base and a bad record fail", () => {
  const dir = join(T, "repo");
  expect(Bun.spawnSync(["git", "init", "-q", dir]).exitCode).toBe(0);
  writeFileSync(join(dir, "a.sh"), "true\n".repeat(900));
  writeFileSync(join(dir, "tool"), "#!/usr/bin/env bash\nf() { :; }\n");
  writeFileSync(join(dir, "notes.md"), "# notes\n");
  writeFileSync(join(dir, "ignored.sh"), "true\n".repeat(900));
  writeFileSync(join(dir, ".gitignore"), "ignored.sh\n");
  symlinkSync("a.sh", join(dir, "link.sh"));
  expect(Bun.spawnSync(["git", "-C", dir, "add", "a.sh"]).exitCode).toBe(0);
  const rec = join(dir, "budget.json");
  writeFileSync(rec, JSON.stringify(record({ files: { "a.sh": 950 } })));
  expect(run(dir, rec, "files").out).toEqual(["a.sh", "tool"]);
  const before = run(dir, rec, "check");
  expect(before.code).toBe(1);
  expect(before.out.at(-1)).toContain("bun checks/budget.ts --write");
  expect(run(dir, rec, "write")).toEqual({ code: 0, out: [] });
  expect(JSON.parse(readFileSync(rec, "utf8")).files).toEqual({ "a.sh": 900 });
  const git = ["git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"];
  expect(Bun.spawnSync([...git, "add", "budget.json"]).exitCode).toBe(0);
  expect(Bun.spawnSync([...git, "commit", "-qm", "base"]).exitCode).toBe(0);
  writeFileSync(join(dir, "a.sh"), "true\n".repeat(960));
  writeFileSync(rec, JSON.stringify(record({ files: { "a.sh": 960 } })));
  expect(run(dir, rec, "check").code).toBe(0);
  expect(run(dir, rec, "check", "HEAD").out[0]).toBe("a.sh: record raised from 900 to 960 lines");
  expect(() => run(dir, rec, "check", "nope")).toThrow(/no such commit/);
  writeFileSync(rec, JSON.stringify(record({ files: { "a.sh": "disabled" as unknown as number } })));
  expect(() => run(dir, rec, "check")).toThrow(/whole number/);
});
