// One Higgsfield generation, capped and logged. Prices the job, reserves the quote against the spot's
// cap, submits, records the job id at once, waits, downloads, and settles the reservation.
//   bun hf.ts <outdir> <name> <model> [higgsfield flags...]
//   bun hf.ts --resume <ref> [jobId]    finish a job whose wait or download failed; never resubmit instead
//   bun hf.ts --release <ref> [--not <jobId,...>] [--checked-history]
//                                       drop a reservation after proving its submission created no job
// The workspace is $HF_WORKSPACE, else the nearest ancestor of <outdir> (of the cwd for --resume and
// --release) holding expenses.jsonl. Rows bill to the spot, <outdir>'s first folder under the
// workspace, and <workspace>/<spot>/cap holds the owner-approved budget in credits: no cap, no job.
// HF_MAX_OPEN (default 8) caps the unsettled jobs across the workspace.
import { existsSync, linkSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync } from "node:fs";
import { hostname } from "node:os";
import { join, relative, sep } from "node:path";
import { appendRow, type Entry, foldLedger, hfJson, isOpen, type Job, ledgerPath, parseJson, pidAlive, readLedger, recentJobs, withLock, workspaceFor } from "./lib.ts";

type Base = { ref: string; spot: string; dir: string; name: string; model: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_OPEN = Number(process.env.HF_MAX_OPEN ?? 8);
// Terminal states that bill nothing; anything else unfinished stays reserved until --resume settles it.
const FREE = new Set(["failed", "canceled", "cancelled"]);
// Server and local clocks disagree by seconds; a minute of slack keeps a job from escaping a check.
const SLACK = 60_000;

const entries = (ws: string) => foldLedger(readLedger(ws));
const baseOf = (e: Entry): Base => ({ ref: e.ref, spot: e.spot, dir: e.dir ?? "", name: e.name, model: e.model });
const sha256 = async (f: string) => new Bun.CryptoHasher("sha256").update(await Bun.file(f).arrayBuffer()).digest("hex");

function getJob(jobId: string): Job {
  const got = hfJson(["generate", "get", jobId]);
  const job = (Array.isArray(got) ? got[0] : got) as Job | undefined;
  if (job?.id !== jobId) throw new Error(`generate get ${jobId} returned another job`);
  return job;
}

function balance() {
  try {
    const b = Number((hfJson(["account", "status"]) as { credits?: unknown }).credits);
    return Number.isFinite(b) ? b : undefined;
  } catch {
    return undefined;
  }
}

/** Records a terminal event once, so a second finisher of the same job logs nothing. */
function settle(ws: string, base: Base, row: { event: "done" | "failed"; jobId: string; credits?: number; file?: string; balance?: number; note?: string }) {
  withLock(ws, () => {
    let settled = false;
    try {
      const e = entries(ws).find((x) => x.ref === base.ref);
      settled = e?.state === "done" || e?.state === "failed";
    } catch {
      // An invalid ledger must not keep a true outcome off it; the next reservation reports the fault.
    }
    if (!settled) appendRow(ws, { ...base, ...row });
  });
}

async function finish(ws: string, base: Base, jobId: string) {
  const outdir = join(ws, base.dir);
  Bun.spawnSync(["higgsfield", "generate", "wait", jobId, "--timeout", "30m", "--quiet", "--no-color"], { stdout: "ignore", stderr: "ignore" });
  let job: Job;
  try {
    job = getJob(jobId);
  } catch (e) {
    throw new Error(`can't read job ${jobId} (${(e as Error).message}): bun hf.ts --resume ${base.ref}`);
  }
  const meta = join(outdir, `${base.name}.job.json`);
  await Bun.write(`${meta}.${process.pid}`, JSON.stringify(job, null, 2));
  renameSync(`${meta}.${process.pid}`, meta);

  if (job.status && FREE.has(job.status)) {
    settle(ws, base, { event: "failed", jobId, credits: 0, note: job.status });
    throw new Error(`job ${jobId} ${job.status}; nothing billed`);
  }
  if (job.status !== "completed" || !job.result_url) throw new Error(`job ${jobId} is ${job.status}: bun hf.ts --resume ${base.ref} once it finishes`);

  const url = new URL(job.result_url);
  if (url.protocol !== "https:") throw new Error(`refusing a non-https result URL for ${jobId}`);
  const ext = url.pathname.match(/\.([A-Za-z0-9]{1,5})$/)?.[1]?.toLowerCase() ?? "bin";
  const file = join(outdir, `${base.name}.${ext}`);
  const part = join(outdir, `.${base.name}.${process.pid}.part`);
  try {
    const dl = Bun.spawnSync(["curl", "-fsSL", "--retry", "3", "--proto", "=https", "--proto-redir", "=https", "-o", part, url.href], { stderr: "pipe" });
    const media = () => Bun.spawnSync(["ffprobe", "-v", "error", "-show_entries", "format=format_name", "-of", "csv=p=0", part]).exitCode === 0;
    if (dl.exitCode !== 0 || !existsSync(part) || statSync(part).size === 0 || !media()) {
      throw new Error(`download of ${jobId} failed or isn't media (${dl.stderr.toString().trim()}): bun hf.ts --resume ${base.ref}`);
    }
    // link() never replaces a file. An identical file at the name means an earlier finisher published
    // this result and stopped before settling; anything else is a different take and stays untouched.
    try {
      linkSync(part, file);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
      if ((await sha256(file)) !== (await sha256(part))) throw new Error(`${file} exists and is not job ${jobId}'s result: move it aside, then --resume ${base.ref}`);
    }
  } finally {
    if (existsSync(part)) unlinkSync(part);
  }
  const bal = balance();
  settle(ws, base, { event: "done", jobId, file: relative(ws, file), balance: bal });
  console.log(`${base.name} -> ${file}`);
}

async function submit([outdirArg, name, model, ...flags]: string[]) {
  if (!outdirArg || !name || !model) throw new Error("usage: bun hf.ts <outdir> <name> <model> [flags...]");
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) throw new Error(`name "${name}" must be a plain file stem`);
  if (!Number.isInteger(MAX_OPEN) || MAX_OPEN < 1) throw new Error("HF_MAX_OPEN must be a positive integer");
  // One reservation tracks one job, recorded before any wait: parallel calls replace batches.
  const batch = flags.findIndex((f) => f === "--batch_size" || f.startsWith("--batch_size="));
  if (batch >= 0 && Number(flags[batch].split("=")[1] ?? flags[batch + 1]) !== 1) throw new Error("one job per call: drop --batch_size and launch calls in parallel");
  if (flags.some((f) => f.startsWith("--wait"))) throw new Error("hf.ts records the job id and then waits itself: drop --wait");
  mkdirSync(outdirArg, { recursive: true });
  const outdir = realpathSync(outdirArg);
  const ws = workspaceFor(outdir);
  const dir = relative(ws, outdir);
  const spot = dir.split(sep)[0];
  if (!spot || spot === ".." || dir.startsWith(`..${sep}`)) throw new Error(`${outdir} is not inside a spot folder of ${ws}`);

  let quote = Number.NaN;
  try {
    quote = Number((hfJson(["generate", "cost", model, ...flags]) as { credits?: unknown }).credits);
  } catch (e) {
    throw new Error(`pricing failed, nothing submitted: ${(e as Error).message}`);
  }
  if (!Number.isFinite(quote) || quote < 0) throw new Error(`pricing returned no credits, nothing submitted: check the flags with \`higgsfield generate cost ${model} ...\``);

  const base = withLock(ws, (): Base => {
    const capFile = join(ws, spot, "cap");
    const cap = existsSync(capFile) ? Number(readFileSync(capFile, "utf8").trim()) : Number.NaN;
    if (!Number.isFinite(cap) || cap < 0) throw new Error(`no approved budget: write the cap in credits to ${capFile}`);
    const all = entries(ws);
    const used = all.filter((e) => e.spot === spot).reduce((a, e) => a + e.credits, 0);
    if (used + quote > cap + 1e-9) throw new Error(`over the cap for ${spot}: ${used.toFixed(2)} committed + ${quote} quoted > ${cap}`);
    const open = all.filter(isOpen).length;
    if (open >= MAX_OPEN) throw new Error(`${open} jobs are unsettled in ${ws}: settle some (ledger.ts lists them) or raise HF_MAX_OPEN`);
    // A take name is used once, ever: the ledger covers takes still in flight, the folder the rest.
    if (all.some((e) => e.dir === dir && e.name === name) || readdirSync(outdir).some((f) => f === name || f.startsWith(`${name}.`))) {
      throw new Error(`${name} is taken in ${outdir}: takes are never reused, bump the take`);
    }
    const refs = new Set(all.map((e) => e.ref));
    let ref: string;
    do ref = crypto.randomUUID().slice(0, 8);
    while (refs.has(ref));
    const b: Base = { ref, spot, dir, name, model };
    appendRow(ws, { ...b, event: "reserved", credits: quote, pid: process.pid, host: hostname() });
    return b;
  });

  const sub = Bun.spawnSync(["higgsfield", "generate", "create", model, ...flags, "--json", "--no-color"], { stdout: "pipe", stderr: "pipe" });
  const [out, err] = [sub.stdout.toString(), sub.stderr.toString()];
  const parsed = parseJson(out);
  // Without --wait, create prints an array of job id strings; accept job objects too.
  const ids = (Array.isArray(parsed) ? parsed : [parsed]).map((j) => (typeof j === "string" ? j : (j as Job | undefined)?.id));
  const jobId = ids[0];
  if (sub.exitCode !== 0 || typeof jobId !== "string" || !UUID.test(jobId)) {
    // The outcome is unknown, so the reservation stands until --release proves no job exists.
    await Bun.write(join(outdir, `${name}.submit.txt`), `exit ${sub.exitCode}\n--- stdout ---\n${out}\n--- stderr ---\n${err}`);
    throw new Error(
      `submission unclear, reservation ${base.ref} kept: ${(err || out).trim().slice(0, 300)}\n` +
        `bun hf.ts --release ${base.ref} checks the account and releases it only if no job was created; if it names one, bun hf.ts --resume ${base.ref} <jobId>.`,
    );
  }
  if (ids.length > 1) console.error(`warning: ${ids.length} jobs came back; only ${jobId} is tracked, ledger.ts lists the rest`);
  withLock(ws, () => appendRow(ws, { ...base, event: "submitted", jobId }));
  console.log(`${name}: ${quote} credits reserved, job ${jobId} (ref ${base.ref})`);
  await finish(ws, base, jobId);
}

