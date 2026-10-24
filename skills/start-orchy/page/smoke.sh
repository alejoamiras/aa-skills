#!/usr/bin/env bash
# Smoke test of the page toolchain on fixtures/, in a throwaway ORCHY_HOME. Exits non-zero on the first failure.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# ORCHY_SMOKE_TMP moves the scratch dir without moving Chrome's TMPDIR, whose socket path must stay short.
T=$(mktemp -d "${ORCHY_SMOKE_TMP:-${TMPDIR:-/tmp}}/orchy-page-smoke.XXXXXX"); trap 'rm -rf "$T"' EXIT
export ORCHY_HOME="$T/home" ORCHY_PROFILE_DIR="$T/profile"; unset ORCHY_PAGE_BUILD DROP_PAGES UNSIGNED
P="$ORCHY_HOME/page"; B="$P/build"
mkdir -p "$P" "$T/bin"; cp -R "$HERE/fixtures/." "$P/"
# A dry-run must never reach GitHub: this gh records the call and fails.
printf '#!/bin/sh\necho "$@" >> "%s/gh-called"\nexit 1\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"
ok() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }
for t in node python3 bun; do command -v "$t" >/dev/null || fail "$t is not on PATH"; done

node --check "$HERE/page.js" && ok "node --check page.js"
node --check "$HERE/render-check.cjs" && ok "node --check render-check.cjs"

python3 -I "$HERE/gen.py" 2> "$T/gen.err" || { cat "$T/gen.err" >&2; fail "gen.py"; }
[ -s "$B/decisions.html" ] || fail "gen.py wrote no decisions.html"
for f in px-light.png px-dark.png; do [ -f "$B/shots/$f" ] || fail "gen.py did not copy shots/$f"; done
grep -q '"shots/px-light.png"' "$B/files.json" || fail "files.json lacks the copied shots"
grep -q '<title>App Backlog Decisions</title>' "$B/decisions.html" || fail "title not taken from site"
ok "gen.py: $(tail -1 "$T/gen.err")"

python3 -I "$HERE/check-brief.py" > "$T/brief.out" || { cat "$T/brief.out" >&2; fail "check-brief.py"; }
grep -q '^OK: 2 records, 1 pages' "$T/brief.out" || fail "check-brief.py: $(cat "$T/brief.out")"
ok "check-brief.py: $(cat "$T/brief.out")"

python3 -I "$HERE/add-page.py" "$HERE/fixtures/page-2.json" > "$T/add.out" || fail "add-page.py page 2"
ok "add-page.py: $(cat "$T/add.out")"
ls "$P"/decisions.json.bak-p2-* "$P"/shots/manifest.json.bak-p2-* >/dev/null || fail "add-page.py made no backups"
jq -e '.pages[] | select(.no == 2) | .added_at | fromdateiso8601' "$P/decisions.json" >/dev/null || fail "add-page.py did not stamp added_at"
sum=$(cksum < "$P/decisions.json")
if python3 -I "$HERE/add-page.py" "$HERE/fixtures/page-2.json" 2> "$T/re.err"; then fail "add-page.py re-added page 2"; fi
grep -q 'exists already' "$T/re.err" || fail "re-add refused for the wrong reason: $(cat "$T/re.err")"
python3 -I - "$HERE/fixtures/page-2.json" "$T/bad.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["page"]["no"] = 3; r = s["records"][0]; r["id"] = "P3-01"; r["page_no"] = 3
r["shots"][1]["id"] = "p3-01-x"; s["manifest_rows"] = [dict(s["manifest_rows"][0], id="p3-01-a", records=["P3-01"], caption="A bug in the list.")]
json.dump(s, open(sys.argv[2], "w"))
PY
if python3 -I "$HERE/add-page.py" "$T/bad.json" 2> "$T/bad.err"; then fail "add-page.py accepted a bad spec"; fi
if ! { grep -q 'must end with -<option key>' "$T/bad.err" && grep -q 'is banned' "$T/bad.err"; }; then fail "bad spec refused for the wrong reason: $(cat "$T/bad.err")"; fi
[ "$(cksum < "$P/decisions.json")" = "$sum" ] || fail "a refused add-page.py changed decisions.json"
jq '.records[0].category="vibes"' "$HERE/fixtures/page-2.json" | jq '.page.no=9 | .records[0].id="P9-01" | .records[0].page_no=9 | .records |= .[:1] | .manifest_rows=[]' > "$T/cat.json"
if python3 -I "$HERE/add-page.py" "$T/cat.json" 2> "$T/cat.err"; then fail "add-page.py accepted an unknown category"; fi
grep -q 'category must be one of' "$T/cat.err" || fail "unknown category not named: $(cat "$T/cat.err")"
ok "add-page.py refuses a re-added page, a bad option suffix, a banned caption and an unknown category"

