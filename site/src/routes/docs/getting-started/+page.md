---
title: Getting Started
order: 1
---

Sideshowdb is a Git-backed local-first database. Git is the source of
truth; local stores and projections are derived views.

This page walks from a clean install to a verifiable end-to-end example
that puts a document and reads it back through the CLI.

The native CLI builds and runs on macOS, Linux, and Windows on `amd64`
and `arm64`. The browser runtime ships as `wasm32-freestanding`.

## Installation

Pick the install path that matches what you need:

- **From a release binary** — fastest path. No Zig toolchain required.
- **From source** — required for development, contributing, or building
  the WASM client.

### From a release binary

Tagged releases publish CLI binaries for **linux**, **macos**, and
**windows** on **amd64** and **arm64**, plus the `sideshowdb.wasm`
artifact. Linux binaries are statically linked against musl so they run
on any modern distro. Each release also ships a `SHA256SUMS` file.

Release assets follow the standard
`sideshowdb-<version>-<os>-<arch>.<ext>` naming convention, so the
[mise](https://mise.jdx.dev/) **github** backend installs the right
asset for your platform out of the box:

```bash
mise use github:sideshowdb/sideshowdb@latest
# or pin a specific tag
mise use github:sideshowdb/sideshowdb@v0.1.0
```

Prefer a direct download? Grab the archive that matches your platform
from the
[Releases page](https://github.com/sideshowdb/sideshowdb/releases). Each
archive contains the `sideshowdb` executable alongside `LICENSE` and
`README.md`. Verify the download against `SHA256SUMS`, then place the
binary somewhere on your `PATH` before running it.

### From source

Source builds need the toolchain below. Release-binary users can skip
this section.

| Dependency | Version | Why |
| ---------- | ------- | --- |
| [Zig](https://ziglang.org/download/) | 0.16.0 | Compiles the core library, CLI, and WASM client |
| [Git](https://git-scm.com/) | any modern release | Backs the [`GitRefStore`](/reference/api/#sideshowdb.storage.GitRefStore) implementation |
| [Bun](https://bun.sh/) | 1.x | Only required for the docs site and playground tooling |

```bash
git clone https://github.com/sideshowdb/sideshowdb.git
cd sideshowdb
zig build           # native CLI -> zig-out/bin/sideshowdb
zig build wasm      # browser runtime -> zig-out/wasm/sideshowdb.wasm
```

To run the docs site and playground locally:

```bash
zig build site:dev  # auto-installs site deps + starts the dev server
```

That step stages the WASM artifact, runs `bun install` in `site/`, and
boots the SvelteKit dev server at <http://localhost:5173>.

## End-to-End Example: Put and Get a Document

The CLI stores documents in a Git ref using
[`DocumentStore`](/reference/api/#sideshowdb.document.DocumentStore) on
top of [`GitRefStore`](/reference/api/#sideshowdb.storage.GitRefStore).
The example below creates a fresh repository, writes one document, then
reads it back. Document JSON is read from `STDIN`.

The example assumes the `sideshowdb` binary is on your `PATH` (true
after a release-binary install). For a source build, either run
`export PATH="$PWD/zig-out/bin:$PATH"` from the repo root or substitute
`./zig-out/bin/sideshowdb` for `sideshowdb` below.

```bash
# 1. Create a temporary repo for the demo.
mkdir -p /tmp/sideshowdb-demo
cd /tmp/sideshowdb-demo
git init -q
git commit -q --allow-empty -m "init"

# 2. Put a document. JSON comes in on STDIN; identity goes on flags.
echo '{"title":"Hello, sideshowdb"}' \
  | sideshowdb doc put --type issue --id doc-1

# 3. Read it back. Output is the stored envelope including a version id.
sideshowdb doc get --type issue --id doc-1
```

The returned envelope includes `namespace`, `type`, `id`, `version`, and
the original `data` payload — the on-disk shape produced by
[`document.deriveKey`](/reference/api/#sideshowdb.document.deriveKey)
and the put pipeline.

To verify the round-trip, inspect the underlying ref directly:

```bash
git for-each-ref refs/sideshowdb/documents
git cat-file -p refs/sideshowdb/documents:default/issue/doc-1.json
```

The CLI writes to `refs/sideshowdb/documents` so document data cannot
collide with normal `refs/heads/*` work.

## Running the Test Suite

The test suite runs against a source checkout, so this section assumes
you followed the **From source** path above.

```bash
zig build test            # core, integration, CLI, transport, git store
zig build check:core-docs # public-API doc-comment lint
zig fmt --check .         # source formatting gate
```

CI runs the same gates, so a green local run is a strong signal that a
contribution is ready for review.

## Next Steps

- [Architecture](/docs/architecture/) — the model behind the CLI and
  WASM surfaces.
- [Concepts](/docs/concepts/) — events, refs, and derived views with
  links into the generated reference.
- [Projection Walkthrough](/docs/projection-walkthrough/) — apply the
  model to a real public repository.
- [Playground Guide](/docs/playground/) — how to use the in-browser
  evaluator experience.
