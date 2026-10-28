// start-orchy's release derivation, run as the bootstrap runs it (bun, stdout, exit code) against a gh shim that answers
// from tests/mocks/orchy/release/<fixture>/; a fixture listed first overrides the ones after it.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { branchMatches, readWorkflow } from "../skills/start-orchy/scripts/release-profile.ts";

const ROOT = join(import.meta.dir, "..");
const SCRIPT = join(ROOT, "skills/start-orchy/scripts/release-profile.ts");
const TEMPLATE = join(ROOT, "skills/my-stack/templates/release-skill.md");
const FIX = join(import.meta.dir, "mocks/orchy/release");
const T = mkdtempSync(join(tmpdir(), "orchy-release-profile-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));

let runs = 0;
function overlay(name: string, api: Record<string, unknown>, files: Record<string, string> = {}) {   // listed first, its keys win
  const dir = join(T, name);
  mkdirSync(dir);
  for (const [f, text] of Object.entries(files)) writeFileSync(join(dir, f), text);
  writeFileSync(join(dir, "api.json"), JSON.stringify(api));
  return dir;
}
async function derive(fixtures: string[], repo: string, args = ["--repo", repo]) {
  const log = join(T, `gh-${++runs}.log`);
  const p = Bun.spawn(["bun", SCRIPT, ...args], { cwd: T, stdout: "pipe", stderr: "pipe", env: { ...process.env,
    PATH: `${FIX}:${process.env.PATH}`, RP_GH_LOG: log, RP_FIXTURES: fixtures.map(f => f.startsWith("/") ? f : join(FIX, f)).join(":") } });
  const [out, err, code] = await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited]);
  // the live check's own shape program, so the two cannot disagree on what orchy.release/1 is
  const shape = Bun.spawnSync(["jq", "-e", "--arg", "repo", repo, "--arg", "rc", String(code), "-f", join(FIX, "schema.jq")], { stdin: Buffer.from(out) });
  expect(shape.exitCode, `${out}\n${err}`).toBe(0);
  // reads only: the shim refuses a write, so the log is checked for the call itself, not its outcome
  for (const call of readFileSync(log, "utf8").trim().split("\n"))
    expect(call).toMatch(/^(api (-H Accept: application\/vnd\.github\.raw )?repos\/\S+|repo view --json nameWithOwner --jq \.nameWithOwner)$/);
  return { code, err, p: JSON.parse(out), log: readFileSync(log, "utf8") };
}

test("promote: two branches, release-please on main, every fact read", async () => {
  const { code, err, p } = await derive(["promote"], "example/app");
  expect(code).toBe(0);
  expect(p.shape).toBe("promote");
  expect(p.trunk).toMatchObject({ name: "dev", methods: ["squash"], linear: true, signed: true, strict: false, reviews: 0 });
  expect(p.trunk.checks).toHaveLength(5);
  expect(p.branch).toMatchObject({ name: "main", methods: ["merge"], strict: true, checks: ["release-gate"], queue: false });
  expect(p.branch.deploys).toEqual([".github/workflows/release.yml", "app/edge-deploy"]);
  expect(p.sync).toEqual({ from: "main", to: "dev", method: "merge", head: "sync/main-into-dev", blocked_by: "linear history on dev" });
  expect(p.tool).toEqual({ kind: "release-please", branch: "main", bot: "app/release-bot", head: "release-please--branches--main" });
  expect(p.environments.filter((e: { reviewers: number }) => e.reviewers > 0)).toHaveLength(4);
  const release = p.workflows.find((w: { path: string }) => w.path === ".github/workflows/release.yml");
  expect(release).toMatchObject({ push_branches: ["main"], push_tags: [] });
  expect(release.dispatch).toHaveLength(5);
  expect(p.tags).toEqual([{ pattern: "v*", creation: "restricted" }]);
  expect([p.freeze, p.external.length, p.unknown]).toEqual([true, 3, []]);
  // the block under the heading wins over json blocks elsewhere and a heading inside a fence; its unknown key is ignored, aloud
  expect(err).toBe('release-profile: ignored the release skill\'s block key "rehearsal_branch"\n');
});