python3 -I "$HERE/gen.py" 2> "$T/gen.err" || { cat "$T/gen.err" >&2; fail "gen.py after add-page"; }
grep -q '"no": 2, "name": "Settings list"' "$B/decisions.html" || fail "page 2 missing from the build"
ok "gen.py again: $(tail -1 "$T/gen.err")"
DROP_PAGES=1 python3 -I "$HERE/gen.py" 2>/dev/null; [ "$(cat "$B/_drop-files.json")" = "[]" ] || fail "DROP_PAGES=1 dropped files page 2 still shows"
DROP_PAGES=1,2 python3 -I "$HERE/gen.py" 2>/dev/null; grep -q 'shots/px-light.png' "$B/_drop-files.json" || fail "DROP_PAGES=1,2 kept the files"
python3 -I "$HERE/gen.py" 2>/dev/null
ok "DROP_PAGES keeps files a kept row shows"
mkdir -p "$T/nosite/page"; python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("site"); json.dump(d, open(sys.argv[2], "w"))' "$P/decisions.json" "$T/nosite/page/decisions.json"
if ORCHY_HOME="$T/nosite" python3 -I "$HERE/gen.py" 2> "$T/nosite.err"; then fail "gen.py built without site"; fi
grep -q 'has no "site" object' "$T/nosite.err" || fail "gen.py without site: $(cat "$T/nosite.err")"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["records"][0]["id"]="P1-01\"x"; json.dump(d, open(sys.argv[2], "w"))' "$P/decisions.json" "$T/nosite/page/decisions.json"
if ORCHY_HOME="$T/nosite" python3 -I "$HERE/gen.py" 2> "$T/nosite.err"; then fail "gen.py built an unsafe id"; fi
grep -q 'cannot render safely' "$T/nosite.err" || fail "gen.py with an unsafe id: $(cat "$T/nosite.err")"
ok "gen.py refuses a decisions.json without site, or with an unsafe id"

PATH="$T/bin:$PATH" bun "$HERE/apply-decisions.ts" --answers "$P/answers" > "$T/apply.out" 2>&1 || { cat "$T/apply.out" >&2; fail "apply-decisions.ts dry-run"; }
grep -q '^dry-run: pages signed 1; issues 2; written 0; skipped 0' "$T/apply.out" || fail "apply: $(head -3 "$T/apply.out")"
[ ! -e "$T/gh-called" ] || fail "dry-run called gh: $(cat "$T/gh-called")"
[ ! -e "$P/apply-receipts.json" ] || fail "dry-run wrote receipts"
V="$P/apply-preview"
if ! { grep -q '^<!-- orchy:decision -->$' "$V/1.md" && grep -q '\*\*Option B\*\*. The title and the date share one line.' "$V/1.md"; }; then fail "preview 1: $(cat "$V/1.md")"; fi
if ! { grep -q '^Lane .home-1., arc-1 (home screen polish); wave 1.$' "$V/1.md" && grep -q '^- P1-01: the header pick sets the layout$' "$V/1.md"; }; then fail "pickup 1: $(cat "$V/1.md")"; fi
grep -qF 'Gates before the PR opens: `tests/e2e/home.spec.ts`; a visible change ships with its after shot in the PR.' "$V/1.md" || fail "pickup gates: $(cat "$V/1.md")"
grep -q '\*\*approved\*\*' "$V/2.md" || fail "preview 2: $(cat "$V/2.md")"
if grep -q 'Owner note' "$V/1.md"; then fail "an empty note leaked into preview 1"; fi
cp "$V/1.md" "$T/1.first"; PATH="$T/bin:$PATH" bun "$HERE/apply-decisions.ts" --answers "$P/answers/decisions" > /dev/null 2>&1 || fail "apply with the export dir itself"
if ! { cmp -s "$V/1.md" "$T/1.first" && [ ! -e "$T/gh-called" ]; }; then fail "export dir and its parent give different previews"; fi
ok "apply-decisions.ts dry-run: $(head -1 "$T/apply.out" | sed 's/; previews in .*//'), no gh call"

