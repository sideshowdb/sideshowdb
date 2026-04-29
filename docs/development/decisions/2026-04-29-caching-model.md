# ADR — Caching Model for SideshowDB Local Materialization

- **Date:** 2026-04-29
- **Status:** Accepted
- **Context window:** sideshowdb-7pp (was: "LevelDB write-behind cache backend")
- **Supersedes:** the loose use of "write-behind" in sideshowdb-7pp.

## 1. Context

SideshowDB's storage architecture treats Git as canonical truth and any
local engine (memory, LevelDB, RocksDB, IndexedDB) as a disposable
materialization. The original issue
[sideshowdb-7pp](../../../.beads/issues.jsonl) used the term
"write-behind" for the local cache layer. As we approached
implementation we discovered that the original wording conflated two
different concerns:

1. A **caching primitive** that lets local engines serve fast reads and
   pre-stage writes without changing the canonical-truth contract.
2. A **write-throughput optimization** that batches multiple logical
   puts into one canonical Git commit and acks the caller before the
   batch is flushed.

(2) is what the term "write-behind" precisely names in industry
literature. (1) is what most of the issue text actually described, and
is what the implementation we just shipped delivers.

This ADR records the decision that (1) ships first, alone, under an
honest name; (2) is filed as separate, dependent work.

## 2. Options Considered

### 2.1 Pure write-through cache

- Caller blocks until canonical accepts.
- Cache populated as a side effect (write-through, plus cache prime on
  the way down to canonical).
- Reads consult cache first, fall through to canonical, refill on miss
  (read-through).

**Pros.** Simple. No new durability story — Git is still the only
durable substrate. Zero data-loss risk on crash. Easy to reason about
under failure: any successful put has a canonical version-id;
unsuccessful puts have neither cache nor canonical state that the
caller relied on.

**Cons.** Latency of a put is bounded by canonical's commit latency. A
Git commit is non-trivial — object hashing, tree write, ref update —
and each put pays that cost individually.

### 2.2 Pure write-behind (no log)

- Caller acks after cache accepts; canonical commit happens later,
  asynchronously.
- Failure between cache-ack and canonical-commit means cache holds data
  canonical does not.

**Pros.** Lowest latency at the put boundary.

**Cons.** Catastrophic for SideshowDB. Canonical is the event log; a
lost canonical commit is a lost event. Caches are explicitly
disposable; relying on them for durability inverts the architecture.
Recovery story is "hope the cache file survived the crash" — unsuitable
for an event-sourced DB.

### 2.3 Write-ahead log (WAL) + batched canonical flush

