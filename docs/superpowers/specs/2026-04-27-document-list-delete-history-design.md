# Sideshowdb Document List/Delete/History Design

Date: 2026-04-27
Status: Proposed
Issue: `sideshowdb-psy`

## Summary

Sideshowdb's first document slice already supports versioned `put` and `get`
across `DocumentStore`, the native CLI, and the host-backed WASM surface. The
next step is to make the slice traversable and maintainable by adding
metadata-first `list`, `delete`, and `history` operations.

This design extends the existing slice without changing the payload contract of
`put` and `get`. Collection-oriented operations return document identity and
Git version metadata only. Full document content remains the responsibility of
single-document `get`.

## Goals

- Add document `list`, `delete`, and `history` operations to the shared
  document slice.
- Keep behavior aligned across `DocumentStore`, CLI, and WASM transports.
- Reuse Git-backed version history as the source of truth for document
  traversal.
- Keep collection responses small and predictable by returning metadata only.
- Define explicit user-facing behavior in EARS so tests can drive the
  implementation.

## Non-Goals

- Returning full document payloads from `list` or `history`
- Adding server-side indexing or non-Git storage for traversal
- Introducing batch delete or wildcard delete semantics
- Adding arbitrary sorting or pagination in the first traversal slice
- Changing the canonical response envelope for `put` and `get`

## Product Decisions

### Metadata-First Collections

`list` and `history` return metadata objects, not full document envelopes. Each
entry uses this shape:

```json
{
  "namespace": "default",
  "type": "issue",
  "id": "doc-1",
  "version": "<git-commit-sha>"
}
```

This keeps collection responses lightweight and makes `get` the single
payload-bearing read path.

### Delete Is Explicitly Idempotent

Deleting a missing document is treated as success. Boundary layers return a
machine-readable confirmation indicating whether a live document was removed.

Recommended delete response shape:

```json
{
  "namespace": "default",
  "type": "issue",
  "id": "doc-1",
  "deleted": true
}
```

When no live document exists, the same shape is returned with `"deleted":
false`.

### History Is Identity-Scoped

`history` operates on one logical document identity at a time:
`(namespace, type, id)`. It returns reachable versions for that key in
newest-first order. History entries include only versions where the document
exists and can be read.

## User-Facing Contract

### Shared Store Surface

The document slice should expose these operations:

- `put(request) -> canonical document envelope`
- `get(request) -> canonical document envelope?`
- `list(request) -> []DocumentMetadata`
- `delete(request) -> DeleteResult`
- `history(request) -> []DocumentMetadata`

Suggested request/response structs:

- `ListRequest`
  - optional `namespace`
  - optional `type`
- `DeleteRequest`
  - optional `namespace`
  - required `type`
  - required `id`
- `HistoryRequest`
  - optional `namespace`
  - required `type`
  - required `id`
- `DocumentMetadata`
  - `namespace`
  - `type`
  - `id`
  - `version`
- `DeleteResult`
  - `namespace`
  - `type`
  - `id`
  - `deleted`

### CLI

The native CLI extends `sideshowdb doc` with:

```text
sideshowdb doc list [--namespace <ns>] [--type <type>]
sideshowdb doc delete --type <type> --id <id> [--namespace <ns>]
sideshowdb doc history --type <type> --id <id> [--namespace <ns>]
```

Behavior:

- `list` prints a JSON array of metadata objects to stdout.
- `history` prints a JSON array of metadata objects to stdout.
- `delete` prints a single JSON object with normalized identity and
  `deleted: true|false`.
- Successful commands write machine-readable JSON only to stdout.
- Argument-shape failures continue to use the shared usage failure behavior.

### WASM

The WASM module extends the existing request/result pattern with:

- `sideshowdb_document_list`
- `sideshowdb_document_delete`
- `sideshowdb_document_history`

Each function:

- reads a request JSON blob from linear memory
- applies the same normalization and validation rules as the CLI
- writes result JSON to `sideshowdb_result_ptr` and `sideshowdb_result_len`

Request shapes:

- `list`
  - optional `namespace`
  - optional `type`
- `delete`
  - optional `namespace`
  - required `type`
  - required `id`
- `history`
  - optional `namespace`
  - required `type`
  - required `id`

## Technical Design

### DocumentStore Responsibilities

`DocumentStore` remains the shared behavioral layer. It should:

- normalize omitted namespaces to `"default"`
- validate identity segments before mutating storage
- derive keys as `<namespace>/<type>/<id>.json`
- shape metadata-first collection responses
- keep `put/get` envelope behavior unchanged

