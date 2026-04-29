# Write-Through RefStore — Functional Spec (MVP)

## 0. Naming and Scope

This document specifies `WriteThroughRefStore`. The name describes
what the type **actually does**: every successful `put` / `delete`
blocks until the canonical `RefStore` accepts the operation, and only
then returns to the caller. There is no asynchronous queue, no
deferred flush, no caller-visible write-then-flush window.

The type was originally drafted as `WriteBehindRefStore`. That name
was retired during pre-merge review because "write-behind" carries a
specific meaning in cache literature — *ack the caller before the
durable backing store accepts* — that this MVP intentionally does not
deliver. The full deliberation, including the rejected alternatives
(pure write-behind, write-around, WAL-batched), lives in
[`docs/development/decisions/2026-04-29-caching-model.md`](../decisions/2026-04-29-caching-model.md).

Sibling caching variants are filed as separate issues to be designed
and shipped independently:

- WAL-batched write-behind (the "real" write-behind):
  [sideshowdb-0r1](../../../.beads/issues.jsonl).
- Write-around (writes bypass cache; cache populated only on read):
  [sideshowdb-p9h](../../../.beads/issues.jsonl).
- Offline writes (cached writes acked while canonical unreachable,
  flushed when connectivity returns):
  [sideshowdb-nbv](../../../.beads/issues.jsonl).

Callers MUST NOT assume `WriteThroughRefStore` acks writes before
canonical persistence. If they need that property they must wait for
the WAL or offline-writes layer.

## 1. Purpose & Scope

`WriteThroughRefStore` is a composite `RefStore` implementation that
fronts a **canonical** `RefStore` with one or more **cache**
`RefStore`s. The composite preserves the contract laid out in
[`git-ref-storage-spec.md`](./git-ref-storage-spec.md) — every
caller-visible operation behaves as if it ran directly against the
canonical store — while opportunistically populating local caches that
serve subsequent reads without round-tripping the canonical engine.

This is the slot into which on-disk cache backends — LevelDB
([sideshowdb-frg](../../../.beads/issues.jsonl)),
RocksDB ([sideshowdb-kcv](../../../.beads/issues.jsonl)),
Zeno, IndexedDB shims — plug in.

### 1.1 Expected deployment shapes

- **Single cache** (most common): a single in-process or on-disk
  cache fronting canonical. The composite degenerates to a
  traditional read-through / write-through cache. The N-cache
  fan-out is exercised mostly during benchmarking and tiered-cache
  experimentation, not in steady-state production.
- **Zero caches** (degenerate): the composite is a thin pass-through
  over canonical. Useful for tests and for callers that want the
  composite type uniformly without paying for caching today.
- **Multiple caches** (advanced): tiered cache (e.g. memory in front
  of LevelDB) for benchmarking or staged rollout of a new cache
  backend.

This document covers:

- The architectural role of the write-through composite layer.
- The MVP operations and their failure semantics.
- The composite (multi-cache) fan-out model.
- The read fall-through and cache-fill model.
- Recovery semantics when a cache is lost or corrupt.

It explicitly does **not** cover:

- A durable on-disk write-ahead queue that survives process death
  between cache-stage and canonical-commit. See
  [sideshowdb-0r1](../../../.beads/issues.jsonl).
- Writes that succeed while canonical is unreachable. See
  [sideshowdb-nbv](../../../.beads/issues.jsonl).
- Optimistic concurrency control on the composite (CAS).
- Cross-cache eventual consistency reconciliation (caches are
  disposable; canonical is truth).
- Per-cache eviction policies (caches manage their own lifecycle).
- Thread safety. `WriteThroughRefStore` is **not** thread-safe;
  callers needing concurrent access shall serialize externally.
  Same posture as every other `RefStore` implementation in this
  codebase.

## 2. Architectural Role

SideshowDB's storage layout has three observable layers:

