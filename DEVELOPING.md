# Developing

This file is the contributor quick-start for day-to-day work in the
repository.

## Issue tracking

SideshowDB uses `bd` (beads) for all work tracking.

```bash
bd ready --json
bd show <id> --json
bd update <id> --claim --json
bd close <id> --reason "Completed" --json
```

See [AGENTS.md](./AGENTS.md) for the full repo workflow and completion
requirements.

### Syncing beads on main

The tracked `.beads/issues.jsonl` file is a generated export of the
Dolt-backed `bd` database. If `main` is otherwise clean but the export is dirty
or stale after issue work, regenerate it from `bd` instead of hand-editing it.

```bash
git status --short --branch
git stash push -m "beads export before main sync" -- .beads/issues.jsonl
git pull --ff-only origin main
bd dolt pull
bd dolt push
bd export -o .beads/issues.jsonl
git diff -- .beads/issues.jsonl
git add .beads/issues.jsonl
git commit -m "chore(beads): sync issue export"
git push
git status
```

If you stashed a stale generated export, remove only that temporary stash after
the regenerated export is committed or verified unnecessary:

```bash
git stash list --date=local
git stash drop stash@{0}
```

If files other than `.beads/issues.jsonl` are dirty, preserve those changes
separately before syncing `main`.

## Common build commands

```bash
zig build
zig build test
zig build wasm
zig build js:acceptance
zig build site:build
```

## Native CLI workflow

The native CLI is now generated-first.

- The canonical source of truth is
  [src/cli/usage/sideshowdb.usage.kdl](./src/cli/usage/sideshowdb.usage.kdl).
- Build-time parsing and Zig code generation live in
  [src/cli/usage/](./src/cli/usage/).
- The tracked CLI reference page at
  [site/src/routes/docs/cli/+page.md](./site/src/routes/docs/cli/+page.md)
  is generated from the usage spec and should not be hand-edited.

When changing the CLI:

1. Update `src/cli/usage/sideshowdb.usage.kdl`.
2. Update runtime dispatch in `src/cli/app.zig` if the change needs new
   handler logic.
3. Add or update Zig regression coverage in `tests/cli_test.zig` and
   `tests/cli_usage_spec_test.zig`.
4. Add or update TypeScript acceptance coverage in
   `acceptance/typescript/features/` for user-visible behavior changes.
5. Regenerate docs and artifacts:

```bash
zig build cli:generate
zig build cli:sync-docs
zig build cli:artifacts
```

6. Re-run verification:

```bash
zig build test
zig build js:acceptance
```

For the deeper CLI authoring flow, file layout, and current `usage-cli`
limitations, see
[docs/development/cli-workflow.md](./docs/development/cli-workflow.md).