test("private on a free plan: rules and protection answer 403, and no environment or protected branch is unread, not none", async () => {
  const { code, p } = await derive(["private"], "example/private-app");
  expect(code).toBe(3);
  expect(p.unknown).toEqual(expect.arrayContaining(["rules main: HTTP 403", "protection main: HTTP 403",
    "environments: none listed while rules answer HTTP 403", "release branch: none protected while rules answer HTTP 403"]));
  expect([p.shape, p.environments, p.trunk.checks, p.trunk.methods]).toEqual(["unknown", null, null, null]);
});

test("dispatch: one branch whose publish runs only when dispatched; the repository comes from gh", async () => {
  const { code, p, log } = await derive(["dispatch"], "example/tool", []);
  expect(code).toBe(0);
  expect([p.shape, p.tool.kind, p.branch, p.sync]).toEqual(["single", "dispatch", null, null]);
  expect(p.trunk.deploys).toEqual([".github/workflows/docs.yml"]);
  expect(log).toStartWith("repo view");
});

test("tag: one branch whose publish runs on a tag push", async () => {
  const { code, p } = await derive(["tag"], "example/lib");
  expect(code).toBe(0);
  expect([p.shape, p.tool.kind, p.branch, p.trunk.reviews]).toEqual(["single", "tag", null, 1]);
});

test("workflows: one over 256 KiB is never fetched, a parse failure is named, the rest are read, and what they leave open is unknown", async () => {
  const { code, p, log } = await derive(["hostile", "dispatch"], "example/tool");
  expect(code).toBe(3);
  expect(p.unknown).toEqual([".github/workflows/broken.yml: YAML does not parse", ".github/workflows/huge.yml: over 256 KiB, skipped",
    "tool: an unread file could name it, and the release skill's block does not"]);
  expect(p.workflows.map((w: { path: string }) => w.path.split("/")[2])).toEqual(["bomb.yml", "ci.yml", "docs.yml", "publish.yml"]);
  // either unread file could be the release-please workflow, or another that deploys from main
  expect([p.tool.kind, p.shape, p.trunk.deploys]).toEqual(["unknown", "unknown", null]);
  expect(log).not.toContain("huge.yml");
});

test("a 9-level alias chain is read at its fixed paths in under 1 s", () => {
  const text = readFileSync(join(FIX, "hostile/bomb.yml"), "utf8");
  const walk = (v: unknown): number => v && typeof v === "object" ? Object.values(v).reduce((n: number, x) => n + walk(x), 1) : 1;
  expect(walk(Bun.YAML.parse(text))).toBeGreaterThan(1_000_000);   // what a reader that walked the document would visit
  const t0 = performance.now(), r = readWorkflow(".github/workflows/bomb.yml", text);
  expect(performance.now() - t0).toBeLessThan(1000);
  expect("wf" in r && r.wf.dispatch).toEqual(["k0", "k1", "k2", "k3"]);
});

test("push filters: GitHub's semantics, in linear time on a pattern built to backtrack", () => {
  const t0 = performance.now();
  expect(branchMatches(["a+".repeat(40) + "b"], "a".repeat(100))).toBe(false);
  expect(performance.now() - t0).toBeLessThan(1000);
  expect(branchMatches(["**/main"], "main")).toBe(true);
  expect(branchMatches(["release/*"], "release/a/b")).toBe(false);
  expect([branchMatches(["**", "!release/**"], "release/x"), branchMatches(["**", "!release/**", "release/keep"], "release/keep")]).toEqual([false, true]);
  expect(branchMatches(["v[12].[0-9]+.[0-9]+"], "v1.10.1")).toBe(true);
  expect(readWorkflow("w.yml", "on:\n  push:\n    branches: ['[main']\n")).toEqual({ error: "a branch filter with a quantifier after nothing or an open [" });
});

