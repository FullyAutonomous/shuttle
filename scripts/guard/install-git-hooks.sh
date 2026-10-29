#!/usr/bin/env bash
# install-git-hooks.sh — put the project's guard hooks where git actually runs them.
#
# This machine has a global core.hooksPath (~/.claude/git-hooks) whose shim chains
# global guard -> $GIT_COMMON_DIR/hooks/<name>, so installing into the common git
# dir is correct AND the global guard still runs first. The installer verifies that
# chain and warns loudly if the configured hooksPath does not forward.
#
# Re-runnable. Never clobbers a hook it does not own: an existing foreign hook is
# moved to <name>.pre-guard-backup once.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "install-git-hooks: not inside a git work tree" >&2
  exit 1
}
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)" || exit 1
HOOKDIR="$COMMON/hooks"
HOOKS="pre-commit pre-push"

mkdir -p "$HOOKDIR"

for name in $HOOKS; do
  target="$HOOKDIR/$name"

  if [ -e "$target" ] && ! grep -q 'sensitive-guard' "$target" 2>/dev/null; then
    if [ -e "$target.pre-guard-backup" ]; then
      echo "install-git-hooks: $name exists and is not ours, and a backup already exists." >&2
      echo "  Move it aside yourself: mv '$target' '$target.$(date +%Y%m%d%H%M%S)'" >&2
      exit 1
    fi
    mv "$target" "$target.pre-guard-backup"
    echo "  kept your existing $name as $target.pre-guard-backup"
  fi

  {
    echo '#!/usr/bin/env bash'
    echo "# Installed by scripts/guard/install-git-hooks.sh — do not edit."
    echo "# Source of truth: .githooks/$name"
    echo 'set -uo pipefail'
    echo "root=\"\$(git rev-parse --show-toplevel 2>/dev/null)\" || exit 0"
    echo "hook=\"\$root/.githooks/$name\""
    echo '[ -x "$hook" ] || exit 0'
    echo 'exec "$hook" "$@"'
  } >"$target"
  chmod +x "$target"
  echo "  installed $target"
done

chmod +x "$ROOT/.githooks/pre-commit" "$ROOT/.githooks/pre-push" \
         "$ROOT/scripts/guard/sensitive-guard.sh" 2>/dev/null || true

hp="$(git config --get core.hooksPath || true)"
echo
if [ -n "$hp" ]; then
  echo "core.hooksPath = $hp (global or local override is in effect)"
  shim="$hp/pre-commit"
  if [ -e "$shim" ] && grep -q 'git-common-dir' "$shim" 2>/dev/null; then
    echo "  verified: that shim chains to $HOOKDIR, so these hooks do run."
  else
    {
      echo "  WARNING: that path does not appear to chain to $HOOKDIR."
      echo "  Your project hooks will NOT run until it does. Either point it at a"
      echo "  chaining shim, or add the chain yourself. Install is otherwise complete."
    } >&2
  fi
else
  echo "core.hooksPath is unset: git runs $HOOKDIR directly. Hooks are active."
fi

echo
echo "Verify with: scripts/guard/selftest.sh"