function openRef(ref: string | undefined) {
  if (!ref) throw new Error("usage: bun hf.ts --resume <ref> [jobId] | --release <ref> [--not <jobId,...>] [--checked-history]");
  const ws = workspaceFor(realpathSync(process.cwd()));
  const e = entries(ws).find((x) => x.ref === ref && x.state !== "legacy");
  if (!e) throw new Error(`no reservation ${ref} in ${ledgerPath(ws)}`);
  if (!isOpen(e)) throw new Error(`${ref} is already settled (${e.state})`);
  return { ws, e };
}

async function resume([ref, given]: string[]) {
  const { ws, e } = openRef(ref);
  if (given && !UUID.test(given)) throw new Error(`"${given}" is not a job id`);
  if (e.jobId && given && given !== e.jobId) throw new Error(`${e.ref} is job ${e.jobId}, not ${given}`);
  const jobId = e.jobId ?? given;
  if (!jobId) throw new Error(`no job id recorded for ${e.ref}: bun hf.ts --release ${e.ref} finds out whether one was created`);
  if (!e.jobId) {
    // A job attached by hand must be this reservation's model, created after it, and not on the ledger.
    const job = getJob(jobId);
    if (job.job_type && job.job_type !== e.model) throw new Error(`job ${jobId} is ${job.job_type}, but ${e.ref} reserved ${e.model}`);
    if (Date.parse(job.created_at) < e.since - SLACK) throw new Error(`job ${jobId} was created before ${e.ref} was reserved`);
    withLock(ws, () => {
      const owner = entries(ws).find((x) => x.jobId === jobId);
      if (owner) throw new Error(`job ${jobId} is already recorded under ${owner.ref}`);
      appendRow(ws, { ...baseOf(e), event: "submitted", jobId, note: "attached on resume" });
    });
  }
  await finish(ws, baseOf(e), jobId);
}