# --apply against a gh stub that keeps issues as files: the block lands below the marker, the lane label is added, receipts are written
G="$T/bin-apply"; mkdir -p "$G" "$T/issues"; export ISSUES="$T/issues"
cat > "$G/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$ISSUES/gh.log"
case "$1 $2" in
"issue view") n=$3; f="$ISSUES/$n.json"; [ -f "$f" ] || printf '{"body":"Original body of #%s.","labels":[{"name":"owner-decision"}],"state":"OPEN"}' "$n" > "$f"; cat "$f";;
"issue edit") n=$3; f="$ISSUES/$n.json"; body=""; labels=$(jq -c '.labels' "$f"); shift 3
  while [ $# -gt 0 ]; do case "$1" in --body-file) body=$(cat "$2"); shift;; --add-label) labels=$(jq -c --arg l "$2" '. + [{name:$l}]' <<<"$labels"); shift;; --remove-label) labels=$(jq -c --arg l "$2" 'map(select(.name!=$l))' <<<"$labels"); shift;; esac; shift; done
  jq -n --arg b "$body" --argjson l "$labels" --arg st "$(jq -r .state "$f")" '{body:$b,labels:$l,state:$st}' > "$f";;
"label create") exit 0;;
*) echo "stub gh: $*" >&2; exit 1;;
esac
GH
chmod +x "$G/gh"
cp -r "$P/answers" "$T/ans1"
PATH="$G:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans1" --apply > "$T/apply2.out" 2>&1 || { cat "$T/apply2.out" >&2; fail "apply --apply"; }
grep -q '^applied: pages signed 1; issues 2; written 2; skipped 0' "$T/apply2.out" || fail "apply --apply: $(head -3 "$T/apply2.out")"
jq -r .body "$T/issues/1.json" | grep -q '^Original body of #1.$' || fail "apply lost the original body"
jq -r .body "$T/issues/1.json" | grep -q '^<!-- orchy:decision -->$' || fail "apply wrote no marker"
jq -r '[.labels[].name]|join(",")' "$T/issues/1.json" | grep -q 'lane:home-1' || fail "apply added no lane label"
jq -r '[.labels[].name]|join(",")' "$T/issues/1.json" | grep -q 'owner-decision' && fail "apply kept the owner-decision label"
jq -e '."1".lane=="home-1"' "$P/apply-receipts.json" >/dev/null || fail "no receipt for #1"
PATH="$G:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans1" --apply > "$T/apply3.out" 2>&1 || fail "second apply"
grep -q 'written 0; skipped 2' "$T/apply3.out" || fail "second apply rewrote unchanged blocks: $(head -1 "$T/apply3.out")"
R="$ORCHY_PROFILE_DIR/example-app.jsonl"
[ "$(wc -l < "$R")" = 2 ] || fail "two applies did not leave one owner-record row per record: $(cat "$R")"
jq -se 'map({(.record): [.chosen, .agreed, .explicit, .via_recommend_all]}) | add == {"P1-01": ["B", true, true, false], "P1-02": ["approve", true, false, false]}' "$R" >/dev/null || fail "owner-record rows: $(cat "$R")"
ok "apply --apply: marker block below the original body, lane label, receipts, idempotent, one owner-record row per record"
# take-all provenance is the signoff's, not the live doc's; a torn last line in the owner record swallows no row
cp -r "$P/answers" "$T/ans10"; jq '.taken_all=["P1-01"]' "$T/ans10/decisions/signoff-P1.json" > "$T/c.json" && mv "$T/c.json" "$T/ans10/decisions/signoff-P1.json"
mkdir -p "$T/prof2"; printf '{"record":"torn"' > "$T/prof2/example-app.jsonl"
ORCHY_PROFILE_DIR="$T/prof2" PATH="$G:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans10" --apply > /dev/null 2>&1 || fail "apply with taken_all"
jq -Rr 'fromjson? | select(.record == "P1-01") | .via_recommend_all' "$T/prof2/example-app.jsonl" | grep -qx true || fail "take-all not read from the signoff, or the torn line ate the row: $(cat "$T/prof2/example-app.jsonl")"
ok "take-all provenance from the signoff; a torn owner-record line keeps the next row"
# scan.leak and prompt_ban hold free text bound for a public issue, with grep -E's own semantics (per line, POSIX classes)
echo '{"scan":{"leak":"/m[n]t/[a-z]"}}' > "$ORCHY_HOME/orchy.json"; echo '{"prompt_ban":"^acct-z([[:space:]]|$)"}' > "$ORCHY_HOME/local.json"; cp -r "$P/answers" "$T/ans11"
jq --arg n "see /m""nt/x for the file" '.note=$n' "$T/ans11/decisions/choice-P1-01.json" > "$T/c.json" && mv "$T/c.json" "$T/ans11/decisions/choice-P1-01.json"
jq --arg e $'Hold the footer\nacct-z' '.except=$e' "$T/ans11/decisions/signoff-P1.json" > "$T/c.json" && mv "$T/c.json" "$T/ans11/decisions/signoff-P1.json"
if PATH="$T/bin:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans11" > "$T/apply12.out" 2>&1; then fail "free text with a local path or a banned name passed"; fi
grep 'carry a local path' "$T/apply12.out" | grep -q 'P1-01.note' && grep 'carry a local path' "$T/apply12.out" | grep -q 'signoff-P1.except' || fail "leaked fields not named: $(cat "$T/apply12.out")"
rm "$ORCHY_HOME/orchy.json" "$ORCHY_HOME/local.json"
ok "free text matching scan.leak or prompt_ban is refused before anything is written"

