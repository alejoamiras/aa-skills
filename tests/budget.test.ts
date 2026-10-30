// checks/budget.ts: the lexer it measures functions with, the ratchet rules, and the CLI over a real git tree.
import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type Budget, check, functions, isShell, type Measured, run, shellSources, tighten } from "../checks/budget.ts";

const T = mkdtempSync(join(tmpdir(), "budget-test-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));
const record = (b: Partial<Budget> = {}): Budget => ({ files: {}, functions: {}, duplicates: {}, ...b });
const bash = (args: string[], stdin = "") => Bun.spawnSync(["bash", ...args], { stdin: Buffer.from(stdin) });

// Braces in every place that is not syntax, a function inside a heredoc and one inside an awk program.
const TRICKY = `a() {
  echo "}" '}' $'\\'}' "$(printf '%s' "}")" \`echo }\` # a } in a comment
  x=\${y%%) }}; echo \${#x} $# "\${x:-"}"}"
  cat <<EOF
}
b() {
EOF
  cat <<-'END' > /dev/null; cat <<< '}'
\t}
\tEND
  (( n = 1 << 2 ))
  echo $(( (n) << 1 )) }
  awk 'function c(x) { return x }'
}
d() { :; }; e()
{
  [[ $x == {a,b} ]] && { echo; }
}
`;

test("isShell: a .sh name or a sh-family shebang, nothing else", () => {
  for (const s of ["#!/usr/bin/env bash\n", "#!/bin/sh -e\n", "#!/usr/bin/env -S dash -e\n"]) expect(isShell("bin/x", s)).toBe(true);
  for (const s of ["#!/usr/bin/env zsh\n", "#!/usr/bin/env bun\n", "#!/usr/bin/env node --x-sh\n", "echo\n#!/bin/sh\n"]) expect(isShell("bin/x", s)).toBe(false);
  expect(isShell("lib/x.sh", "")).toBe(true);
});

test("functions: the definitions bash sees, measured past quotes, expansions, heredocs, comments and arithmetic", () => {
  expect(bash(["-c", `${TRICKY}declare -F`]).stdout.toString()).toBe("declare -f a\ndeclare -f d\ndeclare -f e\n");
  expect(functions(TRICKY)).toEqual([{ name: "a", line: 1, lines: 14 }, { name: "d", line: 15, lines: 1 }, { name: "e", line: 15, lines: 4 }]);
});

test("functions: braces it cannot pair, or a body it cannot measure, throw instead of passing", () => {
  expect(() => functions("f() {\n  echo\n")).toThrow(/never closes/);
  expect(() => functions("echo; }\n")).toThrow(/closes nothing/);
  expect(() => functions("f() ( echo )\n")).toThrow(/no \{ \} body/);
});

test("every function measured in this repo is one complete bash definition", () => {
  const broken: string[] = [];
  for (const [path, text] of Object.entries(shellSources(join(import.meta.dir, "..")))) {
    const lines = text.split("\n");
    for (const f of functions(text))
      if (bash(["-n"], `${lines.slice(f.line - 1, f.line - 1 + f.lines).join("\n")}\n`).exitCode !== 0) broken.push(`${path}:${f.line} ${f.name}`);
  }
  expect(broken).toEqual([]);
});

test("check: growth past a record, or past the default without one, fails; a renamed function gets the default", () => {
  const m: Measured = { files: { big: 900, fresh: 801, ok: 800 }, functions: { big: { grown: 121, kept: 120, renamed: 178, short: 80 } } };
  const { errors, stale } = check(m, record({ files: { big: 899 }, functions: { big: { grown: 120, kept: 120, original: 178 } } }));
  expect(errors).toEqual([
    "big: 900 lines, over its recorded budget of 899; split it",
    "fresh: 801 lines, over its default budget of 800; split it",
    "big: grown(): 121 lines, over its recorded budget of 120; split it into smaller functions",
    "big: renamed(): 178 lines, over its default budget of 80; split it into smaller functions",
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

test("run: measures tracked and untracked shell files but no symlink or ignored file, and --write banks a shrink", () => {
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
});
