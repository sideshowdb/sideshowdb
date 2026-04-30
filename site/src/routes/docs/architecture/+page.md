---
title: Architecture
order: 3
---

SideshowDB treats Git as the canonical event store and treats every other
surface — local indexes, document projections, browser views — as a
disposable derived view over Git history.

## Layers

<figure class="docs-diagram"><svg
id="architecture-layers-diagram"
role="img"
aria-labelledby="architecture-layers-title architecture-layers-desc"
viewBox="0 0 920 620"
xmlns="http://www.w3.org/2000/svg"
>
<title id="architecture-layers-title">SideshowDB architecture layers</title>
<desc id="architecture-layers-desc">
Git is the source of truth. Local materialization is disposable and derived from Git. Read surfaces consume derived views.
</desc>
<defs>
<marker id="architecture-layers-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
<path d="M 0 0 L 10 5 L 0 10 z" class="diagram-arrow-head" />
</marker>
</defs>
<rect x="28" y="28" width="864" height="564" rx="26" class="diagram-canvas" />
<g>
<rect x="116" y="72" width="688" height="128" rx="18" class="diagram-card diagram-card-primary" />
<text x="460" y="112" text-anchor="middle" class="diagram-heading">Git Repository</text>
<text x="460" y="148" text-anchor="middle" class="diagram-text">Canonical event logs, document blobs, snapshot markers</text>
<text x="460" y="176" text-anchor="middle" class="diagram-code">refs/sideshowdb/&lt;section&gt;</text>
<text x="746" y="126" text-anchor="end" class="diagram-badge">source of truth</text>
</g>
<path d="M 460 206 L 460 270" class="diagram-arrow" marker-end="url(#architecture-layers-arrow)" />
<text x="488" y="242" class="diagram-label">pull / merge / rebase</text>
<g>
<rect x="116" y="282" width="688" height="128" rx="18" class="diagram-card" />
<text x="460" y="322" text-anchor="middle" class="diagram-heading">Local Materialization Layer</text>
<text x="460" y="358" text-anchor="middle" class="diagram-text">Event indexes, document projections, snapshot caches</text>
<text x="746" y="346" text-anchor="end" class="diagram-badge">disposable</text>
</g>
<path d="M 460 416 L 460 480" class="diagram-arrow" marker-end="url(#architecture-layers-arrow)" />
<text x="488" y="452" class="diagram-label">derived</text>
<g>
<rect x="116" y="492" width="688" height="84" rx="18" class="diagram-card" />
<text x="460" y="528" text-anchor="middle" class="diagram-heading">Read Surfaces</text>
<text x="460" y="558" text-anchor="middle" class="diagram-text">CLI, WASM browser runtime, site playground</text>
<text x="746" y="540" text-anchor="end" class="diagram-badge">consume views</text>
</g>
</svg></figure>

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

This namespace owns its tree exclusively, so SideshowDB data cannot
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

