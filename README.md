# kikori 🪓

*A woodcutter for your git worktrees: grows a fresh worktree per work session, and fells everything a merged branch leaves behind.*

[日本語 README](README.ja.md)

`kikori` manages the lifecycle of **session worktrees** — the disposable
checkouts you create per task (especially when running several AI-coding or
review sessions in parallel):

- **`kikori start`** creates a worktree under `<repo>-worktrees/<branch>` with a
  dated branch name, copies your gitignored personal files into it, and runs
  your project's setup hook.
- **`kikori cleanup`** finds local branches whose PR has merged — including
  stacked PRs whose heads were rebased server-side — and deletes the branches,
  their worktrees, and any project resources tied to them (simulators, caches,
  containers, …) after a single confirmation.

Everything project-specific is injected through config, hooks, and **cleaner
plugins**, so the core stays language- and toolchain-agnostic.

## Install

```bash
git clone https://github.com/sei-lit/kikori.git ~/.kikori
ln -s ~/.kikori/bin/kikori /usr/local/bin/kikori
```

Requirements: bash 3.2+ (macOS's `/bin/bash` works), git 2.31+.
`kikori cleanup` additionally needs [gh](https://cli.github.com/) and a GitHub
repository (PR lookup is GitHub-only for now).

## `kikori start`

```
$ kikori start
  📝  Describe the task (Enter to skip)
  ▸ fix login crash on cold start
  🌱  Base branch (Enter for origin/main)
  ▸
  🤖  Generating branch slug... done (3s)
  ✓  Branch slug: fix-login-cold-start-crash
  🔄  Fetching origin/main... done
  📦  Creating worktree (base: origin/main)... done
  ✓  Worktree ready
    Branch  20260916-fix-login-cold-start-crash
    Path    /path/to/repo-worktrees/20260916-fix-login-cold-start-crash
```

What happens, in order:

1. The base branch is fetched (`origin/<main>` by default, detected from the
   remote HEAD).
2. `git worktree add -b <branch> <worktrees-dir>/<branch> <base>`.
3. Paths listed in `.kikori-copy` (root-relative, globs allowed, `#` comments)
   are copied in — worktrees only contain committed files, so this is how
   gitignored personal settings and build caches survive. Copies use
   copy-on-write (`cp -c` on APFS, `--reflink=auto` on Linux), so multi-GB
   caches cost ~0 disk and time. The copy source is the base branch's worktree
   when it has one, falling back to the main checkout.
4. Your `kikori_post_create` hook runs (dependency install, simulator creation,
   relinking symlinks…). Failure warns but keeps the worktree.

Options: `--task <text>`, `--base <branch>`, `--copy-from <dir>`,
`--skip-post-create`, `--dry-run`.

## `kikori cleanup`

```
$ kikori cleanup
  🧹  To be deleted
    Worktrees
      1) /path/to/repo-worktrees/20260916-fix-login-cold-start-crash
    Branches
      1) 20260916-fix-login-cold-start-crash
    xcode-simulators
      1) wt-20260916-fix-login-cold-start-crash (4A1B..., Shutdown)
  🧹  Delete these? (y/N)
```

A branch is only auto-deleted when kikori can **prove** its changes are
contained in `origin/<main>`:

1. the local tip equals a merged PR head (PRs merged into other branches don't
   count), or
2. the local tip is reachable from `origin/<main>`, or
3. the branch was rebased + force-pushed server-side before merging (GitHub
   stacked PRs do this): the branch is gone from the remote, the local tip was
   pushed, there are no local merge commits, and every commit's patch-id has an
   equivalent on `origin/<main>`.

Anything with a merged PR that can't be proven is listed under **Needs review**
with the reason and the manual command — it is deleted only with `--force`.
Worktrees with uncommitted changes also require `--force`. Every failure mode
errs toward keeping things.

Options:

| flag | effect |
| --- | --- |
| `--only <targets>` | Clean only some targets: `branches`, `worktrees`, and each cleaner plugin by name. `--only xcode-simulators,xcodebuildmcp-caches` deletes just those resources. With `--only branches`, branches still checked out in a worktree are skipped (with the reason shown) rather than half-deleted. |
| `--force` | Also delete needs-review items. |
| `--dry-run` | List everything, delete nothing, no prompt. |
| `--yes` | Skip the confirmation prompt. |

Exit codes: `0` success, `1` cancelled or partial failure, `2` preconditions
not met.

## Configuration

Layered, weakest first:

1. built-in defaults
2. `${XDG_CONFIG_HOME:-~/.config}/kikori/config.sh` (per user)
3. `<repo>/.kikori/config.sh` (per repository; requires `kikori trust`)
4. environment variables
5. command-line flags

See [examples/config.sh](examples/config.sh) for every variable and hook:

- `KIKORI_REMOTE`, `KIKORI_MAIN_BRANCH`, `KIKORI_BASE_BRANCH`,
  `KIKORI_WORKTREES_DIR`, `KIKORI_COPY_FILE`, `KIKORI_PROTECTED_BRANCHES`,
  `KIKORI_CLEANERS`
- `kikori_slug <task>` — generate the branch slug (an LLM CLI works well;
  non-slug output is discarded, falling back to a timestamp)
- `kikori_branch_name <slug>` — override the `YYYYMMDD-<slug>` naming
- `kikori_post_create <worktree> <branch> <base>` — project setup

### Security model

Config files are sourced as bash, which runs their code. Your user config is
your own. **Repository config is code that arrives with the repository**, so
kikori refuses to load `<repo>/.kikori/config.sh` until you trust its exact
content with `kikori trust` (interactively it offers to trust after showing a
warning). Any change to the file — including one arriving in a pulled commit —
invalidates the trust. Without a TTY, an untrusted config is a hard error, not
a silent skip.

## Cleaner plugins

Platform-specific resources (iOS simulators, build caches, containers, DB
snapshots…) are cleaned by **cleaner plugins**: executables in
`<repo>/.kikori/cleaners/`, or paths listed in `KIKORI_CLEANERS`. Each plugin's
name (its basename) becomes a `--only` target. Two shipped examples:

- [examples/cleaners/xcode-simulators](examples/cleaners/xcode-simulators) —
  deletes per-worktree iOS simulators whose worktree is gone
- [examples/cleaners/xcodebuildmcp-caches](examples/cleaners/xcodebuildmcp-caches) —
  deletes XcodeBuildMCP DerivedData caches whose workspace root is gone

### Protocol

A cleaner is called in two phases:

```
<cleaner> plan [--assume-removed <path>]...
<cleaner> delete [--force]        # confirmed ids on stdin, one per line
```

**plan** writes one TSV line per item to stdout:

```
auto<TAB><id><TAB><display>
review<TAB><id><TAB><display><TAB><reason>
```

`auto` items are deleted after the user confirms; `review` items are shown and
only deleted with `--force`. `--assume-removed` paths are worktrees kikori is
about to delete in the same run — treat them as already gone (each is an
absolute path of a worktree that is actually scheduled for removal).

**delete** receives the confirmed ids on stdin and writes one TSV result line
per id:

```
deleted<TAB><id>
skipped<TAB><id><TAB><reason>
failed<TAB><id><TAB><reason>
```

Exit non-zero when anything failed.

Rules a cleaner must follow:

- **Re-validate in the delete phase.** State can change between plan and
  delete (a worktree removal can fail, a simulator can boot). Never delete an
  id you would no longer classify as deletable — report it as `skipped`.
  `--force` widens what counts as deletable (review items); it never means
  "skip validation".
- **Be idempotent.** Deleting an already-gone id is `skipped`, not an error.
- **Stay independent.** Plugins run in unspecified order and must not depend
  on each other. If two resources must be deleted in order, make them one
  plugin.
- Ids and displays must not contain tabs or newlines.
- kikori exports `KIKORI_MAIN_ROOT`, `KIKORI_WORKTREES_DIR`, `KIKORI_REMOTE`
  and `KIKORI_MAIN_BRANCH` to cleaner processes.

Anything on the cleaner's stderr is passed through to the user; stdout is
protocol only.

## Development

```bash
tests/run.sh              # self-contained: throwaway repos + a stubbed gh
tests/run.sh cleaner      # filter by name
shellcheck -x -s bash bin/kikori libexec/* lib/*.sh examples/cleaners/*
```

## License

[MIT](LICENSE)
