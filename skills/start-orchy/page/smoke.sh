#!/usr/bin/env bash
# Smoke test of the page toolchain on fixtures/, in a throwaway ORCHY_HOME. Exits non-zero on the first failure.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# ORCHY_SMOKE_TMP moves the scratch dir without moving Chrome's TMPDIR, whose socket path must stay short.
T=$(mktemp -d "${ORCHY_SMOKE_TMP:-${TMPDIR:-/tmp}}/orchy-page-smoke.XXXXXX"); trap 'rm -rf "$T"' EXIT
export ORCHY_HOME="$T/home"; unset ORCHY_PAGE_BUILD DROP_PAGES UNSIGNED
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
ok "add-page.py refuses a re-added page, a bad option suffix and a banned caption"

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
ok "apply --apply: marker block below the original body, lane label, receipts, idempotent"

# a choice changed after signing is held, never written; an except note holds the page; a sensitive result holds everything
cp -r "$P/answers" "$T/ans2"; jq '.choice="A"' "$T/ans2/decisions/choice-P1-01.json" > "$T/c.json" && mv "$T/c.json" "$T/ans2/decisions/choice-P1-01.json"
PATH="$T/bin:$PATH" bun "$HERE/apply-decisions.ts" --answers "$T/ans2" > "$T/apply4.out" 2>&1 || fail "apply with a changed choice"
grep -q 'P1-01 changed after page 1 was signed (signed B, now A)' "$T/apply4.out" || fail "a changed choice was not held: $(cat "$T/apply4.out")"
grep -q 'Option A' "$P/apply-preview/1.md" && fail "the changed choice reached the preview"
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
