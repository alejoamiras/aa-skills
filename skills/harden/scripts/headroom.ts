// A harden run's account headroom, from claude-usage's cached snapshot only (`--json --cached`, then `current` and
// `list`, which never probe once a snapshot exists): `gate` judges this session's account, `fanout` deals the Claude
// cluster agents over the roster accounts with headroom, this session's account last. The floors and the 2-hour life
// of a reading mirror orchy's heavy-lead defaults (accounts.sh acct_view).
// Usage (through run.sh):
//   gate --model <alias>      prints "ok: …" (exit 0) or "stop: …" (exit 1)
//   fanout --model <alias> [--passes 1|2] [--exclude-from <file>] <cluster>…
//                             prints "<cluster> <pass> =<key>|session" per slot, then "methodology: …", which names no account
// A usage error exits 2.
import { closeSync, constants, fstatSync, openSync, readSync } from "node:fs";

export const WEEK_FLOOR = 25, SESSION_FLOOR = 30;
const FRESH_S = 7200, CU_TIMEOUT_MS = 20_000, EXCLUDE_MAX = 64 << 10;
const MODEL = /^[a-z][a-z0-9.-]{0,39}$/, CLUSTER = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/, NAME = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}$/;

/** One row of `claude-usage --json --cached`: percentages left, resets and readings in epoch seconds, null when unknown. */
export type Row = { account: string; email: string; session_left_pct: number | null; session_window: string; week_left_pct: number | null;
  premium_model: string; premium_left_pct: number | null; observed_at: number | null; session_resets_at: number | null;
  week_resets_at: number | null; premium_resets_at: number | null; note: string };
export type Account = { key: string; label: string };
export type Slot = { cluster: string; pass: number; key: string | null };

const num = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const came = (reset: unknown, now: number) => num(reset) && reset <= now;
export const isFable = (model: string) => /fable/i.test(model);
const age = (s: number) => (s < 5400 ? `${Math.max(0, Math.round(s / 60))} min` : `${Math.round(s / 3600)} h`);
const and = (l: string[]) => (l.length < 2 ? l.join("") : `${l.slice(0, -1).join(", ")} and ${l.at(-1)}`);
const STALE = "the latest reading is";

/** Why the row may not take harden work on `model` now, or null when it may. An unknown value a floor applies to fails. */
export function judge(r: Row | undefined, model: string, now: number): string | null {
  if (!r) return "no reading in the snapshot";
  if (r.note) return `claude-usage notes ${r.note}`;
  // a spent bucket stays spent until its own reset, however old the reading
  if (r.week_left_pct === 0 && !came(r.week_resets_at, now)) return "its week is spent";
  if (r.session_left_pct === 0 && !came(r.session_resets_at, now)) return "its 5-hour window is spent";
  if (!num(r.observed_at) || now - r.observed_at > FRESH_S) return `${STALE} ${num(r.observed_at) ? `${age(now - r.observed_at)} old` : "of unknown age"}`;
  if (came(r.week_resets_at, now)) return "its week reset after the latest reading";
  if (!num(r.week_left_pct)) return "its week headroom is unknown";
  if (r.week_left_pct < WEEK_FLOOR) return `${r.week_left_pct}% of the week left, under the ${WEEK_FLOOR}% floor`;
  if (r.session_window !== "none" && !came(r.session_resets_at, now)) {
    if (!num(r.session_left_pct)) return "its 5-hour window headroom is unknown";
    if (r.session_left_pct < SESSION_FLOOR) return `${r.session_left_pct}% of the 5-hour window left, under the ${SESSION_FLOOR}% floor`;
  }
  if (isFable(model) && !came(r.premium_resets_at, now)) {
    if (!/^fable$/i.test(r.premium_model) || !num(r.premium_left_pct)) return "its Fable week headroom is unknown";
    if (r.premium_left_pct < WEEK_FLOOR) return `${r.premium_left_pct}% of the Fable week left, under the ${WEEK_FLOOR}% floor`;
  }
  return null;
}

