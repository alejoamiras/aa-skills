#!/usr/bin/env bash
# overlap.sh <ledger> <file>...: exit 1 when a file shares six consecutive words with the owner's verbatim words (a ledger
# row's `text` or `said`), exit 2 when the ledger or a file cannot be read, else 0. It catches a copied sentence, not a
# disclosure: a private fact in fewer words, or paraphrased, passes. Runs that also occur in templates/*.md are public
# boilerplate and never count, nor do runs of text that passed check-public when it was written (the ledger's stored
# restatements and the requests beside it), so an owner's echo of either is no copy of theirs. A word is a run of bytes that are neither ASCII space nor punctuation (nor the common
# Unicode quotes, dashes and inverted marks), ASCII-lowercased, so accented and non-Latin text compares as typed.
set -u
L=${1:?usage: overlap.sh <ledger> <file>...}; shift
for f in "$@"; do [ -r "$f" ] || { echo "overlap: cannot read $f" >&2; exit 2; }; done
if [ ! -e "$L" ]; then   # absent only when the nearest existing ancestor is searchable: -e is also false behind a locked dir
  a=$L; while [ ! -e "$a" ]; do n=$(dirname -- "$a"); [ "$n" != "$a" ] || { echo "overlap: cannot tell whether $L exists" >&2; exit 2; }; a=$n; done
  [ -d "$a" ] && [ -x "$a" ] || { echo "overlap: cannot tell whether $L exists" >&2; exit 2; }; exit 0
fi
[ -r "$L" ] || { echo "overlap: cannot read $L" >&2; exit 2; }
src=$(jq -Rr 'fromjson? | (.text // empty), (.said // empty) | strings | gsub("[\r\n]+"; " ")' "$L") || { echo "overlap: cannot parse $L" >&2; exit 2; }
[ -n "$src" ] || exit 0
tpl=("$(dirname "$(realpath "$0")")"/../templates/*.md); [ -e "${tpl[0]}" ] || tpl=()
R=${L%.jsonl}.requests; rqs=(); for f in "$R"/rq*.json "$R"/closed/rq*.json; do [ -f "$f" ] && rqs+=("$f"); done
# one text per line; one the reader cannot parse only leaves its runs counted, never hides a copy
pl=$(jq -Rr 'fromjson? | .public // empty | strings | gsub("[\r\n]+"; " ")' "$L"
  [ ${#rqs[@]} = 0 ] || jq -Rr 'fromjson? | .. | strings | gsub("[\r\n]+"; " ")' "${rqs[@]}" 2>/dev/null)
# ¿ ¡ « » ‘ ’ “ ” – — … and a no-break space: separators, so a phone's curly quote matches a typed straight one
sep=$(printf '\302\277|\302\241|\302\253|\302\273|\342\200\230|\342\200\231|\342\200\234|\342\200\235|\342\200\223|\342\200\224|\342\200\246|\302\240')
LC_ALL=C awk -v sep="$sep" -v nt="${#tpl[@]}" '
function push(x) {   # the rolling six-word window of the current source
  win = (nw ? win " " x : x); if (++nw > 6) { sub(/^[^ ]+ /, "", win); nw = 6 }
  return nw == 6
}
# roles by argument position, not by counting files as they open: an empty file opens no record
BEGIN { for (i = 1; i < ARGC; i++) role[ARGV[i]] = i == 1 ? "own" : i <= 1 + nt ? "pub" : i == 2 + nt ? "line" : "chk" }
FNR == 1 { nw = 0; win = "" }
{
  r = role[FILENAME]; s = tolower($0); gsub(sep, " ", s); gsub(/[[:space:][:punct:]]+/, " ", s)
  if (r == "own" || r == "line") { nw = 0; win = "" }   # one text per line: no run spans two of them
  n = split(s, w, " ")
  for (i = 1; i <= n; i++) {
    if (w[i] == "" || !push(w[i])) continue
    if (r == "own") own[win] = 1
    else if (r == "pub" || r == "line") pub[win] = 1
    else if ((win in own) && !(win in pub) && !(FILENAME in hit)) { hit[FILENAME] = win; bad = 1 }
  }
}
END { for (f in hit) printf "overlap: %s copies the owner'\''s words: \"%s\"\n", f, hit[f]; exit bad }
' <(printf '%s\n' "$src") "${tpl[@]}" <(printf '%s\n' "$pl") "$@"
