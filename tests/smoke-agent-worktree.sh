#!/usr/bin/env bash
# Smoke test for bin/agent-worktree — throwaway repos + isolated AGENTS_DIR.
# Covers every subcommand plus the codex-audit attack cases. Runs anywhere:
# fixture commits skip signing; the real ~/.agents is never touched.
set -uo pipefail

AW="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/agent-worktree"
S="$(mktemp -d)"
export AGENTS_DIR="$S/agents"
REPO="$S/fakerepo"
REPO2="$S/otherrepo"
FAIL=0

t() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok    $label"; else echo "FAIL  $label"; FAIL=1; fi; }
# SMOKE_VERBOSE=1 prints why each expected failure failed: a refusal for the wrong reason still exits non-zero.
tn() { local label="$1" out; shift; if out="$("$@" 2>&1)"; then echo "FAIL  $label (expected failure)"; FAIL=1; else echo "ok    $label"; [ -z "${SMOKE_VERBOSE:-}" ] || echo "        ${out##*$'\n'}"; fi; }

mkrepo() { # mkrepo <dir>
  mkdir -p "$1" && cd "$1" || return 1
  git init -q -b main
  { echo "node_modules/"; echo ".env"; } > .gitignore
  echo ".env" > .worktreeinclude
  echo "SECRET=1" > .env
  echo "hi" > README.md
  git add README.md .gitignore .worktreeinclude
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm init
}

mkrepo "$REPO"

# --- new ---
"$AW" new escrow-refund --no-start > "$S/new.out" 2>&1
t "new: exit 0" test $? -eq 0
t "new: worktree dir exists" test -d "$REPO/.claude/worktrees/escrow-refund"
t "new: on branch worktree-escrow-refund" test "$(git -C "$REPO/.claude/worktrees/escrow-refund" branch --show-current)" = "worktree-escrow-refund"
t "new: .env carried over" test -f "$REPO/.claude/worktrees/escrow-refund/.env"
t "new: manifest row exists" grep -q "^| escrow-refund |" "$AGENTS_DIR/workspaces.md"
t "new: exclude has worktrees" grep -qxF ".claude/worktrees/" "$REPO/.git/info/exclude"
t "new: git status clean in root" test -z "$(git -C "$REPO" status --porcelain)"
tn "new: duplicate slug refused" "$AW" new escrow-refund --no-start
tn "new: bad slug refused" "$AW" new "Bad Slug!" --no-start
tn "new: from-inside-worktree refused" env -C "$REPO/.claude/worktrees/escrow-refund" "$AW" new other --no-start

# --- new: symlinked .env is skipped (codex B4) ---
cd "$REPO" || exit 1
ln -s /etc/hosts .env.local 2>/dev/null
echo ".env.local" >> .gitignore && echo ".env.local" >> .worktreeinclude
git add .gitignore .worktreeinclude && git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm inc
"$AW" new symlink-case --no-start > "$S/symlink.out" 2>&1
t "carry: symlinked file NOT copied" test ! -e "$REPO/.claude/worktrees/symlink-case/.env.local"
t "carry: regular .env still copied" test -f "$REPO/.claude/worktrees/symlink-case/.env"
"$AW" 'done' symlink-case --force >/dev/null 2>&1

# --- unborn repo refused (codex should-fix) ---
mkdir -p "$S/unborn" && git -C "$S/unborn" init -q -b main
tn "new: unborn repo refused" env -C "$S/unborn" "$AW" new some-task --no-start

# --- status ---
cd "$REPO" || exit 1
"$AW" status escrow-refund "phase 2: wiring refunds" >/dev/null 2>&1
t "status: exit 0" test $? -eq 0
t "status: text landed" grep -q "phase 2: wiring refunds" "$AGENTS_DIR/workspaces.md"
tn "status: unknown slug dies" "$AW" status nope "x"
"$AW" status escrow-refund "pipe | injection attempt" >/dev/null 2>&1
t "status: pipes sanitized" grep -q "pipe / injection attempt" "$AGENTS_DIR/workspaces.md"

# --- register (upsert from inside worktree, simulating blueprint) ---
env -C "$REPO/.claude/worktrees/escrow-refund" "$AW" register escrow-refund --status "homed by blueprint" >/dev/null 2>&1
t "register: exit 0" test $? -eq 0
t "register: upserted (one row)" test "$(grep -c "^| escrow-refund |" "$AGENTS_DIR/workspaces.md")" = 1
t "register: default plan filled" grep -q "implementations-plan/escrow-refund" "$AGENTS_DIR/workspaces.md"
tn "register: refused from canonical clone" env -C "$REPO" "$AW" register escrow-refund
tn "register: refused on slug/path mismatch" env -C "$REPO/.claude/worktrees/escrow-refund" "$AW" register wrong-name

