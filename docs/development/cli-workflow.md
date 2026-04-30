# Native CLI development workflow

This document explains how to change the native Zig CLI after the move to
the generated-first `usage` spec flow.

## Source of truth

The canonical CLI definition is:

- [src/cli/usage/sideshowdb.usage.kdl](../../src/cli/usage/sideshowdb.usage.kdl)

This file defines the public CLI shape:

- commands and subcommands
- flags
- choices and defaults
- help and long-help text
- examples
- documentation metadata used by `usage`

The shipped native CLI does not parse this file at runtime in v1.

## How the build works

There are three layers in the current implementation:

1. [src/cli/usage/root.zig](../../src/cli/usage/root.zig)
   This is the build-time parser and code generator. It uses `ckdl`
   through Zig FFI to parse the KDL usage spec and emit a generated Zig
   module.
2. [src/cli/usage/runtime.zig](../../src/cli/usage/runtime.zig)
   This is the runtime-only usage model and generic argv parser. It is
   intentionally separate so the shipped CLI does not need the build-time
   `ckdl` parser linked into it.
3. [src/cli/app.zig](../../src/cli/app.zig)
   This is the thin runtime dispatcher. It consumes generated usage
   metadata and routes parsed commands into the existing handlers.

`build.zig` wires this together so `zig build` first generates a Zig
module from `sideshowdb.usage.kdl`, then compiles the native CLI against
that generated module.

## CLI build steps

The dedicated CLI build steps are:

```bash
zig build cli:generate
zig build cli:sync-docs
zig build cli:artifacts
```

### `zig build cli:generate`

Parses `src/cli/usage/sideshowdb.usage.kdl` with `ckdl` and emits the
generated Zig module into the build cache.

Use this when you want to validate that the usage spec and codegen still
compile.

### `zig build cli:sync-docs`

Regenerates the tracked CLI reference page:

- [site/src/routes/docs/cli/+page.md](../../site/src/routes/docs/cli/+page.md)

This page is generated from the usage spec via `usage generate markdown`
and should not be edited by hand.

### `zig build cli:artifacts`

Generates CLI release artifacts from the usage spec:

- `zig-out/share/man/man1/sideshowdb.1`
- `zig-out/share/completions/sideshowdb.bash`
- `zig-out/share/completions/sideshowdb.fish`
- `zig-out/share/completions/_sideshowdb`

## Typical change flow

When adding or changing CLI behavior:

1. Edit
   [src/cli/usage/sideshowdb.usage.kdl](../../src/cli/usage/sideshowdb.usage.kdl).
2. If the change introduces new runtime behavior, update
   [src/cli/app.zig](../../src/cli/app.zig).
3. Add or update Zig tests:
   - [tests/cli_usage_spec_test.zig](../../tests/cli_usage_spec_test.zig)
   - [tests/cli_test.zig](../../tests/cli_test.zig)
4. Add or update acceptance coverage in:
   - [acceptance/typescript/features/](../../acceptance/typescript/features/)
5. Regenerate docs and artifacts:

```bash
zig build cli:generate
zig build cli:sync-docs
zig build cli:artifacts
```

6. Run verification:

```bash
zig build test
zig build js:acceptance
```

For user-visible changes, keep the repo’s EARS and acceptance-test rules in
mind:

- add or update EARS statements
- map each user-visible requirement to acceptance coverage
- do not land CLI surface changes with only unit tests

## Where to put tests

Use the tests by responsibility:

- [tests/cli_usage_spec_test.zig](../../tests/cli_usage_spec_test.zig)
  For usage-spec parsing, codegen, unsupported-node handling, raw/multiline
  string handling, command/flag metadata, and generic parser behavior.
- [tests/cli_test.zig](../../tests/cli_test.zig)
  For native CLI contract behavior, dispatch, output, exit codes, backend
  selection, and regressions across real commands.
- [acceptance/typescript/features/](../../acceptance/typescript/features/)
  For end-to-end user-visible CLI scenarios.

## Current limitations

The current implementation is intentionally conservative about which
`usage` metadata it relies on.

The biggest known limitation is config metadata support in `usage-cli`
`3.2.1`:

- top-level `config_file` was rejected by the current `usage` binary
- flag-level `config=` metadata was also rejected

Because of that, the canonical usage spec currently documents config
precedence for `--refstore` in `long_help` text rather than in first-class
`usage` config metadata.

Tracked follow-up:

- `sideshowdb-evf` — investigate `usage-cli` config metadata support for
  CLI specs

## Editing rules of thumb

- Treat `sideshowdb.usage.kdl` as the public command contract.
- Treat generated CLI docs as derived artifacts.
- Prefer adding metadata to the spec before adding ad hoc help text in
  Zig code.
- Keep runtime dispatch in `src/cli/app.zig` thin; if parsing behavior can
  come from generated metadata, prefer that over another handwritten argv
  special case.
