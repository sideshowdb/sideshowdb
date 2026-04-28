---
title: Getting Started
order: 1
---

# Getting Started

Sideshowdb is a Git-backed local-first database. Git is the source of
truth; local stores and projections are derived views.

This page walks from a clean checkout to a verifiable end-to-end example
that puts a document and reads it back through the CLI.

> Implements EARS: *The Sideshowdb docs section shall provide a Getting
> Started page with installable Zig 0.16 prerequisites, build commands,
> and at least one verifiable end-to-end example.*

## Prerequisites

| Dependency | Version | Why |
| ---------- | ------- | --- |
| [Zig](https://ziglang.org/download/) | 0.16.0 | Compiles the core library, CLI, and WASM client |
| [Bun](https://bun.sh/) | 1.x | Runs the docs site and playground tooling |
| [Git](https://git-scm.com/) | any modern release | Backs the [`GitRefStore`](/reference/api/#sideshowdb.storage.GitRefStore) implementation |

The native CLI builds and runs on macOS and Linux. The browser runtime
ships as `wasm32-freestanding`.

## Install

```bash
git clone https://github.com/sideshowdb/sideshowdb.git
cd sideshowdb
zig build           # native CLI -> zig-out/bin/sideshowdb
zig build wasm      # browser runtime -> zig-out/wasm/sideshowdb.wasm
```

To run the docs site and playground locally:

```bash
zig build siteDev   # auto-installs site deps + starts the dev server
```

That step stages the WASM artifact, runs `bun install` in `site/`, and
boots the SvelteKit dev server at <http://localhost:5173>.

## End-to-End Example: Put and Get a Document

The CLI stores documents in a Git ref using
[`DocumentStore`](/reference/api/#sideshowdb.document.DocumentStore) on
top of [`GitRefStore`](/reference/api/#sideshowdb.storage.GitRefStore).
The example below creates a fresh repository, writes one document, then
reads it back. Document JSON is read from `STDIN`.

```bash
# 1. Build the CLI.
zig build

# 2. Create a temporary repo for the demo.
mkdir -p /tmp/sideshowdb-demo
cd /tmp/sideshowdb-demo
git init -q
git commit -q --allow-empty -m "init"

# 3. Put a document. JSON comes in on STDIN; identity goes on flags.
echo '{"title":"Hello, sideshowdb"}' \
  | ../sideshowdb/zig-out/bin/sideshowdb doc put --type issue --id doc-1

# 4. Read it back. Output is the stored envelope including a version id.
../sideshowdb/zig-out/bin/sideshowdb doc get --type issue --id doc-1
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

```bash
zig build test            # core, integration, CLI, transport, git store
zig build checkCoreDocs   # public-API doc-comment lint
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
