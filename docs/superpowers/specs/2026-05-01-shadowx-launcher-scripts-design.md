# Shadowx Launcher Scripts Design

## Goal

Rename only the checked-in launcher wrapper scripts from `sideshow` to `shadowx`.
The native CLI binary, generated CLI usage, release artifact names, npm packages,
Zig module names, Git refs, and SideshowDB product naming remain unchanged.

Tracked by beads issue `sideshowdb-csk`.

## Requirements

- When a caller runs the POSIX `shadowx` wrapper with a wrapper flag such as
  `--help`, the wrapper shall identify itself as `shadowx` and describe
  forwarded arguments as `sideshow` CLI arguments.
- When a caller runs the Windows `shadowx.cmd` wrapper, the wrapper shall
  delegate to `shadowx.ps1`.
- When the `shadowx` wrapper resolves or installs a CLI release, it shall
  continue to locate and execute the existing `sideshow` binary artifacts
  without changing release asset names.
- If legacy `sideshow` wrapper paths are absent, then repository documentation
  shall direct users to `shadowx` for wrapper-based invocation.

## Scope

In scope:

- Rename root wrapper files to `shadowx`, `shadowx.ps1`, and `shadowx.cmd`.
- Update wrapper-facing help, comments, diagnostics, and README wrapper
  examples to use `shadowx`.
- Add focused tests or smoke checks for wrapper help and script presence.

Out of scope:

- Renaming `zig-out/bin/sideshow`.
- Renaming CLI usage text generated from `src/cli/usage/sideshow.usage.kdl`.
- Renaming release archives such as `sideshow-<version>-<os>-<arch>`.
- Renaming `@sideshowdb/*`, `sideshowdb.wasm`, Zig imports, or
  `refs/sideshowdb/*`.

## Design

The wrapper name is treated as a user-facing launcher alias for acquiring and
running the existing CLI. The POSIX and Windows wrappers should report the
script name as `shadowx`, but their install and execution path should continue
to target release layouts containing `dist/sideshow` or `dist/sideshow.exe`.

Documentation should make the distinction visible: users invoke the wrapper as
`./shadowx`, while arguments after wrapper options are still ordinary
`sideshow` CLI arguments. This keeps the requested rename narrow and avoids
changing generated CLI docs, completions, release packaging, or acceptance
scenarios for the native binary.

## Testing

Use TDD for wrapper-observable behavior:

- Add or update a smoke check that validates `./shadowx --help` identifies the
  wrapper as `shadowx`.
- Add a filesystem-level check that the root wrapper files are named
  `shadowx*` and the old root `sideshow*` wrapper files are absent.
- Run a targeted shell smoke test, then run the existing CLI build/test gate
  needed to prove the native binary name remains `sideshow`.