```
+----------------------------------------------------------+
|  Canonical RefStore                                      |
|  (Git ref via Ziggit / subprocess git)                   |  <- truth
+-------------------------+--------------------------------+
                          ^
                          | commit (write-through)
                          | refill (read-fall-through)
                          v
+----------------------------------------------------------+
|  WriteThroughRefStore (this spec)                        |
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

`MemoryRefStore` is intended as the in-process default cache and as a
test double for canonical. It is **not** intended as a production
canonical store — production canonical is always Git-backed.

The composite preserves the seven core invariants from
[`docs/development/specs/sideshowdb-spec.md`](./sideshowdb-spec.md):
canonical truth lives in Git, caches never write back to truth, and a
total cache loss must be survivable by replaying canonical history.

## 3. Logical Operations

The composite implements the same five-operation surface as every
other `RefStore`:

```text
put(key, value)             — write-through to caches and canonical.
get(key, version?)          — try caches, fall through to canonical.
delete(key)                 — write-through delete to caches and canonical.
list()                      — list from canonical (authoritative).
history(key)                — history from canonical (authoritative).
```

### 3.1 Write order

A successful `put` / `delete` performs work in this fixed order:

1. **Validate** the key (same rules as every other `RefStore`).
2. **Stage** the operation in each cache, in declaration order.
3. **Commit** to canonical.
4. On canonical success, return canonical's `VersionId`.

Stages 2 and 3 are sequenced — caches are staged-first — but the
operation is not durable from the caller's perspective until canonical
returns success.

### 3.2 Read order

For `get`:

1. **Validate** the key.
2. For each cache in declaration order, attempt
   `cache.get(key, version)`.
3. On the first non-null result, return it. The composite does **not**
   refill earlier caches that returned null on this read; refill
   happens only on canonical fall-through. (See §4.5.)
4. On all caches missing, attempt `canonical.get(key, version)`.
5. If canonical returns a value, **refill** every cache that did not
   have it (best-effort; refill failures are non-fatal — see
   [sideshowdb-9lp](../../../.beads/issues.jsonl) for the metrics
   surface that will make these failures observable).
6. Return canonical's value (or null).

`list` and `history` read directly from canonical. Caches do not
participate; they are not authoritative for enumeration or version
chains.

### 3.3 VersionId provenance

The `VersionId` returned by `put` is **always** the canonical store's
version-id. Cache version-ids are observed only when serving cache
hits on a previously refilled value, in which case the cache's
version-id is returned (caches mint their own ids during refill — see
§4.2).

## 4. Cache Semantics

### 4.1 Staging vs durability

A cache is permitted to accept a write before canonical does. If
canonical then **fails**, the cache holds a *speculative* entry. The
composite handles this two ways:

- **Default (`.lax`)**: leave the speculative entry in the cache.
  Caches are disposable; a later read will find the same speculative
  value and return it, then the next successful `put` to the same
  key will overwrite it with a canonical-anchored value. Callers can
  re-issue the failed `put` to converge.
- **Strict (`.strict`)**: when canonical fails after a cache stage,
  attempt a compensating `delete` against every cache that staged.
  Compensation is best-effort and silently ignored on per-cache
  failure (instrumentation hook deferred to
  [sideshowdb-9lp](../../../.beads/issues.jsonl)). The original
  canonical error is what the caller sees, regardless of compensation
  outcome.

### 4.2 Refill

When a cache misses but canonical has a value, the composite calls
`cache.put(key, value_from_canonical)` for that cache. The cache mints
its **own** version-id during refill — but the composite returns
**canonical's** version-id to the caller. Subsequent cache hits on
the same `(key, null)` query may return the cache's own version-id.

This is permitted by the `RefStore` contract: a `VersionId` is an
opaque identifier for one read operation, not a globally stable
identity. Where cross-backend version stability matters (e.g. a
follow-up optimistic CAS layer), use `history(key)` against canonical
to obtain a canonical version chain.

### 4.3 List authority

`list` reads from canonical only. Listing from a cache risks omitting
keys the cache never refilled (cold reads), or surfacing keys the
cache holds speculatively that canonical never accepted.

**Caveat.** Under `.lax`, after a canonical `put` fails, caches that
already staged hold a key that canonical does not. In that window,
`list()` and `get(key)` disagree on the universe of keys: `list()`
omits the speculative key, `get(key)` returns the speculative value
from cache. Callers requiring transactional consistency between
`list` and `get` shall use `.strict`.

### 4.4 History authority

Same reasoning — caches typically retain only latest entries (or a
truncated history); canonical retains the full commit chain.

### 4.5 Refill is not a repair mechanism

The composite refills caches **only** on canonical fall-through. If
cache 0 errors during a `get` and cache 1 hits, cache 0 remains in
whatever degraded state it was in — the composite does not back-fill
cache 0 from cache 1's value. Repair of a degraded cache is the
operator's responsibility (drop and rebuild). This is intentional:
back-filling between caches couples their version-id namespaces in
ways the composite cannot reason about.

## 5. Composite Fan-Out

The composite holds an ordered list of caches:

```
caches: []const RefStore = &.{ memory_cache, leveldb_cache, ... }
```

### 5.1 Fan-out write

On `put` / `delete`, every cache is contacted in order. A failure in
cache *i* is handled per `cache_failure_policy`:

- `.lax`: continue staging in remaining caches, then commit canonical.
- `.strict`: abort the operation before contacting canonical, run
  compensating `delete` against caches `0..i-1`, return the cache
  error to the caller.

`.strict` mode for `delete` differs from `.strict` mode for `put`
because deletion has no inverse: see §6.

### 5.2 Fan-out read

Reads short-circuit at the first cache that returns a value. Caches
*after* the hitting cache are not consulted (a cold cache later in
the list will be populated on a future cache miss).

A cache that **errors** during `get` is treated according to
`cache_failure_policy`:

- `.lax`: the error is swallowed, treated as a miss, and the next
  cache is consulted. Exception: `error.OutOfMemory` is **always**
  propagated to the caller; allocator failure is never a "cache
  miss".
- `.strict`: the error is propagated to the caller immediately.

### 5.3 Per-cache instrumentation

The composite emits a per-cache event on every operation so a metrics
sink (see [sideshowdb-9lp](../../../.beads/issues.jsonl)) can
attribute latency and error rate to each backend. This is what makes
benchmarking ([sideshowdb-jb6](../../../.beads/issues.jsonl))
meaningful.

## 6. Strict-Mode `delete` Asymmetry

`delete` has no inverse. A `.strict`-mode `put` that fails halfway
can compensate by deleting from caches that already staged —
restoring the pre-put state. A `.strict`-mode `delete` that fails
halfway cannot compensate, because the value(s) needed to resurrect
the deleted entry are no longer available in the failed cache.

The composite therefore handles `.strict` `delete` as follows:

1. Stage delete in cache 0, 1, ..., until cache *i* fails.
2. Surface the cache error to the caller. **Do not contact
   canonical.**
3. Caches `0..i-1` remain in their post-delete state (the key is
   already gone in those caches).
4. The key is still present in canonical and in caches `i..N-1`.

Operators who care about cache/canonical agreement after a
strict-mode delete failure must drop and rebuild the affected caches.
This asymmetry is documented here, codified by EARS in §8, and
locked in by an integration test that drives the exact post-state.

## 7. Recovery Semantics

### 7.1 Cache loss

If any cache is deleted or corrupted between process lifetimes:

1. Construct a fresh, empty cache instance.
2. Pass it back to `WriteThroughRefStore.init` alongside canonical.
3. Reads fall through to canonical on every miss.
4. Refill repopulates the cache lazily as keys are touched.

No state is lost because **no canonical record was ever cache-only**.
Speculative cache entries (created when canonical fails after caches
staged under `.lax`) are explicitly *not* canonical records, and they
disappear when the cache is dropped — which is the correct outcome.

### 7.2 Canonical loss

Catastrophic; canonical is truth. Out of scope for this spec —
recovery is governed by Git's own backup/replication tooling.

### 7.3 Mid-operation crash

Because the MVP is synchronous-flush:

- A crash *between cache stage and canonical commit* leaves caches
  with speculative entries. On restart, the next read hits the cache
  value (correct content); the next write to that key replaces it
  with a canonical-anchored value. If the cache is dropped before
  restart, the speculative entry vanishes — which is correct because
  canonical never accepted the write.
- A crash *during canonical commit* is governed by the canonical
  backend's atomicity (Git ref update is atomic via `update-ref`).
  The caller observes the failure of the previous `put` and may
  retry.

A persistent write-ahead queue that durably survives the cache-stage
→ canonical-commit window is **future work**, tracked under
[sideshowdb-0r1](../../../.beads/issues.jsonl). Cached writes that
ack while canonical is unreachable are tracked under
[sideshowdb-nbv](../../../.beads/issues.jsonl).

## 8. EARS Requirements

### Ubiquitous

- The WriteThroughRefStore shall implement the same `RefStore`
  vtable contract as every other backend.
- The WriteThroughRefStore shall return canonical's `VersionId` from
  every successful `put`.
- The WriteThroughRefStore shall read `list` and `history` from
  canonical only.
- The WriteThroughRefStore shall not refill caches that returned
  null or error during a `get` if a later cache returned a non-null
  result.

### Event-driven

- When `put` is called, the WriteThroughRefStore shall stage the
  write in each cache in declaration order and shall then commit to
  canonical.
- When `delete` is called, the WriteThroughRefStore shall stage the
  delete in each cache in declaration order and shall then commit to
  canonical.
- When `get` is called and at least one cache returns a non-null
  result, the WriteThroughRefStore shall return the first such
  result without contacting canonical.
- When `get` is called and every cache returns null, the
  WriteThroughRefStore shall delegate to canonical and shall refill
  caches that missed if canonical returns a value.

### State-driven

- While `cache_failure_policy` is `.strict`, the
  WriteThroughRefStore shall, on a cache-stage `put` failure, abort
  the operation before contacting canonical and shall attempt a
  compensating `delete` against caches that already staged.
- While `cache_failure_policy` is `.strict`, the
  WriteThroughRefStore shall, on a cache-stage `delete` failure,
  abort the operation before contacting canonical, leave caches
  `0..i-1` in their post-delete state, and surface the cache error
  to the caller.
- While `cache_failure_policy` is `.lax`, the WriteThroughRefStore
  shall, on a cache-stage failure, continue staging in remaining
  caches and shall proceed to commit canonical.
- While `cache_failure_policy` is `.lax`, the WriteThroughRefStore
  shall, on a cache-read error other than `OutOfMemory`, treat the
  error as a miss and continue to the next cache.

### Optional feature

- Where caches are configured, the WriteThroughRefStore shall
  populate every cache that missed during a successful canonical
  read.
- Where zero caches are configured, the WriteThroughRefStore shall
  behave as a thin pass-through over canonical.

### Unwanted behavior

- If canonical fails during `put`, then the WriteThroughRefStore
  shall surface canonical's error to the caller and shall not return
  a `VersionId`.
- If a cache is empty or freshly constructed (e.g. after deletion),
  then the WriteThroughRefStore shall rebuild that cache's working
  set lazily via canonical fall-through, without returning an error
  to the caller.
- If a cache returns `OutOfMemory` during `get`, then the
  WriteThroughRefStore shall propagate the error to the caller
  regardless of `cache_failure_policy`.
- If a strict-mode `put` compensation `delete` itself fails, then
  the WriteThroughRefStore shall ignore the compensation failure
  and shall surface the original canonical error to the caller.

## 9. Integration Test Coverage

The MVP is "done" when the parity harness from
[`tests/ref_store_parity.zig`](../../../tests/ref_store_parity.zig)
passes against:

1. A `WriteThroughRefStore` with one in-memory cache and an
   in-memory canonical store.
2. A `WriteThroughRefStore` with three in-memory caches and an
   in-memory canonical store.
3. A `WriteThroughRefStore` with **zero** caches (degenerate
   pass-through).

Plus composite-specific scenarios, all covered in
[`tests/write_through_ref_store_test.zig`](../../../tests/write_through_ref_store_test.zig):

- Cache hit short-circuits canonical (cache-side and canonical-side
  call counters).
- Cache miss → canonical hit → refill: subsequent reads served by
  cache without consulting canonical.
- Canonical-failure propagation: a failing canonical surfaces the
  error and does not consume a `VersionId`.
- `cache_failure_policy = .strict` for `put`: failing cache aborts
  before canonical, compensation runs.
- `cache_failure_policy = .strict` for `put` with a failing
  compensation `delete`: original canonical error surfaces, put
  result unaffected.
- `cache_failure_policy = .strict` for `delete`: failing cache
  aborts before canonical, earlier caches stay in their post-delete
  state.
- `cache_failure_policy = .lax` for `put`: failing cache ignored,
  remaining caches and canonical accept the write.
- `cache_failure_policy = .lax` for `get`: cache-read error treated
  as miss; `OutOfMemory` always propagates.
- `cache_failure_policy = .lax` `list` / `get` divergence after
  canonical-`put` failure (speculative cache entry visible via `get`
  but not via `list`).
- Cache loss after a successful canonical write: fresh cache reads
  through canonical and refills.
- Cache loss after a `.lax` speculative-only entry: fresh cache
  returns `null` (proves no-canonical-record-was-cache-only).
- Refill is not a repair mechanism: cache-error followed by
  later-cache-hit does not back-fill the erroring cache.

User-facing acceptance scenarios (Cucumber) are not part of this
issue. The composite is library-only today; the user-visible CLI
surface (`--refstore write-through:...`) is tracked under
[sideshowdb-utu](../../../.beads/issues.jsonl), and Gherkin scenarios
land with that issue.

## 10. Future Work (not in MVP)

- Durable WAL + batched canonical flush
  ([sideshowdb-0r1](../../../.beads/issues.jsonl)) — the genuine
  write-behind successor.
- Write-around variant (writes bypass cache; cache populated only on
  read fall-through):
  [sideshowdb-p9h](../../../.beads/issues.jsonl).
- Offline writes — caller-visible success while canonical is
  unreachable: [sideshowdb-nbv](../../../.beads/issues.jsonl).
- Optimistic CAS at the composite layer.
- Per-cache eviction policy hooks.
- Cross-cache reconciliation (drift detection between two caches
  that both think they're current).
- Backend-selection CLI exposure
  ([sideshowdb-utu](../../../.beads/issues.jsonl)).
- Real cache backends:
  [LevelDB](../../../.beads/issues.jsonl) (sideshowdb-frg),
  [RocksDB](../../../.beads/issues.jsonl) (sideshowdb-kcv),
  Zeno, IndexedDB shim.
- Instrumentation
  ([sideshowdb-9lp](../../../.beads/issues.jsonl))
  and benchmarking
  ([sideshowdb-jb6](../../../.beads/issues.jsonl)).
- Thread-safety adapter (likely a `Mutex`-guarded wrapper rather
  than per-call locking).
