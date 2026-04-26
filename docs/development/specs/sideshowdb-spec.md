
# Functional Design Specification

## *Git‑Backed Event‑Sourced Document & Graph System*


## 1. Purpose & Scope

This system provides a **local‑first, event‑sourced data platform** whose **source of truth is stored in Git**, enabling:

*   Event‑sourced state reconstruction
*   Deterministic branching, merging, and replay
*   Offline‑first operation
*   Document and graph projections
*   Language‑agnostic implementations
*   No always‑on server requirement

The system is conceptually similar to **Marten**, but replaces the database authority (PostgreSQL) with **Git**.

> **Core principle:**  
> *Git is the event store. Embedded databases are indexes.*

***

## 2. Architectural Overview

    ┌─────────────────────────────────────────────┐
    │                 Git Repository              │
    │                                             │
    │   Canonical Event Logs (JSONL / CBOR‑L)     │◄─── Source of Truth
    │   Snapshot Markers (Optional)               │
    │   Metadata / Versioning                     │
    └───────────────┬─────────────────────────────┘
                    │ pull / merge / rebase
                    ▼
    ┌─────────────────────────────────────────────┐
    │        Local Materialization Layer           │
    │                                             │
    │   Event Index (RocksDB / IndexedDB)          │
    │   Snapshot Cache                             │
    │   Document Projections                       │
    │   Graph Projections                          │
    └───────────────┬─────────────────────────────┘
                    │ derived
                    ▼
    ┌─────────────────────────────────────────────┐
    │        Optional Analytical Layer             │
    │                                             │
    │   Parquet / Arrow Artifacts                  │
    │   DuckDB / DuckDB‑WASM                       │
    └─────────────────────────────────────────────┘

***

## 3. Core Invariants (Non‑Negotiable)

1.  **Events are append‑only**
2.  **Events are immutable**
3.  **History is reconstructible by replay**
4.  **Git stores canonical truth**
5.  **Local databases are disposable**
6.  **Merges happen on events, not state**
7.  **Projections never write back to truth**

Breaking any of these invalidates the design.

***

## 4. Canonical Data Model

### 4.1 Event Log

**Format:**

*   Primary: `JSON Lines (JSONL)`
*   Optional alternative: `CBOR sequences (CBOR‑L)`

**Constraints:**

*   One event per record
*   Line‑oriented (streamable)
*   Each event is self‑contained
*   No in‑place mutation

**Event Record (logical schema):**

```json
{
  "event_id": "evt-<hash>",
  "event_type": "String",
  "aggregate_id": "String",
  "timestamp": "RFC3339",
  "payload": { },
  "metadata": {
    "author": "...",
    "schema_version": 1,
    "causation_id": "...",
    "correlation_id": "..."
  }
}
```

The system does **not** enforce a global schema — only minimal required fields.

***

### 4.2 Event Storage Layout (Git)

Recommended layout:

    /.events/
      /<aggregate-type>/
        /<aggregate-id>.jsonl

Examples:

    .events/issues/issue-9f3a.jsonl
    .events/users/user-alice.jsonl

**Rules:**

*   Appends only
*   No rewriting
*   No deletions (tombstone events instead)

***

## 5. Event Processing Model

### 5.1 Replay

State reconstruction occurs by:

1.  Reading events sequentially
2.  Applying domain‑specific reducers
3.  Producing derived state

Replay must be:

*   Deterministic
*   Idempotent
*   Side‑effect free

***

### 5.2 Snapshots (Optional Optimization)

Snapshots exist solely for performance.

**Properties:**

*   Derived from events ≤ N
*   Rebuildable at any time
*   Not authoritative

Example snapshot metadata:

```json
{
  "snapshot_of": "aggregate-id",
  "up_to_event": "evt-abc123",
  "hash": "..."
}
```

Snapshots MAY be stored:

*   Locally only, or
*   In Git (clearly marked as derived)

Deleting snapshots must never lose information.

***

## 6. Local Storage & Indexing

Local engines are **materialization tools**, not databases of record.

### 6.1 Event Index

Purpose:

*   Fast lookup
*   Range scans
*   Replay acceleration

**Recommended engines:**

*   Native: RocksDB
*   Browser: IndexedDB
*   Optional: SQLite (projection‑only)

**Rebuild rule:**

> If the local store is deleted, the system must rehydrate fully from Git.

***

### 6.2 Document Projections

Documents represent **current materialized state**.

Example:

```json
{
  "id": "issue-9f3a",
  "status": "open",
  "title": "Design Git‑native event store",
  "updated_at": "..."
}
```

Derived solely by applying reducers to events.

***

## 7. Graph Projections (Linked Data Support)

### 7.1 Graph State

Graphs represent relationships derived from events.

Supported derived formats:

*   RDF N‑Quads (streaming)
*   JSON‑LD
*   Property graph representations

**Rule:**

> Graphs are derived views — never event sources.

***

### 7.2 RDF Mapping

Each event MAY emit one or more derived statements.

Example mapping:

```json
AddDependency(issueA, issueB)
```

Produces:

```nq
<issue:A> <blocks> <issue:B> <graph:issues> .
```

Graph rebuilding is done via full or incremental replay.

***

## 8. Git Semantics

### 8.1 Branching

*   Branch = parallel event timeline
*   Branch contains full historical context
*   No special handling required

***

### 8.2 Merging

Merges operate on **event logs**, not projections.

Merge strategies:

*   Append all non‑conflicting events
*   Resolve conflicts via event‑level rules
*   Never merge projections directly

Human‑readable diffs are a first‑class feature (JSONL).

***

## 9. Analytical Layer (Optional)

For read‑heavy or analytical workloads:

*   Events or projections MAY be exported to Parquet
*   DuckDB (native or WASM) MAY query these artifacts

**Constraints:**

*   Analytics never mutate source logs
*   Artifacts are cacheable and discardable

***

## 10. Language‑Neutral API Surface

### Required Capabilities

All implementations MUST support:

*   Append event
*   Load event stream
*   Replay to state
*   Produce projection
*   Rebuild local state
*   Sync via Git

### Optional Capabilities

*   Snapshotting
*   Graph exports
*   Analytics export
*   Schema upcasting

***

## 11. Explicit Non‑Goals

This system is **not**:

*   A real‑time transactional database
*   A distributed consensus system
*   A strongly consistent global store
*   A binary‑opaque Git blob system
*   A replacement for SQL OLTP systems

***

## 12. Design Summary (Guiding Sentence)

> **This system treats Git as an immutable event store and uses embedded databases as disposable indexes, enabling document and graph projections through deterministic event replay.**

***

## Next Steps

From here, natural follow‑ups are:

*   A **canonical reducer interface**
*   Event schema versioning rules
*   Conflict resolution strategies
*   Minimal “beads‑like” MVP spec
*   Reference implementation matrix (Go / Rust / TS)

When you’re ready, we can turn this into:

*   A formal RFC‑style spec
*   A README suitable for an OSS project
*   Or a “contract test suite” that multiple implementations can prove against

You’ve landed on something both elegant *and* powerful.