`list` should enumerate the current live keys under
`refs/sideshowdb/documents`, parse the key structure, optionally filter by
namespace and type, and synthesize metadata entries with the latest reachable
version for each live document.

`delete` should derive the key from the normalized identity, delete the latest
live blob for that key, and report whether a live document existed at deletion
time.

`history` should walk the Git-backed history for one derived key and return
metadata entries in newest-first order, excluding commits where the key is not
present.

### RefStore Requirements

The current low-level ref storage already supports:

- `put`
- `get`
- `delete`
- `list`

To support document history cleanly, the lower layer will likely need a new
capability that enumerates reachable versions for one key, or an equivalent
Git-backed helper inside the document slice. The important boundary is that the
document layer owns identity normalization and response shaping, while the
storage layer owns Git traversal.

### Response Semantics

- `list` returns `[]` when no live documents match.
- `history` returns `[]` when the target identity has no reachable versions.
- `delete` succeeds for both present and missing documents and reports the
  outcome through `deleted`.
- `history` excludes deletion events and returns only versions where the target
  key existed.

## EARS Requirements

### Ubiquitous Requirements

- The document slice shall expose `list`, `delete`, and `history` behavior
  through the shared store, native CLI, and WASM transport.
- The document slice shall normalize omitted namespace values to `"default"` at
  the CLI and WASM boundaries.
- The document slice shall return metadata-only entries from `list` and
  `history`.
- The document slice shall preserve `put/get` as the only payload-bearing
  document operations in this slice.

### Event-Driven Requirements

- When a caller executes `sideshowdb doc list` without filters, the system
  shall return all live documents under `refs/sideshowdb/documents` as a JSON
  array of metadata entries.
- When a caller executes `sideshowdb doc list` with `--namespace` and/or
  `--type`, the system shall return only live documents matching those filters.
- When a caller executes `sideshowdb doc delete` for an existing live document,
  the system shall remove the latest blob for that identity and return a JSON
  object with `deleted: true`.
- When a caller executes `sideshowdb doc history` for an identity with
  reachable versions, the system shall return a JSON array of metadata entries
  ordered newest-first.

### State-Driven Requirements

- While a document exists at the derived key, the system shall report that
  document in `list`.
- While a document does not exist at the derived key, the system shall exclude
  that document from `list`.
- While traversing history for a document identity, the system shall include
  only versions where the derived key exists and is readable.

### Error-Handling Requirements

- If a caller supplies an invalid namespace, type, or id segment, then the
  system shall reject the operation before mutating storage.
- If `sideshowdb doc delete` targets a missing latest document, then the system
  shall succeed and return `deleted: false`.
- If `sideshowdb doc history` targets an identity with no reachable versions,
  then the system shall return an empty JSON array.
- If `sideshowdb doc list` finds no matching live documents, then the system
  shall return an empty JSON array.

### Interface Requirements

- When the same logical `list`, `delete`, or `history` operation is invoked
  through the native CLI or the WASM module, the system shall apply the same
  normalization, validation, and JSON response rules.
- When the WASM module executes `sideshowdb_document_list`,
  `sideshowdb_document_delete`, or `sideshowdb_document_history`, the system
  shall accept request JSON from linear memory and expose result JSON through
  `sideshowdb_result_ptr` and `sideshowdb_result_len`.

## Testing Strategy

### DocumentStore Tests

Add store-level tests for:

- listing live documents across default and non-default namespaces
- filtering by namespace
- filtering by document type
- deleting an existing live document
- idempotent delete of a missing document
- history ordering after multiple writes to the same identity
- history returning `[]` for never-written identities
- history excluding deletion events

### Transport Tests

Add transport tests for:

- JSON request parsing for `list`, `delete`, and `history`
- normalized namespace behavior
- metadata-array responses for `list` and `history`
- delete confirmation responses with `deleted: true|false`

### CLI Tests

Add CLI tests for:

- `doc list` printing machine-readable metadata JSON
- `doc delete` printing confirmation JSON
- `doc history` printing newest-first metadata JSON
- usage failures for missing required arguments
- empty-result behavior for `list` and `history`

## Implementation Notes

- Follow TDD strictly: add one failing test per behavior, watch it fail for the
  right reason, then implement the minimum code to pass.
- Keep API naming close to the existing `put/get` slice so callers can predict
  the surface.
- Prefer adding a focused history primitive rather than leaking Git traversal
  details into CLI or WASM layers.
