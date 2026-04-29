# Critic Review — `feature/leveldb-write-behind`

- **Date:** 2026-04-29
- **Branch:** `feature/leveldb-write-behind`
- **Commit at review time:** 3bc90f8 (Add WriteBehindRefStore composite + write-behind storage spec)
- **Reviewer posture:** NASA-grade quality control — skeptical, evidence-driven.
- **Verdict:** **REVISE** (block merge until P0 addressed; P1 should land in same PR).
- **Test state at review:** 76/76 zig tests pass across 10 binaries; site build clean; JS check clean.

## Resolution Status (post-review)

A second commit on this branch addresses the findings below. Summary:

- **P0-1** — Resolved by rename: `WriteBehindRefStore` → `WriteThroughRefStore`. ADR `docs/development/decisions/2026-04-29-caching-model.md` records the deliberation. The two original write-behind EARS migrated verbatim to a new issue (`sideshowdb-0r1`, WAL-batched flush). Sibling primitives (write-around `sideshowdb-p9h`, offline writes `sideshowdb-nbv`) filed for future work. Updated `sideshowdb-7pp` notes document the scope split.
- **P1-1** — Resolved: spec now contains an EARS statement pinning "no refill on a later-cache hit if an earlier cache returned null/error" and a test `refill is not a repair mechanism (later-cache hit, earlier cache stays degraded)` locks the behavior in.
- **P1-2** — Resolved: new test `speculative-only entry vanishes after cache loss` exercises the `.lax` canonical-fail → cache-loss → fresh-cache trajectory and asserts the speculative value is *gone* (not refilled), proving the spec's no-canonical-record-was-cache-only claim by observation.
- **P1-3** — Resolved: spec rewritten to drop the misleading "recorded" wording (instrumentation explicitly deferred to `sideshowdb-9lp`); new test `strict put surfaces original cache error even when compensation delete fails` asserts compensation-delete-failure does not change the put outcome.
- **P1-4** — Resolved: spec §6 documents the strict-mode delete asymmetry; EARS in §8 codifies it; new test `strict-mode delete aborts before canonical and leaves earlier caches deleted` locks the post-state.
- **P1-5** — Resolved: spec §4.3 documents `list`/`get` divergence under `.lax`; new test `lax list/get diverge after canonical put failure` exercises the divergence.
- **P2-1** — Resolved: `validateKey` consolidated to a single `RefStore.validateKey` static method in `ref_store.zig`. Both `MemoryRefStore` and `WriteThroughRefStore` call the shared function; drift impossible by construction.
- **P2-2** — Resolved: `WriteThroughRefStore.get` now propagates `error.OutOfMemory` from any cache regardless of policy. New tests cover OOM propagation under both `.lax` and `.strict`. EARS in §8 codifies the rule.
- **P2-3** — Resolved: spec §1 and architecture page state the not-thread-safe posture explicitly.
- **P2-4** — Resolved: spec §9 renamed from "Acceptance Tests (informal)" to "Integration Test Coverage"; defers Cucumber acceptance to `sideshowdb-utu`.
- **P3-1** — Resolved: architecture page hedges the "tiered-cache / benchmarking" sentence and pins it to the on-disk-backend and benchmarking follow-up issues.
- **P3-2** — Resolved: architecture page now lists `history(gpa, key)` as the fifth `RefStore` operation.

The remaining open question — *"Is `MemoryRefStore` ever expected to be used as a canonical in production"* — is now answered in spec §2: production canonical is always Git-backed; `MemoryRefStore` canonical is for tests only.

Verdict expected to upgrade to **ACCEPT** once the resolution commit lands and the test suite re-runs green.

---

This document captures the review verbatim so the findings have a durable home alongside the spec they critique. The PR author will respond to each item below in commit messages or PR comments. Items resolved before merge will be checked off; items deferred will be filed as `bd` follow-up issues with explicit pointers back here.

---

## Overall assessment

