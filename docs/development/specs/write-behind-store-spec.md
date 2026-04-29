# Write-Behind RefStore — Functional Spec (MVP)

## 1. Purpose & Scope

This spec describes `WriteBehindRefStore`: a composite `RefStore`
implementation that fronts a **canonical** `RefStore` with one or more
**cache** `RefStore`s. The composite preserves the contract laid out in
[`git-ref-storage-spec.md`](./git-ref-storage-spec.md) — every
caller-visible operation behaves as if it ran directly against the
canonical store — while opportunistically populating local caches that
can serve subsequent reads without round-tripping the canonical engine.

This is the slot into which on-disk cache backends — LevelDB
([sideshowdb-frg](https://github.com/sideshowdb/sideshowdb/issues/frg)),
RocksDB ([sideshowdb-kcv](https://github.com/sideshowdb/sideshowdb/issues/kcv)),
Zeno, IndexedDB shims — plug in.

This document covers:

- The architectural role of the write-behind composite layer.
- The MVP operations and their failure semantics.
- The composite (multi-cache) fan-out model.
- The read fall-through and cache-fill model.
- Recovery semantics when a cache is lost or corrupt.

It explicitly does **not** cover:

- A durable on-disk write-ahead queue that survives process death between
  cache-stage and canonical-commit. The MVP is *synchronous-flush*: the
  composite returns only after canonical accepts. Async deferred-flush
  with a persisted queue is future work.
- Optimistic concurrency control on the composite (CAS).
- Cross-cache eventual consistency reconciliation (caches are disposable;
  canonical is truth).
- Per-cache eviction policies (caches manage their own lifecycle).

---

## 2. Architectural Role

Sideshowdb's storage layout has three observable layers:

```
+----------------------------------------------------------+
|  Canonical RefStore                                      |
|  (Git ref via Ziggit / subprocess git)                   |  <- truth
+-------------------------+--------------------------------+
                          ^
                          | flush  (write-through)
                          | refill (read-fall-through)
                          v
+----------------------------------------------------------+
|  WriteBehindRefStore (this spec)                         |
|  Fan-out to N caches + canonical.                        |
+----+------------------+------------------+---------------+
     |                  |                  |
     v                  v                  v
+----------+      +-----------+      +----------+
| Cache 0  |      | Cache 1   |      | Cache N  |   <- disposable
| (e.g.    |      | (e.g.     |      | (e.g.    |      materialisation
|  Memory) |      |  LevelDB) |      |  RocksDB)|
+----------+      +-----------+      +----------+
```

The composite preserves the seven core invariants from
[`docs/development/specs/sideshowdb-spec.md`](./sideshowdb-spec.md):
canonical truth lives in Git, caches never write back to truth, and a
total cache loss must be survivable by replaying canonical history.

---

## 3. Logical Operations

The composite implements the same four-plus-history surface as every
other `RefStore`:

```text
put(key, value)             — write-through to caches and canonical.
get(key, version?)          — try caches, fall through to canonical.
delete(key)                 — write-through delete to caches and canonical.
list()                      — list from canonical (authoritative).
history(key)                — history from canonical (authoritative).
```

### 3.1 Write order

A successful `put`/`delete` performs work in this fixed order:

1. **Validate** the key (same rules as every other `RefStore`).
2. **Stage** the operation in each cache, in declaration order.
3. **Commit** to canonical.
4. On canonical success, return canonical's `VersionId`.

Stages 2 and 3 are sequenced — caches are *staged-first*, but the
operation is not durable from the caller's perspective until canonical
returns success.

### 3.2 Read order

For `get`:

1. **Validate** the key.
2. For each cache in declaration order, attempt
   `cache.get(key, version)`.
3. On the first non-null result, return it.
4. On all caches missing, attempt `canonical.get(key, version)`.
5. If canonical returns a value, **refill** all caches that did not have
   it (best-effort; refill failures are non-fatal, surfaced via metrics
   only — see [sideshowdb-9lp](https://github.com/sideshowdb/sideshowdb/issues/9lp)).
6. Return canonical's value (or null).

`list` and `history` read directly from canonical. Caches do not
participate; they are not authoritative for enumeration or version
chains.

### 3.3 VersionId provenance

The `VersionId` returned by `put` is **always** the canonical store's
version-id. Cache version-ids are observed only when serving cache hits
on a previously refilled value, in which case the cache's version-id is
returned (caches must agree with canonical's version-id at refill time
— see §4.2).

---

## 4. Cache Semantics

### 4.1 Staging vs durability

A cache is permitted to accept a write before canonical does. If
canonical then **fails**, the cache holds a *speculative* entry. The
composite handles this two ways:

- **Default (`.lax`)**: leave the speculative entry in the cache. Caches
  are disposable; a later read will find the same speculative value and
  return it, then attempt to refresh against canonical on the next write.
  Callers can re-issue the failed `put` to converge.
- **Strict (`.strict`)**: when canonical fails after a cache stage,
  attempt a compensating delete on every cache that staged. Best-effort;
  any compensating delete failure is recorded but does not change the
  outcome of `put` (which already failed on canonical).

The choice is a `cache_failure_policy` field on `WriteBehindRefStore.Options`.
Default `.lax` because canonical-truth makes speculative cache entries
self-healing without compensation traffic; strict mode exists for
operators who want strict consistency between cache snapshots and
canonical history at the cost of extra round-trips.

### 4.2 Refill

When a cache misses but canonical has a value, the composite calls
`cache.put(key, value_from_canonical)` for that cache. The cache will
mint its **own** version-id during refill — but the composite returns
**canonical's** version-id to the caller. Subsequent cache hits on the
same `(key, null)` query return the cache's own version-id. This is
permitted by the `RefStore` contract (a `VersionId` is an opaque
identifier for one read operation, not a globally stable identity).

Where cross-backend version stability matters (e.g. a follow-up
optimistic CAS layer), use `history(key)` against canonical to obtain a
canonical version chain.

### 4.3 List authority

`list` reads from canonical only. Listing from a cache risks omitting
keys the cache never refilled (cold reads), or surfacing keys the cache
holds speculatively that canonical never accepted.

### 4.4 History authority

Same reasoning — caches typically retain only latest entries (or a
truncated history); canonical retains the full commit chain.

---

## 5. Composite Fan-Out

The composite holds an ordered list of caches:

```
caches: []const RefStore = &.{ memory_cache, leveldb_cache, ... }
```

### 5.1 Fan-out write

On `put`/`delete`, every cache is contacted in order. A failure in cache
*i* is handled per `cache_failure_policy`:

- `.lax`: log the failure (via metrics hook when available), continue to
  cache *i+1*, then to canonical.
- `.strict`: abort the operation before contacting canonical, run
  compensation against caches `0..i-1`, return an error to the caller.

### 5.2 Fan-out read

Reads short-circuit at the first cache that returns a value. Caches
*after* the hitting cache are not consulted, and are not refilled
(they may already have it; a cold cache later in the list will be
populated on a future cache miss).

### 5.3 Per-cache instrumentation

The composite emits a per-cache event on every operation so a metrics
sink (see [sideshowdb-9lp](https://github.com/sideshowdb/sideshowdb/issues/9lp))
can attribute latency and error rate to each backend. This is what makes
benchmarking ([sideshowdb-jb6](https://github.com/sideshowdb/sideshowdb/issues/jb6))
meaningful.

---

## 6. Recovery Semantics

### 6.1 Cache loss

If any cache is deleted or corrupted between process lifetimes:

1. Construct a fresh, empty cache instance.
2. Pass it back to `WriteBehindRefStore.init` alongside canonical.
3. Reads fall through to canonical on every miss.
4. Refill repopulates the cache lazily as keys are touched.

No state is lost because no canonical record was ever cache-only.

### 6.2 Canonical loss

Catastrophic; canonical is truth. Out of scope for this spec — recovery
is governed by Git's own backup/replication tooling.

### 6.3 Mid-operation crash

Because the MVP is synchronous-flush:

- A crash *between cache stage and canonical commit* leaves caches with
  speculative entries. On restart, the next read hits the cache value
  (correct content); the next write to that key replaces it with a
  canonical-anchored value.
- A crash *during canonical commit* is governed by the canonical
  backend's atomicity (Git ref update is atomic via `update-ref`). The
  caller observes the failure of the previous `put` and may retry.

A persistent write-ahead queue that durably survives the cache-stage →
canonical-commit window is **future work**, tracked separately. Such a
queue is what would let the composite return success before canonical
acknowledges; it is also where the most subtle failure-mode reasoning
lives, which is why it is deferred.

---

## 7. EARS Requirements

### Ubiquitous

- The WriteBehindRefStore shall implement the same `RefStore` vtable
  contract as every other backend.
- The WriteBehindRefStore shall return canonical's `VersionId` from
  every successful `put`.
- The WriteBehindRefStore shall read `list` and `history` from canonical
  only.

### Event-driven

- When `put` is called, the WriteBehindRefStore shall stage the write in
  each cache in declaration order and shall then commit to canonical.
- When `delete` is called, the WriteBehindRefStore shall stage the
  delete in each cache in declaration order and shall then commit to
  canonical.
- When `get` is called and at least one cache returns a non-null result,
  the WriteBehindRefStore shall return the first such result without
  contacting canonical.
- When `get` is called and every cache returns null, the
  WriteBehindRefStore shall delegate to canonical and shall refill
  caches that missed if canonical returns a value.

### State-driven

- While `cache_failure_policy` is `.strict`, the WriteBehindRefStore
  shall, on a cache-stage failure, abort the operation before contacting
  canonical and shall attempt compensating deletes against caches that
  already staged.
- While `cache_failure_policy` is `.lax`, the WriteBehindRefStore shall,
  on a cache-stage failure, continue staging in remaining caches and
  shall proceed to commit canonical.

### Optional feature

- Where caches are configured, the WriteBehindRefStore shall populate
  every cache that missed during a successful canonical read.
- Where zero caches are configured, the WriteBehindRefStore shall behave
  as a thin pass-through over canonical.

### Unwanted behavior

- If canonical fails during `put`, then the WriteBehindRefStore shall
  surface canonical's error to the caller and shall not return a
  `VersionId`.
- If a cache is unreadable during `get` and canonical succeeds, then the
  WriteBehindRefStore shall return canonical's value and shall not fail
  the read.
- If a cache is empty or freshly constructed (e.g. after deletion), then
  the WriteBehindRefStore shall rebuild that cache's working set lazily
  via canonical fall-through, without returning an error to the caller.

---

## 8. Acceptance Tests (informal)

The MVP is "done" when the parity harness from
[`tests/ref_store_parity.zig`](../../../tests/ref_store_parity.zig)
passes against:

1. A `WriteBehindRefStore` with one in-memory cache and an in-memory
   canonical store.
2. A `WriteBehindRefStore` with three in-memory caches and an in-memory
   canonical store.
3. A `WriteBehindRefStore` with **zero** caches (degenerate pass-through).

Plus composite-specific scenarios:

- Cache loss: drop a cache, construct a fresh one, observe that prior
  canonical writes are reachable through the new composite.
- Cache miss → canonical hit → refill: verify the cache now answers the
  same `get` without consulting canonical (instrumented via a counting
  test double).
- Canonical-failure propagation: a failing canonical surfaces the error
  to the caller and does not consume a `VersionId`.
- `cache_failure_policy = .strict`: a failing cache aborts the put
  before canonical is contacted.

---

## 9. Future Work (not in MVP)

- Durable write-ahead queue + deferred-flush mode.
- Optimistic CAS at the composite layer.
- Per-cache eviction policy hooks.
- Cross-cache reconciliation (drift detection between two caches that
  both think they're current).
- Backend-selection CLI exposure
  ([sideshowdb-utu](https://github.com/sideshowdb/sideshowdb/issues/utu)).
- Real cache backends:
  [LevelDB](https://github.com/sideshowdb/sideshowdb/issues/frg),
  [RocksDB](https://github.com/sideshowdb/sideshowdb/issues/kcv),
  Zeno, IndexedDB shim.
- Instrumentation
  ([sideshowdb-9lp](https://github.com/sideshowdb/sideshowdb/issues/9lp))
  and benchmarking
  ([sideshowdb-jb6](https://github.com/sideshowdb/sideshowdb/issues/jb6)).
