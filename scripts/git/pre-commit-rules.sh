#!/usr/bin/env bash
# pre-commit-rules.sh — the structural git rules, checked before a commit is written.
#
#   1. no commits on a protected branch (main, master, develop, staging, production,
#      gh-pages) — branch first, merge by pull request
#   2. no commits on a detached HEAD (that is how work gets lost)
#   3. the branch name must follow the convention in scripts/git/lib.sh
#   4. no staged file larger than 5 MiB
#   5. no staged conflict markers
#
# Exceptions: a merge, cherry-pick, revert, `git am` or rebase in progress may write
# its commit. `git rebase` runs neither pre-commit nor commit-msg on this git version,
# so the rebase path is simply not guarded — do not read this as "rebase is checked".
#
# Called by .githooks/pre-commit, which then runs the secret guard.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$ROOT" || exit 0

rc=0
in_progress=0
in_progress_operation && in_progress=1

# --- 1/2/3: branch ---------------------------------------------------------
if branch="$(current_branch)"; then
  if is_protected "$branch"; then
    # A merge INTO a protected branch is allowed to create its commit; the result
    # still cannot be pushed (pre-push refuses the ref).
    if [ ! -e "$(git_path MERGE_HEAD)" ]; then
      refuse "commits on the protected branch '$branch'" \
        "Protected branches are updated by pull request, not by local commits." \
        "" \
        "  git switch -c feat/<short-description>   # keep the work, move it off $branch" \
        "  git branch -f $branch origin/$branch     # if $branch already moved locally"
      rc=1
    fi
  elif ! valid_branch "$branch"; then
    refuse "branch name does not follow the convention" \
      "  branch: $branch" \
      "" \
      "Expected <type>/<slug>, type in: ${BRANCH_TYPES//|/, }." \
      "  feat/2135-compute-tier-ord   fix/PROJ-123-null-deref   chore/cleanup-docs" \
      "Rename it:" \
      "  git branch -m <type>/<slug>" \
      "Full rules: scripts/git/README.md"
    rc=1
  fi
elif [ "$in_progress" -eq 0 ]; then
  refuse "commits on a detached HEAD" \
    "Detached HEAD commits are unreachable once you leave, which is how work is lost." \
    "" \
    "  git switch -c feat/<short-description>   # attach a branch here" \
    "  git switch -c <branch> <sha>            # or start from the commit you meant"
  rc=1
fi

# --- 4: large files --------------------------------------------------------
large=()
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  size="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"
  [ -n "$size" ] || continue
  if [ "$size" -gt "$LARGE_FILE_BYTES" ]; then
    large+=("  - $f ($((size / 1048576)) MiB)")
  fi
done < <(git diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null)
if [ "${#large[@]}" -gt 0 ]; then
  refuse "staged file larger than 5 MiB" "${large[@]}" \
    "Binary assets belong in a release artefact, or LFS — both are human decisions." \
    "If it is genuinely source, commit it with: git commit --no-verify"
  rc=1
fi

# --- 5: conflict markers ---------------------------------------------------
# Patterns are written as <{7} / ={7} / >{7} so that this file never contains a
# literal marker and cannot flag itself.
markers="$(git diff --cached -U0 --no-color --diff-filter=ACMR -- . 2>/dev/null | awk '
  /^\+\+\+ b\// { file = substr($0, 7); next }
  /^\+(<{7}( |$)|={7}$|>{7}( |$))/ { print "  - " file ": " substr($0, 2) }
')"
if [ -n "$markers" ]; then
  refuse "conflict markers in the staged change" "$markers"
  rc=1
fi

exit "$rc"
