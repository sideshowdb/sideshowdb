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