<figure class="docs-diagram"><svg
id="write-through-composite-diagram"
role="img"
aria-labelledby="write-through-title write-through-desc"
viewBox="0 0 920 470"
xmlns="http://www.w3.org/2000/svg"
>
<title id="write-through-title">Write-through composite overview</title>
<desc id="write-through-desc">
Put and delete operations stage cache writes before committing to canonical storage. Get operations try caches first and refill them after a canonical hit.
</desc>
<defs>
<marker id="write-through-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
<path d="M 0 0 L 10 5 L 0 10 z" class="diagram-arrow-head" />
</marker>
</defs>
<rect x="28" y="28" width="864" height="414" rx="26" class="diagram-canvas" />
<text x="244" y="76" text-anchor="middle" class="diagram-label">put / delete</text>
<path d="M 244 88 L 244 126" class="diagram-arrow" marker-end="url(#write-through-arrow)" />
<g>
<rect x="104" y="136" width="280" height="148" rx="18" class="diagram-card diagram-card-primary" />
<text x="244" y="176" text-anchor="middle" class="diagram-heading">WriteThrough</text>
<text x="244" y="212" text-anchor="middle" class="diagram-text">stage caches left to right</text>
<text x="244" y="242" text-anchor="middle" class="diagram-text">then commit canonical</text>
</g>
<path d="M 244 292 L 244 348" class="diagram-arrow" marker-end="url(#write-through-arrow)" />
<g>
<rect x="104" y="358" width="280" height="72" rx="18" class="diagram-card" />
<text x="244" y="390" text-anchor="middle" class="diagram-heading">canonical RefStore</text>
<text x="244" y="416" text-anchor="middle" class="diagram-text">truth in Git ref</text>
</g>
<text x="676" y="76" text-anchor="middle" class="diagram-label">get</text>
<path d="M 676 88 L 676 126" class="diagram-arrow" marker-end="url(#write-through-arrow)" />
<g>
<rect x="536" y="136" width="280" height="184" rx="18" class="diagram-card diagram-card-primary" />
<text x="676" y="176" text-anchor="middle" class="diagram-heading">WriteThrough</text>
<text x="676" y="212" text-anchor="middle" class="diagram-text">try caches in declaration order</text>
<text x="676" y="242" text-anchor="middle" class="diagram-text">fall through to canonical</text>
<text x="676" y="272" text-anchor="middle" class="diagram-text">refill caches after canonical hit</text>
</g>
<path d="M 536 258 C 460 304, 452 390, 392 390" class="diagram-arrow" marker-end="url(#write-through-arrow)" />
</svg></figure>

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

<figure class="docs-diagram docs-diagram-compact"><svg
id="read-fall-through-diagram"
role="img"
aria-labelledby="read-fall-through-title read-fall-through-desc"
viewBox="0 0 920 420"
xmlns="http://www.w3.org/2000/svg"
>
<title id="read-fall-through-title">Read fall-through cache flow</title>
<desc id="read-fall-through-desc">
A get checks cache 0, cache 1, and later caches before canonical storage. Cache hits return immediately. Canonical hits refill caches best effort.
</desc>
<defs>
<marker id="read-fall-through-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
<path d="M 0 0 L 10 5 L 0 10 z" class="diagram-arrow-head" />
</marker>
</defs>
<rect x="28" y="28" width="864" height="364" rx="26" class="diagram-canvas" />
<rect x="72" y="70" width="144" height="68" rx="16" class="diagram-card diagram-card-primary" />
<text x="144" y="110" text-anchor="middle" class="diagram-heading">get(key)</text>
<rect x="292" y="70" width="170" height="68" rx="16" class="diagram-card" />
<text x="377" y="110" text-anchor="middle" class="diagram-heading">cache 0</text>
<rect x="292" y="176" width="170" height="68" rx="16" class="diagram-card" />
<text x="377" y="216" text-anchor="middle" class="diagram-heading">cache 1</text>
<text x="304" y="282" text-anchor="end" class="diagram-label">more caches</text>
<rect x="292" y="322" width="170" height="52" rx="16" class="diagram-card" />
<text x="377" y="354" text-anchor="middle" class="diagram-heading">canonical</text>
<rect x="584" y="70" width="256" height="68" rx="16" class="diagram-card diagram-result" />
<text x="712" y="100" text-anchor="middle" class="diagram-heading">return value</text>
<text x="712" y="124" text-anchor="middle" class="diagram-text">cache version-id</text>
<rect x="584" y="304" width="256" height="70" rx="16" class="diagram-card diagram-result" />
<text x="712" y="334" text-anchor="middle" class="diagram-heading">refill caches</text>
<text x="712" y="358" text-anchor="middle" class="diagram-text">return canonical version-id</text>
<path d="M 216 104 L 280 104" class="diagram-arrow" marker-end="url(#read-fall-through-arrow)" />
<path d="M 462 104 L 572 104" class="diagram-arrow" marker-end="url(#read-fall-through-arrow)" />
<text x="510" y="92" text-anchor="middle" class="diagram-label">hit</text>
<path d="M 377 142 L 377 164" class="diagram-arrow" marker-end="url(#read-fall-through-arrow)" />
<text x="414" y="158" class="diagram-label">miss</text>
<path d="M 377 248 L 377 302" class="diagram-arrow diagram-arrow-soft" marker-end="url(#read-fall-through-arrow)" />
<text x="414" y="278" class="diagram-label">miss</text>
<path d="M 462 348 L 572 348" class="diagram-arrow" marker-end="url(#read-fall-through-arrow)" />
<text x="510" y="336" text-anchor="middle" class="diagram-label">hit</text>
<path d="M 377 378 L 377 388" class="diagram-arrow-soft" />
<text x="414" y="398" class="diagram-label">miss -> null</text>
</svg></figure>

