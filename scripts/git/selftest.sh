#!/usr/bin/env bash
# selftest.sh — prove the git rules block, end to end, with real git commands.
#
# Throwaway repo, hooks installed the real way, a local bare remote with `main`.
# Nothing here touches the working clone.
#
# Run: scripts/git/selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

repo="$TMP/repo"
remote="$TMP/remote.git"
out="$TMP/out"
pass=0
fail=0
ZERO=0000000000000000000000000000000000000000

ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -s "$out" ] && sed 's/^/        /' "$out"; }

expect_block() {
  local name="$1"; shift
  if "$@" >"$out" 2>&1; then bad "$name (expected refusal, got success)"; else ok "$name"; fi
}

expect_allow() {
  local name="$1"; shift
  if "$@" >"$out" 2>&1; then ok "$name"; else bad "$name (expected success, got refusal)"; fi
}

# The marker probe is built at runtime: this file must not contain a literal marker.
marker="$(printf '<%.0s' $(seq 1 7))"

# ---------------------------------------------------------------------------
# Throwaway repo carrying this repo's real hooks and rules.
# ---------------------------------------------------------------------------
mkdir -p "$repo/scripts/git" "$repo/scripts/guard" "$repo/.githooks"
cp "$SRC/.gitignore" "$SRC/.gitleaks.toml" "$SRC/.gitmessage" "$repo/"
cp "$SRC"/.githooks/* "$repo/.githooks/"
cp "$SRC"/scripts/git/* "$repo/scripts/git/"
cp "$SRC"/scripts/guard/*.sh "$repo/scripts/guard/"
chmod +x "$repo/.githooks/"* "$repo/scripts/git/"*.sh "$repo/scripts/guard/"*.sh

cd "$repo" || exit 1
git init -q
git config user.email rules@example.invalid
git config user.name rules-selftest
git add -A
git commit -qm "chore: scaffold the selftest repo" --no-verify

# bare remote with a `main` (seeded directly: no hooks, no push involved)
git init -q --bare "$remote"
git --git-dir="$remote" update-ref refs/heads/main "$(git rev-parse main)"
git remote add origin "$remote"

echo "installing hooks:"
"$repo/scripts/guard/install-git-hooks.sh" >"$out" 2>&1 || { cat "$out"; exit 1; }
echo "  ok"
echo
echo "checks:"

# --- branch rules ----------------------------------------------------------
echo probe >probe.txt && git add probe.txt
expect_block "commit on protected branch main is refused" git commit -qm "chore: probe"

git switch -qc stuff
expect_block "commit on badly named branch 'stuff' is refused" git commit -qm "chore: probe"
git switch -q main && git branch -qD stuff

git switch -qc feat/probe
expect_block "commit message without a type is refused" git commit -qm "update the thing"
expect_block "commit message with a trailing period is refused" git commit -qm "feat(probe): add thing."
expect_block "AI attribution trailer is refused" \
  git commit -qm "feat(probe): add thing" -m "Co-Authored-By: Claude <noreply@anthropic.com>"

printf 'Co-Authored-By: Claude <noreply@anthropic.com>\n' >notes.txt
git add notes.txt
expect_allow "attribution text in the DIFF of commit --verbose is not read as the message" \
  git commit -qm "docs(probe): record notes" --verbose

expect_allow "conforming message is accepted" git commit -q --allow-empty -m "feat(probe): add thing"
expect_allow "wip: checkpoint is accepted" git commit -q --allow-empty -m "wip: checkpoint"
expect_allow "multi-scope message is accepted" \
  git commit -q --allow-empty -m "feat(builder, cargo-shuttle): add thing"

git checkout -q --detach
expect_block "commit on detached HEAD is refused" git commit -q --allow-empty -m "feat(probe): x"
git switch -q feat/probe

# --- hygiene ---------------------------------------------------------------
dd if=/dev/zero of=big.bin bs=1048576 count=6 2>/dev/null
git add big.bin
expect_block "staged 6 MiB file is refused" git commit -qm "chore(probe): add asset"
git reset -q && rm -f big.bin

printf '%s HEAD\nours\n' "$marker" >conflict.txt
git add conflict.txt
expect_block "staged conflict marker is refused" git commit -qm "chore(probe): add file"
git reset -q && rm -f conflict.txt

# --- push rules ------------------------------------------------------------
# A clean feature branch pushes normally, through the shim.
git switch -qc feat/clean main
echo clean >clean.txt && git add clean.txt
git commit -qm "feat(clean): add a file"
expect_allow "clean feature branch push is allowed" git push -q -u origin HEAD

# HEAD:main must be refused BY THE PROJECT RULE. The machine-global guard would
# pre-empt the assertion, so this one runs the project hooks directly.
expect_block "push HEAD:main is refused by the project rule" \
  git -c "core.hooksPath=$repo/.git/hooks" push -q origin HEAD:main

# tags are not branches
git tag v0.0.1
expect_allow "tag push is allowed" git push -q origin v0.0.1

# deleting a branch whose work is NOT in main is refused
git switch -qc feat/unmerged main
echo u >u.txt && git add u.txt && git commit -qm "feat(unmerged): work not merged"
git push -q -u origin HEAD
expect_block "deleting an unmerged remote branch is refused" git push -q origin --delete feat/unmerged

# deleting a squash-merged branch is allowed (patch equivalence, not ancestry)
git switch -qc feat/squashed main
echo s >s.txt && git add s.txt && git commit -qm "feat(squashed): single commit"
git push -q -u origin HEAD
git switch -q main
# the "squash merge": same patch, new commit. Local commits on main are refused, so
# this is the deliberate bypass a human would use.
git cherry-pick -n feat/squashed >"$out" 2>&1 || { bad "setup: cherry-pick onto main failed"; cat "$out"; }
git commit -qm "feat(squashed): single commit" --no-verify
expect_allow "deleting a patch-equivalent (squash-merged) branch is allowed" \
  git push -q origin --delete feat/squashed

# force-push on a feature branch is allowed (advisory only)
git switch -q feat/clean
echo more >>clean.txt && git add clean.txt && git commit -q --amend -m "feat(clean): add a file"
expect_allow "force-push of a feature branch is allowed" git push -q --force origin HEAD

# amend on main is refused
git switch -q main
echo x >>probe.txt
git add probe.txt
expect_block "commit --amend on main is refused" git commit -q --amend -m "chore: probe"

# push --all with main present is refused (remote ref is protected)
git switch -q feat/clean
expect_block "push --all is refused while it would send main" \
  git -c "core.hooksPath=$repo/.git/hooks" push -q --all origin

echo
echo "-----------------------------------------------"
echo " passed: $pass    failed: $fail"
echo "-----------------------------------------------"
[ "$fail" -eq 0 ] || exit 1
