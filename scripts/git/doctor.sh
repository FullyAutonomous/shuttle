#!/usr/bin/env bash
# doctor.sh — read-only report on branch/worktree lifecycle. Changes nothing.
#
#   branch, upstream, ahead/behind, fetch freshness
#   worktrees: path, branch, dirty, and any that live outside .worktrees/
#   local branches merged into main (safe to delete) and whose upstream is gone
#
# Exit code is always 0: this is a report, not a gate.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "doctor: not inside a git work tree" >&2
  exit 0
}
cd "$ROOT" || exit 0

base=""
for cand in origin/main main master origin/master; do
  if git rev-parse --verify -q "$cand" >/dev/null 2>&1; then base="$cand"; break; fi
done

echo "repo:    $ROOT"
if branch="$(current_branch)"; then
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  printf 'branch:  %s' "$branch"
  if [ -n "$upstream" ]; then
    counts="$(git rev-list --left-right --count "$upstream...HEAD" 2>/dev/null || true)"
    printf '  (upstream %s, behind/ahead: %s)' "$upstream" "${counts:-?}"
  else
    printf '  (no upstream)'
  fi
  echo
  if is_protected "$branch"; then
    echo "  ! you are ON a protected branch — commits here are refused; branch first"
  elif ! valid_branch "$branch"; then
    echo "  ! branch name does not follow the convention (scripts/git/README.md)"
  fi
else
  echo "branch:  (detached HEAD — commits here are refused)"
fi
echo "base:    ${base:-unresolved (run git fetch)}"

echo
echo "worktrees:"
git worktree list --porcelain | awk '
  /^worktree / { path = substr($0, 10); next }
  /^branch /   { print path "\t" substr($0, 8); next }
  /^detached/  { print path "\tdetached"; next }
' | while IFS=$'\t' read -r path bname; do
  bname="${bname#refs/heads/}"
  state="clean"
  [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ] && state="DIRTY"
  rogue=""
  case "$path" in
    "$ROOT") ;;
    "$ROOT"/.worktrees/*) ;;
    *) rogue="  ! outside .worktrees/ — move it: scripts/git/worktree.sh add <branch>" ;;
  esac
  printf '  %-8s %-44s %s\n' "$state" "$bname" "$path"
  [ -n "$rogue" ] && echo "$rogue"
done

echo
echo "local branches:"
if [ -n "$base" ]; then
  git for-each-ref --format='%(refname:short)' refs/heads | while IFS= read -r b; do
    [ "$b" = "$base" ] && continue
    merged="no"
    merged_into "$base" "$b" && merged="yes"
    gone=""
    up="$(git rev-parse --abbrev-ref --symbolic-full-name "$b@{u}" 2>/dev/null || true)"
    [ -n "$up" ] && ! git rev-parse --verify -q "$up" >/dev/null 2>&1 && gone="  upstream gone"
    [ "$merged" = "yes" ] || [ -n "$gone" ] && \
      printf '  %-44s merged=%s%s\n' "$b" "$merged" "$gone"
  done
else
  echo "  (skipped: no base branch resolved)"
fi

echo
echo "Nothing was changed. Rules: scripts/git/README.md"
exit 0
