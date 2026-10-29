#!/usr/bin/env bash
# sensitive-guard.sh — one source of truth for "this must never reach the repo".
#
# Why this exists: .gitignore only hides untracked files. It does not stop
# `git add -f`, it does not stop a file that was committed before the rule was
# written, and it does not stop a secret pasted into a normal source file.
# The hooks in .githooks/ call this script and refuse the commit / push.
#
# Modes
#   staged            check the index .......................... .githooks/pre-commit
#   push [remote]     check every file outgoing commits add ..... .githooks/pre-push
#   tree              audit what is already tracked ............. cargo make guard
#
# The path rules mirror the never-commit zone at the top of .gitignore.
# Keep the two lists in sync when you add a category. Pattern syntax differs:
# gitignore uses globs (X/, *.pem, !negation); this file uses POSIX ERE matched
# against the repo-relative path ((^|/)X(/|$), \.pem$, SAFE_PATTERNS).
#
# Exit codes: 0 = clean, 1 = violation (the hook aborts the git operation), 2 = usage.
#
# Deliberate escape hatch, human only: git commit/push --no-verify.
set -uo pipefail

MODE="${1:-staged}"
REMOTE="${2:-origin}"

if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "sensitive-guard: not inside a git work tree, nothing to check" >&2
  exit 0
fi
cd "$ROOT" || exit 1

ZERO=0000000000000000000000000000000000000000

# ---------------------------------------------------------------------------
# Paths that must never be committed. ERE, matched against the repo-relative
# path. Mirrors .gitignore's never-commit zone.
# ---------------------------------------------------------------------------
PATH_PATTERNS=(
  # agent / assistant state and instruction dirs (any depth: always tool state)
  '(^|/)\.agent(/|$)'
  '(^|/)\.agents(/|$)'
  '(^|/)\.claude(/|$)'
  '(^|/)\.codex(/|$)'
  '(^|/)\.cursor(/|$)'
  '(^|/)\.windsurf(/|$)'
  '(^|/)\.continue(/|$)'
  '(^|/)\.serena(/|$)'
  '(^|/)\.specstory(/|$)'
  '(^|/)\.gemini(/|$)'
  '(^|/)\.anthropic(/|$)'
  '(^|/)\.opencode(/|$)'
  '(^|/)\.aider[^/]*(/|$)'
  '(^|/)\.mcp\.json$'
  # agent working dirs, repo root only (crate-level "agent" is not a thing here,
  # but crate-level "docs" might be — both are anchored so nesting stays usable)
  '^agent(/|$)'
  '^agents(/|$)'
  # local-only working dirs
  '(^|/)\.worktrees?(/|$)'
  '(^|/)\.docs(/|$)'
  '^docs(/|$)'
  '(^|/)\.plans(/|$)'
  # environment files
  '(^|/)\.env$'
  '(^|/)\.env\.[^/]+$'
  '(^|/)\.envrc$'
  # keys, keystores, credential blobs (*.asc is not blocked by name: it is the
  # normal extension for PGP public keys and detached signatures; a private PGP
  # block is caught by the content scan instead)
  '\.(pem|key|p12|pfx|jks|keystore|kdbx|ppk|ovpn|har|pcap|pcapng)$'
  '(^|/)id_rsa[^/]*$'
  '(^|/)id_dsa[^/]*$'
  '(^|/)id_ecdsa[^/]*$'
  '(^|/)id_ed25519[^/]*$'
  '(^|/)\.netrc$'
  '(^|/)\.npmrc$'
  '(^|/)\.pypirc$'
  '(^|/)\.htpasswd$'
  '(^|/)\.git-credentials$'
  '(^|/)\.kube(/|$)'
  '(^|/)kubeconfig[^/]*$'
  '(^|/)\.docker/config\.json$'
  '(^|/)\.cargo/credentials(\.toml)?$'
  '(^|/)auth\.json$'
  # named credentials / secrets files
  '(^|/)credentials[^/]*\.(json|ya?ml|toml|ini|txt|env)$'
  '(^|/)secrets?\.(json|ya?ml|toml|ini|txt|env)$'
  '(^|/)service[-_]account[^/]*\.json$'
  '(^|/)acme[^/]*\.json$'
  # infrastructure state and var files
  '(^|/)secrets\.tfvar$'
  '\.tfvars(\.json)?$'
  '\.tfstate(\.[^/]*)?$'
  '(^|/)\.terraform(/|$)'
  # local databases
  '\.(sqlite3?|db|db3|mdb)$'
)