# --- cross-repo same slug (codex B1) ---
mkrepo "$REPO2"
env -C "$REPO" "$AW" new docs --no-start >/dev/null 2>&1
env -C "$REPO2" "$AW" new docs --no-start >/dev/null 2>&1
t "collision: both rows present" test "$(grep -c "^| docs |" "$AGENTS_DIR/workspaces.md")" = 2
tn "collision: unqualified status dies ambiguous" "$AW" status docs "x"
t "collision: qualified status works" "$AW" status otherrepo/docs "working in repo2"
"$AW" 'done' fakerepo/docs >/dev/null 2>&1
t "collision: qualified done removed only fakerepo's" test ! -d "$REPO/.claude/worktrees/docs"
t "collision: otherrepo's worktree survives" test -d "$REPO2/.claude/worktrees/docs"
t "collision: otherrepo's row survives" grep -q "^| docs | otherrepo |" "$AGENTS_DIR/workspaces.md"
"$AW" 'done' otherrepo/docs >/dev/null 2>&1

# --- done verification (codex B3): tampered manifest path refused ---
env -C "$REPO" "$AW" new tamper-me --no-start >/dev/null 2>&1
# point the row's path at the OTHER repo's canonical root (a real dir, wrong layout)
awk -F'|' -v OFS='|' -v bad=" $REPO2 " '$2 == " tamper-me " { $8 = bad } { print }' "$AGENTS_DIR/workspaces.md" > "$S/m.tmp" && mv "$S/m.tmp" "$AGENTS_DIR/workspaces.md"
tn "done: tampered path (wrong layout) refused" "$AW" 'done' tamper-me
t "done: tampered target untouched" test -d "$REPO2"
# re-register the real worktree → slug now ambiguous (poisoned row + real row)
env -C "$REPO/.claude/worktrees/tamper-me" "$AW" register tamper-me >/dev/null 2>&1
tn "done: ambiguous after re-register dies" "$AW" 'done' tamper-me
t "done: poisoned row dropped via --forget" "$AW" 'done' "$REPO2" --forget
t "done: forget touched no disk" test -d "$REPO2"
t "done: real one still removable" "$AW" 'done' tamper-me

# --- B1 residual: same-basename repos (path-keyed identity) ---
mkrepo "$S/x/twin"
mkrepo "$S/y/twin"
env -C "$S/x/twin" "$AW" new docs --no-start >/dev/null 2>&1
env -C "$S/y/twin" "$AW" new docs --no-start >/dev/null 2>&1
t "twin: both rows survive (path-keyed)" test "$(grep -c "^| docs | twin |" "$AGENTS_DIR/workspaces.md")" = 2
tn "twin: repo/slug still ambiguous dies" "$AW" status twin/docs "x"
t "twin: path-form status works" "$AW" status "$S/x/twin/.claude/worktrees/docs" "via path"
t "twin: path-form done removes only one" "$AW" 'done' "$S/x/twin/.claude/worktrees/docs"
t "twin: other twin survives" test -d "$S/y/twin/.claude/worktrees/docs"
"$AW" 'done' "$S/y/twin/.claude/worktrees/docs" >/dev/null 2>&1

# --- B3 residual: branch ownership enforced ---
git -C "$REPO" worktree add "$REPO/.claude/worktrees/rogue" -b other-branch >/dev/null 2>&1
tn "rogue: register refused on wrong branch" env -C "$REPO/.claude/worktrees/rogue" "$AW" register rogue
git -C "$REPO" worktree remove --force "$REPO/.claude/worktrees/rogue" >/dev/null 2>&1
git -C "$REPO" branch -D other-branch >/dev/null 2>&1

env -C "$REPO" "$AW" new hijack-me --no-start >/dev/null 2>&1
git -C "$REPO/.claude/worktrees/hijack-me" checkout -q -b hijacked
tn "hijack: done refused on wrong live branch (even --force)" "$AW" 'done' hijack-me --force
t "hijack: worktree untouched after refusal" test -d "$REPO/.claude/worktrees/hijack-me"
git -C "$REPO/.claude/worktrees/hijack-me" checkout -q worktree-hijack-me
git -C "$REPO" branch -D hijacked >/dev/null 2>&1
t "hijack: done works back on our branch" "$AW" 'done' hijack-me --force

