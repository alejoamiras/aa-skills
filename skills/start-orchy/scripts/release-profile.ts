// Derives orchy.release/1, the facts a repository's releases rest on, from GitHub's answers, the workflow YAML and the
// release skill's block. GETs only, through `gh api`, each under a 30 s timeout; it writes nothing and needs no orchy home.
// Usage: bun release-profile.ts [--repo owner/name]   (default: the repository gh resolves from the working directory)
// stdout: the profile; stderr: the block keys it ignored. Exit 0 complete; 3 partial, each field it could not read null and
// named in .unknown (a 403 is unread, never none); 2 failed.
const METHODS = ["merge", "squash", "rebase"];
const PUBLISH = ["id-token", "npm publish", "gh release"];   // the signals act takes as publishing, besides an environment
const SKILL = ".claude/skills/release/SKILL.md";
const FILE_CAP = 256 * 1024, JSON_CAP = 8 * 1024 * 1024, MAX_JOBS = 100, MAX_STEPS = 200, MAX_LIST = 100, MAX_EXTERNAL = 20;
const RUN_BUDGET = 4 * FILE_CAP;   // run text scanned per workflow, since an alias can repeat one long scalar at every step

type Obj = Record<string, unknown>;
type Got = { status: number; text: string };   // the HTTP code (200 on success); 0 gh failed with none, -1 over the cap, -2 timed out
type Workflow = { path: string; dispatch: string[] | null; push_branches: string[]; push_tags: string[];
  environments: string[]; signals: string[] };
type Branch = { name: string; methods: string[] | null; linear: boolean | null; signed: boolean | null; strict: boolean | null;
  checks: string[] | null; reviews: number | null; queue: boolean | null; deploys: string[] | null };
type Block = { shape?: string; release_branch?: string; tool?: string; freeze?: boolean; external?: string[];
  sync?: { method?: string; opened_by?: string; head?: string } };

const isObj = (v: unknown): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const own = (o: unknown, k: string): unknown => isObj(o) && Object.hasOwn(o, k) ? o[k] : undefined;
const list = (v: unknown): unknown[] => Array.isArray(v) ? v : [];
const BAD = /[\u{0}-\u{1f}\u{7f}-\u{9f}\u{61c}\u{200e}\u{200f}\u{2028}\u{2029}\u{202a}-\u{202e}\u{2066}-\u{2069}]/u;
// the length test comes first: an aliased scalar can be long and repeated thousands of times
const textOk = (s: unknown): s is string => typeof s === "string" && s.length > 0 && s.length <= 320 && s.isWellFormed()
  && !BAD.test(s) && [...s].length <= 160;
const refOk = (s: unknown): s is string => typeof s === "string" && s.length <= 100 && /^[A-Za-z0-9._/-]+$/.test(s)
  && !s.includes("..") && !/^[-/]/.test(s);
const uniq = (xs: string[]) => [...new Set(xs)].sort();

let active = 0; const waiting: (() => void)[] = [];
async function gh(args: string[], cap: number): Promise<Got> {
  while (active >= 4) await new Promise<void>(r => waiting.push(r));
  active++;
  try {
    const p = Bun.spawn(["gh", ...args], { stdin: "ignore", stdout: "pipe", stderr: "pipe", timeout: 30_000, killSignal: "SIGKILL" });
    const err = new Response(p.stderr).text(), chunks: Uint8Array[] = [];
    let size = 0;
    for await (const c of p.stdout) { size += c.length; if (size > cap) { p.kill("SIGKILL"); break; } chunks.push(c); }
    const [code, e] = [await p.exited, await err];
    if (size > cap) return { status: -1, text: "" };
    if (p.signalCode === "SIGKILL") return { status: -2, text: "" };
    const text = Buffer.concat(chunks).toString("utf8");
    // gh prints an error's body on stdout and "gh: <message> (HTTP <code>)" on stderr; the code ends the last line, since the
    // message before it is the server's text
    const st = /\(HTTP (\d{3})\)$/.exec(e.trimEnd().split("\n").at(-1) ?? "");
    return { status: code === 0 ? 200 : Number(st?.[1] ?? 0), text };
  } finally { active--; waiting.shift()?.(); }
}
const get = (path: string) => gh(["api", path], JSON_CAP);
const raw = (path: string) => gh(["api", "-H", "Accept: application/vnd.github.raw", path], FILE_CAP);
const body = (g: Got): unknown => { try { return JSON.parse(g.text); } catch { return undefined; } };
const json = (g: Got): unknown => g.status === 200 ? body(g) : undefined;
const why = (g: Got) => g.status > 0 ? `HTTP ${g.status}` : ["gh failed with no HTTP status", "answer over its size cap", "no answer in 30 s"][-g.status];

