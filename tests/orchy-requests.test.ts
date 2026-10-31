import { afterAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { answer, entry, ledgerRow, linked, misfit, screen, screenText, take, verdict } from "../skills/start-orchy/scripts/orchy/answers.ts";
import {
  add, close, type Content, CONTENT_MAX, contentBytes, FILE_MAX, list, logEntry, note, type O, type Request, type Store, specFile, stored,
} from "../skills/start-orchy/scripts/orchy/requests.ts";

const WREF = new RegExp("^(pr|issue):[1-9][0-9]{0,8}$|^page:(0|[1-9][0-9]{0,8})$|^ask:ask[0-9]{1,9}$|^lane:[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$|^other:[a-z0-9-]{1,32}$");
const T = mkdtempSync(join(tmpdir(), "orchy-requests-"));
afterAll(() => rmSync(T, { recursive: true, force: true }));
const SHOTS = join(T, "shots");
mkdirSync(SHOTS);
const shot = (body: string) => { writeFileSync(join(SHOTS, "unit.png"), body); return createHash("sha256").update(body).digest("hex"); };
const spec = (o: unknown, ref = "pr:12", raw?: string) => {
  const p = join(T, "spec.json");
  writeFileSync(p, raw ?? JSON.stringify(o));
  return specFile(p, ref, WREF, Buffer.from(SHOTS));
};
const refusal = (f: () => unknown) => { try { f(); return "accepted"; } catch (e) { return (e as Error).message; } };
let n = 0;
const store = (): Store => {
  const dir = join(T, `store-${++n}`);
  mkdirSync(join(dir, "closed"), { recursive: true });
  for (const d of ["taken", "refused", ".tmp"]) mkdirSync(join(T, `answers-${n}`, d), { recursive: true });
  return { dir: Buffer.from(dir), ans: Buffer.from(join(T, `answers-${n}`)), wref: WREF, now: "2026-10-31T10:00:00Z" };
};
const file = (s: Store, name: string) => JSON.parse(readFileSync(join(s.dir.toString(), name), "utf8")) as Request;
const plant = (s: Store, name: string, r: object) => writeFileSync(join(s.dir.toString(), name), `${JSON.stringify(r)}\n`, { mode: 0o600 });
const pick = { shape: "pick", title: "Choose the test path", blocks: ["lane:docs"],
  options: [{ id: "unit", label: "Unit tests", pictures: [{ file: "unit.png", alt: "the unit run" }] }, { id: "e2e", label: "Browser tests", consequence: "slower" }],
  recommend: { id: "unit", why: "cheaper and enough here" } };
const approve = (wording: string) => ({ shape: "approve", title: "File the cleanup issues", wording, binding: { kind: "text" } });
const sha = (s: string) => createHash("sha256").update(s).digest("hex");

describe("spec", () => {
  test("one valid spec per shape normalizes to its stored content, its hashes filled", () => {
    const h = shot("png bytes");
    const base = { context: "", steps: [], blocks: [] };
    const rows: [unknown, string, Content][] = [
      [pick, "pr:12", { shape: "pick", title: pick.title, ...base, blocks: ["lane:docs"],
        options: [{ id: "unit", label: "Unit tests", consequence: "", pictures: [{ file: "unit.png", alt: "the unit run", sha256: h }] },
          { id: "e2e", label: "Browser tests", consequence: "slower", pictures: [] }], recommend: pick.recommend }],
      [approve("File three issues:\n- one\n- two"), "other:filing", { shape: "approve", title: "File the cleanup issues", ...base,
        wording: "File three issues:\n- one\n- two", binding: { kind: "text", sha256: sha("File three issues:\n- one\n- two") } }],
      [{ shape: "done", title: "Rename the required check", steps: [{ text: "Rename it in the branch rules", command: "gh api repos/o/r/branches/dev/protection" }] },
        "pr:12", { shape: "done", title: "Rename the required check", ...base, steps: [{ text: "Rename it in the branch rules", command: "gh api repos/o/r/branches/dev/protection" }] }],
      [{ shape: "reply", title: "Which locale ships first?", context: "Two **are** ready.\nOne is `es`." }, "issue:7",
        { shape: "reply", title: "Which locale ships first?", ...base, context: "Two **are** ready.\nOne is `es`." }],
      [{ shape: "sign", title: "Sign page 3", page: 3, blocks: ["lane:docs"] }, "page:3", { shape: "sign", title: "Sign page 3", ...base, blocks: ["lane:docs"], page: 3 }],
    ];
    for (const [s, ref, want] of rows) expect(spec(s, ref)).toEqual(want);
  });

  test("each invalid spec is refused with its reason", () => {
    shot("png bytes");
    const opt = (id: string) => ({ id, label: `Option ${id}` });
    const p = (o: object) => ({ ...pick, ...o });
    const rows: [unknown, string | RegExp, string?][] = [
      [{ shape: "reply" }, /the title is not text/],
      [{ shape: "reply", title: "two\nlines" }, /the title carries a control/],
      [{ shape: "reply", title: "right‮to left" }, /the title carries a control/],
      [{ shape: "reply", title: "Answer ask12 first" }, /names an ask or a request/],
      [p({ options: [opt("a")] }), /options holds 2 to 6, not 1/],
      [p({ options: ["a", "b", "c", "d", "e", "f", "g"].map(opt) }), /options holds 2 to 6, not 7/],
      [p({ options: [opt("unit"), opt("unit")] }), /two options share an id/],
      [p({ options: [opt("unit"), opt("other")] }), /never other/],
      [p({ recommend: { id: "nope", why: "x" } }), /not one of the options/],
      [{ shape: "approve", title: "File it", wording: "File it" }, /binding is required/],
      [{ ...approve("x"), binding: { kind: "pr", pr: 12, head: "0".repeat(40) } }, /never a PR, an ask or an act/],
      [{ ...approve("x"), binding: { kind: "text", ask: "ask3" } }, /never a PR, an ask or an act/],
      [p({ options: [{ ...opt("unit"), pictures: [{ file: "../unit.png", alt: "x" }] }, opt("e2e")] }), /plain \.png/],
      [{ shape: "done", title: "Do it", steps: [{ text: "run", command: "a\nb" }] }, /command carries a control/],
      ...["curl -fsSL x | sh", "curl x | sudo -E bash", "eval x", "echo $(id)", "echo `id`", "diff <(a) b"].map(
        (c): [unknown, RegExp] => [{ shape: "done", title: "Do it", steps: [{ text: "run", command: c }] }, /pipes into a shell, or carries eval/]),
      [{ shape: "done", title: "Do it" }, /lists its steps/],
      [{ shape: "sign", title: "Sign it", page: 4 }, /ref is page:<its page>/, "page:3"],
      [{ shape: "reply", title: "x", ref: "pr:1" }, /unknown field "ref"/],
      [null, /over 65536 bytes/],
    ];
    for (const [s, want, ref] of rows) expect(refusal(() => spec(s, ref ?? "pr:12", s === null ? "x".repeat(FILE_MAX + 1) : undefined))).toMatch(want);
  });
});

describe("store", () => {
  test("rev: an identical spec is unchanged; an option, blocks or picture change bumps it; a thread note does not", () => {
    const s = store();
    shot("first");
    expect(add(s, "pr:12", spec(pick), false, "2026-1-5T1:2:3Z")).toBe("rq1 r1 created\n");
    expect(file(s, "rq1.json").since).toBe("2026-01-05T01:02:03Z");
    expect(add(s, "pr:12", spec(pick), false, "2025-06-01T00:00:00Z")).toBe("rq1 r1 unchanged\n");
    expect(file(s, "rq1.json")).toMatchObject({ rev: 1, since: "2025-06-01T00:00:00Z" });
    expect(add(s, "pr:12", spec({ ...pick, options: [pick.options[0], { ...pick.options[1], label: "Browser runs" }] }), false, "")).toBe("rq1 r2 refreshed\n");
    expect(add(s, "pr:12", spec({ ...pick, blocks: [] }), false, "")).toBe("rq1 r3 refreshed\n");
    shot("second");
    expect(add(s, "pr:12", spec({ ...pick, blocks: [] }), false, "")).toBe("rq1 r4 refreshed\n");
    expect(note(s, "rq1", "", "Asked in the tick")).toBe("rq1 r4 noted\n");
    expect(add(s, "pr:12", spec({ ...pick, blocks: [] }), false, "")).toBe("rq1 r4 unchanged\n");
    expect(file(s, "rq1.json")).toMatchObject({ rev: 4, since: "2025-06-01T00:00:00Z", thread: [{ at: s.now, text: "Asked in the tick" }] });
  });

  test("size: a maximal log entry is at most 200 bytes, and the largest request the caps allow fits in 64 KiB", () => {
    const e = { id: "rq999999999.99", rev: 999999999, kind: "approve", go: false, state: "refused", reason: "withdrawn", withheld: "secret", ask: "ask999999999", at: "2026-10-31T10:00:00Z" };
    expect(logEntry(e, "rq999999999")).toEqual(e as never);
    expect(Buffer.byteLength(JSON.stringify(e))).toBeLessThanOrEqual(200);
    const s = store(), big = "😀".repeat(800);
    add(s, "pr:12", spec({ ...pick, context: "😀".repeat(2000) }), false, "");
    const r = file(s, "rq1.json");
    while (contentBytes({ ...r, thread: [...r.thread, { at: s.now, text: big }] }) <= CONTENT_MAX) r.thread.push({ at: s.now, text: big });
    let k = 800;
    while (k > 0 && contentBytes({ ...r, thread: [...r.thread, { at: s.now, text: "x".repeat(k) }] }) > CONTENT_MAX) k--;
    if (k > 0) r.thread.push({ at: s.now, text: "x".repeat(k) });
    expect(contentBytes(r)).toBeGreaterThan(CONTENT_MAX - 64);
    const max = { ...r, id: "rq999999999", rev: 999999999, status: "withdrawn", outcome: "😀".repeat(300), taken: { answer: "rq999999999.99", at: s.now },
      thread: [...r.thread, { at: s.now, re: "rq999999999.99", text: big }],
      answers: Array.from({ length: 99 }, (_, i) => ({ ...e, id: `rq999999999.${i + 1}` })) };
    expect(stored(JSON.parse(JSON.stringify(max)), "rq999999999", WREF).answers).toHaveLength(99);
    expect(Buffer.byteLength(`${JSON.stringify(max)}\n`)).toBeLessThan(FILE_MAX);
    plant(s, "rq1.json", r);
    expect(refusal(() => note(s, "rq1", "", "one more"))).toMatch(/rq1 is full/);
  });

  test("list: a malformed file is isolated in errors, and closed requests show only with --all", () => {
    const s = store();
    shot("png bytes");
    add(s, "pr:12", spec(pick), false, "");
    add(s, "issue:7", spec({ shape: "reply", title: "Which locale ships first?" }), false, "");
    expect(close(s, "rq2", "withdrawn", "asked in chat instead")).toBe("rq2 withdrawn issue:7\n");
    plant(s, "rq3.json", { schema: "orchy.request/1", id: "rq3" });
    writeFileSync(join(s.dir.toString(), "rq4.json"), "{not json");
    plant(s, "rq5.json", { ...file(s, "rq1.json"), id: "rq5", since: "2026-10-31T10:00:00Z \u001b[31m" });
    const open = list(s, false);
    expect(open.requests.map((r) => [r.id, r.status, r.age_s, r.unanswered])).toEqual([["rq1", "open", 0, []]]);
    expect(open.errors).toEqual([{ file: "rq3.json", error: "its ref is not text" }, { file: "rq4.json", error: "not JSON" },
      { file: "rq5.json", error: "its since is not a UTC time" }]);
    expect(list(s, true).requests.map((r) => [r.id, r.status, r.outcome])).toEqual([["rq1", "open", undefined], ["rq2", "withdrawn", "asked in chat instead"]]);
  });

  test("not now: a new request on a ref last answered Not now on the same binding is refused; a new binding or --again passes", () => {
    const planted = () => {
      const s = store();
      add(s, "other:filing", spec(approve("File the three cleanup issues"), "other:filing"), false, "");
      const r = file(s, "rq1.json");
      plant(s, "closed/rq1.json", { ...r, status: "done", outcome: "not now", answers: [{ id: "rq1.1", rev: 1, kind: "approve", go: false, state: "taken", at: s.now }] });
      rmSync(join(s.dir.toString(), "rq1.json"));
      return s;
    };
    const same = () => spec(approve("File the three cleanup issues"), "other:filing");
    expect(refusal(() => add(planted(), "other:filing", same(), false, ""))).toMatch(/answered not now on this binding/);
    expect(add(planted(), "other:filing", spec(approve("File the two cleanup issues"), "other:filing"), false, "")).toBe("rq2 r1 created\n");
    expect(add(planted(), "other:filing", same(), true, "")).toBe("rq2 r1 created\n");
  });

  test("a taken reply blocks a content change and a close until a note answers it", () => {
    const s = store();
    add(s, "issue:7", spec({ shape: "reply", title: "Which locale ships first?" }, "issue:7"), false, "");
    plant(s, "rq1.json", { ...file(s, "rq1.json"), answers: [{ id: "rq1.1", rev: 1, kind: "reply", state: "taken", at: s.now }] });
    expect(list(s, false).requests[0].unanswered).toEqual(["rq1.1"]);
    expect(refusal(() => add(s, "issue:7", spec({ shape: "reply", title: "Which locale ships next?" }, "issue:7"), false, ""))).toMatch(/--re rq1\.1 first/);
    expect(refusal(() => close(s, "rq1", "done", "answered"))).toMatch(/--re rq1\.1 first/);
    expect(refusal(() => note(s, "rq1", "rq1.2", "no such reply"))).toMatch(/not a taken reply of rq1/);
    expect(note(s, "rq1", "rq1.1", "Spanish first; it is ready")).toBe("rq1 r1 noted\n");
    expect(refusal(() => note(s, "rq1", "rq1.1", "twice"))).toMatch(/not a taken reply of rq1/);
    expect(close(s, "rq1", "done", "answered")).toBe("rq1 done issue:7\n");
    expect(file(s, "closed/rq1.json")).toMatchObject({ status: "done", outcome: "answered", thread: [{ re: "rq1.1" }] });
  });
});

describe("answers", () => {
  const GL = join(import.meta.dir, "mocks/orchy/fake-gitleaks"), at = "2026-10-31T10:00:00Z", B = sha("File three issues");
  const done = { shape: "done", title: "Rename the required check", steps: [{ text: "Rename it in the branch rules" }] };
  // rq1 pick on ask:ask1, rq2 approve, rq3 done blocking ask:ask2, rq4 reply, rq5 sign
  const five = () => {
    const s = store();
    shot("png bytes");
    for (const [ref, c] of [["ask:ask1", pick], ["other:filing", approve("File three issues")], ["pr:12", { ...done, blocks: ["ask:ask2"] }],
      ["issue:7", { shape: "reply", title: "Which locale ships first?" }], ["page:3", { shape: "sign", title: "Sign page 3", page: 3 }]] as const)
      add(s, ref, spec(c, ref), false, "");
    return s;
  };
  const r = (s: Store, id: string) => file(s, `${id}.json`);
  const a = (id: string, o: object): O => ({ schema: "orchy.answer/1", id, request: id.split(".")[0], rev: 1, at, ...o });
  const inbox = (s: Store, o: O) => {
    const b = `${JSON.stringify(o)}\n`;
    writeFileSync(join(s.ans.toString(), `${o.id}.json`), b, { mode: 0o600 });
    return sha(b);
  };

  test("validation: one answer per kind, a reply for every shape, and each invalid one refused", () => {
    const s = five();
    const fits: [O, string][] = [[a("rq1.1", { kind: "pick", choice: "unit", note: "fine" }), "rq1"], [a("rq1.1", { kind: "pick", choice: "other", text: "the smoke" }), "rq1"],
      [a("rq2.1", { kind: "approve", go: true, binding: { kind: "text", sha256: B } }), "rq2"], [a("rq2.1", { kind: "approve", go: false, note: "not now" }), "rq2"],
      [a("rq3.1", { kind: "done", note: "renamed", log: "e2e\tok\nlint\tok" }), "rq3"],
      ...["rq1", "rq2", "rq3", "rq4", "rq5"].map((id): [O, string] => [a(`${id}.1`, { kind: "reply", text: "why?" }), id])];
    for (const [o, id] of fits) expect(misfit(answer(o, o.id as string), r(s, id))).toBeNull();
    const bad: [O, RegExp][] = [[a("rq5.1", { kind: "sign" }), /sign answer is refused/], [a("rq4.1", { kind: "question", text: "x" }), /kind is pick/],
      [a("rq1.1", { kind: "pick", choice: "other" }), /other text is not text/], [a("rq4.1", { kind: "reply", text: "a \u202e turn" }), /bidi/],
      [a("rq4.2", { kind: "reply", text: "x" }), /not its file's name/], [a("rq4.1", { kind: "reply", text: "x", why: 1 }), /unknown field/],
      [a("rq2.1", { kind: "approve", go: false, binding: { kind: "text", sha256: B } }), /not now carries no binding/]];
    for (const [o, re] of bad) expect(refusal(() => answer(o, o.id === "rq4.2" ? "rq4.1" : (o.id as string)))).toMatch(re);
    const other = a("rq2.1", { kind: "approve", go: true, binding: { kind: "text", sha256: sha("other words") } });
    expect(misfit(answer(other, "rq2.1"), r(s, "rq2"))).toMatch(/binding is not rq2's/);
    expect(misfit(answer(a("rq1.1", { kind: "done" }), "rq1.1"), r(s, "rq1"))).toMatch(/does not fit a pick request/);
    expect(misfit(answer(a("rq1.1", { kind: "pick", choice: "lint" }), "rq1.1"), r(s, "rq1"))).toMatch(/not one of rq1's options/);
  });

  test("routing: text and note reach the ledger and a log stays; the ask is the ref's, else the first block's, else none", () => {
    const s = five(), asks = new Set(["ask1", "ask2"]);
    expect([linked(r(s, "rq1"), asks), linked(r(s, "rq3"), asks), linked(r(s, "rq1"), new Set(["ask2"])), linked(r(s, "rq4"), asks)]).toEqual(["ask1", "ask2", "", ""]);
    expect(ledgerRow(a("rq1.1", { kind: "pick", choice: "other", text: "the smoke", note: "today" }), "rq1.1", r(s, "rq1"), asks, at))
      .toEqual({ id: "ask1", at, said: "the smoke\ntoday", answer: "rq1.1" });
    expect(ledgerRow(a("rq3.1", { kind: "done", note: "renamed", log: "e2e\tok" }), "rq3.1", r(s, "rq3"), asks, at)).toEqual({ id: "ask2", at, said: "renamed", answer: "rq3.1" });
    expect(ledgerRow(a("rq3.1", { kind: "done", log: "e2e\tok" }), "rq3.1", r(s, "rq3"), asks, at)).toBeNull();
    // gitleaks reads the free text and any value no grammar vouches for, never a valid binding or choice
    expect(screenText(a("rq2.1", { kind: "approve", go: true, binding: { kind: "text", sha256: B }, note: "ok" }))).toBe("ok");
    expect(screenText(a("rq1.1", { kind: "pick", choice: "AKIA-x", extra: { k: 1 } }))).toBe('AKIA-x\nextra\n{"k":1}');
    expect(screenText(JSON.parse('{"kind": "pick", "constructor": "c1", "__proto__": "p1"}'))).toBe("constructor\nc1\n__proto__\np1");
    // a current reply is taken and a pick for a past rev refused, and both file their text on no ask
    inbox(s, a("rq4.1", { kind: "reply", text: "Spanish" }));
    inbox(s, a("rq4.2", { kind: "pick", rev: 9, choice: "unit", note: "stale words" }));
    const ledger = Buffer.from(join(T, "ledger.jsonl"));
    expect([screen(s, GL, "rq4.1", ledger, at).row, screen(s, GL, "rq4.2", ledger, at).row])
      .toEqual([{ at, answer: "rq4.1", text: "Spanish" }, { at, answer: "rq4.2", text: "stale words" }]);
  });

  test("take: stale before invalid, replies at any rev, a withheld file first, a recovery's first outcome, valid fields only", () => {
    const s = five(), v = (o: O, id: string, over: Partial<Request> = {}, closed = false) => {
      const x = verdict(o, o.id as string, { ...r(s, id), ...over }, closed);
      return x.reason ?? x.state;
    };
    const p1 = a("rq1.1", { kind: "pick", choice: "unit" }), reply = a("rq1.2", { kind: "reply", text: "why?" });
    add(s, "ask:ask1", spec(approve("Use the unit tests"), "ask:ask1"), false, "");
    expect([v(p1, "rq1"), v({ ...p1, rev: 2 }, "rq1", { status: "taken" }), v({ ...p1, rev: 2 }, "rq1", { status: "stale" })]).toEqual(["stale", "stale", "stale"]);
    expect([v(reply, "rq1"), v(reply, "rq1", { status: "stale" }), v(reply, "rq1", { status: "taken" }), v(reply, "rq1", {}, true)]).toEqual(["taken", "taken", "taken", "closed"]);
    const held = a("rq1.1", { kind: "pick", choice: "unit", note: null, withheld: "secret" });
    expect([v(held, "rq1"), v(held, "rq1", {}, true)]).toEqual(["invalid", "invalid"]);
    expect(verdict(held, "rq1.1", null, false)).toMatchObject({ withheld: "secret" });
    const bad = a("rq4.1", { kind: "nod", rev: "1", go: "yes" });
    expect(v(bad, "rq4")).toBe("invalid");
    expect(entry(bad, "rq4.1", verdict(bad, "rq4.1", r(s, "rq4"), false), "", at)).toEqual({ id: "rq4.1", state: "refused", at, reason: "invalid" });
    const sh = inbox(s, a("rq4.1", { kind: "reply", text: "Spanish" }));
    const first = take(s, GL, "rq4.1", sh, false, "", "");
    expect([first.code, first.out.verdict, r(s, "rq4").answers.length]).toEqual([0, "taken", 1]);
    // a replay of the archived bytes is a recovery that removes it; other bytes under the settled id are refused, both kept
    const ledger = Buffer.from(join(T, "ledger.jsonl"));
    const same = inbox(s, a("rq4.1", { kind: "reply", text: "Spanish" }));
    expect(take(s, GL, "rq4.1", same, false, "", "")).toMatchObject({ code: 0, out: { verdict: "taken", recovered: true, answer: { text: "Spanish" } } });
    const other = inbox(s, a("rq4.1", { kind: "reply", text: "French" }));
    expect([screen(s, GL, "rq4.1", ledger, at).row, refusal(() => take(s, GL, "rq4.1", other, false, "", ""))]).toEqual([null, expect.stringMatching(/different files/)]);
    rmSync(join(s.ans.toString(), "rq4.1.json"));
    // a fresh take replaces what a deposit left in the archive under its name, and prints what it verified
    writeFileSync(join(s.ans.toString(), "refused", "rq4.5.json"), JSON.stringify(a("rq4.5", { kind: "reply", text: "forged" })));
    const s5 = inbox(s, a("rq4.5", { kind: "reply", text: "real" }));
    expect(take(s, GL, "rq4.5", s5, false, "", "").out).toMatchObject({ reason: "invalid", answer: { text: "real" } });
    expect(JSON.parse(readFileSync(join(s.ans.toString(), "refused", "rq4.5.json"), "utf8")).text).toBe("real");
    const st = inbox(s, a("rq1.3", { kind: "pick", choice: "unit" }));
    expect(take(s, GL, "rq1.3", st, false, "", "")).toMatchObject({ code: 4, out: { verdict: "refused", reason: "stale" } });
    rmSync(join(s.ans.toString(), "refused", "rq1.3.json"));
    expect(take(s, GL, "rq1.3", inbox(s, a("rq1.3", { kind: "pick", choice: "unit", rev: 2 })), false, "", "")).toMatchObject({ code: 4, out: { reason: "stale", recovered: true } });
    expect([r(s, "rq1").status, r(s, "rq1").answers.length, r(s, "rq4").answers.length]).toEqual(["open", 1, 2]);
    // a file that is no JSON object is archived as its stub, never as its bytes, a secret among them or not
    for (const [id, raw] of [["rq4.6", "not json"], ["rq4.7", `{"text": "AKIA${"Q".repeat(16)}"`]]) {
      writeFileSync(join(s.ans.toString(), `${id}.json`), raw);
      const x = screen(s, GL, id, ledger, at), y = take(s, GL, id, x.sha as string, x.flagged as boolean, "", "");
      expect([y.code, readFileSync(join(s.ans.toString(), "refused", `${id}.json`), "utf8").includes(raw.slice(0, 8))]).toEqual([1, false]);
    }
    // a secret dropped straight into refused/, which no take ever redacted, is withheld from the output too
    writeFileSync(join(s.ans.toString(), "refused", "rq99.1.json"), JSON.stringify(a("rq99.1", { kind: "reply", text: `the token is AKIA${"Q".repeat(16)}` })));
    const sc = screen(s, GL, "rq99.1", ledger, at);
    expect(take(s, GL, "rq99.1", "", sc.flagged as boolean, "", "").out).toMatchObject({ recovered: true, answer: { text: null, withheld: "secret" } });
  });
});
