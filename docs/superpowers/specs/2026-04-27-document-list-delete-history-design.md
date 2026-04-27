# Sideshowdb Document List/Delete/History Design

Date: 2026-04-27
Status: Proposed
Issue: `sideshowdb-psy`

## Summary

Sideshowdb's first document slice already supports versioned `put` and `get`
across `DocumentStore`, the native CLI, and the host-backed WASM surface. The
next step is to make the slice traversable and maintainable by adding `list`,
`delete`, and `history`.

This revised design keeps `put` and `get` intact, but makes collection reads
more flexible:

- `list` and `history` support `summary` and `detailed` response modes
- `summary` returns identity/version metadata
- `detailed` returns full canonical document envelopes including `data`
- `list` and `history` both support `limit + next_cursor` pagination

## Goals

- Add document `list`, `delete`, and `history` operations to the shared
  document slice.
- Keep behavior aligned across `DocumentStore`, CLI, and WASM transports.
- Reuse Git-backed version history as the source of truth for document
  traversal.
- Support both lightweight summary traversal and full-envelope detailed
  traversal.
- Support cursor-based pagination with size limits for collection reads.
- Define explicit user-facing behavior in EARS so tests can drive the
  implementation.

## Non-Goals

- Adding server-side indexing or non-Git storage for traversal
- Introducing batch delete or wildcard delete semantics
- Adding arbitrary sorting beyond the defined stable traversal order
- Changing the canonical response envelope for `put` and `get`
- Adding offset-based pagination

## Product Decisions

### Dual Collection Modes

`list` and `history` both accept a `mode` option with these values:

- `summary`
- `detailed`

If `mode` is omitted, the system defaults to `summary`.

`summary` returns items shaped like:

```json
{
  "namespace": "default",
  "type": "issue",
  "id": "doc-1",
  "version": "<git-commit-sha>"
}
```

`detailed` returns full canonical document envelopes shaped like:

```json
{
  "namespace": "default",
  "type": "issue",
  "id": "doc-1",
  "version": "<git-commit-sha>",
  "data": {}
}
```

This preserves a fast metadata-only path while allowing callers to fetch full
document data during traversal when needed.

### Cursor-Based Pagination

`list` and `history` both use `limit + next_cursor` pagination.

- `limit` is optional
- `cursor` is optional on requests after the first page
- `next_cursor` is `null` when no more items remain

This is preferred over offset pagination because it is more stable under
concurrent inserts and deletes and gives the implementation freedom to change
internal traversal details later.

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
newest-first order. Deletion events themselves are not returned as items.

## User-Facing Contract

### Shared Store Surface

The document slice should expose these operations:

- `put(request) -> canonical document envelope`
- `get(request) -> canonical document envelope?`
- `list(request) -> CollectionPage`
- `delete(request) -> DeleteResult`
- `history(request) -> CollectionPage`

Suggested request/response structs:

- `CollectionMode`
  - `summary`
  - `detailed`
- `ListRequest`
  - optional `namespace`
  - optional `type`
  - optional `limit`
  - optional `cursor`
  - optional `mode`
- `DeleteRequest`
  - optional `namespace`
  - required `type`
  - required `id`
- `HistoryRequest`
  - optional `namespace`
  - required `type`
  - required `id`
  - optional `limit`
  - optional `cursor`
  - optional `mode`
- `DocumentMetadata`
  - `namespace`
  - `type`
  - `id`
  - `version`
- `CollectionItem`
  - `DocumentMetadata` in `summary` mode
  - canonical document envelope in `detailed` mode
- `CollectionPage`
  - `mode`
  - `items`
  - `next_cursor`
- `DeleteResult`
  - `namespace`
  - `type`
  - `id`
  - `deleted`

### CLI

The native CLI extends `sideshowdb doc` with:

```text
sideshowdb doc list [--namespace <ns>] [--type <type>] [--limit <n>] [--cursor <cursor>] [--mode summary|detailed]
sideshowdb doc delete --type <type> --id <id> [--namespace <ns>]
sideshowdb doc history --type <type> --id <id> [--limit <n>] [--cursor <cursor>] [--mode summary|detailed] [--namespace <ns>]
```

Behavior:

- `list` prints a JSON page object with `mode`, `items`, and `next_cursor`.
- `history` prints a JSON page object with `mode`, `items`, and `next_cursor`.
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
  - optional `limit`
  - optional `cursor`
  - optional `mode`
- `delete`
  - optional `namespace`
  - required `type`
  - required `id`
- `history`
  - optional `namespace`
  - required `type`
  - required `id`
  - optional `limit`
  - optional `cursor`
  - optional `mode`

## Technical Design

### DocumentStore Responsibilities

`DocumentStore` remains the shared behavioral layer. It should:

- normalize omitted namespaces to `"default"`
- validate identity segments before mutating storage
- derive keys as `<namespace>/<type>/<id>.json`
- resolve summary vs detailed item shaping
- enforce a supported page-size ceiling
- keep `put/get` envelope behavior unchanged

`list` should enumerate the current live keys under
`refs/sideshowdb/documents`, parse the key structure, optionally filter by
namespace and type, order results stably, and emit a page of summary or
detailed items plus `next_cursor`.

In `summary` mode, `list` should synthesize metadata entries with the latest
reachable version for each live document.

In `detailed` mode, `list` should materialize the latest canonical document
envelope for each live document returned on the page.