// GitHub's filter patterns: * stays within a path segment, ** crosses them (and **/ may match no segment), ? and + quantify
// the character or set before, [] is a set with a-z ranges. null: a pattern this reader cannot place
type Tok = { t: "c" | "set" | "*" | "**"; v: string; q: "" | "?" | "+" };
function globToks(p: string): Tok[] | null {
  const out: Tok[] = [];
  for (let i = 0; i < p.length; i++) {
    const c = p[i], last = out.at(-1);
    if (c === "?" || c === "+") { if (!last || last.q || last.t === "*" || last.t === "**") return null; last.q = c; }
    else if (c === "*") { const two = p[i + 1] === "*"; out.push({ t: two ? "**" : "*", v: "", q: "" }); if (two) i++; }
    else if (c === "[") { const j = p.indexOf("]", i + 1); if (j < 0) return null; out.push({ t: "set", v: p.slice(i + 1, j), q: "" }); i = j; }
    else out.push({ t: "c", v: c, q: "" });
  }
  return out;
}
const inSet = (set: string, ch: string) => {
  for (let k = 0; k < set.length; k++) {
    if (set[k + 1] === "-" && k + 2 < set.length) { if (set[k] <= ch && ch <= set[k + 2]) return true; k += 2; }
    else if (set[k] === ch) return true;
  }
  return false;
};
/** Whether a branch matches GitHub's push filter list: a later pattern overrides an earlier one, so a ! after a match excludes
 *  the branch and a match after a ! includes it again. Memoized over (token, offset), never a regex: the patterns are a
 *  workflow's, and a backtracking engine takes seconds on one like a+a+…a+b. */
export function branchMatches(patterns: string[], b: string): boolean {
  return patterns.reduce((hit, p) => {
    const neg = p.startsWith("!"), toks = globToks(neg ? p.slice(1) : p);
    if (!toks) return hit;
    const n = toks.length, m = b.length, memo = new Uint8Array((n + 1) * (m + 1));   // 0 unknown, 1 yes, 2 no
    const one = (k: Tok, j: number) => j < m && (k.t === "c" ? b[j] === k.v : inSet(k.v, b[j]));
    const go = (i: number, j: number): boolean => {
      if (i === n) return j === m;
      const key = i * (m + 1) + j;
      if (memo[key]) return memo[key] === 1;
      const k = toks[i], nx = toks[i + 1];
      const r = k.t === "**" ? go(i + 1, j) || (j < m && go(i, j + 1)) || (nx?.t === "c" && nx.v === "/" && !nx.q && (j === 0 || b[j - 1] === "/") && go(i + 2, j))
        : k.t === "*" ? go(i + 1, j) || (j < m && b[j] !== "/" && go(i, j + 1))
        : k.q === "?" ? go(i + 1, j) || (one(k, j) && go(i + 1, j + 1))
        : k.q === "+" ? one(k, j) && (go(i + 1, j + 1) || go(i, j + 1))
        : one(k, j) && go(i + 1, j + 1);
      memo[key] = r ? 1 : 2;
      return r;
    };
    return go(0, 0) ? !neg : hit;
  }, false);
}
const pushesTo = (w: Workflow, b: string) => branchMatches(w.push_branches, b);
const publishes = (w: Workflow) => w.environments.length > 0 || w.signals.some(s => PUBLISH.includes(s));

type Read = { wf: Workflow; tagged: boolean; rp: (string | null)[]; notes: string[] };
/** Reads one workflow at fixed paths with capped counts. Bun.YAML shares aliased nodes, so walking or stringifying a parsed
 *  document can visit millions of nodes; nothing here does either. `tagged`: its push trigger names tags. `rp`: each
 *  release-please step's target branch, "" when it names none (the trunk), null for an expression. */
