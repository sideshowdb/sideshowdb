//! Integration tests for `WriteBehindRefStore`. Drives the composite
//! through the shared parity harness across several cache topologies,
//! plus composite-specific checks (cache short-circuit reads, canonical
//! refill, failure-policy semantics, cache recovery from total loss).

const std = @import("std");
const sideshowdb = @import("sideshowdb");
const parity = @import("ref_store_parity.zig");

const Allocator = std.mem.Allocator;
const RefStore = sideshowdb.RefStore;

test "WriteBehindRefStore: parity harness with zero caches" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &.{},
    });
    defer composite.deinit();

    try parity.exerciseRefStore(.{
        .gpa = std.testing.allocator,
        .ref_store = composite.refStore(),
    });
}

test "WriteBehindRefStore: parity harness with one cache" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer cache.deinit();

    const caches = [_]RefStore{cache.refStore()};
    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
    });
    defer composite.deinit();

    try parity.exerciseRefStore(.{
        .gpa = std.testing.allocator,
        .ref_store = composite.refStore(),
    });
}

test "WriteBehindRefStore: parity harness with three caches" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var c0 = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer c0.deinit();
    var c1 = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer c1.deinit();
    var c2 = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer c2.deinit();

    const caches = [_]RefStore{ c0.refStore(), c1.refStore(), c2.refStore() };
    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
    });
    defer composite.deinit();

    try parity.exerciseRefStore(.{
        .gpa = std.testing.allocator,
        .ref_store = composite.refStore(),
    });
}

test "WriteBehindRefStore: cache hit short-circuits canonical on get" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var counting = CountingRefStore.init(.{ .gpa = std.testing.allocator });
    defer counting.deinit();
    var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer cache.deinit();

    // Composite: cache → counting-canonical wrapper.
    counting.inner = canonical.refStore();
    const caches = [_]RefStore{cache.refStore()};
    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = counting.refStore(),
        .caches = &caches,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    const v = try rs.put(std.testing.allocator, "k", "v");
    defer std.testing.allocator.free(v);

    // After a successful put we expect canonical.put to have been called once,
    // and canonical.get to have NOT been called yet.
    try std.testing.expectEqual(@as(usize, 1), counting.calls.put);
    try std.testing.expectEqual(@as(usize, 0), counting.calls.get);

    // The next get should be served by the cache without touching canonical.
    const got = try rs.get(std.testing.allocator, "k", null);
    defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?.value);
    try std.testing.expectEqual(@as(usize, 0), counting.calls.get);
}

test "WriteBehindRefStore: cache miss falls through to canonical and refills" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    // Pre-seed canonical with a value the cache doesn't know about.
    {
        const seed_v = try canonical.refStore().put(std.testing.allocator, "k", "from-canonical");
        std.testing.allocator.free(seed_v);
    }

    var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer cache.deinit();

    var counting = CountingRefStore.init(.{ .gpa = std.testing.allocator });
    defer counting.deinit();
    counting.inner = canonical.refStore();

    const caches = [_]RefStore{cache.refStore()};
    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = counting.refStore(),
        .caches = &caches,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    // Cold read: cache misses, canonical hit, cache should be refilled.
    {
        const got = try rs.get(std.testing.allocator, "k", null);
        defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("from-canonical", got.?.value);
    }
    try std.testing.expectEqual(@as(usize, 1), counting.calls.get);

    // Warm read: cache should now serve without consulting canonical.
    {
        const got = try rs.get(std.testing.allocator, "k", null);
        defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("from-canonical", got.?.value);
    }
    try std.testing.expectEqual(@as(usize, 1), counting.calls.get);
}

test "WriteBehindRefStore: list reads from canonical only" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer cache.deinit();

    const caches = [_]RefStore{cache.refStore()};
    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    const v1 = try rs.put(std.testing.allocator, "a", "1");
    defer std.testing.allocator.free(v1);
    const v2 = try rs.put(std.testing.allocator, "b", "2");
    defer std.testing.allocator.free(v2);

    const keys = try rs.list(std.testing.allocator);
    defer RefStore.freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
}

test "WriteBehindRefStore: canonical put failure surfaces and yields no version" {
    var failing = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer failing.deinit();
    failing.fail_put = true;
    failing.error_kind = .canonical;

    var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer cache.deinit();

    const caches = [_]RefStore{cache.refStore()};
    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = failing.refStore(),
        .caches = &caches,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    try std.testing.expectError(error.SimulatedCanonicalFailure, rs.put(std.testing.allocator, "k", "v"));
}

