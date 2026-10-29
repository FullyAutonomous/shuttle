#!/usr/bin/env bash
# setup.sh — one command per clone: local git config + the project hooks.
#
# Local-only settings (never global): they make the documented workflow the default.
# Run again any time; it is idempotent.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "setup: not inside a git work tree" >&2
  exit 1
}
cd "$ROOT" || exit 1

git config --local pull.rebase true
git config --local fetch.prune true
git config --local merge.conflictStyle zdiff3
git config --local rerere.enabled true
git config --local push.autoSetupRemote true
git config --local commit.template .gitmessage

echo "local git config:"
git config --local --get-regexp '^(pull|fetch|merge|rerere|push|commit)\.' | sed 's/^/  /'
echo
echo "hooks:"
"$ROOT/scripts/guard/install-git-hooks.sh"
