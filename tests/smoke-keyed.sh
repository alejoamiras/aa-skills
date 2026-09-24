#!/usr/bin/env bash
# Smoke test for keyed runs (bin/env-exec + bin/op-remote) with fake secrets only: stub op and ssh,
# a throwaway repo pushed to a bare origin, and a fake HOME so the real ~/.agents is never touched.
# Needs strace, script (util-linux), jq and perl; the bash 3.2 pass of the Mac side needs docker.
# shellcheck disable=SC2329,SC2016,SC2054,SC2034,SC1091 # helpers run via t/tn; literal $… on purpose
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
S=$(mktemp -d)
trap '[ -n "${KEEP:-}" ] && echo "kept $S" || rm -rf "$S"' EXIT
export HOME="$S/home" SHELL=/bin/bash
mkdir -p "$HOME" "$S/stub"
FAIL=0

t() { local label="$1"; shift; if "$@" > /dev/null 2>&1; then echo "ok    $label"; else echo "FAIL  $label"; FAIL=1; fi; }
tn() { local label="$1"; shift; if "$@" > /dev/null 2>&1; then echo "FAIL  $label (expected failure)"; FAIL=1; else echo "ok    $label"; fi; }
for tool in strace script jq perl git; do command -v "$tool" > /dev/null || { echo "missing $tool"; exit 1; }; done

# Fake secrets. Leak checks grep for the canaries, which strace prints unescaped.
KEY_BODY=5ca1ab1edeadbeef5ca1ab1edeadbeef5ca1ab1edeadbeef5ca1ab1edeadbeef
printf '0x%s' "$KEY_BODY" > "$S/key"
# shellcheck disable=SC2016 # the $(…) must stay literal: it proves values are never evaluated
printf '%s' 'kwCanary9 $(touch PWNED) "q" '\''r'\'' =s' > "$S/words"
printf '%s\n' "$KEY_BODY" kwCanary9 > "$S/needles"
KEY="0x$KEY_BODY"
leaks() { grep -F -i -q -f "$S/needles" "$@"; }

cat > "$S/stub/op" << EOF
#!/bin/bash
echo "\$*" >> "$S/op.calls"
case "\$1 \$2" in
  "read -n") case \$3 in
      op://Keyed-Runs/Test-Local/KT_KEY) cat "$S/key" ;;
      op://Keyed-Runs/Test-Local/KT_WORDS) cat "$S/words" ;;
      *) exit 1 ;;
    esac ;;
  "item list") [ ! -e "$S/list-fails" ] || exit 1; echo '[]' ;;
  "item create") cat > "$S/created.json" ;;
  *) exit 2 ;;
esac
EOF
cat > "$S/stub/ssh" << 'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case $1 in --) shift; break ;; -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
exec bash -c "$*"
EOF
chmod +x "$S/stub/op" "$S/stub/ssh"
export PATH="$S/stub:$PATH"