The composite is small, clean, builds and passes all 76 tests, and the parity-harness coverage across 0/1/3 cache topologies is genuinely good. But the work has one P0 problem of *naming honesty*: this is not "write-behind." The original sideshowdb-7pp issue describes a queued, deferred-flush, recoverable write-behind backend, and the spec quietly redefines the term to mean "synchronous write-through with multiple cache slots." That redefinition needs to be either (a) reverted (rename the type) or (b) called out at the very top of the spec and the architecture page in plain language so readers and future maintainers don't merge two different ideas in their heads. Lower-severity correctness and coverage gaps are listed as P1/P2.

---

## P0 — Must fix before merge

### P0-1 — "Write-behind" is a misnomer; the original issue's central EARS is not satisfied

**Evidence.**

- Original sideshowdb-7pp EARS (verified via `bd show sideshowdb-7pp`):
  - *"When a write is accepted into the LevelDB write-behind queue, the system shall flush the write to canonical Git/ref storage in deterministic order."*
  - *"If a write-behind flush fails, then the system shall surface a recoverable error state and shall not claim canonical commit success until Git/ref persistence succeeds."*
- Spec (`docs/development/specs/write-behind-store-spec.md:30-33`) declares: *"It explicitly does not cover: A durable on-disk write-ahead queue that survives process death between cache-stage and canonical-commit. The MVP is synchronous-flush: the composite returns only after canonical accepts."*
- Implementation (`src/core/storage/write_behind_ref_store.zig:114-135`): `put` blocks on `self.canonical.put(...)` before returning. There is no queue, no deferral, no retry, no flush ordering — caches are written first as a *speculative cache prime*, then canonical is written synchronously.

What the code actually implements is **a fan-out write-through cache with optional speculative cache prime**. That is a useful primitive. It is not write-behind. "Write-behind" is industry-standard terminology for "ack the caller before the durable backing store is written, then flush asynchronously" — which is precisely the property this MVP punts to future work (§9, line 333).

This matters for three reasons:

1. The original-issue EARS *"flush the write to canonical Git/ref storage in deterministic order"* implies an ordered queue; the spec quietly retires that requirement (§6.3 line 241-245 redirects it to "future work") without acknowledging it was originally part of the issue's contract.
2. The original-issue EARS *"shall not claim canonical commit success until Git/ref persistence succeeds"* is *trivially* satisfied by the synchronous design — but only because the design also drops the asynchronous part that gave the property its meaning. The spec frames this as a feature ("synchronous-flush makes the semantics simple") rather than as scope reduction.
3. Future readers will look at `WriteBehindRefStore` and reason about it as if it had write-behind semantics. The architecture page at `site/src/routes/docs/architecture/+page.md:98` calls the layer "Write-Behind Composite" and never tells the reader that no write is actually behind anything.

**Why this matters.** This is the kind of name-vs-behavior drift that survives review and then bites someone six months later when they file a P0 bug because two writes interleaved on a crash and they expected queue replay to recover them. The README/architecture/spec all need to be honest about what was built.

**Fix (pick one, not both):**

- **Preferred:** Rename the type to `CompositeRefStore` or `WriteThroughRefStore` (or `LayeredRefStore`). Reframe the spec as "fan-out write-through with optional cache prime"; deferred-flush write-behind becomes a separately-named follow-up that can compose *over* this primitive. Update sideshowdb-7pp to record that the LevelDB write-behind work was split into composite-now / queue-later, and explicitly carry the two redefined EARS into the deferred follow-up issue.
- **Acceptable:** Keep the name, but add a "Naming and scope" section as the *first* substantive section of `write-behind-store-spec.md` that says, in plain language: "This MVP is synchronous write-through under the write-behind name. Asynchronous deferred-flush is future work tracked under `<issue>`. Callers MUST NOT rely on this composite to ack writes before canonical persistence." Mirror that disclaimer at the top of the architecture page's "Write-Behind Composite" section.

Either way, do not let the redefinition stand silently.

---

## P1 — Should fix before merge

### P1-1 — Refill skips a cache that errored when a later cache hit

