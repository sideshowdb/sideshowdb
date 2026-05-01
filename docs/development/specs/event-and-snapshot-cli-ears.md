# Event And Snapshot CLI EARS

This document defines user-facing CLI requirements for event and snapshot
commands over the core `EventStore` and `SnapshotStore`.

Design rationale:
`docs/superpowers/specs/2026-04-30-event-and-snapshot-store-design.md`.

## Event CLI EARS

- **EVT-CLI-001**
  When a caller invokes `event append` with a valid JSONL batch and valid stream
  identity flags, the CLI shall append the batch and return success output with
  the resulting stream revision.

- **EVT-CLI-002**
  When a caller invokes `event append` with a valid JSON batch (`events` array)
  and valid stream identity flags, the CLI shall append the batch and return
  success output with the resulting stream revision.

- **EVT-CLI-003**
  If `event append` receives malformed, empty, mixed-stream, or otherwise
  invalid batch input, then the CLI shall fail with exit code `1` and shall not
  mutate the stream.

- **EVT-CLI-004**
  If `event append` is called with `--expected-revision N` and the current
  stream revision is not `N`, then the CLI shall fail with exit code `1` and a
  `WrongExpectedRevision` error without mutating the stream.

- **EVT-CLI-005**
  When `event append` is called with `--data-file <path>`, the CLI shall read
  payload bytes from that file.

- **EVT-CLI-006**
  If `--data-file` points to a missing or unreadable path for `event append`,
  then the CLI shall fail with exit code `1`, emit a `--data-file` error, and
  not mutate stream state.

- **EVT-CLI-007**
  When both stdin and `--data-file` are supplied to `event append`, the CLI
  shall use file contents and ignore stdin.

- **EVT-CLI-008**
  When a caller invokes `event load` with valid stream identity flags, the CLI
  shall return events in append order for that stream.

- **EVT-CLI-009**
  When `event load` is called with `--from-revision R`, the CLI shall return
  events whose revisions are greater than or equal to `R`.

## Snapshot CLI EARS

- **SNAP-CLI-001**
  When a caller invokes `snapshot put` with valid identity flags, a revision,
  an up-to-event-id, and valid state JSON, the CLI shall persist the snapshot
  and return success output.

- **SNAP-CLI-002**
  If `snapshot put` receives invalid revision or invalid snapshot content, then
  the CLI shall fail with exit code `1` and shall not mutate snapshot state.

- **SNAP-CLI-003**
  When a caller invokes `snapshot get --latest` for a stream with snapshots,
  the CLI shall return the highest revision snapshot.

- **SNAP-CLI-004**
  When a caller invokes `snapshot get --at-or-before R`, the CLI shall return
  the highest snapshot revision less than or equal to `R`.

- **SNAP-CLI-005**
  When a caller invokes `snapshot list`, the CLI shall return snapshot metadata
  newest-first by revision.