# Paths that look like the above but are safe. Checked first, so they win.
# Mirrors the negations in .gitignore.
SAFE_PATTERNS=(
  '\.pub$'
  '(^|/)\.env\.(example|sample|template|dist|schema)$'
  '(^|/)\.terraform\.lock\.hcl$'
  '\.tfvars\.example$'
)

# ---------------------------------------------------------------------------
# Content patterns — only used when gitleaks is not installed.
# ---------------------------------------------------------------------------
CONTENT_PATTERNS=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '-----BEGIN PGP PRIVATE KEY BLOCK-----'
  '(A3T[A-Z0-9]|AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[A-Z0-9]{16}'
  'gh[pousr]_[A-Za-z0-9]{36,}'
  'github_pat_[A-Za-z0-9_]{40,}'
  'glpat-[A-Za-z0-9_-]{20,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'sk-(proj-)?[A-Za-z0-9_-]{32,}'
  'sk_live_[A-Za-z0-9]{20,}'
  'rk_live_[A-Za-z0-9]{20,}'
  'whsec_[A-Za-z0-9]{20,}'
  'AIza[0-9A-Za-z_-]{35}'
  'ya29\.[0-9A-Za-z_-]{20,}'
  'SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}'
  'npm_[A-Za-z0-9]{36}'
  'dckr_pat_[A-Za-z0-9_-]{20,}'
)

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
fail() {
  local title="$1"; shift
  {
    echo
    echo "=================================================================="
    echo " BLOCKED by sensitive-guard: $title"
    echo "=================================================================="
    printf '%s\n' "$@"
    echo
  } >&2
}

fix_advice() {
  cat >&2 <<'EOF'
 Fix it like this:
   1. git rm --cached <path>                     # untrack, keep it on disk
   2. add the pattern to .gitignore              # so it stays untracked
   3. git commit --amend  (or reset the branch)  # drop it from the commits
   4. if the value ever reached a remote, ROTATE it
 A secret that was pushed is compromised even after you delete it.

 Nothing here belongs in git: agent state, worktrees, plans, .env, keys.
 The tracked template is .env.example.
EOF
}

