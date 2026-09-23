// The credit tab: spend and open reservations per spot against its cap, the balance, and the account's
// recent jobs checked against the ledger. A shared account shows up here as spend you did not make.
//   bun ledger.ts [--size N] [--prompts]
// --size: how many recent account jobs to check (default and API maximum 100; the CLI has no paging,
// so the output says how far back the check reached). --prompts adds each unledgered job's prompt; keep
// it out of anything shared, since those jobs may be another session's.
// The workspace is $HF_WORKSPACE, else the nearest ancestor of the cwd holding expenses.jsonl.
// Exits 1 when the ledger is invalid or can't be reconciled against the account.
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { hostname } from "node:os";
import { join } from "node:path";
import { type Entry, foldLedger, hfJson, isOpen, type Job, ledgerPath, pidAlive, readLedger, recentJobs, workspaceFor } from "./lib.ts";

const args = Bun.argv.slice(2);
const sizeAt = args.indexOf("--size");
const size = sizeAt >= 0 ? Number(args[sizeAt + 1]) : 100;
if (!Number.isInteger(size) || size < 1 || size > 100) throw new Error("--size takes an integer from 1 to 100");
const withPrompts = args.includes("--prompts");
const n2 = (x: number) => x.toFixed(2).padStart(9);
const when = (ms: number) => `${new Date(ms).toISOString().slice(0, 16)}Z`;

const ws = workspaceFor(realpathSync(process.cwd()));
if (!existsSync(ledgerPath(ws))) console.log(`no ledger yet at ${ledgerPath(ws)}`);
let entries: Entry[] = [];
try {
  entries = foldLedger(readLedger(ws));
} catch (e) {
  console.log(`LEDGER INVALID, ${(e as Error).message}\nhf.ts refuses new jobs until that row is repaired by hand; note the repair in the spot's lessons.md.`);
  process.exit(1);
}

console.log(`${"spot".padEnd(16)}${"spent".padStart(9)}${"open".padStart(9)}${"cap".padStart(9)}${"left".padStart(9)}`);
let [spent, open] = [0, 0];
for (const spot of new Set(entries.map((e) => e.spot))) {
  const mine = entries.filter((e) => e.spot === spot);
  const s = mine.filter((e) => !isOpen(e)).reduce((a, e) => a + e.credits, 0);
  const o = mine.filter(isOpen).reduce((a, e) => a + e.credits, 0);
  const capFile = join(ws, spot, "cap");
  const cap = existsSync(capFile) ? Number(readFileSync(capFile, "utf8").trim()) : Number.NaN;
  const [c, l] = Number.isFinite(cap) ? [n2(cap), n2(cap - s - o)] : ["—".padStart(9), "—".padStart(9)];
  console.log(`${spot.padEnd(16)}${n2(s)}${n2(o)}${c}${l}`);
  [spent, open] = [spent + s, open + o];
}
console.log(`${"total".padEnd(16)}${n2(spent)}${n2(open)}`);
for (const e of entries.filter((x) => x.anomaly)) console.log(`ANOMALY ${e.ref} ${e.spot}/${e.name}: ${e.anomaly}; it bills at its quote`);

let failed = false;
try {
  const bal = Number((hfJson(["account", "status"]) as { credits?: unknown }).credits);
  if (!Number.isFinite(bal)) throw new Error("account status carried no credits field");
  console.log(`balance ${bal.toFixed(2)} credits`);
} catch (e) {
  console.log(`balance unknown: ${(e as Error).message}`);
  failed = true;
}

let jobs: Job[] = [];
try {
  jobs = recentJobs(size);
} catch (e) {
  console.log(`account jobs unchecked: ${(e as Error).message}`);
  failed = true;
}

const status = new Map(jobs.map((j) => [j.id, j.status ?? "?"]));
for (const e of entries.filter(isOpen)) {
  const next = e.jobId
    ? `job ${status.get(e.jobId) ?? "not in the recent list"} -> bun hf.ts --resume ${e.ref}`
    : e.pid && e.host === hostname() && pidAlive(e.pid)
      ? `submitting in pid ${e.pid}`
      : `no job id -> bun hf.ts --release ${e.ref}`;
  console.log(`open ${e.ref} ${e.spot}/${e.name} ${e.model} ${e.credits.toFixed(2)} ${next}`);
}

if (!failed && !entries.length) console.log("the ledger is empty: nothing to reconcile");
if (!failed && entries.length) {
  const start = Math.min(...entries.map((e) => e.since).filter(Number.isFinite));
  const known = new Set(entries.map((e) => e.jobId).filter(Boolean));
  // A minute of slack: pre-reservation rows only approximate when their job was submitted.
  const missing = jobs.filter((j) => !known.has(j.id) && Date.parse(j.created_at) >= start - 60_000);
  const reach = Math.min(...jobs.map((j) => Date.parse(j.created_at)));
  console.log(`checked ${jobs.length} account jobs back to ${jobs.length ? when(reach) : "—"}: ${missing.length} not in the ledger`);
  if (jobs.length === size && reach > start) {
    const next = size < 100 ? "rerun with --size 100" : "older jobs can't be listed from the CLI; check them on the account's history page";
    console.log(`coverage stops at ${when(reach)}, after the ledger's start ${when(start)}: ${next}`);
  }
  for (const j of missing) {
    const p = j.params ?? {};
    const shape = [p.duration && `${p.duration}s`, p.resolution].filter(Boolean).join(" ");
    const prompt = withPrompts ? ` "${String(p.prompt ?? "").slice(0, 60)}"` : "";
    console.log(`NOT IN LEDGER ${when(Date.parse(j.created_at))} ${j.job_type ?? "?"} ${shape} ${j.status ?? "?"} ${j.id}${prompt}`);
  }
}
if (failed) process.exit(1);