function release([ref, ...opts]: string[]) {
  const { ws, e } = openRef(ref);
  const checked = opts.includes("--checked-history");
  const notAt = opts.indexOf("--not");
  const not = new Set(notAt >= 0 ? (opts[notAt + 1] ?? "").split(",").filter(Boolean) : []);
  if (opts.some((o, i) => o !== "--checked-history" && o !== "--not" && (notAt < 0 || i !== notAt + 1))) throw new Error(`unknown option in ${opts.join(" ")}`);
  if (e.jobId) throw new Error(`${e.ref} has job ${e.jobId}: bun hf.ts --resume ${e.ref} settles it`);
  if (e.host && e.host !== hostname()) throw new Error(`${e.ref} was reserved on ${e.host}: release it there`);
  if (e.pid && pidAlive(e.pid)) throw new Error(`${e.ref}'s submission may still be running (pid ${e.pid}): let it finish, or stop it first`);
  if (Date.now() - e.since < SLACK) throw new Error(`${e.ref} is under a minute old and the account's job list can lag: retry in a minute`);

  const jobs = recentJobs(100);
  const reach = Math.min(...jobs.map((j) => Date.parse(j.created_at)));
  if (jobs.length === 100 && reach > e.since - SLACK && !checked) {
    throw new Error(
      `the account's last 100 jobs don't reach back to ${e.ref}'s reservation, so a job it created can't be ruled out. ` +
        `Check the account's history for a ${e.model} job from ${new Date(e.since).toISOString()}: if one is there, bun hf.ts --resume ${e.ref} <jobId>; if not, add --checked-history.`,
    );
  }
  const known = new Set(entries(ws).map((x) => x.jobId));
  const suspects = jobs.filter((j) => !known.has(j.id) && !not.has(j.id) && (!j.job_type || j.job_type === e.model) && Date.parse(j.created_at) >= e.since - SLACK);
  if (suspects.length) {
    throw new Error(
      `unledgered ${e.model} jobs since ${e.ref} was reserved (higgsfield generate get <jobId> --json shows each prompt):\n` +
        suspects.map((j) => `  ${j.id}  ${j.created_at}  ${j.status}`).join("\n") +
        `\nIf one is this reservation's job: bun hf.ts --resume ${e.ref} <jobId>. If none is: bun hf.ts --release ${e.ref} --not ${suspects.map((j) => j.id).join(",")}`,
    );
  }
  withLock(ws, () => {
    const now = entries(ws).find((x) => x.ref === e.ref);
    if (now?.state !== "reserved" || now.jobId) throw new Error(`${e.ref} changed while it was being checked: rerun`);
    const note = [not.size ? `not ${[...not].join(",")}` : "", checked ? "history checked by hand" : ""].filter(Boolean).join("; ");
    appendRow(ws, { ...baseOf(e), event: "released", credits: 0, ...(note ? { note } : {}) });
  });
  console.log(`released ${e.ref}`);
}

const [cmd, ...rest] = Bun.argv.slice(2);
if (cmd === "--resume") await resume(rest);
else if (cmd === "--release") release(rest);
else await submit(Bun.argv.slice(2));