test("a forged status, a second page and a review count of another type are unread, never none", async () => {
  const fix = JSON.parse(readFileSync(join(FIX, "dispatch/api.json"), "utf8"));
  const dir = overlay("edge-a", {
    // the message is the server's text: one ending in "(HTTP 404)" must not turn this 403 into an absent directory
    "repos/example/tool/contents/.github/workflows": { $http: 403, message: "Denied (HTTP 404)" },
    "repos/example/tool/environments?per_page=100": { ...fix["repos/example/tool/environments?per_page=100"], total_count: 7 },
    "repos/example/tool/branches?protected=true&per_page=100": Array.from({ length: 100 }, (_, i) => ({ name: `b${i}`, protected: true })),
    "repos/example/tool/branches/main/protection": { required_status_checks: { strict: false, contexts: "ci" },
      required_pull_request_reviews: { required_approving_review_count: "two" } },
  });
  const { code, p } = await derive([dir, "dispatch"], "example/tool");
  expect(code).toBe(3);
  expect([p.workflows, p.environments, p.trunk.checks, p.trunk.reviews]).toEqual([null, null, null, null]);
  expect(p.unknown).toEqual(expect.arrayContaining(["workflows: HTTP 403", "environments: more than one page; the rest unread",
    "protected branches: more than one page; the rest unread", "checks main: a check list is not a list",
    "reviews main: a review count is not a whole number"]));
});

test("a fenced example, a lying size, an expression target and a last-push approval each read as GitHub means them", async () => {
  const fix = JSON.parse(readFileSync(join(FIX, "promote/api.json"), "utf8")), wf = "repos/example/app/contents/.github/workflows";
  const dir = overlay("edge-b", {
    "repos/example/app/rules/branches/dev?per_page=100": { $http: 403, message: "Upgrade to GitHub Pro" },
    "repos/example/app/rules/branches/main?per_page=100": fix["repos/example/app/rules/branches/main?per_page=100"].map(
      (r: { type: string; parameters?: object }) => r.type === "pull_request" ? { ...r, parameters: { ...r.parameters, require_last_push_approval: true } } : r),
    [wf]: [...fix[wf], { name: "huge2.yml", path: ".github/workflows/huge2.yml", size: 10, type: "file" }],
    [`${wf}/huge2.yml`]: { $file: "huge2.yml" }, [`${wf}/release.yml`]: { $file: "release.yml" },
    "repos/example/app/contents/.claude/skills/release/SKILL.md": { $file: "SKILL.md" },
  }, {
    "huge2.yml": `on: push\n${"#".repeat(300 * 1024)}\n`,
    "release.yml": readFileSync(join(FIX, "promote/release.yml"), "utf8").replace("target-branch: main", "target-branch: ${{ vars.RELEASE_TARGET }}"),
    "SKILL.md": '~~~markdown\n## Release profile\n\n```json\n{"schema": "release-profile/1", "sync": {"method": "merge", "head": "attacker"}}\n```\n~~~\n\n'
      + readFileSync(join(FIX, "promote/release-skill.md"), "utf8"),
  });
  const { code, p } = await derive([dir, "promote"], "example/app");
  expect(code).toBe(3);
  // the real block's head, and linear history blocks a merge back-sync though the trunk's methods went unread
  expect(p.sync).toMatchObject({ head: "sync/main-into-dev", blocked_by: "linear history on dev" });
  expect([p.trunk.methods, p.branch.reviews, p.tool.head]).toEqual([null, 1, null]);
  expect(p.unknown).toEqual(expect.arrayContaining([".github/workflows/huge2.yml: over 256 KiB, skipped",
    "tool.branch: release-please's target-branch resolves to no single branch"]));
});

test("a release block with a bidi character, or 21 external steps, is rejected whole", async () => {
  for (const [fixture, why] of [["block-bidi", "a string is empty, over 160 code points, or carries a control or bidi character"],
    ["block-external", "external holds 21 steps, at most 20"]]) {
    const { code, p } = await derive([fixture, "tag"], "example/lib");
    expect(code).toBe(3);
    expect(p.unknown).toEqual([`release skill block: ${why}`]);
    expect([p.skill.block, p.freeze, p.external]).toEqual([false, null, null]);
  }
});

test("my-stack's release skill template, served as a repository's release skill, parses with no unknown key", async () => {
  const dir = join(T, "template");
  mkdirSync(dir);
  writeFileSync(join(dir, "api.json"), JSON.stringify({ "repos/example/app/contents/.claude/skills/release/SKILL.md": { $file: TEMPLATE } }));
  const { code, err, p } = await derive([dir, "promote"], "example/app");
  expect([code, err]).toEqual([0, ""]);
  expect(p.skill).toEqual({ path: ".claude/skills/release/SKILL.md", block: true });
  expect(p.sync).toMatchObject({ method: "merge", head: "main" });
  expect([p.freeze, p.external]).toEqual([true, ["Publish the staged revision in each store's dashboard"]]);
});
