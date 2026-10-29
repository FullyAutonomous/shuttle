#!/usr/bin/env bash
# worktree.sh — the worktree convention, executable.
#
#   worktree.sh add <branch> [base]   create .worktrees/<branch> (branch created if new)
#   worktree.sh list                  every worktree: branch, dirty, ahead/behind
#   worktree.sh remove <branch>       remove safely; delete the branch only if merged
#
# Layout: <repo>/.worktrees/<branch>, slashes preserved (feat/foo -> .worktrees/feat/foo).
# `.worktrees/` is gitignored, so a worktree can never be committed.
#
# Git has no hook for `worktree add`, which is why this is a script and why
# scripts/git/doctor.sh reports worktrees that live outside .worktrees/.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "worktree: not inside a git work tree" >&2
  exit 1
}
cd "$ROOT" || exit 1
WT_ROOT="$ROOT/.worktrees"

base_ref() { # $1 = preferred base name
  local b="${1:-main}"
  if git rev-parse --verify -q "origin/$b" >/dev/null 2>&1; then
    printf 'origin/%s' "$b"
  elif git rev-parse --verify -q "$b" >/dev/null 2>&1; then
    printf '%s' "$b"
  else
    return 1
  fi
}

cmd_add() {
  local branch="${1:-}" base="${2:-main}" start

  [ -n "$branch" ] || { echo "usage: worktree.sh add <branch> [base]" >&2; exit 2; }
  if is_protected "$branch"; then
    echo "worktree: '$branch' is protected — work happens on a branch, not there." >&2
    exit 1
  fi
  if ! valid_branch "$branch"; then
    echo "worktree: '$branch' does not follow the branch convention." >&2
    echo "  expected <type>/<slug>, types: ${BRANCH_TYPES//|/, }" >&2
    exit 1
  fi

  local path="$WT_ROOT/$branch"
  if [ -e "$path" ]; then
    echo "worktree: $path already exists" >&2
    exit 1
  fi

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add "$path" "$branch" || exit 1
    echo "attached existing branch $branch"
  else
    if ! start="$(base_ref "$base")"; then
      echo "worktree: cannot resolve base '$base' — run 'git fetch' first" >&2
      exit 1
    fi
    # --no-track: a new branch must not inherit base's upstream, or `git push`
    # would try to push to that branch.
    git worktree add --no-track -b "$branch" "$path" "$start" || exit 1
    echo "created $branch from $start"
  fi

  echo
  echo "  cd $path"
}

cmd_list() {
  printf '%-14s %-44s %s\n' "STATE" "BRANCH" "PATH"
  git worktree list --porcelain | awk '
    /^worktree / { path = substr($0, 10); branch = "-"; next }
    /^branch /   { branch = substr($0, 8); sub("refs/heads/", "", branch); next }
    /^detached/  { branch = "detached"; next }
    /^$/         { print "WT\t" branch "\t" path; branch = "-"; path = ""; next }
    END          { if (path != "") print "WT\t" branch "\t" path }
  ' | while IFS=$'\t' read -r _ branch path; do
    local state="ok"
    [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ] && state="dirty"
    printf '%-14s %-44s %s\n' "$state" "$branch" "$path"
  done
}

cmd_remove() {
  local branch="${1:-}"
  [ -n "$branch" ] || { echo "usage: worktree.sh remove <branch>" >&2; exit 2; }

  local path="$WT_ROOT/$branch"
  if [ ! -d "$path" ]; then
    echo "worktree: no worktree at $path" >&2
    exit 1
  fi
  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
    echo "worktree: $path has uncommitted changes — refusing to remove it." >&2
    echo "  commit or stash them, or remove manually: git worktree remove --force $path" >&2
    exit 1
  fi

  # Removing from inside the target strands the shell in a deleted directory.
  local main_wt
  main_wt="$(git worktree list --porcelain | awk '/^worktree /{ print substr($0, 10); exit }')"
  cd "$main_wt" || exit 1

  git worktree remove "$path" || exit 1
  echo "removed $path"

  local base
  base="$(base_ref main)" || base="main"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    if merged_into "$base" "$branch"; then
      git branch -d "$branch" && echo "deleted merged branch $branch"
    else
      echo "kept branch $branch: not detected as merged into $base"
      echo "  (a multi-commit squash merge is not locally detectable)"
      echo "  delete deliberately: git branch -D $branch"
    fi
  fi
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  list|ls) cmd_list ;;
  remove|rm) shift; cmd_remove "$@" ;;
  *)
    echo "usage: worktree.sh {add <branch> [base] | list | remove <branch>}" >&2
    exit 2
    ;;
esac