# ---------------------------------------------------------------------------
# Path checking (stdin: one repo-relative path per line)
# ---------------------------------------------------------------------------
check_paths() {
  local -a offenders=()
  local f p s skip
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    f="${f#./}"
    skip=0
    for s in "${SAFE_PATTERNS[@]}"; do
      if [[ "$f" =~ $s ]]; then skip=1; break; fi
    done
    [ "$skip" -eq 1 ] && continue
    for p in "${PATH_PATTERNS[@]}"; do
      if [[ "$f" =~ $p ]]; then offenders+=("$f"); break; fi
    done
  done
  if [ "${#offenders[@]}" -gt 0 ]; then
    local -a lines=("These paths must never be committed:")
    local o
    for o in "${offenders[@]}"; do lines+=("  - $o"); done
    fail "sensitive path(s) in this change" "${lines[@]}"
    fix_advice
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Content checking
# ---------------------------------------------------------------------------
run_gitleaks() {
  # $@ = args for `gitleaks git`. Fails closed: any non-zero exit blocks,
  # including "unable to load gitleaks config".
  local out rc
  out="$(gitleaks git "$ROOT" --no-banner --redact --max-target-megabytes 10 -v "$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "secret scan failed or found a secret (gitleaks exit $rc)" "$out"
    fix_advice
    return 1
  fi
  return 0
}

scan_fallback() {
  # $1 = label; stdin = added lines. Redacts before printing.
  local label="$1" line redacted
  local -a hits=()
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  for pat in "${CONTENT_PATTERNS[@]}"; do
    while IFS= read -r line; do
      redacted="$(printf '%s' "$line" | sed -E 's/[A-Za-z0-9_+\/=-]{12,}/<redacted>/g' | cut -c1-160)"
      hits+=("  - ${label}: ${redacted}")
      [ "${#hits[@]}" -ge 10 ] && break 2
    done < <(grep -E -- "$pat" "$tmp" 2>/dev/null)
  done
  rm -f "$tmp"
  if [ "${#hits[@]}" -gt 0 ]; then
    fail "secret-like string in this change (gitleaks not installed; built-in patterns)" "${hits[@]}"
    fix_advice
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
mode_staged() {
  local rc=0
  check_paths < <(git diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null | tr '\0' '\n') || rc=1

  if have gitleaks; then
    run_gitleaks --staged || rc=1
  else
    scan_fallback "staged" < <(git diff --cached --unified=0 --no-color 2>/dev/null) || rc=1
  fi
  return "$rc"
}

# Build the ranges an outgoing push actually adds, from git's pre-push stdin:
#   <local-ref> <local-sha> <remote-ref> <remote-sha>
# A new branch has an all-zero remote-sha, and "<zeros>..<sha>" is an INVALID
# range that gitleaks scans as zero commits while exiting 0 — so it is derived
# as "<sha> --not --remotes=<remote>" instead (fail-closed, see plan §3.3).
push_ranges() {
  local lref lsha rref rsha
  while IFS=' ' read -r lref lsha rref rsha; do
    [ -n "${rref:-}" ] || continue
    [ -n "${lsha:-}" ] || continue
    [ "$lsha" = "$ZERO" ] && continue        # deleting a remote ref: adds nothing
    if ! git cat-file -e "${lsha}^{commit}" 2>/dev/null; then
      fail "cannot resolve the local commit being pushed" "  - $lref -> $lsha"
      return 1
    fi
    if [ "${rsha:-$ZERO}" = "$ZERO" ]; then
      printf '%s\n' "$lsha --not --remotes=$REMOTE"
    else
      printf '%s\n' "$rsha..$lsha"
    fi
  done
}

mode_push() {
  local input
  input="$(cat 2>/dev/null || true)"

  local ranges_out
  if ! ranges_out="$(printf '%s\n' "$input" | push_ranges)"; then
    return 1
  fi
  [ -n "$ranges_out" ] || return 0

  local rc=0 r count
  local -a files=()
  while IFS= read -r r; do
    [ -n "$r" ] || continue

    # Rule 2: an uncountable range is a block, never a silent pass.
    # shellcheck disable=SC2086
    if ! count="$(git rev-list --count $r 2>/dev/null)"; then
      fail "cannot verify what this push would send" \
        "  - range: $r" \
        "  - git rev-list --count failed; refusing to push unscanned history"
      rc=1
      continue
    fi
    [ "$count" -gt 0 ] || continue

    # shellcheck disable=SC2086
    while IFS= read -r f; do
      [ -n "$f" ] && files+=("$f")
    done < <(git log --diff-filter=AMR --name-only --pretty=format: $r 2>/dev/null)

    if have gitleaks; then
      # shellcheck disable=SC2086
      run_gitleaks --log-opts="$r" || rc=1
    else
      # shellcheck disable=SC2086
      scan_fallback "pushed" < <(git log -p --unified=0 --no-color --pretty=format: $r 2>/dev/null) || rc=1
    fi
  done <<<"$ranges_out"

  if [ "${#files[@]}" -gt 0 ]; then
    if ! printf '%s\n' "${files[@]}" | sort -u | check_paths; then
      rc=1
    fi
  fi
  return "$rc"
}

mode_tree() {
  local rc=0
  check_paths < <(git ls-files) || rc=1

  if have gitleaks; then
    local out
    out="$(gitleaks dir "$ROOT" --no-banner --redact -v --exit-code 0 2>&1)"
    if printf '%s' "$out" | grep -q 'Finding:'; then
      {
        echo
        echo "NOTE: gitleaks reports findings in code you already track."
        printf '%s\n' "$out" | grep -E 'Finding:|RuleID:|File:|Line:' | sed 's/^/  /'
        echo
        echo "  Not blocking — this is already in history. Each one needs a human"
        echo "  decision: rotate it, or allowlist it deliberately in .gitleaks.toml."
      } >&2
    fi
  fi

  if [ "$rc" -eq 0 ]; then
    echo "sensitive-guard: no sensitive path is tracked"
  fi
  return "$rc"
}

case "$MODE" in
  staged) mode_staged ;;
  push)   mode_push ;;
  tree)   mode_tree ;;
  *)
    echo "usage: $0 {staged|push [remote]|tree}" >&2
    exit 2
    ;;
esac