# a choice changed after signing is held, never written; an except note holds the page; a sensitive result holds everything
cp -r "$P/answers" "$T/ans2"; jq '.choice="A"' "$T/ans2/decisions/choice-P1-01.json" > "$T/c.json" && mv "$T/c.json" "$T/ans2/decisions/choice-P1-01.json"
rm -rf "$P/apply-preview"
if PATH="$T/bin:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans2" > "$T/apply4.out" 2>&1; then fail "apply with a changed choice exited 0"; fi
grep -q 'P1-01 changed after page 1 was signed (signed B, now A)' "$T/apply4.out" || fail "a changed choice was not held: $(cat "$T/apply4.out")"
cp -r "$P/answers" "$T/ans5"; rm "$T/ans5/decisions/choice-P1-01.json"
if PATH="$T/bin:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans5" > "$T/apply4b.out" 2>&1; then fail "apply with a signed choice deleted after signing exited 0"; fi
grep -q 'P1-01 changed after page 1 was signed (signed B, now the default)' "$T/apply4b.out" || fail "a deleted signed choice was not held: $(cat "$T/apply4b.out")"
[ ! -e "$P/apply-preview/1.md" ] || fail "the held record's issue got a preview"
grep -q '#1 NOT WRITTEN' "$T/apply4.out" || fail "the held record's issue was not reported as held: $(cat "$T/apply4.out")"
# an approve record changed to "change" after signing is held, never approved by default, and its issue is not touched
cp -r "$P/answers" "$T/ans6"; jq '.choices["P1-02"]="approve"' "$T/ans6/decisions/signoff-P1.json" > "$T/c.json" && mv "$T/c.json" "$T/ans6/decisions/signoff-P1.json"
jq -n '{"__id":"choice-P1-02","page":"decisions","page_no":1,"id":"P1-02","kind":"approve","issue":[2],"choice":"change","note":"","at":"2026-01-07T10:00:00.000Z","by":"u_example"}' > "$T/ans6/decisions/choice-P1-02.json"
rm -rf "$T/issues"; mkdir -p "$T/issues"
if PATH="$G:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans6" --apply > "$T/apply8.out" 2>&1; then fail "a held approve record exited 0"; fi
grep -q 'P1-02 changed after page 1 was signed (signed approve, now change)' "$T/apply8.out" || fail "held approve not reported: $(cat "$T/apply8.out")"
[ ! -e "$T/issues/2.json" ] || fail "a held approve record's issue was written: $(jq -r .body "$T/issues/2.json")"
[ -e "$T/issues/1.json" ] || fail "the unaffected issue was not written"
jq -e 'select(.record == "P1-02")' "$R" | grep -q change && fail "a held record reached the owner record"
# a null snapshot is the signed default even when a doc appears later
cp -r "$P/answers" "$T/ans7"; jq -n '{"__id":"choice-P1-02","page":"decisions","page_no":1,"id":"P1-02","kind":"approve","issue":[2],"choice":"change","note":"later","at":"2026-01-07T10:00:00.000Z","by":"u_example"}' > "$T/ans7/decisions/choice-P1-02.json"
PATH="$T/bin:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans7" > /dev/null 2>&1 || fail "apply with a post-signing doc on a null snapshot"
grep -q '\*\*approved\*\*' "$P/apply-preview/2.md" || fail "a null snapshot did not stay the signed default: $(cat "$P/apply-preview/2.md")"
grep -q 'later' "$P/apply-preview/2.md" && fail "a note added after signing reached the preview"
cp -r "$P/answers" "$T/ans3"; jq '.except="Hold all of this page"' "$T/ans3/decisions/signoff-P1.json" > "$T/c.json" && mv "$T/c.json" "$T/ans3/decisions/signoff-P1.json"
rm -rf "$T/issues"; mkdir -p "$T/issues"
if PATH="$G:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans3" --apply > "$T/apply5.out" 2>&1; then fail "apply with an except note exited 0"; fi
grep -q 'page 1 HELD by its except note' "$T/apply5.out" || fail "except note not reported: $(cat "$T/apply5.out")"
[ ! -e "$T/issues/1.json" ] || fail "an except note did not hold the page's writes"
jq '.except_resolved=true' "$T/ans3/decisions/signoff-P1.json" > "$T/c.json" && mv "$T/c.json" "$T/ans3/decisions/signoff-P1.json"
PATH="$G:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans3" --apply > "$T/apply6.out" 2>&1 || fail "apply after except_resolved"
grep -q 'written 2' "$T/apply6.out" || fail "except_resolved did not release the page: $(head -1 "$T/apply6.out")"
cp -r "$P/answers" "$T/ans4"; jq '.recorded="the reviewer found a vulnerability here"' "$T/ans4/decisions/choice-P1-01.json" > "$T/c.json" && mv "$T/c.json" "$T/ans4/decisions/choice-P1-01.json"
if PATH="$T/bin:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans4" > "$T/apply7.out" 2>&1; then fail "a sensitive recorded field passed"; fi
grep -q 'P1-01.recorded' "$T/apply7.out" || fail "sensitive field not named: $(cat "$T/apply7.out")"
if PATH="$T/bin:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans1" --page 1 > /dev/null 2>&1; then fail "--page still accepted"; fi
ok "apply holds a post-signing change, an except note (until except_resolved) and a sensitive field; --page is refused"

