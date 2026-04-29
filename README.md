# sideshowdb

[![Build](https://github.com/sideshowdb/sideshowdb/actions/workflows/ci.yml/badge.svg)](https://github.com/sideshowdb/sideshowdb/actions/workflows/ci.yml)
[![Package](https://img.shields.io/npm/v/%40sideshowdb%2Fcore?label=npm%20%40sideshowdb%2Fcore)](https://www.npmjs.com/package/@sideshowdb/core)
[![Release](https://img.shields.io/github/v/release/sideshowdb/sideshowdb?display_name=tag)](https://github.com/sideshowdb/sideshowdb/releases)

Sideshow is an event-sourced, offline-friendly database backed by Git.

> **Status:** approaching MVP. Native CLI runs against an in-process
> ziggit-backed Git ref store; the wasm32-freestanding browser client now
> runs document operations standalone against an in-WASM `MemoryRefStore`
> with no host bridge required. Sync, IndexedDB persistence, and the
> RocksDB backend are tracked in the issue tracker. Spec is in
> [docs/development/specs/sideshowdb-spec.md](docs/development/specs/sideshowdb-spec.md).

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
zig build run -- version < /dev/null # build + run the CLI version command (prints the banner)
zig build wasm         # build wasm32-freestanding client into zig-out/wasm/sideshowdb.wasm
zig build js:build-bindings # build TypeScript binding package outputs
zig build js:acceptance # run the TypeScript Cucumber acceptance suite
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
dependency install. The public TypeScript acceptance lane is intentionally
separate from the regular `js:test` and `js:check` workspace lanes, and runs
through `zig build js:acceptance`.

## TypeScript client quick start

Install the client package:

```bash
# from npm (when published)
npm install @sideshowdb/core

# from a local clone of this repo
npm install ./bindings/typescript/sideshowdb-core
```

Load the WASM runtime and run document operations against the built-in
in-WASM `MemoryRefStore` — no host bridge required:

```ts
import { loadSideshowdbClient } from '@sideshowdb/core'

const client = await loadSideshowdbClient({
  wasmPath: '/wasm/sideshowdb.wasm',
})

const putResult = await client.put({
  type: 'note',
  id: 'n1',
  data: { title: 'Hello from TypeScript' },
})

if (!putResult.ok) {
  throw putResult.error
}

const getResult = await client.get<{ title: string }>({
  type: 'note',
  id: 'n1',
})

if (getResult.ok && getResult.found) {
  console.log(getResult.value.data.title)
}
```

The default `MemoryRefStore` is volatile — data is lost on page reload.
For browser persistence, supply a `hostBridge` so ref operations route to
host-managed storage (e.g. IndexedDB). When `hostBridge` is provided the
client switches the WASM module to the imported-ref-store backend
automatically:

```ts
import { loadSideshowdbClient } from '@sideshowdb/core'

type RecordEntry = { version: string; value: string }

const refs = new Map<string, RecordEntry[]>()
let nextVersion = 1

const client = await loadSideshowdbClient({
  wasmPath: '/wasm/sideshowdb.wasm',
  hostBridge: {
    put(key, value) {
      const version = `v${nextVersion++}`
      const history = refs.get(key) ?? []
      refs.set(key, [...history, { version, value }])
      return version
    },
    get(key, version) {
      const history = refs.get(key)
      if (history === undefined || history.length === 0) {
        return null
      }

      if (version) {
        const match = history.find((entry) => entry.version === version)
        return match ? { value: match.value, version: match.version } : null
      }

      const latest = history[history.length - 1]
      return { value: latest.value, version: latest.version }
    },
    delete(key) {
      refs.delete(key)
    },
    list() {
      return Array.from(refs.keys())
    },
    history(key) {
      const history = refs.get(key) ?? []
      return history.map((entry) => entry.version)
    },
  },
})
```

### Ziggit-backed client example

The native CLI client can run with the ziggit-backed refstore explicitly enabled:

```bash
mkdir -p demo-ziggit
cd demo-ziggit
git init

# Option 1: one-off override for this command.
echo '{"title":"Persisted through ziggit"}' \
  | ../zig-out/bin/sideshowdb --json --refstore ziggit doc put --type note --id n-ziggit

# Option 2: environment override for the current shell.
export SIDESHOWDB_REFSTORE=ziggit
../zig-out/bin/sideshowdb --json doc get --type note --id n-ziggit < /dev/null
../zig-out/bin/sideshowdb --json doc history --type note --id n-ziggit < /dev/null
```

You can also persist the backend selection in `.sideshowdb/config.toml`:

```toml
[storage]
refstore = "ziggit"
```

### Loading `doc put` payloads from a file

`doc put` reads payload bytes from stdin by default. For larger payloads
or when piping is awkward, use `--data-file <path>`:

```bash
echo '{"title":"From file"}' > payload.json
zig-out/bin/sideshowdb --json doc put \
  --type note --id file-demo --data-file payload.json
```

Precedence: when both stdin and `--data-file` provide input,
`--data-file` wins. A missing or unreadable `--data-file` path fails the
command with a non-zero exit code and a clear error message before any
document state changes.

## TypeScript package releases

The TypeScript bindings publish to npm as a coordinated pair:
`@sideshowdb/core` and `@sideshowdb/effect` share the same version and are
released from the same `v*` Git tag.

Before tagging a release:

```bash
zig build js:release-prepare
```

That step builds the binding packages, validates their publish metadata, stages
publishable directories under `dist/npm/`, and rewrites the internal
`@sideshowdb/core` dependency to the coordinated release version for the staged
`@sideshowdb/effect` manifest. The `Release` GitHub Actions workflow then
publishes both staged packages to npm with provenance.

## RefStore backend selection

Native Sideshowdb defaults to the in-process ziggit-backed `GitRefStore`. The
subprocess-backed backend remains available as a fallback for compatibility
and debugging. The WASM browser client defaults to the in-process
`MemoryRefStore` (volatile, no host wiring required); supply a
`hostBridge` to route ref ops to host-managed storage instead.

Selection precedence (native, highest first):

1. `--refstore ziggit|subprocess`
2. `SIDESHOWDB_REFSTORE=ziggit|subprocess`
3. `[storage] refstore` in `.sideshowdb/config.toml`
4. built-in default: `ziggit`

Config file:

```toml
[storage]
refstore = "ziggit"
```

An invalid backend name from any source fails the command before any document
ref is written, with a clear `unsupported refstore` error.