export function gateLine(r: Row | undefined, model: string, now: number): { ok: boolean; line: string } {
  const why = judge(r, model, now);
  if (why !== null) {
    if (!r || why.startsWith(STALE) || why.includes("after the latest"))
      return { ok: false, line: `stop: ${r ? why : "this session's account has no reading in the snapshot"}; run claude-usage to take one` };
    return { ok: false, line: `stop: ${why}${num(r.observed_at) ? ` (read ${age(now - r.observed_at)} ago)` : ""}` };
  }
  const row = r as Row, left = [`${row.week_left_pct}% of the week`], floors = [`${WEEK_FLOOR}%`];
  let also = "";
  if (row.session_window === "none") also = "; no 5-hour window";
  else if (came(row.session_resets_at, now)) also = "; its 5-hour window renewed since the reading";
  else { left.push(`${row.session_left_pct}% of the 5-hour window`); floors.push(`${SESSION_FLOOR}%`); }
  if (isFable(model) && !came(row.premium_resets_at, now)) { left.push(`${row.premium_left_pct}% of the Fable week`); floors.push(`${WEEK_FLOOR}%`); }
  const f = floors.length === 1 ? `floor ${floors[0]}` : `floors ${and(floors)}`;
  return { ok: true, line: `ok: ${and(left)} left (${f}${also}), read ${age(now - (row.observed_at as number))} ago` };
}

/** Slots dealt round-robin, cluster-major: eligible roster accounts in the snapshot's rank order, this session's last.
 *  An account sharing an email with an excluded one, this session or one already dealt is the same account. `never`
 *  null means the exclusion list could not be read, so no other account is used. */
export function plan(o: { rows: Row[]; roster: Account[]; current: string; never: string[] | null; model: string; clusters: string[]; passes: number;
  now: number }): { slots: Slot[]; methodology: string } {
  const keyOf = (name: string) => o.roster.find((a) => a.label === name || a.key === name)?.key ?? name;
  const never = new Set((o.never ?? []).map(keyOf)), me = o.rows.find((r) => r.account === o.current), meKey = keyOf(o.current);
  const email = (r: Row | undefined) => (r && r.email !== "" && r.email !== "-" ? r.email.toLowerCase() : null);
  const barred = new Set(o.rows.filter((r) => never.has(keyOf(r.account))).map(email).filter((e) => e !== null));
  const out = (r: Row) => never.has(keyOf(r.account)) || barred.has(email(r) as string) || judge(r, o.model, o.now) !== null;
  const taken = new Set([email(me)].filter((e) => e !== null)), rotation: { key: string | null; row: Row }[] = [];
  if (o.never !== null) for (const r of o.rows) {
    const a = o.roster.find((x) => x.label === r.account), e = email(r);
    if (!a || a.key === meKey || out(r) || (e !== null && taken.has(e))) continue;
    if (e !== null) taken.add(e);
    rotation.push({ key: a.key, row: r });
  }
  const others = rotation.length;
  if (me && !out(me)) rotation.push({ key: null, row: me });
  const all = o.clusters.flatMap((cluster) => Array.from({ length: o.passes }, (_, i) => ({ cluster, pass: i + 1 })));
  const floors = and([`${WEEK_FLOOR}% of the week`, `${SESSION_FLOOR}% of a 5-hour window`, ...(isFable(o.model) ? [`${WEEK_FLOOR}% of the Fable week`] : [])]);
  if (others === 0) {
    const why = o.never === null ? "the exclusion list could not be read" : `no other roster account passed the floors (${floors}) on a reading under 2 h old`;
    return { slots: all.map((s) => ({ ...s, key: null })), methodology: `every Claude cluster agent ran in this session: ${why}.` };
  }
  const slots = all.map((s, i) => ({ ...s, key: rotation[i % rotation.length].key }));
  const used = rotation.filter((_, j) => j < slots.length), name = (j: number) => (rotation[j].key === null ? "this session" : String.fromCharCode(65 + j));
  const took = used.map((_, j) => `${name(j)} took ${slots.filter((_, i) => i % rotation.length === j).map((s) => (s.pass > 1 ? `${s.cluster} pass ${s.pass}` : s.cluster)).join(", ")}`);
  const oldest = Math.min(...used.map((m) => m.row.observed_at as number));
  return { slots, methodology: `Claude cluster agents spread over ${others} other roster account${others > 1 ? "s" : ""} (letters, not names): `
    + `${took.join("; ")}. Readings at most ${age(o.now - oldest)} old; floors ${floors}.` };
}

