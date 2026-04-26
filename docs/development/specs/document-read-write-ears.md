# Namespaced, Versioned Document Read/Write EARS

## Purpose

This specification captures the acceptance expectations for the first public
document slice in sideshowdb: storing and retrieving arbitrary JSON documents
through Git refs, with the same normalization and versioning rules exposed via
the native CLI and the host-backed WASM surface.

This slice builds on the git-ref storage model in
[git-ref-storage-spec.md](./git-ref-storage-spec.md) and narrows it to a
single document-oriented contract.

## Canonical Response Envelope

Successful document reads and writes return JSON in this shape:

```json
{
  "namespace": "default",
  "type": "string",
  "id": "string",
  "version": "<git-commit-sha>",
  "data": {}
}
```

Notes:

- `namespace`, `type`, and `id` form the logical document identity.
- `version` is the Git commit SHA of the ref snapshot used for the response.
- The persisted blob omits `version` internally to avoid a self-referential
  commit-hash cycle; `version` is synthesized at the API boundary from Git
  metadata.
- The backing ref for this slice is `refs/sideshowdb/documents`.
- The backing key for a document is `<namespace>/<type>/<id>.json`.

## EARS Requirements

### Ubiquitous Requirements

- The system shall persist valid document writes under
  `refs/sideshowdb/documents` using the derived key
  `<namespace>/<type>/<id>.json`.
- The system shall treat `(namespace, type, id)` as the document identity.
- The system shall normalize omitted namespace values to `"default"` at the
  CLI and WASM boundaries.
- The system shall return the created Git commit SHA as `version` after a
  successful write.
- The system shall return the latest reachable document for an identity when no
  explicit version selector is supplied.
- The system shall return the document content stored at the requested Git
  commit when a version selector is supplied.

### State-Driven Requirements

- While a document already exists at the derived key, when a caller writes a
  new value for the same `(namespace, type, id)`, the system shall replace the
  latest blob at that key by creating a new commit in the documents ref
  history.
- While a caller provides payload-only JSON to `doc put`, when `--type` and
  `--id` are supplied, the system shall normalize the request into the
  canonical response envelope and apply `--namespace` or `"default"`.
- While a caller provides a full envelope payload without `version`, when CLI
  flags for identity are also supplied, the system shall require the supplied
  identity values to match after namespace defaulting.

### Error-Handling Requirements

- When a write request lacks document identity after combining payload and
  transport metadata, the system shall reject the request before mutating
  storage.
- When a write request supplies `version`, the system shall reject the request
  because version is output-only in this slice.
- When a read targets a missing latest document, the system shall report
  not-found without creating commits or changing refs.
- When a read specifies a version that does not contain the requested key, the
  system shall report not-found for that version without changing refs.
- When transport metadata and payload identity disagree after namespace
  defaulting, the system shall fail validation and perform no write.

### Interface Requirements

- When the same logical document operation is invoked through the native CLI or
  the WASM module, the system shall apply the same normalization, namespace
  defaulting, version synthesis, and validation rules.
- When the CLI executes `sideshowdb doc put`, the system shall read JSON from
  stdin and write machine-readable JSON only to stdout on success.
- When the CLI executes `sideshowdb doc get`, the system shall require `type`
  and `id`, accept optional `namespace` and `version`, and emit canonical
  response JSON to stdout on success.
- When the WASM module executes `sideshowdb_document_put` or
  `sideshowdb_document_get`, the system shall accept request JSON from linear
  memory and expose the result JSON through `sideshowdb_result_ptr` and
  `sideshowdb_result_len`.