**Evidence.** `src/core/storage/write_behind_ref_store.zig:148-160`. If cache 0 errors (treated as a miss, `miss_count++`) and cache 1 hits, the composite returns cache 1's value and never repairs cache 0. The EARS *"Where caches are configured, the WriteBehindRefStore shall populate every cache that missed during a successful canonical read"* does not fire because canonical was never read. Cache 0 stays silently degraded; subsequent reads keep falling through to cache 1.

**Fix.** Either (a) add an EARS statement that pins this behavior and a test that asserts it, or (b) repair cache 0 from the value cache 1 returned. Don't leave it implicit.

### P1-2 — Cache-loss recovery test does not exercise recovery

**Evidence.** `tests/write_behind_ref_store_test.zig:264-310`. Lifetime 1: writes through composite_v1, cache dies. Lifetime 2: fresh cache, reads through composite_v2. The test would pass identically if "cache loss recovery" merely meant "make a new empty cache." It does not exercise the load-bearing claim from spec §6.1: *"No state is lost because no canonical record was ever cache-only."*

**Fix.** Add a test that:

1. Stages a `.lax` write where canonical is configured to fail. Cache 1 holds a speculative entry; canonical does not.
2. Drops cache 1.
3. Brings up a fresh cache 1, reads the key, asserts `null` (because canonical truth says the key never existed) — *not* the cached speculative value.

Without this, the recovery story is asserted by analogy, not observation.

### P1-3 — Compensating-delete-failure semantics asserted in spec but never tested; the spec promises "recorded" but the code silently swallows

**Evidence.**

- Spec §4.1: *"any compensating delete failure is recorded but does not change the outcome of `put`..."*
- Code (`write_behind_ref_store.zig:215-221`): `cache.delete(key) catch {}` — discards the error silently. There is no metrics hook, no log line, no aggregated outcome.
- Tests: no test drives compensation against a cache whose `delete` itself fails. The strict-mode test (line 238-262) only exercises the *first* cache failing; compensation has zero caches to compensate against.

**Fix.**

- Either change the spec to say *"silently ignored (instrumentation hook deferred to sideshowdb-9lp)"*, or add the recording. Pick one and remove the drift.
- Add a test using `FailingRefStore` configured to fail on `delete` to assert: (a) strict-mode `put` still surfaces the *original* canonical error, not the compensation error; (b) the put result is unaffected by compensation failure.

### P1-4 — Strict-mode delete semantics are inconsistent with strict-mode put and undocumented

**Evidence.** `write_behind_ref_store.zig:179-199`. Strict-mode delete returns `err` immediately on cache failure, leaving caches `0..i-1` in a **deleted-but-canonical-still-has-it** state. That is exactly the kind of cache/canonical drift `.strict` mode was sold to avoid. The state-driven EARS (lines 276-279 in the spec) only covers `put`. The implementation silently chooses a different (and arguably worse-than-`.lax`) outcome for `delete`. There is no test for `delete` under strict mode at all.

**Fix.**

- Add an EARS statement that makes the `delete` strict-mode behavior explicit and observable.
- Add a test that drives strict-mode delete against `[ok_cache_0, failing_cache_1, ok_cache_2]` and asserts: cache_0 is now missing the key (already deleted), cache_2 still has it, canonical was never contacted, error surfaces. Whatever the chosen behavior is, lock it in.
- Document the asymmetry in the spec, or change the implementation to either (a) revert cache_0 by re-putting the canonical value (requires a pre-read; expensive), or (b) downgrade strict-mode delete to lax-mode delete (simpler, but should be explicit in the API).

### P1-5 — `list` and `get` disagree under `.lax` after canonical failure (silent inconsistency)

**Evidence.** Spec §4.3: *"`list` reads from canonical only."* Under `.lax`, after a canonical `put` fails:

- Caches that already staged hold the key.
- Canonical does not.
- `list()` does not include the key, but `get(key)` *does* return it (cache hit).

Two callers — one paginating via `list()`, one doing point-lookups via `get()` — see different worlds. Not in §4 or §6 of the spec. No test for it.

