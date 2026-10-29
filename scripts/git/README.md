# Git rules

Everything here is executable: a rule that a hook or a script cannot see is stated as
convention and marked as such. The mechanics live in `lib.sh` (one source of truth), the
hooks in `.githooks/`, and the secrets/agent-state rules in `scripts/guard/README.md`.

```
scripts/git/setup.sh        # one command per clone: local config + hooks
scripts/git/selftest.sh     # prove every rule below actually blocks
scripts/git/doctor.sh       # what is my branch/worktree/merge state?
scripts/git/worktree.sh     # worktree convention, executable
```

## 1. Branches

```
<type>/<slug>
```

| Type | Use for |
|---|---|
| `feat` | new behaviour |
| `fix` | bug fix |
| `hotfix` | urgent fix, may be released out of band |
| `chore` | maintenance, deps, tooling, no product behaviour |
| `docs` | documentation only |
| `refactor` | same behaviour, different structure |
| `test` | tests only |
| `perf` | performance |
| `build` | build system, packaging |
| `ci` | pipelines |
| `style` | formatting only |
| `revert` | reverting a commit |
| `release` | release preparation (`release/1.2.3`) |

Slug: lowercase, `-` separated, dots allowed in versions. An uppercase ticket prefix is
allowed: `fix/PROJ-123-null-deref`, `feat/2135-compute-tier-ord`. Maximum 60 characters.
Bot branches keep their shape and may nest: `dependabot/cargo/serde-1.0.219`,
`renovate/serde-1.x`.

**Protected:** `main`, `master`, `develop`, `staging`, `production`, `gh-pages`. Never committed
to, never pushed to — by any spelling (`git push origin HEAD:main` included), including force and
delete.

## 2. Lifecycle

```
git fetch origin
scripts/git/worktree.sh add feat/short-description        # from origin/main
# ... work, commit, push ...
git push -u origin HEAD                                   # publishes the branch
# ... pull request, review, squash merge on the remote ...
scripts/git/worktree.sh remove feat/short-description      # after the merge
```

- Branch from the remote's `main`, not from a stale local `main`.
- `git pull --rebase` is the default here (`pull.rebase=true`); keep a pushed branch's history
  usable for review, and do not rewrite it after review has started (`CONTRIBUTING.md`).
- A force-push is allowed on a feature branch (fixups), never on a protected branch.
- Delete a branch only after its work is in `main`. A **squash** merge is not ancestry, so the
  hook also accepts patch-equivalence; a multi-commit squash is indistinguishable from an
  unmerged branch locally, and is refused with `--no-verify` named as the deliberate escape.
- Merges into `main` happen by pull request on the remote. Locally, `pre-push` refuses every
  update of a protected ref.

## 3. Worktrees

One layout, no exceptions:

```
<repo>/.worktrees/<branch>          # feat/foo -> .worktrees/feat/foo
```

- `.worktrees/` is gitignored, so a worktree cannot be committed.
- `worktree.sh add <branch> [base]` validates the name, uses `origin/<base>` (falling back to
  local `<base>`, refusing if neither resolves), and creates the branch **without** inheriting
  the base's upstream (`--no-track`) so `git push` can never target `main`.
- `worktree.sh add` on an existing branch attaches it instead of failing — "come back to this
  tomorrow" is a normal case.
- `worktree.sh remove` refuses a dirty worktree, always runs from the main worktree, and only
  deletes the branch when the merge is proven.
- A worktree outside `.worktrees/` is reported by `doctor.sh`; nothing enforces it, because git
  has no hook for `worktree add`.

## 4. Commits

Angular convention, as named by `CONTRIBUTING.md`:

```
<type>(<scope>)!: <description>

<why it changed>

Refs: #123
```

- `scope` optional; comma-separated for several: `feat(builder, cargo-shuttle): ...`
- Subject ≤ 72 characters, no trailing period.
- Exempt verbatim: `Merge …`, `Revert …`, `fixup! …`, `squash! …`, `wip: …` (checkpoints).
- The description need not start lowercase — `MSRV 1.89` and crate names are legitimate.
- **No AI attribution.** No `Co-Authored-By: <assistant>`, no `Generated with …`, no robot
  marker. The human is the sole author. Enforced on the cleaned message (comments, template and
  the `--verbose` diff body are stripped first).
- Comment lines, the scissors body and `.gitmessage` are ignored, so a template that documents
  the rule cannot trip it.

## 5. What enforces what

| Rule | Enforced by | Bypass |
|---|---|---|
| no commits on protected branches | `pre-commit` → `pre-commit-rules.sh` | `--no-verify` |
| no commits on detached HEAD | same | `--no-verify` |
| branch name convention | `pre-commit` (commit) and `pre-push` (destination) | rename; `--no-verify` |
| commit message format + no AI attribution | `commit-msg` | `--no-verify` |
| protected refs never pushed (incl. force, delete, `HEAD:main`) | `pre-push` | `--no-verify` |
| delete only merged branches | `pre-push` | `--no-verify` |
| force-push notice | `pre-push` (advisory, never blocks) | — |
| no staged file > 5 MiB | `pre-commit` | `--no-verify` |
| no staged conflict markers | `pre-commit` | `--no-verify` |
| agent state / `.env` / keys / secret content | `pre-commit` + `pre-push` → `scripts/guard/` | `--no-verify` |
| worktree lives in `.worktrees/<branch>` | `worktree.sh` + `doctor.sh` (convention: no hook exists) | — |
| branch from `origin/main`, squash-merge via PR | convention (remote-side branch protection is out of scope) | — |

**The one bypass is `git commit/push --no-verify`, and it is a human decision, never an agent
one.** Notably, the machine-global guard's interactive "type the branch name" override does not
get past `pre-push`: the project hook runs after it and refuses unconditionally.

Known gaps, stated rather than implied:

- `git rebase` runs neither `pre-commit` nor `commit-msg` (git behaviour), so `rebase -i` reword
  is not validated.
- `git am` does not run `commit-msg`.
- These hooks are local. A clone without `setup.sh` has none of them; remote-side branch
  protection is the real server boundary.

## 6. Local config `setup.sh` sets

| Setting | Why |
|---|---|
| `pull.rebase=true` | linear local history, no accidental merge commits |
| `fetch.prune=true` | deleted remote branches disappear from `branch -a` |
| `merge.conflictStyle=zdiff3` | conflict hunks show the common ancestor |
| `rerere.enabled=true` | repeated conflict resolution |
| `push.autoSetupRemote=true` | `git push` on a new branch does the right thing |
| `commit.template=.gitmessage` | the convention is in front of you while writing |
