import { afterAll, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  add, close, type Content, CONTENT_MAX, contentBytes, FILE_MAX, list, logEntry, note, type Request, type Store, specFile, stored,
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
  return { dir: Buffer.from(dir), wref: WREF, now: "2026-10-31T10:00:00Z" };
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
    expect(add(s, "pr:12", spec(pick), false, "")).toBe("rq1 r1 created\n");
    expect(add(s, "pr:12", spec(pick), false, "")).toBe("rq1 r1 unchanged\n");
    expect(add(s, "pr:12", spec({ ...pick, options: [pick.options[0], { ...pick.options[1], label: "Browser runs" }] }), false, "")).toBe("rq1 r2 refreshed\n");
    expect(add(s, "pr:12", spec({ ...pick, blocks: [] }), false, "")).toBe("rq1 r3 refreshed\n");
    shot("second");
    expect(add(s, "pr:12", spec({ ...pick, blocks: [] }), false, "")).toBe("rq1 r4 refreshed\n");
    expect(note(s, "rq1", "", "Asked in the tick")).toBe("rq1 r4 noted\n");
    expect(add(s, "pr:12", spec({ ...pick, blocks: [] }), false, "")).toBe("rq1 r4 unchanged\n");
    expect(file(s, "rq1.json")).toMatchObject({ rev: 4, since: s.now, thread: [{ at: s.now, text: "Asked in the tick" }] });
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
    const open = list(s, false);
    expect(open.requests.map((r) => [r.id, r.status, r.age_s, r.unanswered])).toEqual([["rq1", "open", 0, []]]);
    expect(open.errors).toEqual([{ file: "rq3.json", error: "its ref is not text" }, { file: "rq4.json", error: "not JSON" }]);
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