test "WriteBehindRefStore: lax policy ignores cache stage failure" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var failing_cache = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer failing_cache.deinit();
    failing_cache.fail_put = true;
    failing_cache.error_kind = .cache;
    var ok_cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer ok_cache.deinit();

    const caches = [_]RefStore{ failing_cache.refStore(), ok_cache.refStore() };
    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
        .cache_failure_policy = .lax,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    const v = try rs.put(std.testing.allocator, "k", "v");
    defer std.testing.allocator.free(v);

    // The healthy cache and canonical should both have the value.
    {
        const got = try canonical.refStore().get(std.testing.allocator, "k", null);
        defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("v", got.?.value);
    }
    {
        const got = try ok_cache.refStore().get(std.testing.allocator, "k", null);
        defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("v", got.?.value);
    }
}

test "WriteBehindRefStore: strict policy aborts before canonical on cache failure" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var counting = CountingRefStore.init(.{ .gpa = std.testing.allocator });
    defer counting.deinit();
    counting.inner = canonical.refStore();

    var failing_cache = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer failing_cache.deinit();
    failing_cache.fail_put = true;
    failing_cache.error_kind = .cache;

    const caches = [_]RefStore{failing_cache.refStore()};
    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = counting.refStore(),
        .caches = &caches,
        .cache_failure_policy = .strict,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    try std.testing.expectError(error.SimulatedCacheFailure, rs.put(std.testing.allocator, "k", "v"));
    try std.testing.expectEqual(@as(usize, 0), counting.calls.put);
}

test "WriteBehindRefStore: cache loss recovery rebuilds via canonical fall-through" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    // Lifetime 1: write through a composite with a cache.
    {
        var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
        defer cache.deinit();
        const caches = [_]RefStore{cache.refStore()};
        var composite = sideshowdb.WriteBehindRefStore.init(.{
            .gpa = std.testing.allocator,
            .canonical = canonical.refStore(),
            .caches = &caches,
        });
        defer composite.deinit();
        const rs = composite.refStore();

        const v = try rs.put(std.testing.allocator, "persisted", "hello");
        std.testing.allocator.free(v);
        // Cache is dropped at scope exit — simulating cache loss.
    }

    // Lifetime 2: brand new (empty) cache + same canonical. Read must succeed.
    {
        var fresh_cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
        defer fresh_cache.deinit();
        const caches = [_]RefStore{fresh_cache.refStore()};
        var composite = sideshowdb.WriteBehindRefStore.init(.{
            .gpa = std.testing.allocator,
            .canonical = canonical.refStore(),
            .caches = &caches,
        });
        defer composite.deinit();
        const rs = composite.refStore();

        const got = try rs.get(std.testing.allocator, "persisted", null);
        defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("hello", got.?.value);

        // The fresh cache should now hold the value (refilled from canonical).
        const cache_got = try fresh_cache.refStore().get(std.testing.allocator, "persisted", null);
        defer if (cache_got) |r| RefStore.freeReadResult(std.testing.allocator, r);
        try std.testing.expect(cache_got != null);
        try std.testing.expectEqualStrings("hello", cache_got.?.value);
    }
}

test "WriteBehindRefStore: zero-cache composite is a thin pass-through" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &.{},
    });
    defer composite.deinit();
    const rs = composite.refStore();

    const v = try rs.put(std.testing.allocator, "k", "v");
    defer std.testing.allocator.free(v);

    const got_via_composite = try rs.get(std.testing.allocator, "k", null);
    defer if (got_via_composite) |r| RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got_via_composite != null);

    const got_via_canonical = try canonical.refStore().get(std.testing.allocator, "k", null);
    defer if (got_via_canonical) |r| RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got_via_canonical != null);
    try std.testing.expectEqualStrings("v", got_via_canonical.?.value);
}