**Fix.** Add an EARS statement and a test that pin this behavior. e.g. *"Under `.lax`, `list()` may omit keys held only speculatively in caches; callers requiring transactional consistency between `list` and `get` shall not use `.lax`."* Add a test that demonstrates the divergence so callers cannot file it as a bug later.

---

## P2 — Nice-to-fix

### P2-1 — `validateKey` is duplicated verbatim between `MemoryRefStore` and `WriteBehindRefStore`

**Evidence.** `memory_ref_store.zig:232-238` and `write_behind_ref_store.zig:224-230` are byte-identical. If a future `RefStore` tightens its key rules, the composite will pass keys the underlying store rejects, surfacing a second validation downstream.

**Fix.** Promote `validateKey` to a `RefStore.validateKey` static helper in `ref_store.zig`. All implementations call the same function. Drift impossible by construction.

### P2-2 — `get` swallows *all* cache errors, including `error.OutOfMemory`

**Evidence.** `write_behind_ref_store.zig:152-159`. The catch-all switch swallows `OutOfMemory`, `Unexpected`, etc. and treats them as misses. There is no metrics callback (sideshowdb-9lp not yet wired). A cache that has been silently failing every read for hours is invisible.

**Fix.** Re-raise allocator/host errors and only swallow domain-level "cache is sick" errors. At minimum, propagate `OutOfMemory`. Even better, make the swallow set explicit and small.

### P2-3 — Concurrency posture is silent

**Evidence.** Spec, code, and architecture page never mention thread safety. Memory caches are not thread-safe; the composite's vtable forwarding is not thread-safe; the spec does not say so.

**Fix.** Add a one-line statement to the spec: *"WriteBehindRefStore is not thread-safe. Callers needing concurrent access shall serialize externally."* Mirror in the architecture page.

### P2-4 — No Cucumber acceptance test, but spec calls its unit tests "Acceptance Tests"

**Evidence.** `acceptance/typescript/features/` contains only `cli-document-lifecycle.feature` and `wasm-document-lifecycle.feature`. The spec's §8 "Acceptance Tests (informal)" lists scenarios that are unit tests in `tests/`, not Cucumber acceptance scenarios. The composite is library-only today (CLI exposure deferred to sideshowdb-utu), so this is technically not yet user-facing — but the vocabulary drift contradicts the project's own CLAUDE.md rules.

**Fix.** Either (a) clarify in the spec that the composite has no user-facing surface yet and Cucumber scenarios will land with sideshowdb-utu, or (b) rename §8 from "Acceptance Tests" to "Integration Test Coverage" so the term is reserved for the Gherkin layer.

---

## P3 — Informational

### P3-1 — Architecture page oversells the MVP

**Evidence.** `site/src/routes/docs/architecture/+page.md:184-185`: *"N caches → fan-out useful for benchmarking and tiered-cache deployments."* Today there is exactly one concrete cache (`MemoryRefStore`); LevelDB and RocksDB are still issues. There is no benchmarking harness (sideshowdb-jb6 is open).

**Fix.** Hedge: *"N caches → fan-out structure that will become useful for benchmarking and tiered-cache deployments once sideshowdb-frg (LevelDB) and sideshowdb-jb6 (benchmarks) land."*

### P3-2 — `RefStore` interface in architecture page omits `history`

**Evidence.** `+page.md:81-84` lists four operations on the RefStore interface; the actual interface has five (`history` is missing). Pre-existing, not introduced by this PR, but the PR touched this file and should clean it up.

---

## What's missing (additions beyond the severity-rated list)

- No EARS statement governing speculative-cache visibility under `.lax` after canonical failure.
- No EARS statement or test for "cache returns inconsistent value vs canonical" (bit-rot / drift).
- No test for `version != null` (version-pinned) reads through the composite. The parity harness covers one version-pinned read after delete; composite-specific coverage is absent.
- No test for "all caches succeed; canonical fails" — the headline `.lax` speculative-entry trajectory.
- No statement of API stability for `WriteBehindRefStore.Options`.