# --- B4 residual: symlinked dir component in target not traversed ---
mkrepo "$S/symrepo"
mkdir -p "$S/outside-target"
cd "$S/symrepo" || exit 1
ln -s "$S/outside-target" config
git add config && git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm symlink
rm config && mkdir -p config/sub && echo "x" > config/sub/.env
echo "config/sub/.env" >> .gitignore
echo "config/sub/.env" >> .worktreeinclude
"$AW" new sym-attack --no-start > "$S/sym.out" 2>&1
t "symdir: outside dir NOT created by mkdir traversal" test ! -e "$S/outside-target/sub"
t "symdir: target's tracked symlink intact" test -L "$S/symrepo/.claude/worktrees/sym-attack/config"
t "symdir: skip reason logged" grep -q "symlinked dir component" "$S/sym.out"
"$AW" 'done' sym-attack --force >/dev/null 2>&1

# --- resume (non-TTY → prints command) ---
OUT="$("$AW" resume escrow-refund 2>&1)"
t "resume: prints cd+claude" bash -c "echo \"\$1\" | grep -q 'claude --continue'" _ "$OUT"

# --- list ---
t "list: shows row" bash -c "\"$AW\" list | grep -q escrow-refund"

# --- done happy path ---
"$AW" 'done' escrow-refund > "$S/done.out" 2>&1
t "done: exit 0" test $? -eq 0
t "done: worktree removed" test ! -d "$REPO/.claude/worktrees/escrow-refund"
t "done: branch deleted" bash -c "! git -C \"$REPO\" show-ref --verify --quiet refs/heads/worktree-escrow-refund"
t "done: row removed" bash -c "! grep -q '^| escrow-refund |' \"$AGENTS_DIR/workspaces.md\""

# --- done refuses dirty ---
env -C "$REPO" "$AW" new dirty-task --no-start >/dev/null 2>&1
echo "wip" > "$REPO/.claude/worktrees/dirty-task/wip.txt"
tn "done: dirty refused without --force" "$AW" 'done' dirty-task
t "done: --force removes dirty" "$AW" 'done' dirty-task --force

# --- done --merged: squash-aware teardown, proven against origin's trunk ---
GC=(git -c commit.gpgsign=false -c user.email=t@t -c user.name=t)
MR="$S/mergerepo"
mkrepo "$MR"
git init -q --bare -b main "$S/origin.git"
git -C "$MR" remote add origin "$S/origin.git" && git -C "$MR" push -q -u origin main
wt() { echo "$MR/.claude/worktrees/$1"; }
work() { echo "$2" > "$(wt "$1")/$2" && git -C "$(wt "$1")" add "$2" && "${GC[@]}" -C "$(wt "$1")" commit -qm "$2"; }   # work <slug> <file>
squash() { git -C "$MR" merge -q --squash "$1" >/dev/null 2>&1 && "${GC[@]}" -C "$MR" commit -qm "squash $1" && git -C "$MR" push -q origin main; }
has_branch() { git -C "$MR" show-ref --verify --quiet "refs/heads/$1"; }
on_origin() { git -C "$S/origin.git" show-ref --verify --quiet "refs/heads/$1"; }

env -C "$MR" "$AW" new solo --no-start >/dev/null 2>&1
work solo solo.txt && git -C "$(wt solo)" push -q origin worktree-solo
tn "merged: refused before the PR lands" "$AW" 'done' solo --merged
t "merged: refusal removed nothing" test -d "$(wt solo)"
squash worktree-solo
echo "transcript" > "$(wt solo)/.env"   # gitignored: disposable by design
tn "merged: --force is rejected" "$AW" 'done' solo --merged --force
echo "wip" > "$(wt solo)/wip.txt"
tn "merged: untracked work refused" "$AW" 'done' solo --merged
rm "$(wt solo)/wip.txt"
tn "merged: --trunk must be an exact branch" "$AW" 'done' solo --merged --trunk HEAD
git -C "$MR" config merge.ours.driver true   # could settle a conflict in trunk's favour
tn "merged: a custom merge driver voids the squash proof" "$AW" 'done' solo --merged
git -C "$MR" config --unset merge.ours.driver
t "merged: squash-merged worktree torn down" env -C "$(wt solo)" "$AW" 'done' solo --merged
t "merged: worktree gone" test ! -d "$(wt solo)"
tn "merged: squashed branch deleted" has_branch worktree-solo
tn "merged: remote branch deleted" on_origin worktree-solo
t "merged: row removed" bash -c "! grep -q '^| solo |' \"$AGENTS_DIR/workspaces.md\""

