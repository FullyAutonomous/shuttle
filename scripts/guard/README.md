# Never-commit guard

Two layers, because either one alone leaks.

| Layer | What it does | Where |
|---|---|---|
| Ignore rules | files never show in `git status`, never swept up by `git add .` | `.gitignore` (never-commit zone at the top) |
| Hooks | refuse the commit / push even for `git add -f`, already-tracked files, and secrets pasted into normal source files | `.githooks/` → `sensitive-guard.sh` |

The rules live in one place: **`scripts/guard/sensitive-guard.sh`**. `.gitignore` mirrors it.
When you add a category, add it to both — the syntaxes differ (globs vs POSIX ERE).

## Install (once per clone)

```sh
scripts/guard/install-git-hooks.sh
```

It installs `pre-commit`, `commit-msg` and `pre-push` into the repo's real hooks directory,
keeps any pre-existing hook as `<name>.pre-guard-backup`, and reports which `core.hooksPath` is
in effect. It is idempotent.

The branch, commit-message and push rules that run alongside this guard are documented in
`scripts/git/README.md` — this page covers only agent state and secrets. On a machine with a global `core.hooksPath` whose shim chains to
`$GIT_COMMON_DIR/hooks/<name>` (the setup here), the global guard still runs first.

Hooks are local, not versioned by git. A fresh clone needs the installer again.

## Use

```sh
cargo make guard           # audit what is already tracked (paths block, content findings note)
scripts/guard/selftest.sh  # prove both hooks actually block, end to end, in a throwaway repo
```

`git commit --no-verify` / `git push --no-verify` bypass the hooks. That is a human
decision, never an agent one.

## What is blocked

Agent state: `.agent/`, `.agents/`, `.claude/`, `.codex/`, `.cursor/`, `.windsurf/`,
`.continue/`, `.serena/`, `.specstory/`, `.gemini/`, `.anthropic/`, `.opencode/`, `.aider*`,
`.mcp.json`, root `/agent/`, `/agents/`.

Local-only work: `.worktrees/`, `.docs/`, `.plans/`, root `/docs/`.

Secrets by name: `.env` / `.env.*` (except `.env.example` and friends), `.envrc`, `*.pem`,
`*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `*.kdbx`, `*.ppk`, `*.ovpn`, `*.har`,
`*.pcap*`, `id_rsa*`, `id_ed25519*` (public `*.pub` allowed), `.netrc`, `.npmrc`, `.pypirc`,
`.htpasswd`, `.git-credentials`, `.kube/`, `kubeconfig*`, `.docker/config.json`,
`.cargo/credentials*`, `auth.json`, `credentials*.*`, `secret(s)?.*`,
`service[-_]account*.json`, `acme*.json`, `*.tfvars` (except `*.tfvars.example`),
`*.tfstate*`, `.terraform/` (lock file allowed), `*.sqlite*`, `*.db`, `*.db3`, `*.mdb`.

Secrets by content: `gitleaks` over staged changes and every outgoing commit. If gitleaks is
missing, a built-in pattern set runs. A scanner failure blocks — it never passes silently.

## Deliberate choices worth knowing

- `docs/` is ignored at the repo root only; a crate-level `docs/` still works. Same for
  `agent/`. Remove the rule from **both** files if a real docs tree is wanted.
- `*.asc` is not blocked by name — it is the normal extension for PGP public keys and
  detached signatures. A private PGP key block is caught by the content scan.
- `.terraform.lock.hcl` is un-ignored on purpose: it belongs in the repo.
- Fixture databases are not carved out: name them `<name>.db.example`.
- The one content finding already in history — a PostHog project ingest key in upstream
  `install.ps1`, which is public by design — is allowlisted in `.gitleaks.toml` by rule
  (`generic-api-key`) and shape (`phc_...`), not by file, so every other finding in that file
  is still reported.
- A secret that already reached a remote is invisible to pre-push. Hooks stop new leaks; they
  cannot un-leak. Rotate it, and rely on remote-side secret scanning for the server boundary.