export function readWorkflow(path: string, text: string): Read | { error: string } {
  let doc: unknown;
  try { doc = Bun.YAML.parse(text); } catch { return { error: "YAML does not parse" }; }
  if (!isObj(doc)) return { error: "YAML is not one mapping" };
  const notes: string[] = [], signals = new Set<string>(), envs: string[] = [], rp: (string | null)[] = [];
  const capped = <T>(xs: T[], max: number, what: string) => { if (xs.length > max) notes.push(`over ${max} ${what}; the rest unread`); return xs.slice(0, max); };
  const pats = (v: unknown, what: string) => {
    const xs = typeof v === "string" ? [v] : Array.isArray(v) ? capped(v, MAX_LIST, what) : null;
    return xs?.every(textOk) ? xs as string[] : null;
  };
  const on = own(doc, "on");
  const events = typeof on === "string" ? [on] : Array.isArray(on) ? capped(on, MAX_LIST, "events") : isObj(on) ? capped(Object.keys(on), MAX_LIST, "events") : [];
  let push_branches: string[] = [], push_tags: string[] = [], dispatch: string[] | null = null, tagged = false;
  if (events.includes("push")) {
    const push = own(on, "push");
    const b = own(push, "branches"), bi = own(push, "branches-ignore"), t = own(push, "tags"), ti = own(push, "tags-ignore");
    const hasB = b !== undefined || bi !== undefined;
    tagged = t !== undefined || ti !== undefined;
    // naming only branches leaves tag pushes out, and the reverse; naming neither runs on both
    const side = (inc: unknown, exc: unknown, named: boolean, other: boolean, what: string) => {
      if (!named) return other ? [] : ["**"];
      const xs = pats(inc ?? exc, what);
      return xs && (inc !== undefined ? xs : ["**", ...xs.map(p => `!${p}`)]);
    };
    const pb = side(b, bi, hasB, tagged, "branch patterns"), pt = side(t, ti, tagged, hasB, "tag patterns");
    if (!pb || !pt) return { error: "a push filter is not a list of short strings" };
    if (!pb.every(p => globToks(p.replace(/^!/, "")))) return { error: "a branch filter with a quantifier after nothing or an open [" };
    push_branches = pb; push_tags = pt;
  }
  if (events.includes("workflow_dispatch")) {
    const inputs = own(own(on, "workflow_dispatch"), "inputs");
    dispatch = isObj(inputs) ? capped(Object.keys(inputs), MAX_LIST, "inputs") : [];
    if (!dispatch.every(k => /^[A-Za-z_][A-Za-z0-9_-]{0,63}$/.test(k))) return { error: "an input name outside [A-Za-z_][A-Za-z0-9_-]" };
  }
  const idToken = (p: unknown) => p === "write-all" || own(p, "id-token") === "write";
  if (idToken(own(doc, "permissions"))) signals.add("id-token");
  const jobs = own(doc, "jobs");
  let budget = RUN_BUDGET;
  for (const id of isObj(jobs) ? capped(Object.keys(jobs), MAX_JOBS, "jobs") : []) {
    const job = own(jobs, id);
    if (idToken(own(job, "permissions"))) signals.add("id-token");
    const env = own(job, "environment"), name = typeof env === "string" ? env : own(env, "name");
    if (name !== undefined) { if (!textOk(name)) return { error: "an environment name is not a short string" }; envs.push(name); }
    for (const step of capped(list(own(job, "steps")), MAX_STEPS, `steps in job ${textOk(id) ? id : "?"}`)) {
      const uses = own(step, "uses"), run = own(step, "run");
      if (typeof uses === "string" && uses.length <= 200) {
        if (/^(googleapis|google-github-actions)\/release-please-action@/.test(uses)) {
          signals.add("release-please");
          // an expression is unresolved: a variable or input can name any branch
          const tb = own(own(step, "with"), "target-branch");
          rp.push(tb === undefined ? "" : refOk(tb) ? tb : null);
        }
        if (/^JS-DevTools\/npm-publish@/i.test(uses)) signals.add("npm publish");
        if (/^softprops\/action-gh-release@/i.test(uses)) signals.add("gh release");
      }
      if (typeof run === "string") {
        if ((budget -= run.length) < 0) return { error: `run steps past ${RUN_BUDGET / 1024} KiB of text` };
        if (/\brelease-please\b/.test(run)) signals.add("release-please");
        if (/\b(npm|pnpm|bun|yarn( npm)?) publish\b/.test(run)) signals.add("npm publish");
        if (/\bgh release (create|upload|edit)\b/.test(run)) signals.add("gh release");
      }
    }
  }
  return { wf: { path, dispatch, push_branches, push_tags, environments: uniq(envs), signals: uniq([...signals]) }, tagged, rp, notes };
}

/** The first fenced json block under `## Release profile`, as release-profile/1. Unknown keys are ignored and listed; any
 *  other fault rejects the whole block, so a half-valid block never fills a fact. */
