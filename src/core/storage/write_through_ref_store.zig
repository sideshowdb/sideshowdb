//! `WriteThroughRefStore` — composite `RefStore` that fronts a
//! canonical store with one or more caches. Every successful `put`
//! / `delete` blocks until canonical accepts.
//!
//! See `docs/development/specs/write-through-store-spec.md` for the
//! conceptual model, the EARS-tagged failure semantics, and the
//! tradeoffs that drive the synchronous-flush design choice. The
//! decision to ship this primitive (instead of a "real" write-behind
//! cache with a durable WAL) is recorded in
//! `docs/development/decisions/2026-04-29-caching-model.md`.
//!
//! Available on every target the standard library supports —
//! including `wasm32-freestanding` — because it composes existing
//! `RefStore` views and depends only on `std.mem.Allocator`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const RefStore = @import("ref_store.zig").RefStore;

/// Composite `RefStore` that fans writes out to N caches and a
/// canonical store, and reads through the cache chain before falling
/// through to canonical. See the module doc-comment and the linked
/// spec for the full contract.
pub const WriteThroughRefStore = struct {
    /// Behavior when staging a write into a cache fails or when a
    /// cache `get` itself errors.
    pub const CacheFailurePolicy = enum {
        /// Continue staging in remaining caches and proceed to commit
        /// canonical. Cache-`get` errors (other than `OutOfMemory`)
        /// are treated as misses. Default. Canonical truth makes
        /// speculative cache state self-healing without compensating
        /// writes.
        lax,

        /// Abort the operation before contacting canonical. For
        /// `put`, run a best-effort compensating delete against
        /// caches that already staged. For `delete`, leave caches
        /// `0..i-1` in their post-delete state (no inverse
        /// available). Cache-`get` errors are propagated to the
        /// caller. Use when operators want strict cache-vs-canonical
        /// agreement at the cost of extra round-trips.
        strict,
    };

    /// Configuration accepted by `WriteThroughRefStore.init`. The
    /// composite borrows every `RefStore` view it receives — the
    /// caller owns the underlying stores and must keep them alive
    /// for the composite's lifetime.
    pub const Options = struct {
        gpa: Allocator,
        canonical: RefStore,
        caches: []const RefStore = &.{},
        cache_failure_policy: CacheFailurePolicy = .lax,
    };

    gpa: Allocator,
    canonical: RefStore,
    caches: []const RefStore,
    cache_failure_policy: CacheFailurePolicy,

    /// Build a composite over `options.canonical` with the given
    /// `caches`. Pure constructor — performs no I/O.
    pub fn init(options: Options) WriteThroughRefStore {
        return .{
            .gpa = options.gpa,
            .canonical = options.canonical,
            .caches = options.caches,
            .cache_failure_policy = options.cache_failure_policy,
        };
    }

    /// Release any composite-owned resources. Currently a no-op —
    /// the composite borrows every backend it touches — but kept for
    /// symmetry with other `RefStore` implementations and to leave
    /// room for future per-composite state (metrics counters, queue
    /// handles, etc.).
    pub fn deinit(_: *WriteThroughRefStore) void {}

    /// Return the type-erased `RefStore` view over `self`. The view
    /// holds a pointer to `self`; the underlying composite must
    /// outlive every returned view.
    pub fn refStore(self: *WriteThroughRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: RefStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .delete = vtableDelete,
        .list = vtableList,
        .history = vtableHistory,
    };

    fn vtablePut(ctx: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.PutResult {
        const self: *WriteThroughRefStore = @ptrCast(@alignCast(ctx));
        return self.put(gpa, key, value);
    }

    fn vtableGet(ctx: *anyopaque, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        const self: *WriteThroughRefStore = @ptrCast(@alignCast(ctx));
        return self.get(gpa, key, version);
    }

    fn vtableDelete(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *WriteThroughRefStore = @ptrCast(@alignCast(ctx));
        return self.delete(key);
    }

    fn vtableList(ctx: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        const self: *WriteThroughRefStore = @ptrCast(@alignCast(ctx));
        return self.list(gpa);
    }

    fn vtableHistory(ctx: *anyopaque, gpa: Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        const self: *WriteThroughRefStore = @ptrCast(@alignCast(ctx));
        return self.history(gpa, key);
    }

    /// See `RefStore.put`. Stages the write in each cache in
    /// declaration order, then commits to canonical. The returned
    /// result is canonical's. On a canonical failure no result is
    /// returned. Cache-stage failures are governed by
    /// `cache_failure_policy`.
    pub fn put(self: *WriteThroughRefStore, gpa: Allocator, key: []const u8, value: []const u8) !RefStore.PutResult {
        try RefStore.validateKey(key);

        var staged: usize = 0;
        while (staged < self.caches.len) : (staged += 1) {
            const stage_result = self.caches[staged].put(self.gpa, key, value) catch |err| {
                switch (self.cache_failure_policy) {
                    .lax => continue,
                    .strict => {
                        compensateCacheStages(self.caches[0..staged], key);
                        return err;
                    },
                }
            };
            // Cache mints its own result for its own bookkeeping.
            // The composite returns canonical's result below — so free
            // the cache's result here. We free with `self.gpa` because
            // the cache `put` was called with `self.gpa`; ownership
            // matches the allocator the cache used to mint the result.
            RefStore.freePutResult(self.gpa, stage_result);
        }

        return try self.canonical.put(gpa, key, value);
    }

    /// See `RefStore.get`. Tries each cache in declaration order,
    /// then falls through to canonical. On a canonical hit, refills
    /// the caches that missed (best-effort; refill failures are
    /// swallowed because canonical already supplied the answer).
    ///
    /// Cache `get` errors are handled per `cache_failure_policy`.
    /// `error.OutOfMemory` from any cache is propagated regardless
    /// of policy — allocator failure is never a "cache miss".
    pub fn get(self: *WriteThroughRefStore, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) !?RefStore.ReadResult {
        try RefStore.validateKey(key);

        // Track which caches missed (or errored under .lax) so we
        // can refill them on a canonical hit. We only refill caches
        // we actually visited.
        var miss_count: usize = 0;
        for (self.caches) |cache| {
            if (cache.get(gpa, key, version)) |maybe_hit| {
                if (maybe_hit) |hit| return hit;
                miss_count += 1;
            } else |err| switch (err) {
                error.OutOfMemory => return err,
                else => switch (self.cache_failure_policy) {
                    .strict => return err,
                    .lax => miss_count += 1,
                },
            }
        }

        const canonical_hit = try self.canonical.get(gpa, key, version) orelse return null;

        // Refill every cache that missed (i.e. caches up to
        // `miss_count` — these are the ones we visited and that did
        // not return a hit).
        var i: usize = 0;
        while (i < miss_count and i < self.caches.len) : (i += 1) {
            const refill_result = self.caches[i].put(self.gpa, key, canonical_hit.value) catch continue;
            RefStore.freePutResult(self.gpa, refill_result);
        }

        return canonical_hit;
    }

    /// See `RefStore.delete`. Stages the delete in each cache in
    /// declaration order, then commits to canonical. Cache-stage
    /// failures follow `cache_failure_policy`.
    ///
    /// Note: strict-mode `delete` does NOT compensate previously-
    /// staged caches because deletion has no inverse. The caches
    /// `0..i-1` remain in their post-delete state and the caller
    /// receives the cache error. See spec §6 for the rationale and
    /// the post-state contract.
    pub fn delete(self: *WriteThroughRefStore, key: []const u8) !void {
        try RefStore.validateKey(key);

        var staged: usize = 0;
        while (staged < self.caches.len) : (staged += 1) {
            self.caches[staged].delete(key) catch |err| {
                switch (self.cache_failure_policy) {
                    .lax => continue,
                    .strict => return err,
                }
            };
        }

        return self.canonical.delete(key);
    }

    /// See `RefStore.list`. Reads from canonical only — caches are
    /// not authoritative for enumeration. Under `.lax`, this means
    /// `list()` and `get(key)` may disagree on the universe of keys
    /// when a canonical `put` failed after caches staged; see spec
    /// §4.3.
    pub fn list(self: *WriteThroughRefStore, gpa: Allocator) ![][]u8 {
        return self.canonical.list(gpa);
    }

    /// See `RefStore.history`. Reads from canonical only — caches
    /// typically retain only latest entries, so they are not
    /// authoritative for version chains.
    pub fn history(self: *WriteThroughRefStore, gpa: Allocator, key: []const u8) ![]RefStore.VersionId {
        try RefStore.validateKey(key);
        return self.canonical.history(gpa, key);
    }

    fn compensateCacheStages(caches: []const RefStore, key: []const u8) void {
        // Best-effort compensating delete on caches that already
        // staged. Errors are swallowed because the operation is
        // already failed; surfacing a compensation error would
        // confuse the original cause. Per-cache compensation
        // outcomes will become observable when sideshowdb-9lp
        // (metrics hooks) lands.
        for (caches) |cache| cache.delete(key) catch {};
    }
};
