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

## Install

Pick whichever path matches what you need:

- **From a release binary** — fastest, no Zig toolchain required.
- **From source** — required for development or building the WASM client.

For the full walkthrough (prerequisites + end-to-end example), see the
[Getting Started](https://sideshowdb.github.io/sideshowdb/docs/getting-started/)
docs.

### From a release binary

Tagged releases publish CLI binaries for **linux**, **macos**, and **windows** on
**amd64** and **arm64**, plus the `sideshowdb.wasm` artifact. Linux binaries are
statically linked against musl so they run on any modern distro. Each release
also ships a `SHA256SUMS` file.

Release assets follow the standard
`sideshowdb-<version>-<os>-<arch>.<ext>` naming convention, so the
[mise](https://mise.jdx.dev/) **github** backend installs the right
asset for your platform out of the box:

```bash
mise use github:sideshowdb/sideshowdb@latest
# or pin a specific tag
mise use github:sideshowdb/sideshowdb@v0.1.0
```

Downloading directly: see the
[Releases page](https://github.com/sideshowdb/sideshowdb/releases) and pick the
archive matching your platform. Each archive contains the `sideshowdb`
executable alongside `LICENSE` and `README.md`. Verify the archive against
`SHA256SUMS` before running it.

### From source

Requirements:

- Zig **0.16.0** or newer (`minimum_zig_version` is enforced in `build.zig.zon`).
- Bun **1.x** for the repo-root workspace that powers the docs site and TypeScript packages.

```bash
git clone https://github.com/sideshowdb/sideshowdb.git
cd sideshowdb
zig build              # build the native CLI into zig-out/bin/sideshowdb
zig build wasm         # build wasm32-freestanding client into zig-out/wasm/sideshowdb.wasm
zig build js:install   # install Bun workspace dependencies from the repo root
```

## Build & run

```bash
zig build              # build the native CLI into zig-out/bin/sideshowdb
zig build run          # build + run the CLI (prints the banner)
zig build wasm         # build wasm32-freestanding client into zig-out/wasm/sideshowdb.wasm
zig build test         # run unit + integration tests
zig build js:test      # run Bun workspace tests from the repo root
zig build js:check     # run Bun workspace typechecks from the repo root
zig build site:build   # build the docs/playground site
zig build site:dev     # stage assets and start the local site dev server
```

The `wasm` step produces a `.wasm` module with no entry point and the
following C-ABI exports: `sideshowdb_version_major`, `sideshowdb_version_minor`,
`sideshowdb_version_patch`, `sideshowdb_banner_ptr`, `sideshowdb_banner_len`.

Zig remains the top-level orchestrator for repo tasks. The `js:*` steps run
against the shared Bun workspace from the repo root, and the `site:*` steps
reuse that same workspace install instead of maintaining a separate `site/`
dependency install.