function parseBlock(md: string): { block?: Block; ignored: string[]; error?: string } {
  let fence = "", section = false, closed = false, lines: string[] | null = null;
  for (const line of md.split(/\r\n|\r|\n/)) {
    if (fence) {   // CommonMark: a line of the fence's character, at least as long, and nothing else closes it
      const c = /^ {0,3}(`+|~+)[ \t]*$/.exec(line);
      if (c && c[1][0] === fence[0] && c[1].length >= fence.length) { if (lines) { closed = true; break; } fence = ""; }
      else lines?.push(line);
      continue;
    }
    // a backtick fence's info string holds no backtick anywhere; its first word is the language
    const f = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line), info = f?.[2].replace(/^[ \t]+|[ \t]+$/g, "") ?? "";
    if (f && !(f[1][0] === "`" && info.includes("`"))) { fence = f[1]; if (section && info.split(/[ \t]/)[0] === "json") lines = []; continue; }
    if (/^ {0,3}#{1,2}(?:[ \t]|$)/.test(line)) { if (section) break; section = /^ {0,3}## Release profile[ \t]*$/.test(line); }
  }
  if (!lines) return { ignored: [] };
  if (!closed) return { ignored: [], error: "its json fence never closes" };
  let v: unknown;
  try { v = JSON.parse(lines.join("\n")); } catch { return { ignored: [], error: "not valid JSON" }; }
  if (!isObj(v) || v.schema !== "release-profile/1") return { ignored: [], error: "not a release-profile/1 object" };
  const sync = own(v, "sync"), external = own(v, "external"), freeze = own(v, "freeze");
  const ignored = [...Object.keys(v).filter(k => !["schema", "shape", "release_branch", "tool", "sync", "freeze", "external"].includes(k)),
    ...(isObj(sync) ? Object.keys(sync).filter(k => !["method", "opened_by", "head"].includes(k)).map(k => `sync.${k}`) : [])];
  const fault = (error: string) => ({ ignored, error });
  const oneOf = (x: unknown, xs: string[]) => x === undefined || xs.includes(x as string);
  const strings = [own(v, "shape"), own(v, "release_branch"), own(v, "tool"), own(sync, "method"), own(sync, "opened_by"), own(sync, "head"), ...list(external)];
  if (!strings.every(s => s === undefined || textOk(s))) return fault("a string is empty, over 160 code points, or carries a control or bidi character");
  if (external !== undefined && !Array.isArray(external)) return fault("external is not a list");
  if (list(external).length > MAX_EXTERNAL) return fault(`external holds ${list(external).length} steps, at most ${MAX_EXTERNAL}`);
  if (!oneOf(own(v, "shape"), ["promote", "single", "none"])) return fault("shape is not promote, single or none");
  if (!oneOf(own(v, "tool"), ["release-please", "tag", "dispatch", "none"])) return fault("tool is not release-please, tag, dispatch or none");
  if (sync !== undefined && !isObj(sync)) return fault("sync is not an object");
  if (!oneOf(own(sync, "method"), METHODS)) return fault("sync.method is not merge, squash or rebase");
  if (!oneOf(own(sync, "opened_by"), ["app", "maintainer"])) return fault("sync.opened_by is not app or maintainer");
  if (![own(v, "release_branch"), own(sync, "head")].every(r => r === undefined || refOk(r))) return fault("a branch name is outside [A-Za-z0-9._/-]");
  if (freeze !== undefined && typeof freeze !== "boolean") return fault("freeze is not true or false");
  const s = (x: unknown) => x as string | undefined;
  return { ignored, block: { shape: s(own(v, "shape")), release_branch: s(own(v, "release_branch")), tool: s(own(v, "tool")), freeze,
    external: Array.isArray(external) ? [...external] as string[] : undefined,
    sync: isObj(sync) ? { method: s(sync.method), opened_by: s(sync.opened_by), head: s(sync.head) } : undefined } };
}

class Failure extends Error {}

async function derive(repo: string): Promise<{ profile: Obj & { unknown: string[] }; ignored: string[] }> {
  const R = `repos/${repo}`, owner = repo.split("/")[0], U: string[] = [];
  const unread = (what: string, g: Got) => { U.push(`${what}: ${why(g)}`); return null; };
  // a page that came back full, or a total above what came back, is unread: the rest could change the answer
  const page = (xs: unknown[], what: string, total?: unknown) =>
    xs.length >= 100 || (typeof total === "number" && total > xs.length) ? (U.push(`${what}: more than one page; the rest unread`), null) : xs;
  const firstOf = async (paths: string[]) => {
    for (const p of paths) { const g = await raw(`${R}/contents/${p}`); if (g.status !== 404) return g; }
    return { status: 404, text: "" };
  };
  const [repoG, protG, listG, rsG, envG, skillG, rpConfG, rpManG] = await Promise.all([get(R),
    get(`${R}/branches?protected=true&per_page=100`), get(`${R}/contents/.github/workflows`), get(`${R}/rulesets?targets=tag&per_page=100`),
    get(`${R}/environments?per_page=100`), raw(`${R}/contents/${SKILL}`),
    firstOf(["release-please-config.json", ".github/release-please-config.json"]),
    firstOf([".release-please-manifest.json", ".github/.release-please-manifest.json"])]);
  const rj = json(repoG);
  if (!isObj(rj)) throw new Failure(`cannot read ${R}: ${why(repoG)}`);
  if (!refOk(rj.default_branch)) throw new Failure(`${R}: its default branch's name is outside [A-Za-z0-9._/-]`);
  const trunk = rj.default_branch;
  const flags = [rj.allow_merge_commit, rj.allow_squash_merge, rj.allow_rebase_merge];
  const allowed = flags.every(f => typeof f === "boolean") ? METHODS.filter((_, i) => flags[i]) : null;
  if (!allowed) U.push("merge settings: the repository's answer carries no allow_* flags");

  let block: Block | undefined, ignored: string[] = [], blockBad = false, skill: Obj | null = null;
  if (skillG.status === 200) {
    const b = parseBlock(skillG.text);
    ({ block, ignored } = b); skill = { path: SKILL, block: !!b.block };
    if (b.error) { blockBad = true; U.push(`release skill block: ${b.error}`); }
  } else if (skillG.status !== 404) { blockBad = true; unread(SKILL, skillG); }

  let workflows: Workflow[] | null = [], gap = false;   // gap: a workflow file, or part of one, went unread
  const miss = (what: string) => { gap = true; U.push(what); };
  const reads: Read[] = [], files = json(listG);
  if (listG.status !== 404 && !Array.isArray(files)) workflows = unread("workflows", listG);
  else if (Array.isArray(files)) {
    const ymls = files.filter(f => own(f, "type") === "file" && /\.ya?ml$/.test(String(own(f, "name"))));
    if (ymls.length > MAX_LIST) miss(`workflows: over ${MAX_LIST} files; the rest unread`);
    await Promise.all(ymls.slice(0, MAX_LIST).map(async f => {
      const name = String(own(f, "name")), path = `.github/workflows/${name}`, size = own(f, "size");
      if (!/^[A-Za-z0-9._-]+\.ya?ml$/.test(name)) return miss("a workflow file: its name is outside [A-Za-z0-9._-], skipped");
      if (typeof size === "number" && size > FILE_CAP) return miss(`${path}: over 256 KiB, skipped`);
      const g = await raw(`${R}/contents/${path}`);
      if (g.status !== 200) return miss(g.status === -1 ? `${path}: over 256 KiB, skipped` : `${path}: ${why(g)}`);
      const r = readWorkflow(path, g.text);
      if ("error" in r) return miss(`${path}: ${r.error}`);
      r.notes.forEach(n => miss(`${path}: ${n}`)); reads.push(r);
    }));
    workflows = reads.map(r => r.wf).sort((a, b) => a.path.localeCompare(b.path));
  }

  // the tool: release-please, else a publishing workflow on tag pushes, else one that runs only when dispatched. release-please
  // outranks the rest, so any other answer stands only when no file that could show it went unread
  let rpGap = false;
  for (const [g, what] of [[rpConfG, "release-please config"], [rpManG, "release-please manifest"]] as const) {
    if (g.status !== 200 && g.status !== 404) { rpGap = true; unread(what, g); }
  }
  const rpSeen = rpConfG.status === 200 || rpManG.status === 200 || reads.some(r => r.wf.signals.includes("release-please"));
  let kind = rpSeen ? "release-please" : workflows === null || gap || rpGap ? null
    : reads.some(r => r.tagged && publishes(r.wf)) ? "tag"
    : reads.some(r => r.wf.dispatch && !r.wf.push_branches.length && publishes(r.wf)) ? "dispatch" : "none";
  // the block fills what GitHub cannot say; where both say and disagree, neither wins
  if (block?.tool && kind && kind !== block.tool) { U.push(`tool: the block says ${block.tool}, the workflows say ${kind}`); kind = "unknown"; }
  kind ??= block?.tool ?? null;
  if (!kind) { kind = "unknown"; U.push("tool: an unread file could name it, and the release skill's block does not"); }
  const targets = uniq(reads.flatMap(r => r.rp).map(t => t === "" ? trunk : t ?? "?"));
  const rpBranch = kind === "release-please" && targets.length === 1 && targets[0] !== "?" ? targets[0] : null;

  // the release branch: the block's, else release-please's, else the only protected branch besides the trunk
  const protJ = json(protG);
  const prot = (Array.isArray(protJ) ? page(protJ, "protected branches") : unread("protected branches", protG))
    ?.map(b => own(b, "name")).filter(refOk).filter(n => n !== trunk) ?? null;
  const UNKNOWN = Symbol("unknown");
  let rel: string | null | typeof UNKNOWN;
  if (block?.release_branch !== undefined) {
    rel = block.release_branch === trunk ? null : block.release_branch;
    if (rpBranch && (rpBranch === trunk ? null : rpBranch) !== rel) {
      U.push(`release branch: the block says ${block.release_branch}, release-please releases from ${rpBranch}`); rel = UNKNOWN;
    }
  } else if (rpBranch) rel = rpBranch === trunk ? null : rpBranch;
  else if (!prot) rel = UNKNOWN;
  else if (prot.length > 1) { U.push(`release branch: ${prot.length} protected branches besides the trunk`); rel = UNKNOWN; }
  else rel = prot[0] ?? null;
  const noneProtected = rel === null && block?.release_branch === undefined && !rpBranch;

  let rules403 = false;
  const facts = async (b: string): Promise<Branch | null> => {
    const [hd, rl, pr] = await Promise.all([get(`${R}/branches/${b}`), get(`${R}/rules/branches/${b}?per_page=100`), get(`${R}/branches/${b}/protection`)]);
    if (hd.status === 404) { U.push(`branch ${b}: not found`); return null; }
    const sha = own(own(json(hd), "commit"), "sha");
    const runs = typeof sha === "string" && /^[0-9a-f]{40}$/.test(sha) ? await get(`${R}/commits/${sha}/check-runs?per_page=100`) : null;
    if (!runs) hd.status === 200 ? U.push(`branch ${b}: no head sha`) : unread(`branch ${b}`, hd);
    if (rl.status === 403) rules403 = true;
    const rj = json(rl), pj = json(pr);
    const rules = Array.isArray(rj) ? page(rj, `rules ${b}`) : unread(`rules ${b}`, rl);
    const classic = pr.status === 404 && own(body(pr), "message") === "Branch not protected" ? {} : isObj(pj) ? pj : unread(`protection ${b}`, pr);
    const both = !!rules && !!classic;
    const of = (t: string) => (rules ?? []).filter(r => own(r, "type") === t).map(r => own(r, "parameters"));
    // true when a readable source requires it, false when both are readable and neither does
    const either = (byRules: boolean, byClassic: boolean) => (rules && byRules) || (classic && byClassic) ? true : both ? false : null;
    const enabled = (k: string) => own(own(classic, k), "enabled") === true;
    const rsc = own(classic, "required_status_checks"), rv = own(classic, "required_pull_request_reviews");
    const linear = either(of("required_linear_history").length > 0, enabled("required_linear_history"));
    const signed = either(of("required_signatures").length > 0, enabled("required_signatures"));
    const strict = either(of("required_status_checks").some(p => own(p, "strict_required_status_checks_policy") === true), own(rsc, "strict") === true);
    // a list or count of another type is unread, never empty or zero: either would let a merge.branches entry be written
    const ctx = (cs: unknown) => Array.isArray(cs) ? cs.map(c => own(c, "context")) : null;
    const lists = [...of("required_status_checks").map(p => ctx(own(p, "required_status_checks"))),
      rsc === undefined ? [] : Array.isArray(own(rsc, "contexts")) && (own(rsc, "checks") === undefined || ctx(own(rsc, "checks")))
        ? [...(own(rsc, "contexts") as unknown[]), ...(ctx(own(rsc, "checks")) ?? [])] : null];
    let checks = both ? (lists.includes(null) ? (U.push(`checks ${b}: a check list is not a list`), null) : lists.flat()) : null;
    if (checks && !checks.every(textOk)) { checks = null; U.push(`checks ${b}: a name is not a short string`); }
    // a required code-owner review or approval of the last push blocks a merge as a count of one does
    const flag = (p: unknown, k: string) => { const v = own(p, k); return v === undefined ? false : typeof v === "boolean" ? v : null; };
    const count = (p: unknown, owners: string) => { const n = own(p, "required_approving_review_count"), o = flag(p, owners), l = flag(p, "require_last_push_approval");
      return Number.isSafeInteger(n) && (n as number) >= 0 && o !== null && l !== null ? Math.max(n as number, o || l ? 1 : 0) : null; };
    const counts = [...of("pull_request").map(p => count(p, "require_code_owner_review")), rv === undefined ? 0 : count(rv, "require_code_owner_reviews")];
    const reviews = !both ? null : counts.includes(null) ? (U.push(`reviews ${b}: a review count or flag has another type`), null) : Math.max(...(counts as number[]));
    // what both the rulesets and the repository allow; linear history removes merge, whichever source requires it
    let methods = allowed && both ? of("pull_request").map(p => own(p, "allowed_merge_methods"))
      .reduce<string[] | null>((m, a) => !m ? null : a === undefined ? m : Array.isArray(a) ? m.filter(x => a.includes(x)) : null, allowed) : null;
    if (allowed && both && !methods) U.push(`methods ${b}: a ruleset's merge methods are not a list`);
    if (methods && linear) methods = methods.filter(m => m !== "merge");
    const crJ = runs && json(runs), crL = own(crJ, "check_runs");
    const cr = Array.isArray(crL) ? page(crL, `check-runs ${b}`, own(crJ, "total_count")) : runs ? unread(`check-runs ${b}`, runs) : null;
    let apps = cr && cr.map(r => own(own(r, "app"), "slug")).filter(s => s !== "github-actions");
    if (apps && !apps.every(textOk)) { apps = null; U.push(`check-runs ${b}: an app slug is not a short string`); }
    const pushers = gap ? undefined : workflows?.filter(w => pushesTo(w, b) && publishes(w)).map(w => w.path);   // whole or null
    return { name: b, methods, linear, signed, strict, checks: checks && uniq(checks as string[]), reviews,
      queue: rules ? of("merge_queue").length > 0 : null, deploys: apps && pushers ? uniq([...apps.map(a => `app/${a}`), ...pushers]) : null };
  };
  const [tf, bf] = await Promise.all([facts(trunk), typeof rel === "string" ? facts(rel) : null]);
  const trunkF = tf ?? { name: trunk, methods: null, linear: null, signed: null, strict: null, checks: null, reviews: null, queue: null, deploys: null };
  if (typeof rel === "string" && !bf) rel = UNKNOWN;

  // a free private repository answers 403 on rules and lists no protected branch, environment or ruleset, whatever it holds
  if (noneProtected && rules403) { rel = UNKNOWN; U.push("release branch: none protected while rules answer HTTP 403"); }
  const envR = json(envG), envJ = own(envR, "environments");
  let environments: Obj[] | null = (Array.isArray(envJ) ? page(envJ, "environments", own(envR, "total_count")) : unread("environments", envG))?.map(e => {
    const rr = list(own(e, "protection_rules")).find(r => own(r, "type") === "required_reviewers");
    return { name: own(e, "name"), reviewers: list(own(rr, "reviewers")).length, self_review_blocked: own(rr, "prevent_self_review") === true };
  }) ?? null;
  if (environments && !environments.every(e => textOk(e.name))) { environments = null; U.push("environments: a name is not a short string"); }
  if (environments?.length === 0 && rules403) { environments = null; U.push("environments: none listed while rules answer HTTP 403"); }
  const rsJ = json(rsG);
  let tags: { pattern: string; creation: string }[] | null = null;
  if (!Array.isArray(rsJ)) unread("tag rulesets", rsG);
  else if (page(rsJ, "tag rulesets")) {
    const ids = rsJ.filter(r => own(r, "target") === "tag" && own(r, "enforcement") === "active").map(r => own(r, "id")).filter(Number.isSafeInteger);
    const got = await Promise.all(ids.slice(0, MAX_LIST).map(id => get(`${R}/rulesets/${id}`)));
    const bad = got.find(g => !isObj(json(g)));
    if (bad) unread("tag rulesets", bad);
    else {
      tags = got.flatMap(g => {
        const r = json(g), creation = list(own(r, "rules")).some(x => own(x, "type") === "creation") ? "restricted" : "open";
        return list(own(own(own(r, "conditions"), "ref_name"), "include"))
          .map(p => ({ pattern: p === "~ALL" ? "*" : String(p).replace(/^refs\/tags\//, ""), creation }));
      });
      if (!tags.every(x => textOk(x.pattern))) { tags = null; U.push("tag rulesets: a pattern is not a short string"); }
      else if (!tags.length && rules403) { tags = null; U.push("tag rulesets: none listed while rules answer HTTP 403"); }
      else tags = [...new Map(tags.map(x => [`${x.pattern} ${x.creation}`, x])).values()].sort((a, b) => a.pattern.localeCompare(b.pattern));
    }
  }

  // release-please opens its PR from release-please--branches--<branch>; its bot is whoever opened the last one
  const tool: { kind: string; branch: string | null; bot: string | null; head: string | null } = { kind, branch: null, bot: null, head: null };
  if (kind === "release-please") {
    tool.branch = targets.includes("?") ? null : rpBranch ?? (typeof rel === "string" ? rel : null);
    const head = tool.branch && `release-please--branches--${tool.branch}`;
    if (!head) U.push("tool.branch: release-please's target-branch resolves to no single branch");
    else if (own(json(rpConfG), "separate-pull-requests") === true) U.push("tool.head: release-please opens one PR per package");
    else if (!refOk(head)) U.push("tool.head: the release branch's name is too long for one");
    else {
      tool.head = head;
      const g = await get(`${R}/pulls?state=all&head=${owner}:${encodeURIComponent(head)}&per_page=1`), prs = json(g);
      const user = own(list(prs)[0], "user"), type = own(user, "type"), login = own(user, "login");
      if (!Array.isArray(prs)) unread("tool.bot", g);
      else if (!prs.length) U.push(`tool.bot: no PR from ${head} yet`);
      else if (type === "Bot" && typeof login === "string" && /^[A-Za-z0-9-]{1,60}\[bot\]$/.test(login)) tool.bot = `app/${login.slice(0, -5)}`;
      else if (type === "User" && typeof login === "string" && /^[A-Za-z0-9-]{1,39}$/.test(login)) tool.bot = login;
      else U.push("tool.bot: the last release PR's author is neither an app nor a user");
    }
  } else if (kind === "tag" || kind === "dispatch") tool.branch = rel === UNKNOWN ? null : rel ?? trunk;

  let shape = rel === UNKNOWN || kind === "unknown" ? "unknown" : rel ? "promote" : kind === "none" ? "none" : "single";
  if (block?.shape && shape !== "unknown" && block.shape !== shape) { U.push(`shape: the block says ${block.shape}, GitHub says ${shape}`); shape = "unknown"; }
  let sync: Obj | null = null;
  if (shape === "promote" && typeof rel === "string") {
    const method = block?.sync?.method ?? null, m = trunkF.methods;
    if (!method) U.push("sync.method: no valid release skill block names it");
    sync = { from: rel, to: trunk, method, head: block?.sync?.head ?? rel,
      // linear history forbids a merge commit even where the methods went unread
      blocked_by: method === "merge" && trunkF.linear ? `linear history on ${trunk}` : !method || !m || m.includes(method) ? null : `${trunk} does not allow ${method}` };
  }
  return { ignored, profile: { schema: "orchy.release/1", repo, at: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"), shape,
    trunk: trunkF, branch: typeof rel === "string" ? bf : null, tool, sync, tags, environments, workflows, skill,
    freeze: blockBad ? null : block?.freeze ?? false, external: blockBad ? null : block?.external ?? [], unknown: U.sort() } };
}

async function main([flag, arg, ...rest]: string[]): Promise<number> {
  if (rest.length || (flag !== undefined && (flag !== "--repo" || !arg))) { console.error("usage: bun release-profile.ts [--repo owner/name]"); return 2; }
  if (!Bun.which("gh")) { console.error("release-profile: gh not found"); return 2; }
  const here = arg ? undefined : await gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], 1024);
  const repo = arg ?? (here?.status === 200 ? here.text.trim() : "");
  if (!/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/.test(repo) || /\/\.\.?$/.test(repo)) {
    console.error(`release-profile: ${repo ? "the repository is not owner/name" : "no repository here: pass --repo owner/name"}`); return 2;
  }
  try {
    const { profile, ignored } = await derive(repo);
    for (const k of ignored) console.error(`release-profile: ignored the release skill's block key ${textOk(k) ? JSON.stringify(k) : "(unprintable)"}`);
    console.log(JSON.stringify(profile, null, 2));
    return profile.unknown.length ? 3 : 0;
  } catch (e) {
    console.error(`release-profile: ${e instanceof Failure ? e.message : e instanceof Error ? e.stack : e}`); return 2;
  }
}

if (import.meta.main) process.exit(await main(process.argv.slice(2)));