# an issue shared by a held page and a signed page is not written and gets no preview, while the signed page's other issues are
cp -r "$P/answers" "$T/ans8"; jq '.except="Hold page 1"' "$T/ans8/decisions/signoff-P1.json" > "$T/c.json" && mv "$T/c.json" "$T/ans8/decisions/signoff-P1.json"
jq -n '{"__id":"choice-P2-01","page":"decisions","page_no":2,"id":"P2-01","kind":"visual","issue":[2],"choice":"B","note":"","at":"2026-01-08T10:00:00.000Z","by":"u_example"}' > "$T/ans8/decisions/choice-P2-01.json"
jq -n '{"__id":"signoff-P2","page":"decisions","page_no":2,"name":"Settings list","head":"abc1234","choices":{"P2-01":"B"},"notes":{},"except":"","changed":1,"at":"2026-01-08T10:01:00.000Z","by":"u_example"}' > "$T/ans8/decisions/signoff-P2.json"
rm -rf "$T/issues" "$P/apply-preview"; mkdir -p "$T/issues"
if PATH="$G:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans8" --apply > "$T/apply9.out" 2>&1; then fail "a shared held issue exited 0"; fi
grep -q '^applied: pages signed 2;' "$T/apply9.out" || fail "page 2 was not the only signed page: $(head -1 "$T/apply9.out")"
grep -q 'page 1 HELD by its except note' "$T/apply9.out" || fail "held page 1 not reported: $(cat "$T/apply9.out")"
grep -q '#2 NOT WRITTEN' "$T/apply9.out" || fail "the shared issue was not reported as held: $(cat "$T/apply9.out")"
[ ! -e "$P/apply-preview/2.md" ] || fail "the shared held issue got a preview from the signed page"
[ ! -e "$T/issues/2.json" ] || fail "the shared held issue was written from the signed page: $(jq -r .body "$T/issues/2.json")"
# page 0 held by its except note holds every issue its charter and no_ask items reach, even with no record on it
python3 -I - "$P/decisions.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["pages"].insert(0, {"no": 0, "name": "Program charter", "wave": 0, "lanes": [], "intro": "The program's standing rules."})
d["charter"] = [{"id": "C-01", "topic": "Merge order", "question": "One merge at a time?", "options": [{"id": "A", "text": "Yes."}, {"id": "B", "text": "No."}],
  "recommend": {"id": "A", "why": "Serial merges keep the trunk green."}, "applies_to": [1], "buttons": ["Option A", "Option B"], "writes_back": {"*": "## Decision\n\nOwner, {date}, page 0: option {option}, {option_text}\n"}}]
