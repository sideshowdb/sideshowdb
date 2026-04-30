# SideshowDB Event And Snapshot Store Design

Date: 2026-04-30
Status: Approved
Issue: `sideshowdb-yik`

## Summary

SideshowDB already describes itself as an event-sourced database, but the
current implementation is centered on a document/key-value layer over
`RefStore`. This design adds the first core event-sourcing layer without
expanding the public CLI, WASM, or TypeScript surfaces yet.

The slice introduces:

- `EventStore`, backed by a `RefStore` rooted at `refs/sideshowdb/events`
- `SnapshotStore`, backed by a `RefStore` rooted at `refs/sideshowdb/snapshots`
- validated event envelopes with opaque JSON payload and metadata
- single-stream event batches accepted as JSONL or JSON structures
- optimistic expected-revision checks
- revision-addressed snapshots that remain derived from event truth

## Goals

- Deliver a real core event store promise behind the architecture docs.
- Keep the first implementation backend-neutral by building on `RefStore`.
- Support namespaced aggregate streams, mirroring the document identity model.
- Support caller-provided event IDs for deterministic idempotency checks.
- Support JSONL and JSON batch input with identical validation semantics.
- Support revision-addressed snapshots as rebuildable performance artifacts.
- Keep public CLI, WASM, and TypeScript APIs out of scope until core behavior
  is stable.

## Non-Goals

- Adding CLI commands for event append/load or snapshot management.
- Adding WASM exports or TypeScript client methods for events or snapshots.
- Adding cross-stream atomic batches.
- Adding domain schema validation, reducers, projection runners, or upcasters.
- Adding indexing, prefix scans, or streaming readers beyond byte-slice parsers.
- Adding remote-sync behavior beyond what the underlying `RefStore` provides.

## Follow-Up Tracking

The full end-to-end feature is tracked by `sideshowdb-asz`. The non-goals
above are intentionally deferred into these follow-up beads:

- `sideshowdb-v71`: public CLI surface for event and snapshot stores
- `sideshowdb-2mv`: WASM and TypeScript APIs for event and snapshot stores
- `sideshowdb-thd`: reducer, projection, schema validation, and upcaster
  pipeline
- `sideshowdb-q6c`: streaming event readers and indexed stream traversal
- `sideshowdb-3tz`: cross-stream event batch semantics
- `sideshowdb-9gs`: remote sync semantics for event and snapshot stores
- `sideshowdb-fed`: docs and playground walkthrough for event-sourced workflow

## Architecture

The new stores are sibling layers to `DocumentStore`:

```text
EventStore(RefStore for refs/sideshowdb/events)
SnapshotStore(RefStore for refs/sideshowdb/snapshots)
```

The caller owns backend selection and lifetime. Tests can use
`MemoryRefStore`; native integration can use `SubprocessGitRefStore`;
`GitHubApiRefStore` will work later because it implements the same `RefStore`
contract.

Event streams are stored as JSONL blobs under:

```text
<namespace>/<aggregate_type>/<aggregate_id>.jsonl
```

Snapshots are stored as revision-addressed JSON blobs under:

```text
<namespace>/<aggregate_type>/<aggregate_id>/<revision>.json
```

This keeps Git as canonical event truth while making snapshots clearly derived
and discardable.

## Event Model

Core v1 event records use a validated envelope:

```json
{
  "event_id": "evt-1",
  "event_type": "IssueOpened",
  "namespace": "default",
  "aggregate_type": "issue",
  "aggregate_id": "issue-1",
  "timestamp": "2026-04-30T12:00:00Z",
  "payload": {},
  "metadata": {}
}
```

Required fields:

- `event_id`
- `event_type`
- `namespace`
- `aggregate_type`
- `aggregate_id`
- `timestamp`
- `payload`

Optional fields:

- `metadata`

`payload` and `metadata` may be any valid JSON value. Core validates the
envelope and stream identity, but it does not validate domain-specific payload
schema.

The existing placeholder `src/core/event.zig` should become the home for:

- `StreamIdentity`
- `EventEnvelope`
- `ParsedEventBatch`
- `AppendRequest`
- `AppendResult`
- `EventStore`
- JSON and JSONL batch parsing helpers

## Append Semantics

The append API should be shaped like:

```zig
pub const AppendRequest = struct {
    identity: StreamIdentity,
    expected_revision: ?u64 = null,
    events: []const EventEnvelope,
};
```

Revision semantics:

- The current stream revision is the number of existing events.
- `expected_revision = null` skips revision checking.
- `expected_revision = 0` means the stream must not exist or must be empty.
- `expected_revision = N` means the stream must currently contain exactly `N`
  events.
- A successful append returns the new revision and the backing
  `RefStore.VersionId`.

Validation happens before mutation:

- Empty batches are rejected.
- Every event in a batch must target the request stream identity.
- Mixed-stream batches are rejected.
- Duplicate `event_id` values inside the incoming batch are rejected.
- Duplicate `event_id` values already present in the target stream are
  rejected.
- Invalid stream identity parts are rejected before contacting storage.

The first implementation can read the existing stream blob, parse JSONL,
validate the append, append canonicalized JSONL lines, and write the full blob
back through `RefStore.put`.

## Batch Input

Core supports JSONL and JSON batch input before public boundaries exist, so
later CLI/WASM/TypeScript layers inherit one parsing contract.

JSONL batch input:

```jsonl
{"event_id":"evt-1","event_type":"IssueOpened","namespace":"default","aggregate_type":"issue","aggregate_id":"issue-1","timestamp":"2026-04-30T12:00:00Z","payload":{"title":"First"}}
{"event_id":"evt-2","event_type":"IssueRenamed","namespace":"default","aggregate_type":"issue","aggregate_id":"issue-1","timestamp":"2026-04-30T12:01:00Z","payload":{"title":"Second"}}
```

JSON batch input:

```json
{
  "events": [
    {
      "event_id": "evt-1",
      "event_type": "IssueOpened",
      "namespace": "default",
      "aggregate_type": "issue",
      "aggregate_id": "issue-1",
      "timestamp": "2026-04-30T12:00:00Z",
      "payload": { "title": "First" }
    }
  ]
}
```

The parser layer exposes:

```zig
pub fn parseJsonlBatch(gpa: Allocator, bytes: []const u8) !ParsedEventBatch;
pub fn parseJsonBatch(gpa: Allocator, bytes: []const u8) !ParsedEventBatch;
```

Both parsers produce the same internal batch type. Both reject malformed JSON,
empty batches, mixed stream identities, invalid envelopes, and duplicate event
IDs before the store mutates the backing ref.

JSONL is line-oriented so future streaming readers can process one event at a
time. Core v1 only needs byte-slice parsers; a true incremental reader can be
added without changing the stored format.

## Loading Streams

The first core store should expose stream loading by identity:

```zig
pub fn load(gpa: Allocator, identity: StreamIdentity) !EventStream;
pub fn loadFromRevision(
    gpa: Allocator,
    identity: StreamIdentity,
    start_revision: u64,
) !EventStream;
```

Revisions are one-based for returned events. A stream with two events has
revision `2`; loading from revision `2` returns the second event and later
events. Loading from revision `0` is invalid and returns
`error.InvalidRevision`. Loading a missing stream returns an empty stream.

## Snapshot Model

Snapshots are derived, revision-addressed records:

```json
{
  "namespace": "default",
  "aggregate_type": "issue",
  "aggregate_id": "issue-1",
  "revision": 42,
  "up_to_event_id": "evt-42",
  "state": {},
  "metadata": {}
}
```

Required fields:

- `namespace`
- `aggregate_type`
- `aggregate_id`
- `revision`
- `up_to_event_id`
- `state`

Optional fields:

- `metadata`

Rules:

- `revision` must be greater than zero.
- Snapshot identity must match its key.
- `state` may be any valid JSON value.
- Snapshot writes are idempotent only when the same revision is written with
  byte-identical canonical content.
- Conflicting content for an existing revision is rejected.

`src/core/snapshot.zig` should contain:

- `SnapshotRecord`
- `SnapshotMetadata`
- `PutSnapshotRequest`
- `SnapshotWriteResult`
- `SnapshotStore`

## Snapshot Operations

The first `SnapshotStore` API should expose:

```zig
pub fn put(gpa: Allocator, request: PutSnapshotRequest) !SnapshotWriteResult;
pub fn getLatest(gpa: Allocator, identity: StreamIdentity) !?SnapshotRecord;
pub fn getAtOrBefore(
    gpa: Allocator,
    identity: StreamIdentity,
    revision: u64,
) !?SnapshotRecord;
pub fn list(gpa: Allocator, identity: StreamIdentity) ![]SnapshotMetadata;
```

Lookup can be intentionally simple in v1:

1. Call `RefStore.list()`.
2. Filter keys by stream prefix.
3. Parse revision filenames.
4. Sort revisions descending for latest and at-or-before lookups.
5. Fetch the selected blob with `RefStore.get()`.

This is correct over every `RefStore` implementation. Prefix indexes and
backend-level scans can come later.

`list` returns snapshot metadata newest-first by revision. This mirrors event
history traversal and makes the first item the same snapshot that `getLatest`
would select.

## Error Handling

Core should use specific errors that future transport layers can map cleanly:

```zig
error.InvalidEvent
error.InvalidRevision
error.InvalidSnapshot
error.InvalidStreamIdentity
error.EmptyBatch
error.MixedStreamBatch
error.DuplicateEventId
error.WrongExpectedRevision
error.SnapshotConflict
```

Storage errors from the backing `RefStore` propagate unchanged.

## Testing

Add focused Zig tests:

- `tests/event_store_test.zig`
  - appends one event to an empty stream
  - appends JSONL batches
  - appends JSON batches
  - loads a missing stream as empty
  - loads from a one-based revision
  - rejects load from revision `0`
  - rejects empty batches
  - rejects mixed-stream batches
  - rejects duplicate IDs inside a batch
  - rejects duplicate IDs already in a stream
  - enforces expected revision `0`, `N`, and mismatch
  - rejects invalid identity and key fields
- `tests/snapshot_store_test.zig`
  - writes and reads latest snapshot
  - reads snapshot at or before a revision
  - lists snapshots newest-first by revision
  - rejects revision `0`
  - rejects identity/key mismatch
  - allows byte-identical idempotent writes
  - rejects conflicting same-revision writes

No acceptance tests are required in this core-only slice because no public
CLI/WASM/TypeScript behavior changes yet. When public surfaces are added, each
user-facing EARS statement must map to Cucumber scenarios under
`acceptance/typescript/features/`.

## Implementation Notes

- Keep serialization deterministic by writing canonical JSON for stored events
  and snapshots.
- Reuse `RefStore.validateKey` style constraints for derived keys.
- Do not add a new storage backend or backend-specific assumptions.
- Re-export `event` and `snapshot` from `src/core/root.zig` when implemented.
- Register new tests in `build.zig`.
- Keep follow-up public API work in separate beads issues after the core plan
  is accepted.