g() { git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
git init -q --bare "$S/origin.git"
git init -q -b main "$S/repo"
cd "$S/repo" || exit 1
git remote add origin "$S/origin.git"
cat > keyed.env.example << 'EOF'
# fake secrets for the smoke test
# op: generate eth-key
KT_KEY=op://Keyed-Runs/Test-Local/KT_KEY
# op: import
KT_WORDS=op://Keyed-Runs/Test-Local/KT_WORDS
KT_PLAIN=a $b "c" =d
EOF
cat > probe.sh << 'EOF'
#!/bin/bash
echo "key $KT_KEY bare ${KT_KEY#0x} upper ${KT_KEY^^}"
echo "words $KT_WORDS"
[ "$KT_WORDS" = "$(cat "$1")" ] && echo words-literal-ok
echo "plain $KT_PLAIN"
exit "${2:-0}"
EOF
chmod +x probe.sh
printf '# op: bad\033[2Jdirective\nBAD_KEY=op://Keyed-Runs/Bad/BAD_KEY\n' > bad.env.example
ln -s safe link && echo quoted > '"odd name"'
g add -A && g commit -qm init && git push -q -u origin main 2> /dev/null
HEAD=$(git rev-parse HEAD)
KD="$HOME/.agents/keyed"

req() { # req <slug> <cmd…>: file a request, print its id
  local out
  out=$("$BIN/env-exec" request --template keyed.env.example --slug "$1" -- "${@:2}" 2>&1) || return 1
  printf '%s\n' "$out" | sed -n 's/^request \([a-z0-9-]*\):.*/\1/p'
}
approve() { # approve <answer> <cmd…>: run cmd on a pty, typing <answer> at its /dev/tty
  local ans=$1
  shift
  printf '%s\n' "$ans" | script -qec "$(printf '%q ' "$@")" /dev/null
}
TRACE=(strace -f -qq -e trace=execve,execveat -s 65535 -o)
recv() { local id=$1; shift; printf '%s\0' "$@" | "$BIN/env-exec" receive "$id"; }
run1() { printf '%s\0' KEYED-RUN1 "$1" "$HEAD" "$S/repo" /bin/bash 3 /bin/bash -c "$2" 0; }

# --- template grammar ---
parse() { printf '%s\n' "$@" > "$S/tpl" && (KEYED_LIB=1 && . "$BIN/env-exec" && keyed_parse_template "$S/tpl"); }
t "grammar: value kept verbatim" bash -c "KEYED_LIB=1; . '$BIN/env-exec'; keyed_parse_template '$S/repo/keyed.env.example'; [ \"\${t_value[2]}\" = 'a \$b \"c\" =d' ]"
tn "grammar: name without underscore (RANDOM & co) refused" parse 'RANDOM=a[$(touch PWNED)0]'
tn "grammar: hook prefix refused" parse 'NODE_OPTIONS=--require=./x.js'
tn "grammar: duplicate refused" parse 'A_B=1' 'A_B=2'
tn "grammar: dangling directive refused" parse '# op: import' '' 'A_B=op://V/I/A_B'
tn "grammar: export syntax refused" parse 'export A_B=1'

# --- commit pin ---
echo x >> probe.sh
tn "pin: dirty tracked file refused" req x ./probe.sh
git checkout -q probe.sh
git update-index --assume-unchanged probe.sh && echo 'curl evil' >> probe.sh
tn "pin: assume-unchanged edit refused" req x ./probe.sh
git update-index --no-assume-unchanged probe.sh && git checkout -q probe.sh
echo 'probe.sh filter=hide' > .git/info/attributes && git config filter.hide.clean 'git cat-file blob HEAD:probe.sh'
echo 'curl evil' >> probe.sh && git add probe.sh
t "pin: (setup) git itself calls the filtered edit clean" test -z "$(git status --porcelain)"
tn "pin: edit hidden by a clean filter refused" req x ./probe.sh
rm .git/info/attributes && git config --unset filter.hide.clean && git checkout -q probe.sh
ln -sfn $'sa\nfe' link && git update-index --assume-unchanged link
tn "pin: symlink retargeted and hidden from git refused" req x ./probe.sh
git update-index --no-assume-unchanged link && git checkout -q link
touch stray
tn "pin: untracked file refused" req x ./probe.sh
rm stray
echo bunfig.toml >> .git/info/exclude && echo 'preload = ["./x.ts"]' > bunfig.toml
tn "pin: ignored bunfig.toml refused" req x ./probe.sh
rm bunfig.toml
g commit -q --allow-empty -m unpushed && git update-ref refs/remotes/origin/fake HEAD
tn "pin: unpushed HEAD refused even with a forged remote ref" req x ./probe.sh
git reset -q --hard "$HEAD" && git update-ref -d refs/remotes/origin/fake

# --- approve + run, end to end, every execve traced ---
ID=$(req probe ./probe.sh "$S/words" 3)
t "request: prints an id" test -n "$ID"
approve y "${TRACE[@]}" "$S/trace" "$BIN/op-remote" testhost "$ID" > "$S/run.out" 2>&1
rc=$?
t "run: exits with the command's code" test "$rc" -eq 3
t "run: secret masked in every form" grep -q 'key 0x\[masked:KT_KEY\] bare \[masked:KT_KEY\] upper 0X\[masked:KT_KEY\]' "$S/run.out"
t "run: \$(…) and quotes arrive literally" grep -q words-literal-ok "$S/run.out"
t "run: plain value passed as-is" grep -qF 'plain a $b "c" =d' "$S/run.out"
tn "run: no canary in the streamed output" leaks "$S/run.out"
tn "run: no canary in the log on disk" leaks "$KD/$ID/run/log"
t "run: the trace covers the command" grep -q 'probe.sh' "$S/trace"
tn "run: no canary in any execve argv" leaks "$S/trace"
t "run: nothing was executed from a value" test -z "$(find "$S" -name PWNED)"
out=$(timeout 20 "$BIN/env-exec" wait "$ID" 2>&1)
t "wait: exit code and masked log" bash -c "[ $? -eq 3 ] && grep -q 'masked:KT_WORDS' <<< \"\$1\"" _ "$out"
approve y "$BIN/op-remote" testhost "$ID" > "$S/again.out" 2>&1
tn "single use: a request runs once" test $? -eq 0
t "single use: says why" grep -q 'already ran' "$S/again.out"

ID=$(req leak /bin/bash -c '/bin/true "$KT_WORDS"')
approve y "${TRACE[@]}" "$S/trace2" "$BIN/op-remote" testhost "$ID" > /dev/null 2>&1
t "control: the argv check catches a command that leaks" leaks "$S/trace2"

# --- the approval screen ---
: > "$S/op.calls"
ID=$(req render ./probe.sh "$(printf 'esc\033[2Kx')" '' $'\xe2\x80\xae' 'lit\x1b')
approve n "$BIN/op-remote" testhost "$ID" > "$S/render.out" 2>&1
t "render: ESC escaped" grep -qF '"esc\x1b[2Kx"' "$S/render.out"
t "render: empty argument visible" grep -qF '[2] ""' "$S/render.out"
t "render: bidi override escaped" grep -qF '"\xe2\x80\xae"' "$S/render.out"
t "render: a literal \\x1b stays distinct" grep -qF '"lit\\x1b"' "$S/render.out"
tn "render: no raw ESC reaches the terminal" grep -q $'\x1b' "$S/render.out"
tn "render: no → 1Password never asked" grep -q '^read' "$S/op.calls"
t "render: no → nothing claimed" test ! -e "$KD/$ID/run"
ID=bad-00000001
mkdir -p "$KD/$ID" && printf '%s\0' KEYED-REQ1 "$S/repo" bad.env.example 1 ./probe.sh END > "$KD/$ID/request"
approve y "$BIN/op-remote" testhost "$ID" > "$S/bad.out" 2>&1
t "render: a bad template is refused" grep -q 'unknown directive' "$S/bad.out"
tn "render: its diagnostic carries no raw ESC" grep -q $'\x1b' "$S/bad.out"

# --- receiver: refusals, race, lifecycle ---
ID=$(req recv ./probe.sh)
tn "receive: HEAD mismatch refused" recv "$ID" KEYED-RUN1 "$ID" 0123456789012345678901234567890123456789 "$S/repo" /bin/bash 1 /bin/bash 0 1 "KT_KEY=$KEY" END
tn "receive: truncated stream refused" bash -c "$(declare -f run1); HEAD=$HEAD S=$S; { run1 $ID true; printf '%s\0' 1 KT_KEY=$KEY; } | '$BIN/env-exec' receive $ID"
tn "receive: bytes after END refused" bash -c "$(declare -f run1); HEAD=$HEAD S=$S; { run1 $ID true; printf '%s\0' 1 KT_KEY=$KEY END junk; } | '$BIN/env-exec' receive $ID"
tn "receive: hook name refused" bash -c "$(declare -f run1); HEAD=$HEAD S=$S; { run1 $ID true; printf '%s\0' 1 LD_PRELOAD=/tmp/evil.so END; } | '$BIN/env-exec' receive $ID"
t "receive: refusals claim nothing" test ! -e "$KD/$ID/run"

ID=$(req race ./probe.sh)
for i in 1 2; do ({ run1 "$ID" true; printf '%s\0' 1 "KT_KEY=$KEY" END; } | "$BIN/env-exec" receive "$ID" > /dev/null 2>&1; echo $? > "$S/race$i") & done
wait
t "race: exactly one of two receivers runs" test "$(cat "$S/race1" "$S/race2" | sort | tr -d '\n')" = 01

ID=$(req mask ./probe.sh)
(ulimit -f 1; { run1 "$ID" 'head -c 8192 /dev/zero | tr "\0" x'; printf '%s\0' 1 "KT_KEY=$KEY" END; } | "$BIN/env-exec" receive "$ID") > /dev/null 2>&1
t "masker: a failed log write is reported, never 'finished'" grep -q '^failed masker' "$KD/$ID/run/status"

ID=$(req alias ./probe.sh)
{ run1 "$ID" '[ "$R_NAME" = collide-1234 ]'; printf '%s\0' 1 R_NAME=collide-1234 END; } | "$BIN/env-exec" receive "$ID" > /dev/null 2>&1
t "receive: a secret named like an internal variable arrives intact" test $? -eq 0

ID=stale-00000001
mkdir -p "$KD/$ID/run" && : > "$KD/$ID/request" && echo claimed > "$KD/$ID/run/status" && echo "999999 1" > "$KD/$ID/run/pid"
t "state: a dead supervisor is 'unknown', never a hang" test "$("$BIN/env-exec" status "$ID")" = 'unknown supervisor-vanished'

ID=$(req grow ./probe.sh)
{ run1 "$ID" 'for i in $(seq 1 200000); do echo "line-$i"; done'; printf '%s\0' 1 "KT_KEY=$KEY" END; } | "$BIN/env-exec" receive "$ID" > "$S/grow.out" 2>&1
t "follow: a log growing while streamed arrives whole" test "$?/$(grep -c '^line-' "$S/grow.out")" = 0/200000

ID=$(req lost ./probe.sh)
{ run1 "$ID" 'sleep 2; echo late-line'; printf '%s\0' 1 "KT_KEY=$KEY" END; } | "$BIN/env-exec" receive "$ID" > /dev/null 2>&1 &
rpid=$!
sleep 0.7 && kill "$rpid" 2> /dev/null
out=$("$BIN/env-exec" wait "$ID" 2> /dev/null)
t "ssh loss after launch: the run still finishes and wait sees it" bash -c "[ $? -eq 0 ] && grep -q late-line <<< \"\$1\"" _ "$out"

# --- create: generated and imported values reach op on stdin only ---
ID=$(req create ./probe.sh)
touch "$S/list-fails"
approve y "$BIN/op-remote" create testhost "$ID" > /dev/null 2>&1
t "create: a failed vault lookup aborts before anything is created" test ! -e "$S/created.json"
rm "$S/list-fails"
mkfifo "$S/tty-in"
script -qec "$(printf '%q ' "${TRACE[@]}" "$S/trace3" "$BIN/op-remote" create testhost "$ID")" /dev/null < "$S/tty-in" > "$S/create.out" 2>&1 &
exec 5> "$S/tty-in"
printf 'y\n' >&5
prompted=no
for _ in $(seq 100); do grep -q 'paste KT_WORDS' "$S/create.out" && { prompted=yes; break; }; sleep 0.1; done
t "create: asks for the pasted value" test "$prompted" = yes
sleep 0.3; printf 'importedValue123\n' >&5; exec 5>&-; wait
key=$(jq -r '.fields[] | select(.label == "KT_KEY") | .value' "$S/created.json" 2> /dev/null)
t "create: one item, both fields, from stdin" jq -e '.title == "Test-Local" and ([.fields[].label] == ["KT_KEY", "KT_WORDS"])' "$S/created.json"
t "create: eth key is 0x+64 hex below the secp256k1 order" bash -c '[[ $1 =~ ^0x[0-9a-f]{64}$ ]] && LC_ALL=C && [[ ${1#0x} < fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141 ]]' _ "$key"
t "create: imported value verbatim" jq -e '.fields[1].value == "importedValue123"' "$S/created.json"
tn "create: no value printed, generated or pasted" grep -qiF -e "${key#0x}" -e importedValue123 "$S/create.out"
tn "create: no value in any execve argv" grep -qiF -e "${key#0x}" -e importedValue123 "$S/trace3"

# --- the Mac side under bash 3.2: its payload must satisfy the bash 5 receiver ---
if command -v docker > /dev/null && docker image inspect bash:3.2 > /dev/null 2>&1; then
  ID=$(req mac ./probe.sh "$S/words" 0)
  mkdir -p "$S/b32/stub"
  (cd / && env -i HOME="$HOME" LANG=C.UTF-8 /bin/bash "$BIN/env-exec" inspect "$ID") > "$S/b32/inspect"
  cp "$S/key" "$S/words" "$S/b32/"
  sed -e "s#$S#/w#g" -e '1s|.*|#!/usr/bin/env bash|' "$S/stub/op" > "$S/b32/stub/op"
  cat > "$S/b32/stub/ssh" << 'EOF'
#!/usr/bin/env bash
case "$*" in
  *" env-exec inspect "*) cat /w/inspect ;;
  *" env-exec receive "*) cat > /w/payload ;;
  *" env-exec status "*) echo 'finished 0' ;;
esac
EOF
  chmod +x "$S/b32/stub/op" "$S/b32/stub/ssh"
  approve y docker run --rm -it -v "$BIN:/k:ro" -v "$S/b32:/w" bash:3.2 \
    bash -c "PATH=/w/stub:\$PATH; bash /k/op-remote testhost $ID" > "$S/b32.out" 2>&1
  t "bash 3.2: op-remote approves and exits 0" grep -q 'finished 0' "$S/b32.out"
  "$BIN/env-exec" receive "$ID" < "$S/b32/payload" > "$S/b32.run" 2>&1
  t "bash 3.2: its payload runs on the bash 5 receiver" grep -q words-literal-ok "$S/b32.run"
else
  echo "skip  bash 3.2 pass (docker or the bash:3.2 image missing)"
fi

[ "$FAIL" -eq 0 ] && echo "all passed" || echo "SOME FAILED"
exit "$FAIL"
