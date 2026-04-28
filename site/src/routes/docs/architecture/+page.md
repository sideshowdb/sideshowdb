---
title: Architecture
order: 2
---

Sideshowdb treats Git as the canonical event store and treats every other
surface — local indexes, document projections, browser views — as a
disposable derived view over Git history.

## Layers

```
+----------------------------------------------------------+
|                    Git Repository                        |
|                                                          |
|  Canonical event logs, document blobs, snapshot markers  |  <- source of truth
|  Stored under refs/sideshowdb/<section> only             |
+-------------------------+--------------------------------+
                          | pull / merge / rebase
                          v
+----------------------------------------------------------+
|              Local Materialization Layer                 |
|                                                          |
|  Event index (RocksDB / IndexedDB)                       |
|  Document projections                                    |  <- disposable
|  Snapshot cache                                          |
+-------------------------+--------------------------------+
                          | derived
                          v
+----------------------------------------------------------+
|                   Read Surfaces                          |
|                                                          |
|  CLI (sideshowdb doc put/get)                            |
|  WASM browser runtime                                    |  <- consume
|  Site playground                                         |     derived views
+----------------------------------------------------------+
```

## Core Invariants

These are non-negotiable. Breaking any of them invalidates the design.

1. Events are append-only.
2. Events are immutable.
3. History is reconstructible by replay.
4. Git stores canonical truth.
5. Local databases are disposable.
6. Merges happen on events, not state.
7. Projections never write back to truth.

A more detailed treatment lives in
[`docs/development/specs/sideshowdb-spec.md`](https://github.com/sideshowdb/sideshowdb/blob/main/docs/development/specs/sideshowdb-spec.md).

## Storage Boundaries

Every section of state lives under its own ref:

```
refs/sideshowdb/<section-name>
```

Examples in current and planned use:

```
refs/sideshowdb/documents      # current document slice (CLI doc put/get)
refs/sideshowdb/events         # planned event log
refs/sideshowdb/projections.*  # planned derived projections
```

This namespace owns its tree exclusively, so Sideshowdb data cannot
collide with the user's `refs/heads/*`, tags, or remotes.

## The RefStore Interface

[`storage.RefStore`](/reference/api/index.html#sideshowdb.storage.RefStore) is a
small vtable-style "interface" struct (the same shape as
`std.mem.Allocator` or `std.Io.Writer`). It exposes four operations on a
section-scoped key/value store:

- `put(gpa, key, value) -> VersionId`
- `get(gpa, key, version?) -> ?ReadResult`
- `delete(key)`
- `list(gpa) -> [][]u8`

Two concrete implementations live in the codebase:

- [`storage.GitRefStore`](/reference/api/index.html#sideshowdb.storage.GitRefStore)
  shells out to the user's `git` binary and produces real commits per
  write. It is gated to non-freestanding targets.
- The wasm32-freestanding build resolves
  [`storage.GitRefStore`](/reference/api/index.html#sideshowdb.storage.GitRefStore)
  to `void` so the browser surface can compile without subprocesses.

New implementations should pass the contract tests in
[`tests/git_ref_store_test.zig`](https://github.com/sideshowdb/sideshowdb/blob/main/tests/git_ref_store_test.zig)
to be considered conforming.

## DocumentStore on Top of RefStore

[`document.DocumentStore`](/reference/api/index.html#sideshowdb.document.DocumentStore)
is the first end-to-end slice. Documents are addressed by an
[`Identity`](/reference/api/index.html#sideshowdb.document.Identity) of
`(namespace, doc_type, id)` and stored as JSON envelopes that include
identity plus a `data` payload. The canonical key is computed by
[`document.deriveKey`](/reference/api/index.html#sideshowdb.document.deriveKey) as
`<namespace>/<doc_type>/<id>.json`.

Errors surface as
[`document.Error`](/reference/api/index.html#sideshowdb.document.Error) variants
(`ConflictingIdentity`, `InvalidDocument`, `InvalidIdentity`,
`MissingIdentity`, `VersionIsOutputOnly`).

Transport adapters live in
[`document_transport`](/reference/api/index.html#sideshowdb.document_transport) for
JSON wire-format usage by CLI and WASM bridges.

## Local-First Operation

There is no always-on server. Every Sideshowdb consumer:

- Reads canonical state from a Git working copy or `git fetch`.
- Writes canonical state by producing commits on
  `refs/sideshowdb/<section>`.
- Builds derived state (indexes, projections) on demand and may delete
  it at any time.

Pulling, branching, merging, and rebasing are normal Git operations
because the store layout is a normal Git tree under a Sideshowdb-owned
ref.

## Browser Constraints

The WASM client builds against `wasm32-freestanding`, so
[`storage.GitRefStore`](/reference/api/index.html#sideshowdb.storage.GitRefStore)
is unavailable in the browser. Browser playground code therefore:

- Fetches public GitHub data with the Fetch API.
- Calls into the loaded WASM module for projection logic.
- Treats the result as an explanatory derived view, not a writable
  database.

See the [Projection Walkthrough](/docs/projection-walkthrough/) for the
end-to-end mapping from a real public repo into Sideshowdb concepts.

## Where to Look in the Reference

- [`sideshowdb`](/reference/api/index.html#sideshowdb) — top-level module
- [`sideshowdb.storage`](/reference/api/index.html#sideshowdb.storage)
- [`sideshowdb.document`](/reference/api/index.html#sideshowdb.document)
- [`sideshowdb.document_transport`](/reference/api/index.html#sideshowdb.document_transport)
- [`sideshowdb.event`](/reference/api/index.html#sideshowdb.event)