`delete` should derive the key from the normalized identity, delete the latest
live blob for that key, and report whether a live document existed at deletion
time.

`history` should walk the Git-backed history for one derived key and return a
page of summary or detailed items in newest-first order, excluding commits
where the key is not present.

### Pagination Semantics

Collection traversal order must be stable within a response contract so a
cursor can resume correctly.

`list` response shape:

```json
{
  "mode": "summary",
  "items": [],
  "next_cursor": null
}
```

`history` uses the same page wrapper.

The first request omits `cursor`. If additional items remain after the current
page, the response includes a non-null `next_cursor`. A caller can pass that
value back as `cursor` to continue traversal.

The implementation should define a default page size and a maximum supported
page size. Requests above the supported ceiling should fail validation rather
than silently returning an unexpectedly different page size.

### RefStore Requirements

The current low-level ref storage already supports:

- `put`
- `get`
- `delete`
- `list`

To support paged history cleanly, the lower layer will likely need a new
capability that enumerates reachable versions for one key, or an equivalent
Git-backed helper inside the document slice. The important boundary is that the
document layer owns identity normalization, mode selection, and response
shaping, while the storage layer owns Git traversal.

### Response Semantics

- `list` returns a page object whose `items` may be empty.
- `history` returns a page object whose `items` may be empty.
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
- The document slice shall support `summary` and `detailed` modes for `list`
  and `history`.
- The document slice shall default `list` and `history` to `summary` mode when
  `mode` is omitted.
- The document slice shall return metadata-only items from `list` and
  `history` when `mode` is `summary`.
- The document slice shall return full canonical document envelopes from
  `list` and `history` when `mode` is `detailed`.

### Event-Driven Requirements

- When a caller executes `sideshowdb doc list` without filters, the system
  shall return the first page of live documents under
  `refs/sideshowdb/documents`.
- When a caller executes `sideshowdb doc list` with `--namespace` and/or
  `--type`, the system shall return only live documents matching those filters.
- When a caller executes `sideshowdb doc list` or `sideshowdb doc history`
  with `--mode summary`, the system shall return summary items.
- When a caller executes `sideshowdb doc list` or `sideshowdb doc history`
  with `--mode detailed`, the system shall return detailed items including
  `data`.
- When a caller omits `mode` for `sideshowdb doc list` or
  `sideshowdb doc history`, the system shall return summary items.
- When a caller executes `sideshowdb doc delete` for an existing live document,
  the system shall remove the latest blob for that identity and return a JSON
  object with `deleted: true`.
- When a caller executes `sideshowdb doc history` for an identity with
  reachable versions, the system shall return the first page of history entries
  ordered newest-first.
- When a caller supplies a valid `cursor` for `list` or `history`, the system
  shall return the next page in the same traversal order.

### State-Driven Requirements

- While a document exists at the derived key, the system shall report that
  document in `list`.
- While a document does not exist at the derived key, the system shall exclude
  that document from `list`.
- While traversing history for a document identity, the system shall include
  only versions where the derived key exists and is readable.
- While additional items remain after the current page, the system shall return
  a non-null `next_cursor`.
- While no additional items remain after the current page, the system shall
  return `next_cursor` as `null`.

### Error-Handling Requirements

- If a caller supplies an invalid namespace, type, or id segment, then the
  system shall reject the operation before mutating storage.
- If a caller supplies an unsupported `mode`, then the system shall reject the
  operation.
- If a caller supplies a `limit` greater than the supported page-size ceiling,
  then the system shall reject the operation.
- If a caller supplies an invalid or unreadable `cursor`, then the system shall
  reject the operation.
- If `sideshowdb doc delete` targets a missing latest document, then the system
  shall succeed and return `deleted: false`.
- If `sideshowdb doc history` targets an identity with no reachable versions,
  then the system shall return a page object with an empty `items` array.
- If `sideshowdb doc list` finds no matching live documents, then the system
  shall return a page object with an empty `items` array.

### Interface Requirements

- When the same logical `list`, `delete`, or `history` operation is invoked
  through the native CLI or the WASM module, the system shall apply the same
  normalization, validation, pagination, and JSON response rules.
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
- list summary mode responses
- list detailed mode responses including `data`
- history summary mode responses
- history detailed mode responses including `data`
- paged `list` traversal across multiple pages
- paged `history` traversal across multiple pages
- `next_cursor` becoming `null` at exhaustion
- rejecting oversized limits
- deleting an existing live document
- idempotent delete of a missing document
- history excluding deletion events

### Transport Tests

Add transport tests for:

- JSON request parsing for `list`, `delete`, and `history`
- normalized namespace behavior
- `mode` selection
- `limit` and `cursor` handling
- page wrapper responses for `list` and `history`
- delete confirmation responses with `deleted: true|false`

### CLI Tests

Add CLI tests for:

- `doc list --mode summary`
- `doc list --mode detailed`
- `doc history --mode summary`
- `doc history --mode detailed`
- paged `list` output with `--limit` and `--cursor`
- paged `history` output with `--limit` and `--cursor`
- `doc delete` confirmation JSON
- usage failures for missing required arguments
- validation failures for bad `mode` or oversized `limit`

## Implementation Notes

- Follow TDD strictly: add one failing test per behavior, watch it fail for the
  right reason, then implement the minimum code to pass.
- Keep API naming close to the existing `put/get` slice so callers can predict
  the surface.
- Prefer adding a focused history primitive rather than leaking Git traversal
  details into CLI or WASM layers.
