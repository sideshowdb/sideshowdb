# Event And Snapshot Store EARS

This document defines requirements for the first Zig core event and snapshot
storage layer in SideshowDB.

Scope: core `EventStore` and `SnapshotStore` over existing `RefStore`
implementations. Public CLI, WASM, TypeScript, and Cucumber acceptance surfaces
are out of scope for this slice.

Design rationale:
`docs/superpowers/specs/2026-04-30-event-and-snapshot-store-design.md`.

## Event Store EARS

- **EVT-STORE-001**
  The EventStore shall persist stream events under `refs/sideshowdb/events`
  using the derived key
  `<namespace>/<aggregate_type>/<aggregate_id>.jsonl`.

- **EVT-STORE-002**
  The EventStore shall treat `(namespace, aggregate_type, aggregate_id)` as the
  event stream identity.

- **EVT-STORE-003**
  When a caller appends a valid single event to an empty stream with
  `expected_revision = 0`, the EventStore shall persist the event and return
  revision `1`.

- **EVT-STORE-004**
  When a caller appends a valid batch of events to a stream, the EventStore
  shall persist the events in request order.

- **EVT-STORE-005**
  When a caller appends a valid batch to a stream with `expected_revision = N`,
  the EventStore shall reject the append with `WrongExpectedRevision` unless
  the stream currently contains exactly `N` events.

- **EVT-STORE-006**
  When a caller appends a valid batch with `expected_revision = null`, the
  EventStore shall append without enforcing a stream length check.

- **EVT-STORE-007**
  If an append request contains no events, then the EventStore shall reject the
  request with `EmptyBatch` and not mutate storage.

- **EVT-STORE-008**
  If an append request contains events for more than one stream identity, then
  the EventStore shall reject the request with `MixedStreamBatch` and not
  mutate storage.

- **EVT-STORE-009**
  If an append request contains duplicate `event_id` values inside the incoming
  batch, then the EventStore shall reject the request with `DuplicateEventId`
  and not mutate storage.

- **EVT-STORE-010**
  If an append request contains an `event_id` that already exists in the target
  stream, then the EventStore shall reject the request with `DuplicateEventId`
  and not mutate storage.

- **EVT-STORE-011**
  If an event envelope lacks `event_id`, `event_type`, `namespace`,
  `aggregate_type`, `aggregate_id`, `timestamp`, or `payload`, then the
  EventStore shall reject the event with `InvalidEvent`.

- **EVT-STORE-012**
  If a stream identity contains an invalid key segment, then the EventStore
  shall reject the request with `InvalidStreamIdentity` before mutating
  storage.

- **EVT-STORE-013**
  When a caller loads an existing stream, the EventStore shall return events in
  stored append order.

- **EVT-STORE-014**
  When a caller loads a missing stream, the EventStore shall return an empty
  stream without mutating storage.

- **EVT-STORE-015**
  When a caller loads from revision `R`, the EventStore shall return events
  whose one-based revisions are greater than or equal to `R`.

- **EVT-STORE-016**
  If a caller loads from revision `0`, then the EventStore shall reject the
  request with `InvalidRevision`.

- **EVT-STORE-017**
  When `parseJsonlBatch` receives valid JSONL containing one event envelope per
  line for one stream, the parser shall return an equivalent event batch.

- **EVT-STORE-018**
  When `parseJsonBatch` receives a valid JSON object with an `events` array for
  one stream, the parser shall return an equivalent event batch.

- **EVT-STORE-019**
  If a JSONL or JSON batch input is malformed, empty, mixed-stream, or contains
  duplicate event IDs, then the parser shall fail before any EventStore append
  mutates storage.

## Snapshot Store EARS

- **SNAP-STORE-001**
  The SnapshotStore shall persist snapshots under `refs/sideshowdb/snapshots`
  using the derived key
  `<namespace>/<aggregate_type>/<aggregate_id>/<revision>.json`.

- **SNAP-STORE-002**
  The SnapshotStore shall treat `(namespace, aggregate_type, aggregate_id,
  revision)` as the snapshot identity.

- **SNAP-STORE-003**
  When a caller writes a valid snapshot for a revision greater than zero, the
  SnapshotStore shall persist the snapshot record including all fields
  (`namespace`, `aggregate_type`, `aggregate_id`, `revision`, `up_to_event_id`,
  `state`, and `metadata` when present).

- **SNAP-STORE-004**
  If a snapshot has revision `0`, then the SnapshotStore shall reject the write
  with `InvalidSnapshot` and not mutate storage.

- **SNAP-STORE-005**
  If a snapshot record lacks `namespace`, `aggregate_type`, `aggregate_id`,
  `revision`, `up_to_event_id`, or `state`, then the SnapshotStore shall reject
  the record with `InvalidSnapshot`.

- **SNAP-STORE-006**
  If a snapshot identity contains an invalid key segment, then the
  SnapshotStore shall reject the request with `InvalidStreamIdentity` before
  mutating storage.

- **SNAP-STORE-007**
  If a snapshot record identity does not match the requested snapshot identity,
  then the SnapshotStore shall reject the write with `InvalidSnapshot` and not
  mutate storage.

- **SNAP-STORE-008**
  When a caller writes the same snapshot revision with byte-identical
  canonical content, the SnapshotStore shall treat the write as idempotent and
  return a result with `idempotent = true`. The first successful write for a
  revision shall return `idempotent = false`.

- **SNAP-STORE-009**
  If a caller writes an existing snapshot revision with different canonical
  content, then the SnapshotStore shall reject the write with
  `SnapshotConflict` and not replace the existing snapshot.

- **SNAP-STORE-010**
  When a caller requests the latest snapshot for a stream, the SnapshotStore
  shall return the snapshot with the highest stored revision for that stream.

- **SNAP-STORE-011**
  When a caller requests a snapshot at or before revision `R`, the
  SnapshotStore shall return the highest stored snapshot revision less than or
  equal to `R`.

- **SNAP-STORE-012**
  When a caller lists snapshots for a stream, the SnapshotStore shall return
  snapshot metadata sorted newest-first by revision.

- **SNAP-STORE-013**
  When a caller requests snapshots for a stream with no snapshots, the
  SnapshotStore shall return an empty result without mutating storage.

- **SNAP-STORE-014**
  When a snapshot record is read back from storage, the SnapshotStore shall
  return the `metadata` field exactly as it was written, or `null` if no
  metadata was stored.

## Acceptance Mapping

No Cucumber acceptance scenarios are required for this core-only slice because
it does not add user-facing CLI, WASM, or TypeScript behavior.

Future public event or snapshot surfaces shall add feature files under
`acceptance/typescript/features/` and map each user-facing EARS statement to at
least one scenario.