---

## Multi-perspective notes

- **Executor (the human filing sideshowdb-frg next):** From this spec alone, it is unclear whether `LevelDbRefStore` must satisfy any flushing/queueing semantics, or just the `RefStore` contract. The original 7pp issue's "deterministic flush order" requirement is now homeless — neither in the WriteBehind spec nor in the LevelDB issue. The next executor will guess.
- **Stakeholder (sideshowdb maintainer):** Original-issue acceptance criterion *"Integration test: ordered writes flushed from LevelDB queue are reflected in canonical Git/ref history in the same order"* cannot be satisfied by this MVP because there is no queue. The MVP closes 7pp on a shifted scope without a paper trail of what was deferred.
- **Skeptic:** Strongest argument against: this is not write-behind, and hiding that under the original name creates a maintenance trap. Strongest argument for: an architecture-first composite that any future cache can plug into is genuinely a useful primitive — but that argument lives or dies on calling it what it is.

---

## Realist-check

- **P0-1.** Severity stays. Pre-merge naming/scope dishonesty in the contract document. Fix is cheap; worst case downstream is months-deep.
- **P1-1.** Severity stays. Issue under transient cache errors only; observable as latency increase under metrics, invisible without.
- **P1-2.** Severity stays. The recovery test is the load-bearing test for the spec's central claim.
- **P1-3.** Severity stays. Code/spec contradiction.
- **P1-4.** Severity stays. Strict-mode delete inverting strict-mode put is exactly the asymmetry that earns its severity.
- **P1-5.** Severity stays. `list`/`get` divergence under `.lax` will cause user bugs eventually.

No downgrades. No upgrades.

---

## What would change the verdict

Upgrade to **ACCEPT-WITH-RESERVATIONS** if all of the following land:

1. Naming/scope-redefinition (P0-1) addressed via rename **or** prominent disclaimer in spec + architecture page, **and** the original two write-behind EARS either carried into a follow-up issue or explicitly retired in sideshowdb-7pp's notes with rationale.
2. New test: speculative cache entry under `.lax` after canonical failure, then cache loss + fresh cache, asserting *the absence of the speculative value* on rehydration. (P1-2.)
3. New test: strict-mode `put` against `[ok, failing]` driving compensation, where the compensating `delete` itself fails. (P1-3.)
4. New test: strict-mode `delete` semantics under cache failure, plus a corresponding EARS statement. (P1-4.)
5. `validateKey` consolidated to a single canonical implementation. (P2-1.)
6. `error.OutOfMemory` from cache `get` propagates instead of being swallowed. (P2-2.)
7. Concurrency posture stated in one line in the spec and architecture page. (P2-3.)

Upgrade to **ACCEPT** if all of the above land **and** the architecture page hedges the "tiered-cache / benchmarking" sentence.

---

## Open questions for the author

- Was the scope shift from "real write-behind queue" to "synchronous composite" agreed in writing somewhere? If so, link it from the spec; that single citation converts P0-1 from drift to a documented decision.
- Is `MemoryRefStore` ever expected to be used as canonical in production, or only in tests? The composite's design assumes canonical is always Git-backed; if "tests only," say so in §2.
- Why is the cache's version-id freed using `self.gpa` rather than the caller's `gpa`? Technically correct (the cache allocated with `self.gpa` because `put` passes `self.gpa`), but cross-cuts ownership in a non-obvious way. A comment would help future readers.

---

## Files cited

- `docs/development/specs/write-behind-store-spec.md`
- `src/core/storage/write_behind_ref_store.zig`
- `src/core/storage/memory_ref_store.zig`
- `src/core/storage/ref_store.zig`
- `tests/write_behind_ref_store_test.zig`
- `tests/ref_store_parity.zig`
- `site/src/routes/docs/architecture/+page.md`
- `docs/development/specs/git-ref-storage-spec.md`

Test run at review time: `zig build test --summary all` → 76/76 tests pass across 10 test binaries.