- Caller writes to a durable WAL (fsync'd). WAL ack returns to caller.
- A flusher coalesces N WAL entries into one canonical Git commit
  (one tree update, one ref move).
- On crash, WAL is replayed against canonical at startup; entries that
  did not yet make it into a canonical commit are flushed.

**Pros.** Throughput of pure write-behind without the durability hole.
Per-put latency = WAL fsync, not Git commit. Throughput at canonical =
1/N puts per commit. The classic "write-behind" pattern, properly
engineered.

**Cons.** Substantial complexity surface: WAL format, WAL fsync policy,
crash-replay ordering, idempotency guarantees, observable mid-batch
state. Needs its own EARS and test plan. Not appropriate as a P3
backlog issue without dedicated design.

### 2.4 Write-around (cache only on read)

- Writes go straight to canonical, bypassing cache.
- Cache is populated only when a read pulls a value through.

**Pros.** Trivial to implement. No speculative-cache state. No
`.lax`/`.strict` distinction for writes (only canonical can fail).
No `list`/`get` divergence under failure. Realistic match for the
common "single cache, optimize reads, accept canonical write
latency" deployment shape.

**Cons.** Defeats the point of having multiple cache slots —
write-heavy workloads never benefit. Subsequent reads of a fresh
write must hit canonical at least once before the cache warms up.

**Status.** Filed as a sibling primitive in
[sideshowdb-p9h](../../../.beads/issues.jsonl) to be designed and
shipped independently. Not bundled into this PR because it is a
distinct write semantic with its own EARS, even though it shares the
read path with `WriteThroughRefStore`.

## 3. Decision

Ship **write-through with read-through fallback** as the *first*
primitive (option 2.1) under the explicit name `WriteThroughRefStore`.

Sibling primitives are filed as separately-scoped follow-ups, each to
be designed and shipped independently:

- **WAL + batched canonical flush** (option 2.3) →
  [sideshowdb-0r1](../../../.beads/issues.jsonl). The genuine
  "write-behind" pattern; layers over the write-through primitive
  without changing it.
- **Write-around** (option 2.4) →
  [sideshowdb-p9h](../../../.beads/issues.jsonl). Distinct write
  semantic — useful when single-cache deployments want to skip the
  speculative-cache window entirely. Reuses the read-through path
  introduced here.
- **Offline writes** (caller-visible success while canonical
  unreachable) → [sideshowdb-nbv](../../../.beads/issues.jsonl).
  Overlaps with the WAL primitive; final shape depends on whether it
  shares WAL infrastructure or stands alone.

Reject option 2.2 outright: a pure write-behind cache without a
durable log creates a data-loss hole that is incompatible with
SideshowDB's event-sourced contract.

### 3.1 Deployment intent

Production deployments are expected to use **single-cache** topologies
in the steady state — most callers will want one in-memory or
on-disk cache fronting canonical. The N-cache fan-out is exercised
during benchmarking and tiered-cache experimentation, not in
production hot paths.

The two operational regimes that matter most in practice:

- **Online, single cache, read-perf focus.** `WriteThroughRefStore`
  with one cache. Reads short-circuit cache; writes block on
  canonical. No new durability story. This is what ships now.
- **Offline-tolerant local-first.** Writes succeed against a
  durable local cache while canonical is unreachable, then flush
  on reconnect. Tracked as
  [sideshowdb-nbv](../../../.beads/issues.jsonl). This is the
  feature SideshowDB's local-first posture ultimately needs; it is
  scoped separately because its design surface (durability format,
  reconciliation, conflict policy) is independent from the
  composite slot delivered here.

### 3.1 Rationale

- **Architecture-first.** A composite slot any cache backend can plug
  into delivers immediate value: read-perf for in-memory cache,
  upcoming on-disk cache backends (LevelDB, RocksDB, Zeno, IndexedDB),
  multi-backend benchmarking, tiered-cache experimentation.
- **No durability regression.** Canonical truth still lives in Git
  refs. Any cache loss is recoverable by replaying canonical history.
  This holds regardless of which concrete cache backend slots in.
- **WAL is independently scoped.** Adding a WAL-batched flush layer is
  a self-contained throughput optimization. It can be implemented as a
  separate `RefStore` that wraps a `WriteThroughRefStore` and intercepts
  writes for batching. The two pieces are independently shippable and
  independently testable. Coupling them in one issue gives us both at
  once at the cost of a much larger blast radius.
- **Honest naming.** `WriteThroughRefStore` describes what the type
  actually does, not what its parent issue happened to be titled.
  Pure write-behind has a precise meaning in cache literature; using it
  for write-through introduces a maintenance trap.

### 3.2 Consequences

- The type ships as `WriteThroughRefStore` (renamed from the
  pre-review `WriteBehindRefStore`). Every reference in spec, tests,
  exports, and architecture doc is updated to match.
- The original sideshowdb-7pp issue is split:
  - **Composite primitive (this PR)** delivers the architectural slot.
  - **WAL-batched flush** is filed as a new issue with its own EARS and
    test plan. The original 7pp's two queue/flush EARS migrate to that
    issue verbatim.
- The `WriteThroughRefStore` API stays minimal so a future
  `BatchedFlushRefStore` (or similar) can wrap it without breaking
  existing callers. No batch-handle, no flush-callback, no implicit
  futures in the surface today.

## 4. Out of Scope (deferred)

- WAL durability format and replay protocol.
- Async flusher thread / fiber.
- Mid-batch crash recovery semantics.
- Cross-process WAL contention.
- Per-cache eviction policy hooks.

These all live with the WAL-batched issue when filed.

## 5. References

- Pre-rename spec: `docs/development/specs/write-behind-store-spec.md`
  (renamed in this PR to `write-through-store-spec.md`).
- Critic review: `docs/development/reviews/2026-04-29-write-behind-composite-review.md`.
- Original issue: sideshowdb-7pp (notes updated in this PR to point
  here and to the new WAL follow-up issue).
