#!/usr/bin/env bash
# selftest.sh — prove the guard actually blocks, end to end, through real git.
#
# Nothing here touches the working clone: it builds a throwaway repo, installs the
# real hooks the real way, and then uses real `git commit` / `git push` so that the
# global core.hooksPath shim, the installer and the guard are all exercised.
#
# Run: scripts/guard/selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

repo="$TMP/repo"
out="$TMP/out"
pass=0
fail=0

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

# ---------------------------------------------------------------------------
# Throwaway repo carrying this repo's real guard files.
# ---------------------------------------------------------------------------
mkdir -p "$repo/scripts/guard" "$repo/.githooks"
cp "$SRC/.gitignore" "$SRC/.gitleaks.toml" "$SRC/.env.example" "$repo/"
cp "$SRC"/.githooks/* "$repo/.githooks/"
cp "$SRC"/scripts/guard/*.sh "$repo/scripts/guard/"
chmod +x "$repo/.githooks/"* "$repo/scripts/guard/"*

cd "$repo" || exit 1
git init -q
git config user.email guard@example.invalid
git config user.name guard-selftest
git add -A
git commit -qm scaffold --no-verify

echo "installing hooks into the throwaway repo:"
"$repo/scripts/guard/install-git-hooks.sh" || exit 1
echo
echo "checks:"

# A token shaped like a real one, assembled at runtime so this script is not itself
# a committed secret. Mixed characters on purpose: gitleaks' rules carry an entropy
# floor, so a 36x repeated "B" probe is not detected and would make this test lie.
# AKIAIOSFODNN7EXAMPLE is also NOT a valid probe — it is in gitleaks' default allowlist.
tok="ghp_$(printf '%s' 'a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8' | cut -c1-36)"

# 1. force-added .env (the exact bypass .gitignore cannot stop)
printf 'PLACEHOLDER=\n' >.env
git add -f .env
expect_block "pre-commit refuses force-added .env" git commit -qm leak
git reset -q
rm -f .env

# 2. force-added agent state
mkdir -p .agent
echo x >.agent/probe.md
git add -f .agent/probe.md
expect_block "pre-commit refuses force-added .agent/probe.md" git commit -qm leak
git reset -q
rm -rf .agent

# 3. secret content in an innocently-named file
printf 'token = "%s"\n' "$tok" >src_note.txt
git add src_note.txt
expect_block "pre-commit refuses a secret-shaped line in a normal file" git commit -qm leak
git reset -q
rm -f src_note.txt

# 4. clean change still commits
echo clean >ok.txt
git add ok.txt
expect_allow "pre-commit allows a clean change" git commit -qm clean

# 5. clean branch pushes
git init -q --bare "$TMP/remote.git"
git remote add origin "$TMP/remote.git"
git switch -qc test/clean main
echo hi >clean.txt
git add clean.txt
git commit -qm clean
expect_allow "pre-push allows a clean branch" git push -q origin HEAD

# 6. a new branch (remote-sha all zeros) carrying a secret is refused — the case
#    where gitleaks would otherwise scan zero commits and exit 0
git switch -qc test/secret main
printf 'token = "%s"\n' "$tok" >leaked.txt
git add leaked.txt
git commit -qm leak --no-verify
expect_block "pre-push refuses a new branch containing a secret" git push -q origin HEAD

# 7. history: secret added, then removed in a later commit — still refused
git switch -qc test/removed main
printf 'token = "%s"\n' "$tok" >tmp_leak.txt
git add tmp_leak.txt
git commit -qm "add" --no-verify
git rm -q tmp_leak.txt
git commit -qm "remove"
expect_block "pre-push refuses history whose secret was removed later" git push -q origin HEAD

# 8. empty ref list (the shim always replays at least a blank line) and a
#    ref deletion must both pass
printf '\n' >"$TMP/refs"
expect_allow "pre-push tolerates an empty ref list" \
  bash -c "cat '$TMP/refs' | '$repo/.githooks/pre-push' origin"
printf 'refs/heads/gone %s refs/heads/gone %s\n' \
  "0000000000000000000000000000000000000000" "$(git rev-parse main)" >"$TMP/refs"
expect_allow "pre-push tolerates deleting a remote ref" \
  bash -c "cat '$TMP/refs' | '$repo/.githooks/pre-push' origin"

echo
echo "-----------------------------------------------"
echo " passed: $pass    failed: $fail"
echo "-----------------------------------------------"
[ "$fail" -eq 0 ] || exit 1