# A stack ends on its top branch; a bystander at the fork point must survive,
# and so must a remote branch someone else pushed to.
env -C "$MR" "$AW" new stk --no-start >/dev/null 2>&1
git -C "$MR" branch -q --no-track bystander origin/main
work stk arc1.txt
git -C "$(wt stk)" checkout -q -b stk-arc2 && work stk arc2.txt
git -C "$(wt stk)" checkout -q -b stk-close-out && work stk close.txt
git -C "$(wt stk)" push -q origin worktree-stk stk-arc2 stk-close-out
FOREIGN="$("${GC[@]}" -C "$S/origin.git" commit-tree "$(git -C "$S/origin.git" hash-object -w -t tree /dev/null)" -p refs/heads/stk-arc2 -m foreign)"
git -C "$S/origin.git" update-ref refs/heads/stk-arc2 "$FOREIGN"
squash stk-close-out
"$AW" 'done' stk --merged > "$S/stk.out" 2>&1
t "stack: exit 0" test $? -eq 0
t "stack: worktree gone" test ! -d "$(wt stk)"
tn "stack: adopted layer deleted" has_branch worktree-stk
tn "stack: middle arc deleted" has_branch stk-arc2
tn "stack: top layer deleted" has_branch stk-close-out
t "stack: bystander at the fork point survives" has_branch bystander
t "stack: trunk survives" has_branch main
tn "stack: merged remote branch deleted" on_origin stk-close-out
t "stack: remote branch with a foreign commit kept" on_origin stk-arc2
t "stack: kept remote is reported" grep -q "remote branch kept.*origin/stk-arc2" "$S/stk.out"

# A worktree's submodule repositories die with it, so one that holds any is
# left alone even though the superproject is clean and merged.
FILE_OK=(-c protocol.file.allow=always)
git init -q --bare -b main "$S/sub.git"
git clone -q "$S/sub.git" "$S/subsrc" 2>/dev/null
echo lib > "$S/subsrc/lib.txt" && git -C "$S/subsrc" add lib.txt \
  && "${GC[@]}" -C "$S/subsrc" commit -qm lib && git -C "$S/subsrc" push -q origin HEAD:main
git -C "$MR" "${FILE_OK[@]}" submodule --quiet add "$S/sub.git" vendor >/dev/null 2>&1
"${GC[@]}" -C "$MR" commit -qm "add submodule" && git -C "$MR" push -q origin main
env -C "$MR" "$AW" new subm --no-start >/dev/null 2>&1
git -C "$(wt subm)" "${FILE_OK[@]}" submodule --quiet update --init >/dev/null 2>&1
tn "submodule: a worktree holding one is not removed" "$AW" 'done' subm --merged
t "submodule: refusal removed nothing" test -d "$(wt subm)/vendor"
t "submodule: branch and row survive the refusal" bash -c "git -C \"$MR\" show-ref --verify --quiet refs/heads/worktree-subm && grep -q '^| subm |' \"$AGENTS_DIR/workspaces.md\""

# --- prune on list ---
env -C "$REPO" "$AW" new gone-task --no-start >/dev/null 2>&1
rm -rf "$REPO/.claude/worktrees/gone-task"
"$AW" list >/dev/null 2>&1
t "prune: stale row dropped on list" bash -c "! grep -q '^| gone-task |' \"$AGENTS_DIR/workspaces.md\""

# --- lock: dead-owner reclaim (codex should-fix) ---
mkdir "$AGENTS_DIR/.workspaces.lock"
echo "4194000 $(hostname)" > "$AGENTS_DIR/.workspaces.lock/owner"   # surely-dead pid
t "lock: dead local owner reclaimed" "$AW" list
# --- lock: live/foreign lock times out ---
mkdir -p "$AGENTS_DIR/.workspaces.lock"
echo "$$ not-this-host" > "$AGENTS_DIR/.workspaces.lock/owner"
tn "lock: foreign-host lock times out (~10s)" "$AW" list
rm -rf "$AGENTS_DIR/.workspaces.lock"

echo ""
if [ "$FAIL" = 0 ]; then echo "ALL SMOKE TESTS PASSED"; else echo "SMOKE FAILURES PRESENT"; exit 1; fi
