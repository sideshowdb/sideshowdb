---
title: Architecture
order: 3
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

Design rationale (ADRs, RFCs, and vocabulary) is indexed from the
[design hub](https://github.com/sideshowdb/sideshowdb/blob/main/docs/design/README.md)
and summarized on the [Design hub](/docs/design/) docs page.

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
- `history(gpa, key) -> []VersionId`

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

## Write-Through Composite

[`storage.WriteThroughRefStore`](/reference/api/index.html#sideshowdb.storage.WriteThroughRefStore)
is a `RefStore` that fronts a **canonical** `RefStore` with one or more
**cache** `RefStore`s. Every operation is exposed under the same
vtable contract, so the composite is itself just another `RefStore`
to the caller. Every successful `put` / `delete` blocks until canonical
accepts — there is no asynchronous queue today.

```
    put / delete                      get
        |                              |
        v                              v
  +-----------------+            +-----------------+
  | WriteThrough:   |            | WriteThrough:   |
  | stage caches    |            | try caches in   |
  | left -> right   |            | declaration     |
  | then canonical  |            | order, fall     |
  +--------+--------+            | through to      |
           |                     | canonical, then |
           |                     | refill caches   |
           v                     +-----------------+
  +--------+--------+
  |   canonical     |
  |   RefStore      |   <- truth (Git ref)
  +-----------------+
```

The full contract — write order, read fall-through, refill, recovery,
and the EARS-tagged failure semantics — lives in
[`docs/development/specs/write-through-store-spec.md`](https://github.com/sideshowdb/sideshowdb/blob/main/docs/development/specs/write-through-store-spec.md).
The deliberation that produced this primitive (rather than a "real"
write-behind cache with a durable WAL) is recorded in
[`docs/development/decisions/2026-04-29-caching-model.md`](https://github.com/sideshowdb/sideshowdb/blob/main/docs/development/decisions/2026-04-29-caching-model.md).

Two practical reasons for this layer:

1. **Speed.** A local cache can answer reads without round-tripping
   the canonical Git engine. With multiple caches in the chain (e.g.
   an in-memory hot cache in front of a LevelDB warm cache), the
   cheapest tier serves the common path.
2. **Backend swap.** Cache backends — LevelDB, RocksDB, IndexedDB —
   plug into the same composite without changing the canonical layer.
   A future native deployment can mix-and-match without re-deriving
   the read/write semantics.

```
read fall-through:

   get(key) ->  cache_0.get(key)  --hit-->  return value (cache version-id)
                       |
                       miss
                       v
                cache_1.get(key)  --hit-->  return value (cache version-id)
                       |
                       miss
                       v
                ...
                       |
                       miss
                       v
                canonical.get(key) --hit-->  refill cache_0..N (best-effort)
                       |                     return canonical version-id
                       miss
                       v
                       null
```

```
write fan-out:

   put(key, value) ->  cache_0.put  (stage)
                            |
                            v
                       cache_1.put  (stage)
                            |
                            v
                       ...
                            |
                            v
                       canonical.put  (commit, atomic)
                            |
                            v
                       return canonical version-id
```

The composite degenerates cleanly:

- Zero caches → thin pass-through to canonical.
- One cache → traditional read-through / write-through cache. Expected
  to be the common steady-state shape.
- N caches → fan-out structure that becomes useful for benchmarking
  and tiered-cache experimentation once on-disk cache backends and
  an instrumentation hook land. Today every cache is in-memory; the
  multi-cache topology mostly exercises the composite's failure
  semantics.

`WriteThroughRefStore` is **not thread-safe**; callers needing
concurrent access must serialize externally. Same posture as every
other `RefStore` implementation in the codebase.

Sibling caching primitives are filed for separate design and shipping
when the use cases land:

- **WAL + batched canonical flush** — the genuine "write-behind"
  pattern; layers over write-through.
- **Write-around** — writes bypass cache entirely, cache populated
  only on read fall-through. Useful when single-cache deployments
  want to skip the speculative-cache window.
- **Offline writes** — caller-visible success while canonical is
  unreachable, with durable buffering and reconnect-flush. The
  feature SideshowDB's local-first posture ultimately needs.

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