<figure class="docs-diagram docs-diagram-compact"><svg
id="write-fan-out-diagram"
role="img"
aria-labelledby="write-fan-out-title write-fan-out-desc"
viewBox="0 0 920 360"
xmlns="http://www.w3.org/2000/svg"
>
<title id="write-fan-out-title">Write fan-out cache flow</title>
<desc id="write-fan-out-desc">
A put stages writes through each cache before committing atomically to canonical storage and returning the canonical version id.
</desc>
<defs>
<marker id="write-fan-out-arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">
<path d="M 0 0 L 10 5 L 0 10 z" class="diagram-arrow-head" />
</marker>
</defs>
<rect x="28" y="28" width="864" height="304" rx="26" class="diagram-canvas" />
<rect x="70" y="120" width="154" height="72" rx="16" class="diagram-card diagram-card-primary" />
<text x="147" y="148" text-anchor="middle" class="diagram-heading">put</text>
<text x="147" y="174" text-anchor="middle" class="diagram-code">key, value</text>
<rect x="286" y="120" width="142" height="72" rx="16" class="diagram-card" />
<text x="357" y="148" text-anchor="middle" class="diagram-heading">cache 0</text>
<text x="357" y="174" text-anchor="middle" class="diagram-text">stage</text>
<rect x="488" y="120" width="142" height="72" rx="16" class="diagram-card" />
<text x="559" y="148" text-anchor="middle" class="diagram-heading">cache 1</text>
<text x="559" y="174" text-anchor="middle" class="diagram-text">stage</text>
<text x="676" y="162" text-anchor="middle" class="diagram-label">...</text>
<rect x="730" y="120" width="142" height="72" rx="16" class="diagram-card" />
<text x="801" y="148" text-anchor="middle" class="diagram-heading">canonical</text>
<text x="801" y="174" text-anchor="middle" class="diagram-text">commit</text>
<path d="M 224 156 L 274 156" class="diagram-arrow" marker-end="url(#write-fan-out-arrow)" />
<path d="M 428 156 L 476 156" class="diagram-arrow" marker-end="url(#write-fan-out-arrow)" />
<path d="M 630 156 L 718 156" class="diagram-arrow diagram-arrow-soft" marker-end="url(#write-fan-out-arrow)" />
<path d="M 801 196 L 801 248 L 460 248" class="diagram-arrow" marker-end="url(#write-fan-out-arrow)" />
<rect x="300" y="224" width="300" height="56" rx="16" class="diagram-card diagram-result" />
<text x="450" y="258" text-anchor="middle" class="diagram-heading">return canonical version-id</text>
</svg></figure>

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

There is no always-on server. Every SideshowDB consumer:

- Reads canonical state from a Git working copy or `git fetch`.
- Writes canonical state by producing commits on
  `refs/sideshowdb/<section>`.
- Builds derived state (indexes, projections) on demand and may delete
  it at any time.

Pulling, branching, merging, and rebasing are normal Git operations
because the store layout is a normal Git tree under a SideshowDB-owned
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
end-to-end mapping from a real public repo into SideshowDB concepts.

## Where to Look in the Reference

- [`sideshowdb`](/reference/api/index.html#sideshowdb) — top-level module
- [`sideshowdb.storage`](/reference/api/index.html#sideshowdb.storage)
- [`sideshowdb.document`](/reference/api/index.html#sideshowdb.document)
- [`sideshowdb.document_transport`](/reference/api/index.html#sideshowdb.document_transport)
- [`sideshowdb.event`](/reference/api/index.html#sideshowdb.event)
