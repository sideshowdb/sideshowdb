//! `WriteBehindRefStore` — composite `RefStore` that fronts a canonical
//! store with one or more caches.
//!
//! See `docs/development/specs/write-behind-store-spec.md` for the
//! conceptual model, the EARS-tagged failure semantics, and the
//! tradeoffs that drive the synchronous-flush design choice.
//!
//! Available on every target the standard library supports — including
//! `wasm32-freestanding` — because it composes existing `RefStore`
//! views and depends only on `std.mem.Allocator`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const RefStore = @import("ref_store.zig").RefStore;

/// Composite `RefStore` that fans writes out to N caches and a
/// canonical store, and reads through the cache chain before falling
/// through to canonical. See the module doc-comment and the linked
/// spec for the full contract.
pub const WriteBehindRefStore = struct {
    /// Behavior when staging a write into a cache fails.
    pub const CacheFailurePolicy = enum {
        /// Continue staging in remaining caches and proceed to commit
        /// canonical. Default. Canonical truth makes speculative cache
        /// state self-healing without compensating writes.
        lax,

        /// Abort the operation before contacting canonical. Run a
        /// best-effort compensating delete against caches that already
        /// staged. Use when operators want strict cache-vs-canonical
        /// agreement at the cost of extra round-trips.
        strict,
    };

    /// Configuration accepted by `WriteBehindRefStore.init`. The
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
    pub fn init(options: Options) WriteBehindRefStore {
        return .{
            .gpa = options.gpa,
            .canonical = options.canonical,
            .caches = options.caches,
            .cache_failure_policy = options.cache_failure_policy,
        };
    }

    /// Release any composite-owned resources. Currently a no-op — the
    /// composite borrows every backend it touches — but kept for
    /// symmetry with other `RefStore` implementations and to leave
    /// room for future per-composite state (metrics counters, queue
    /// handles, etc.).
    pub fn deinit(_: *WriteBehindRefStore) void {}

    /// Return the type-erased `RefStore` view over `self`. The view
    /// holds a pointer to `self`; the underlying composite must
    /// outlive every returned view.
    pub fn refStore(self: *WriteBehindRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: RefStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .delete = vtableDelete,
        .list = vtableList,
        .history = vtableHistory,
    };

    fn vtablePut(ctx: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.VersionId {
        const self: *WriteBehindRefStore = @ptrCast(@alignCast(ctx));
        return self.put(gpa, key, value);
    }

    fn vtableGet(ctx: *anyopaque, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        const self: *WriteBehindRefStore = @ptrCast(@alignCast(ctx));
        return self.get(gpa, key, version);
    }

    fn vtableDelete(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *WriteBehindRefStore = @ptrCast(@alignCast(ctx));
        return self.delete(key);
    }

    fn vtableList(ctx: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        const self: *WriteBehindRefStore = @ptrCast(@alignCast(ctx));
        return self.list(gpa);
    }

    fn vtableHistory(ctx: *anyopaque, gpa: Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        const self: *WriteBehindRefStore = @ptrCast(@alignCast(ctx));
        return self.history(gpa, key);
    }

    /// See `RefStore.put`. Stages the write in each cache in
    /// declaration order, then commits to canonical. The returned
    /// `VersionId` is canonical's. On a canonical failure no version
    /// is returned. Cache-stage failures are governed by
    /// `cache_failure_policy`; see the type doc-comment.
    pub fn put(self: *WriteBehindRefStore, gpa: Allocator, key: []const u8, value: []const u8) !RefStore.VersionId {
        try validateKey(key);

        var staged: usize = 0;
        while (staged < self.caches.len) : (staged += 1) {
            const stage_v = self.caches[staged].put(self.gpa, key, value) catch |err| {
                switch (self.cache_failure_policy) {
                    .lax => continue,
                    .strict => {
                        compensateCacheStages(self.caches[0..staged], key);
                        return err;
                    },
                }
            };
            // Cache mints its own version-id for its own bookkeeping.
            // The composite returns canonical's id below — so free the
            // cache's id here.
            self.gpa.free(stage_v);
        }

        return try self.canonical.put(gpa, key, value);
    }

    /// See `RefStore.get`. Tries each cache in declaration order, then
    /// falls through to canonical. On a canonical hit, refills the
    /// caches that missed (best-effort; refill failures are swallowed
    /// because canonical already supplied the answer).
    pub fn get(self: *WriteBehindRefStore, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) !?RefStore.ReadResult {
        try validateKey(key);

        // Track which caches missed so we can refill them on a
        // canonical hit. We only refill caches before the first hit;
        // caches after a hit are not consulted in the first place.
        var miss_count: usize = 0;
        for (self.caches) |cache| {
            if (cache.get(gpa, key, version)) |maybe_hit| {
                if (maybe_hit) |hit| return hit;
                miss_count += 1;
            } else |err| switch (err) {
                else => {
                    // Cache failed to read. Treat as a miss and keep
                    // looking. Canonical truth means we cannot let a
                    // sick cache poison reads.
                    miss_count += 1;
                },
            }
        }

        const canonical_hit = try self.canonical.get(gpa, key, version) orelse return null;

        // Refill every cache that missed (we know miss_count >= 0; we
        // refill all caches up to miss_count because they are the ones
        // we visited and missed).
        var i: usize = 0;
        while (i < miss_count and i < self.caches.len) : (i += 1) {
            const refill_v = self.caches[i].put(self.gpa, key, canonical_hit.value) catch continue;
            self.gpa.free(refill_v);
        }

        return canonical_hit;
    }

    /// See `RefStore.delete`. Stages the delete in each cache in
    /// declaration order, then commits to canonical. Cache-stage
    /// failures follow `cache_failure_policy`.
    pub fn delete(self: *WriteBehindRefStore, key: []const u8) !void {
        try validateKey(key);

        var staged: usize = 0;
        while (staged < self.caches.len) : (staged += 1) {
            self.caches[staged].delete(key) catch |err| {
                switch (self.cache_failure_policy) {
                    .lax => continue,
                    .strict => {
                        // Compensation for delete is awkward (we cannot
                        // resurrect what a previous cache successfully
                        // deleted), so strict-mode delete merely aborts
                        // before canonical and surfaces the cache error.
                        return err;
                    },
                }
            };
        }

        return self.canonical.delete(key);
    }

    /// See `RefStore.list`. Reads from canonical only — caches are not
    /// authoritative for enumeration.
    pub fn list(self: *WriteBehindRefStore, gpa: Allocator) ![][]u8 {
        return self.canonical.list(gpa);
    }

    /// See `RefStore.history`. Reads from canonical only — caches
    /// typically retain only latest entries, so they are not
    /// authoritative for version chains.
    pub fn history(self: *WriteBehindRefStore, gpa: Allocator, key: []const u8) ![]RefStore.VersionId {
        try validateKey(key);
        return self.canonical.history(gpa, key);
    }

    fn compensateCacheStages(caches: []const RefStore, key: []const u8) void {
        // Best-effort compensating delete on caches that already
        // staged. Errors are swallowed because the operation is
        // already failed; surfacing a compensation error would
        // confuse the original cause.
        for (caches) |cache| cache.delete(key) catch {};
    }
};

fn validateKey(key: []const u8) !void {
    if (key.len == 0) return error.InvalidKey;
    if (key[0] == '/') return error.InvalidKey;
    if (key[key.len - 1] == '/') return error.InvalidKey;
    if (std.mem.indexOf(u8, key, "//") != null) return error.InvalidKey;
    if (std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidKey;
}
