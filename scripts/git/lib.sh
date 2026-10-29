#!/usr/bin/env bash
# lib.sh — the git rules, in one place. Sourced, never executed.
#
# Keep the rules here and only here: the hooks, the worktree script, the doctor and
# the selftest all read them from this file. A rule that exists in two places drifts.
# bash 3.2 compatible (no mapfile, no associative arrays, no ${var,,}, no (?i)).

BRANCH_TYPES='feat|fix|hotfix|chore|docs|refactor|test|perf|build|ci|style|revert|release'

# <type>/<slug>, optional uppercase ticket prefix, nested bot paths.
#   feat/2135-compute-tier-ord      fix/PROJ-123-null-deref
#   chore/gitignore-secret-guard    release/1.2.3
#   dependabot/cargo/serde-1.0.219  renovate/serde-1.x
BRANCH_RE="^((($BRANCH_TYPES)/([A-Z][A-Z0-9]*-[0-9]+-)?[a-z0-9][a-z0-9._-]*)|((dependabot|renovate)/([A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+))$"

PROTECTED_RE='^(main|master|develop|staging|production|gh-pages)$'

# Subject line: <type>(<scope>)!: <description>, or an exempt form.
COMMIT_SUBJECT_RE="^((($BRANCH_TYPES)(\(([a-z0-9._/-]+(, [a-z0-9._/-]+)*)\))?!?: .+)|(Merge .+)|(Revert .+)|(fixup! .+)|(squash! .+)|(wip: .+))$"
COMMIT_EXEMPT_RE='^(Merge|Revert|fixup!|squash!|wip:)'

# AI attribution, refused by workspace rules. Case-insensitive matching is done with
# grep -Eqi, because bash 3.2 has no inline (?i) in [[ =~ ]].
AI_TRAILER_RE='co-authored-by:.*(claude|anthropic|openai|gpt|codex|copilot|gemini|cursor)'
AI_MARKER_RE='generated with .*(claude|chatgpt|openai|copilot|gemini|codex)|noreply@anthropic\.com'

MAX_BRANCH_LEN=60
MAX_SUBJECT_LEN=72
LARGE_FILE_BYTES=5242880   # 5 MiB

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

is_protected() { [[ "$1" =~ $PROTECTED_RE ]]; }

valid_branch() {
  [ "${#1}" -le "$MAX_BRANCH_LEN" ] || return 1
  [[ "$1" =~ $BRANCH_RE ]]
}

# The branch to judge. Prints nothing and fails on a detached HEAD.
current_branch() {
  local b
  b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 1
  [ "$b" = "HEAD" ] && return 1
  printf '%s' "$b"
}

git_path() { git rev-parse --path-format=absolute --git-path "$1" 2>/dev/null; }

in_progress_operation() {
  local f
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    [ -e "$(git_path "$f")" ] && return 0
  done
  [ -d "$(git_path rebase-merge)" ] && return 0
  [ -d "$(git_path rebase-apply)" ] && return 0
  return 1
}

# "Is this work already in the base branch?" — ancestry OR patch-equivalence.
# Squash merges create a new commit, so the tip is never an ancestor; `git cherry`
# compares patch ids and prints '-' for commits already upstream. A multi-commit
# squash is not locally detectable (every line is '+'), and callers must treat that
# as "not provably merged".
merged_into() {
  local base="$1" tip="$2" out
  [ -n "$base" ] && [ -n "$tip" ] || return 1
  git merge-base --is-ancestor "$tip" "$base" 2>/dev/null && return 0
  out="$(git cherry "$base" "$tip" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | grep -q '^+' && return 1
  return 0
}

refuse() {
  local title="$1"; shift
  {
    echo
    echo "=================================================================="
    echo " BLOCKED: $title"
    echo "=================================================================="
    [ "$#" -gt 0 ] && printf '%s\n' "$@"
    echo
  } >&2
}

note() { printf 'note: %s\n' "$*" >&2; }