test "WriteBehindRefStore: invalid key rejected before any backend is touched" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var counting = CountingRefStore.init(.{ .gpa = std.testing.allocator });
    defer counting.deinit();
    counting.inner = canonical.refStore();

    var composite = sideshowdb.WriteBehindRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = counting.refStore(),
        .caches = &.{},
    });
    defer composite.deinit();
    const rs = composite.refStore();

    try std.testing.expectError(error.InvalidKey, rs.put(std.testing.allocator, "", "v"));
    try std.testing.expectError(error.InvalidKey, rs.put(std.testing.allocator, "/leading", "v"));
    try std.testing.expectError(error.InvalidKey, rs.put(std.testing.allocator, "trailing/", "v"));
    try std.testing.expectError(error.InvalidKey, rs.put(std.testing.allocator, "a//b", "v"));
    try std.testing.expectEqual(@as(usize, 0), counting.calls.put);
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// A `RefStore` that delegates to an inner store while counting calls.
const CountingRefStore = struct {
    pub const Options = struct { gpa: Allocator };

    pub const Calls = struct {
        put: usize = 0,
        get: usize = 0,
        delete: usize = 0,
        list: usize = 0,
        history: usize = 0,
    };

    gpa: Allocator,
    inner: RefStore = undefined,
    calls: Calls = .{},

    pub fn init(opts: Options) CountingRefStore {
        return .{ .gpa = opts.gpa };
    }

    pub fn deinit(_: *CountingRefStore) void {}

    pub fn refStore(self: *CountingRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: RefStore.VTable = .{
        .put = vtPut,
        .get = vtGet,
        .delete = vtDelete,
        .list = vtList,
        .history = vtHistory,
    };

    fn vtPut(ctx: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.VersionId {
        const self: *CountingRefStore = @ptrCast(@alignCast(ctx));
        self.calls.put += 1;
        return self.inner.put(gpa, key, value);
    }

    fn vtGet(ctx: *anyopaque, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        const self: *CountingRefStore = @ptrCast(@alignCast(ctx));
        self.calls.get += 1;
        return self.inner.get(gpa, key, version);
    }

    fn vtDelete(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *CountingRefStore = @ptrCast(@alignCast(ctx));
        self.calls.delete += 1;
        return self.inner.delete(key);
    }

    fn vtList(ctx: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        const self: *CountingRefStore = @ptrCast(@alignCast(ctx));
        self.calls.list += 1;
        return self.inner.list(gpa);
    }

    fn vtHistory(ctx: *anyopaque, gpa: Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        const self: *CountingRefStore = @ptrCast(@alignCast(ctx));
        self.calls.history += 1;
        return self.inner.history(gpa, key);
    }
};

/// A `RefStore` test double that fails on demand. Distinguishes
/// canonical-vs-cache provenance via `error_kind` so tests can assert
/// exactly which side of the composite raised the error.
const FailingRefStore = struct {
    pub const Options = struct { gpa: Allocator };
    pub const ErrorKind = enum { canonical, cache };

    gpa: Allocator,
    fail_put: bool = false,
    fail_get: bool = false,
    error_kind: ErrorKind = .canonical,

    pub fn init(opts: Options) FailingRefStore {
        return .{ .gpa = opts.gpa };
    }

    pub fn deinit(_: *FailingRefStore) void {}

    pub fn refStore(self: *FailingRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: RefStore.VTable = .{
        .put = vtPut,
        .get = vtGet,
        .delete = vtDelete,
        .list = vtList,
        .history = vtHistory,
    };

    fn vtPut(ctx: *anyopaque, _: Allocator, _: []const u8, _: []const u8) anyerror!RefStore.VersionId {
        const self: *FailingRefStore = @ptrCast(@alignCast(ctx));
        if (!self.fail_put) return error.SimulatedNotConfigured;
        return switch (self.error_kind) {
            .canonical => error.SimulatedCanonicalFailure,
            .cache => error.SimulatedCacheFailure,
        };
    }

    fn vtGet(ctx: *anyopaque, _: Allocator, _: []const u8, _: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        const self: *FailingRefStore = @ptrCast(@alignCast(ctx));
        if (!self.fail_get) return null;
        return switch (self.error_kind) {
            .canonical => error.SimulatedCanonicalFailure,
            .cache => error.SimulatedCacheFailure,
        };
    }

    fn vtDelete(_: *anyopaque, _: []const u8) anyerror!void {
        return;
    }

    fn vtList(_: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        return try gpa.alloc([]u8, 0);
    }

    fn vtHistory(_: *anyopaque, gpa: Allocator, _: []const u8) anyerror![]RefStore.VersionId {
        return try gpa.alloc(RefStore.VersionId, 0);
    }
};