d["no_ask"] = [{"issue": 3, "decision": "Settled by the merge rule.", "rule": "R-01"}]
json.dump(d, open(sys.argv[1], "w"), indent=1)
PY
cp -r "$P/answers" "$T/ans9"
jq -n '{"__id":"choice-C-01","page":"decisions","page_no":0,"id":"C-01","kind":"charter","issue":[1],"choice":"A","note":"","at":"2026-01-09T10:00:00.000Z","by":"u_example"}' > "$T/ans9/decisions/choice-C-01.json"
jq -n '{"__id":"signoff-P0","page":"decisions","page_no":0,"name":"Program charter","head":"abc1234","choices":{"C-01":"A"},"notes":{},"except":"Hold the charter","changed":1,"at":"2026-01-09T10:01:00.000Z","by":"u_example"}' > "$T/ans9/decisions/signoff-P0.json"
rm -rf "$T/issues" "$P/apply-preview"; mkdir -p "$T/issues"
if PATH="$G:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans9" --apply > "$T/apply10.out" 2>&1; then fail "a held page 0 exited 0"; fi
grep -q 'page 0 HELD by its except note' "$T/apply10.out" || fail "held page 0 not reported: $(cat "$T/apply10.out")"
for n in 1 3; do grep -q "#$n NOT WRITTEN" "$T/apply10.out" || fail "issue #$n reached by held page 0 was not held: $(cat "$T/apply10.out")"; [ ! -e "$T/issues/$n.json" ] || fail "issue #$n was written under a held page 0"; [ ! -e "$P/apply-preview/$n.md" ] || fail "issue #$n got a preview under a held page 0"; done
[ -e "$T/issues/2.json" ] || fail "issue #2, untouched by page 0, was not written"
jq '.except_resolved=true' "$T/ans9/decisions/signoff-P0.json" > "$T/c.json" && mv "$T/c.json" "$T/ans9/decisions/signoff-P0.json"
PATH="$G:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans9" --apply > "$T/apply11.out" 2>&1 || fail "apply after page 0 except_resolved: $(cat "$T/apply11.out")"
grep -q 'pages signed 0,1;' "$T/apply11.out" || fail "page 0 did not release: $(head -1 "$T/apply11.out")"
jq -r .body "$T/issues/3.json" | grep -q 'Settled by the merge rule.' || fail "no_ask issue not written after release: $(jq -r .body "$T/issues/3.json")"
jq -r .body "$T/issues/1.json" | grep -q 'page 0: option A, Yes.' || fail "charter text not written after release: $(jq -r .body "$T/issues/1.json")"
ok "apply holds an issue shared with a held page, and every issue a held page 0 reaches, until released"

if [ -d "$PWD/node_modules/puppeteer" ]; then
  node "$HERE/render-check.cjs" "$B/decisions.html" > "$T/render.out" 2>&1 || fail "render-check: $(cat "$T/render.out")"
  grep -q '"items":3,"toc":2,"pages":2' "$T/render.out" || fail "render-check: $(cat "$T/render.out")"
  if grep 'PAGEERROR' "$T/render.out" | grep -vq 'claude is not defined'; then fail "page error: $(cat "$T/render.out")"; fi
  ok "render-check: $(head -1 "$T/render.out")"
else echo "skip render-check (no ./node_modules/puppeteer here)"; fi

BAN="nu""lo|pro""gram-?2|/m""nt/|/Us""ers/|/ho""me/[a-z]|wal""let|mar""tu|pro""ton|ic""loud|GzK""w77"
if grep -rniIE -- "$BAN" "$HERE" "$B/decisions.html"; then fail "forbidden strings above"; fi
ok "no forbidden strings in the sources or the build"
echo "SMOKE OK"