/** The roster from `claude-usage list`: "<label> <dir> …" per account; the ~/.claude slot ("main") is never one. */
export function roster(list: string): Account[] {
  return list.split("\n").map((l) => l.trim().split(/\s+/)).filter((w) => w.length >= 2)
    .map(([label, dir]) => ({ label, key: dir.replace(/.*\//, "") }))
    .filter((a) => a.label !== "main" && a.key !== "main" && NAME.test(a.label) && NAME.test(a.key));
}

const cu = (args: string[], model: string): string | null => {
  const r = Bun.spawnSync(["claude-usage", ...args], { env: { ...process.env, CLAUDE_USAGE_MODEL: model }, stdin: "ignore", timeout: CU_TIMEOUT_MS });
  return r.exitCode === 0 ? r.stdout.toString() : null;
};
function rows(model: string): Row[] | null {
  const out = cu(["--json", "--cached"], model);
  try { const v = out === null ? null : JSON.parse(out); return Array.isArray(v) ? v.filter((r) => typeof r?.account === "string") : null; } catch { return null; }
}
// non-blocking and bounded, so a FIFO or a huge file at that path reads as unreadable
function neverList(file: string): string[] | null {
  try {
    const fd = openSync(file, constants.O_RDONLY | constants.O_NONBLOCK);
    try {
      if (!fstatSync(fd).isFile()) return null;
      const b = Buffer.alloc(EXCLUDE_MAX + 1), n = readSync(fd, b, 0, EXCLUDE_MAX + 1, null);
      const v = n > EXCLUDE_MAX ? null : JSON.parse(b.subarray(0, n).toString());
      return Array.isArray(v?.never) && v.never.every((x: unknown) => typeof x === "string" && NAME.test(x)) ? v.never : null;
    } finally { closeSync(fd); }
  } catch { return null; }
}

function main(argv: string[]): number {
  const usage = () => { process.stderr.write("usage: headroom.ts gate --model <alias> | fanout --model <alias> [--passes 1|2] [--exclude-from <file>] <cluster>…\n"); return 2; };
  const [op, ...a] = argv, opt: Record<string, string> = {}, pos: string[] = [];
  for (let i = 0; i < a.length; i++) {
    if (["--model", "--passes", "--exclude-from"].includes(a[i]) && i + 1 < a.length) opt[a[i]] = a[++i];
    else if (a[i].startsWith("--")) return usage();
    else pos.push(a[i]);
  }
  const model = opt["--model"] ?? "", passes = Number(opt["--passes"] ?? "1"), now = Math.floor(Date.now() / 1000);
  if (!MODEL.test(model)) return usage();
  if (op === "gate" && pos.length === 0 && !opt["--passes"] && !opt["--exclude-from"]) {
    const fix = (why: string) => { process.stdout.write(`stop: ${why}\n`); return 1; };
    if (!Bun.which("claude-usage")) return fix("claude-usage is not on PATH, so this account's headroom is unknown; install it, or say in Phase 0 to skip the headroom gate");
    const r = rows(model);
    if (r === null) return fix("claude-usage has no snapshot to read; run claude-usage once");
    const cur = cu(["current"], model)?.trim();
    if (!cur || cur === "?") return fix("claude-usage cannot tell which account this session runs on");
    const g = gateLine(r.find((x) => x.account === cur), model, now);
    process.stdout.write(`${g.line}\n`);
    return g.ok ? 0 : 1;
  }
  if (op !== "fanout" || pos.length === 0 || pos.length > 64 || new Set(pos).size !== pos.length || !pos.every((c) => CLUSTER.test(c)) || ![1, 2].includes(passes)) return usage();
  const r = Bun.which("claude-usage") ? rows(model) : null, cur = r === null ? null : cu(["current"], model)?.trim(), list = cur ? cu(["list"], model) : null;
  const never = opt["--exclude-from"] === undefined ? [] : neverList(opt["--exclude-from"]);
  const p = r === null || !cur || cur === "?" || list === null
    ? { slots: pos.flatMap((cluster) => Array.from({ length: passes }, (_, i) => ({ cluster, pass: i + 1, key: null }))),
        methodology: "every Claude cluster agent ran in this session: claude-usage had no snapshot, roster or current account to read." }
    : plan({ rows: r, roster: roster(list), current: cur, never, model, clusters: pos, passes, now });
  process.stdout.write(`${p.slots.map((s) => `${s.cluster} ${s.pass} ${s.key === null ? "session" : `=${s.key}`}`).join("\n")}\nmethodology: ${p.methodology}\n`);
  return 0;
}

if (import.meta.main) process.exitCode = main(process.argv.slice(2));
