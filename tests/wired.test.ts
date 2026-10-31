import { afterAll, expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const T = mkdtempSync(join(tmpdir(), "wired-test-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));
let repos = 0;

// checks/wired.sh run in a throwaway repo holding only the given workflows and (empty) test files.
function wired(workflows: Record<string, string>, files: string[]) {
  const dir = join(T, `repo-${++repos}`);
  for (const f of ["checks/wired.sh", ...files]) mkdirSync(dirname(join(dir, f)), { recursive: true });
  mkdirSync(join(dir, ".github/workflows"), { recursive: true });
  copyFileSync(join(import.meta.dir, "../checks/wired.sh"), join(dir, "checks/wired.sh"));
  for (const [name, text] of Object.entries(workflows)) writeFileSync(join(dir, ".github/workflows", name), text);
  for (const f of files) writeFileSync(join(dir, f), "");
  expect(Bun.spawnSync(["git", "init", "-q", dir]).exitCode).toBe(0);
  const r = Bun.spawnSync(["bash", join(dir, "checks/wired.sh")]);
  return { code: r.exitCode, err: r.stderr.toString() };
}

const gated = (filters: string, run: string) => `jobs:
  changes:
    steps:
      - uses: dorny/paths-filter
        with:
          filters: |
${filters}
  smoke:
    needs: changes
    if: needs.changes.outputs.relevant == 'true'
    steps:
      - run: ${run}
`;
const list = (name: string, ...paths: string[]) => [`            ${name}:`, ...paths.map((p) => `              - '${p}'`)].join("\n");

test("wired: only the relevant list covers a test, and a workflow without one fails", () => {
  const smoke = ["skills/x/smoke.sh"];
  expect(wired({ "x.yml": gated(list("relevant", "skills/x/**"), "bash skills/x/smoke.sh") }, smoke).code).toBe(0);
  const pooled = wired({ "x.yml": gated(`${list("relevant", "tests/**")}\n${list("unrelated", "skills/x/smoke.sh")}`, "bash skills/x/smoke.sh") }, smoke);
  expect(pooled).toEqual({ code: 1, err: ".github/workflows/x.yml runs skills/x/smoke.sh, but its path filter skips changes to it\n" });
  const unfiltered = wired({ "x.yml": gated(list("other", "**"), "bash skills/x/smoke.sh") }, smoke);
  expect(unfiltered).toEqual({ code: 1, err: ".github/workflows/x.yml runs skills/x/smoke.sh but has no paths-filter list named relevant\n" });
});

test("wired: every Bun test file name form needs a workflow", () => {
  const files = ["tests/a.spec.ts", "tests/b_test.js", "tests/c_spec.jsx", "tests/d.test.tsx"];
  const r = wired({ "t.yml": gated(list("relevant", "tests/**"), "bun test tests/d.test.tsx") }, files);
  expect(r.code).toBe(1);
  expect(r.err.split("\n").filter(Boolean).map((l) => l.split(":")[0])).toEqual(["tests/a.spec.ts", "tests/b_test.js", "tests/c_spec.jsx"]);
});
