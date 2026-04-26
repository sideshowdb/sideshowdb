# sideshowdb

Sideshow is an event-sourced, offline-friendly database backed by Git.

> **Status:** project skeleton. Spec is in
> [docs/development/specs/sideshowdb-spec.md](docs/development/specs/sideshowdb-spec.md);
> implementation lands in follow-up work.

## Layout

```text
src/
  core/   shared library (module name: "sideshowdb")
  cli/    native CLI executable
  wasm/   wasm32-freestanding browser client
tests/    cross-module integration tests
```

## Requirements

- Zig **0.16.0** or newer (`minimum_zig_version` is enforced in `build.zig.zon`).

## Build & run

```bash
zig build              # build the native CLI into zig-out/bin/sideshowdb
zig build run          # build + run the CLI (prints the banner)
zig build wasm         # build wasm32-freestanding client into zig-out/wasm/sideshowdb.wasm
zig build test         # run unit + integration tests
```

The `wasm` step produces a `.wasm` module with no entry point and the
following C-ABI exports: `sideshowdb_version_major`, `sideshowdb_version_minor`,
`sideshowdb_version_patch`, `sideshowdb_banner_ptr`, `sideshowdb_banner_len`.
