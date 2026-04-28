---
title: Concepts
order: 3
---

Sideshowdb has a small set of vocabulary terms. Each term maps directly
to a symbol in the generated reference, so you can move from prose into
the API surface without guessing.

## Events

Events are append-only records of "something that happened." History is
the union of every event ever appended; current state is the result of
replaying that history through deterministic reducers.

The placeholder shape lives at
[`event.Event`](/reference/api/index.html#sideshowdb.event.Event), with these
fields today:

| Field | Meaning |
| ----- | ------- |
| `event_id` | unique identifier |
| `event_type` | discriminator chosen by the producer |
| `aggregate_id` | logical owner the event applies to |
| `timestamp_ms` | Unix epoch milliseconds |

Events do not own their slice memory; callers manage lifetimes. Build
one with
[`event.Event.init`](/reference/api/index.html#sideshowdb.event.Event.init).

The full event log schema lands when the spec is implemented; today the
type carries the minimum identity needed by downstream surfaces.

## Refs

A Sideshowdb section is one Git ref. Writes produce commits on that ref.
Reads pin to the current tip or to an explicit historical version.

The namespace is reserved:

```text
refs/sideshowdb/<section-name>
```

The current document slice uses `refs/sideshowdb/documents`. Future
slices will use `refs/sideshowdb/events` and
`refs/sideshowdb/projections.*`.

The interface that hides the underlying ref is
[`storage.RefStore`](/reference/api/index.html#sideshowdb.storage.RefStore). The
concrete implementation backed by a real `git` binary is
[`storage.GitRefStore`](/reference/api/index.html#sideshowdb.storage.GitRefStore).

A version returned from
[`RefStore.put`](/reference/api/index.html#sideshowdb.storage.RefStore.put) is the
new commit SHA on that section's ref.

## Identities and Documents

A document is identified by
[`document.Identity`](/reference/api/index.html#sideshowdb.document.Identity), a
triple of `(namespace, doc_type, id)`. The canonical Git tree key for
that identity is computed by
[`document.deriveKey`](/reference/api/index.html#sideshowdb.document.deriveKey)
and lays out as:

```text
<namespace>/<doc_type>/<id>.json
```

The store is
[`document.DocumentStore`](/reference/api/index.html#sideshowdb.document.DocumentStore),
which sits over any
[`storage.RefStore`](/reference/api/index.html#sideshowdb.storage.RefStore).
Errors surface as
[`document.Error`](/reference/api/index.html#sideshowdb.document.Error).

Two input shapes are accepted via
[`document.PutRequest`](/reference/api/index.html#sideshowdb.document.PutRequest):

- [`PutRequest.Payload`](/reference/api/index.html#sideshowdb.document.PutRequest.Payload)
  — caller supplies raw JSON plus identity flags.
- [`PutRequest.Envelope`](/reference/api/index.html#sideshowdb.document.PutRequest.Envelope)
  — caller supplies a JSON object that already carries identity, with
  optional non-conflicting overrides.

[`PutRequest.fromOverrides`](/reference/api/index.html#sideshowdb.document.PutRequest.fromOverrides)
picks between the two based on which fields the caller provided.

## Derived Views

Derived views are anything not stored in Git. They include:

- Local event indexes (RocksDB / IndexedDB).
- Document projections built by reducer replay.
- Snapshot caches keyed by `up_to_event`.
- Browser playground panels that map fetched GitHub data into
  Sideshowdb shapes.

The contract is one-way: derived views read from Git and may be
discarded at any moment. They never write back.

## Transport

Transport adapters live in
[`document_transport`](/reference/api/index.html#sideshowdb.document_transport).
They take a single JSON wire object (carrying identity overrides plus
document JSON) and forward into the
[`DocumentStore`](/reference/api/index.html#sideshowdb.document.DocumentStore)
API:

- [`document_transport.handlePut`](/reference/api/index.html#sideshowdb.document_transport.handlePut)
- [`document_transport.handleGet`](/reference/api/index.html#sideshowdb.document_transport.handleGet)

These are the seams that the CLI and the browser bridge consume.

## Local-First

Sideshowdb has no always-on server. The CLI uses
[`storage.GitRefStore`](/reference/api/index.html#sideshowdb.storage.GitRefStore)
against a working tree on disk; the browser uses the WASM build and
public GitHub fetches. Anything you write must end up under
`refs/sideshowdb/<section>` for it to count as canonical.

## See Also

- [Architecture](/docs/architecture/) — how these pieces fit together.
- [Projection Walkthrough](/docs/projection-walkthrough/) — concepts
  applied to a real public repo.
- [Reference](/reference/api/index.html) — the generated low-level API.
