//! Integration tests for `WriteThroughRefStore`. Drives the
//! composite through the shared parity harness across several cache
//! topologies, plus composite-specific checks (cache short-circuit
//! reads, canonical refill, failure-policy semantics, cache recovery
//! from total loss, OOM propagation, strict-mode delete asymmetry,
//! list/get divergence under .lax).

const std = @import("std");
const sideshowdb = @import("sideshowdb");
const parity = @import("ref_store_parity.zig");

const Allocator = std.mem.Allocator;
const RefStore = sideshowdb.RefStore;

test "WriteThroughRefStore: parity harness with zero caches" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    var composite = sideshowdb.WriteThroughRefStore.init(.{
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

test "WriteThroughRefStore: parity harness with one cache" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer cache.deinit();

    const caches = [_]RefStore{cache.refStore()};
    var composite = sideshowdb.WriteThroughRefStore.init(.{
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

test "WriteThroughRefStore: parity harness with three caches" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var c0 = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer c0.deinit();
    var c1 = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer c1.deinit();
    var c2 = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer c2.deinit();

    const caches = [_]RefStore{ c0.refStore(), c1.refStore(), c2.refStore() };
    var composite = sideshowdb.WriteThroughRefStore.init(.{
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

test "WriteThroughRefStore: cache hit short-circuits canonical on get" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var counting = CountingRefStore.init(.{ .gpa = std.testing.allocator });
    defer counting.deinit();
    var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer cache.deinit();

    counting.inner = canonical.refStore();
    const caches = [_]RefStore{cache.refStore()};
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = counting.refStore(),
        .caches = &caches,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    const v = try rs.put(std.testing.allocator, "k", "v");
    defer std.testing.allocator.free(v);

    try std.testing.expectEqual(@as(usize, 1), counting.calls.put);
    try std.testing.expectEqual(@as(usize, 0), counting.calls.get);

    const got = try rs.get(std.testing.allocator, "k", null);
    defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?.value);
    try std.testing.expectEqual(@as(usize, 0), counting.calls.get);
}

test "WriteThroughRefStore: cache miss falls through to canonical and refills" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

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
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = counting.refStore(),
        .caches = &caches,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    {
        const got = try rs.get(std.testing.allocator, "k", null);
        defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("from-canonical", got.?.value);
    }
    try std.testing.expectEqual(@as(usize, 1), counting.calls.get);

    {
        const got = try rs.get(std.testing.allocator, "k", null);
        defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings("from-canonical", got.?.value);
    }
    try std.testing.expectEqual(@as(usize, 1), counting.calls.get);
}

test "WriteThroughRefStore: list reads from canonical only" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer cache.deinit();

    const caches = [_]RefStore{cache.refStore()};
    var composite = sideshowdb.WriteThroughRefStore.init(.{
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

test "WriteThroughRefStore: canonical put failure surfaces and yields no version" {
    var failing = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer failing.deinit();
    failing.fail_put = true;
    failing.error_kind = .canonical;

    var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer cache.deinit();

    const caches = [_]RefStore{cache.refStore()};
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = failing.refStore(),
        .caches = &caches,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    try std.testing.expectError(error.SimulatedCanonicalFailure, rs.put(std.testing.allocator, "k", "v"));
}

test "WriteThroughRefStore: lax policy ignores cache stage failure" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var failing_cache = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer failing_cache.deinit();
    failing_cache.fail_put = true;
    failing_cache.error_kind = .cache;
    var ok_cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer ok_cache.deinit();

    const caches = [_]RefStore{ failing_cache.refStore(), ok_cache.refStore() };
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
        .cache_failure_policy = .lax,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    const v = try rs.put(std.testing.allocator, "k", "v");
    defer std.testing.allocator.free(v);

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

test "WriteThroughRefStore: strict policy aborts before canonical on cache failure" {
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
    var composite = sideshowdb.WriteThroughRefStore.init(.{
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

test "WriteThroughRefStore: strict policy compensation runs against earlier-staged caches" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    var ok_cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer ok_cache.deinit();

    var failing_cache = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer failing_cache.deinit();
    failing_cache.fail_put = true;
    failing_cache.error_kind = .cache;

    const caches = [_]RefStore{ ok_cache.refStore(), failing_cache.refStore() };
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
        .cache_failure_policy = .strict,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    try std.testing.expectError(error.SimulatedCacheFailure, rs.put(std.testing.allocator, "k", "v"));

    // ok_cache staged then was compensated — final state is "key absent".
    const got = try ok_cache.refStore().get(std.testing.allocator, "k", null);
    try std.testing.expect(got == null);

    // canonical never received the put.
    const got_canonical = try canonical.refStore().get(std.testing.allocator, "k", null);
    try std.testing.expect(got_canonical == null);
}

test "WriteThroughRefStore: strict put surfaces original cache error even when compensation delete fails" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    var fail_on_delete = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer fail_on_delete.deinit();
    fail_on_delete.fail_delete = true;
    fail_on_delete.error_kind = .cache;
    fail_on_delete.delegate_put = true; // permit put to succeed

    var failing_cache = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer failing_cache.deinit();
    failing_cache.fail_put = true;
    failing_cache.error_kind = .cache;

    const caches = [_]RefStore{ fail_on_delete.refStore(), failing_cache.refStore() };
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
        .cache_failure_policy = .strict,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    // Original error is the cache failure from index 1; compensation
    // of index 0 fails on `delete`, but that failure is swallowed.
    try std.testing.expectError(error.SimulatedCacheFailure, rs.put(std.testing.allocator, "k", "v"));

    // canonical was never contacted.
    const got_canonical = try canonical.refStore().get(std.testing.allocator, "k", null);
    try std.testing.expect(got_canonical == null);
}

test "WriteThroughRefStore: strict-mode delete aborts before canonical and leaves earlier caches deleted" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    // Pre-seed canonical and ok_cache so the delete has something to remove.
    {
        const v = try canonical.refStore().put(std.testing.allocator, "k", "v");
        std.testing.allocator.free(v);
    }
    var ok_cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer ok_cache.deinit();
    {
        const v = try ok_cache.refStore().put(std.testing.allocator, "k", "v");
        std.testing.allocator.free(v);
    }

    var failing_cache = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer failing_cache.deinit();
    failing_cache.fail_delete = true;
    failing_cache.error_kind = .cache;

    var counting_canonical = CountingRefStore.init(.{ .gpa = std.testing.allocator });
    defer counting_canonical.deinit();
    counting_canonical.inner = canonical.refStore();

    const caches = [_]RefStore{ ok_cache.refStore(), failing_cache.refStore() };
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = counting_canonical.refStore(),
        .caches = &caches,
        .cache_failure_policy = .strict,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    try std.testing.expectError(error.SimulatedCacheFailure, rs.delete("k"));

    // canonical.delete must NOT have been called.
    try std.testing.expectEqual(@as(usize, 0), counting_canonical.calls.delete);

    // ok_cache (index 0) had its delete applied — key now absent.
    const got_ok = try ok_cache.refStore().get(std.testing.allocator, "k", null);
    try std.testing.expect(got_ok == null);

    // canonical still has the key.
    const got_canonical = try canonical.refStore().get(std.testing.allocator, "k", null);
    defer if (got_canonical) |r| RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got_canonical != null);
    try std.testing.expectEqualStrings("v", got_canonical.?.value);
}

test "WriteThroughRefStore: lax get treats cache-read error as miss; canonical answers" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    {
        const v = try canonical.refStore().put(std.testing.allocator, "k", "from-canonical");
        std.testing.allocator.free(v);
    }

    var sick_cache = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer sick_cache.deinit();
    sick_cache.fail_get = true;
    sick_cache.error_kind = .cache;

    const caches = [_]RefStore{sick_cache.refStore()};
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
        .cache_failure_policy = .lax,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    const got = try rs.get(std.testing.allocator, "k", null);
    defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("from-canonical", got.?.value);
}

test "WriteThroughRefStore: get propagates OutOfMemory from cache regardless of policy" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var oom_cache = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer oom_cache.deinit();
    oom_cache.fail_get = true;
    oom_cache.error_kind = .out_of_memory;

    const caches = [_]RefStore{oom_cache.refStore()};

    {
        var composite = sideshowdb.WriteThroughRefStore.init(.{
            .gpa = std.testing.allocator,
            .canonical = canonical.refStore(),
            .caches = &caches,
            .cache_failure_policy = .lax,
        });
        defer composite.deinit();
        const rs = composite.refStore();
        try std.testing.expectError(error.OutOfMemory, rs.get(std.testing.allocator, "k", null));
    }
    {
        var composite = sideshowdb.WriteThroughRefStore.init(.{
            .gpa = std.testing.allocator,
            .canonical = canonical.refStore(),
            .caches = &caches,
            .cache_failure_policy = .strict,
        });
        defer composite.deinit();
        const rs = composite.refStore();
        try std.testing.expectError(error.OutOfMemory, rs.get(std.testing.allocator, "k", null));
    }
}

test "WriteThroughRefStore: strict get propagates non-OOM cache errors" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var sick_cache = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer sick_cache.deinit();
    sick_cache.fail_get = true;
    sick_cache.error_kind = .cache;

    const caches = [_]RefStore{sick_cache.refStore()};
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
        .cache_failure_policy = .strict,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    try std.testing.expectError(error.SimulatedCacheFailure, rs.get(std.testing.allocator, "k", null));
}

test "WriteThroughRefStore: lax list/get diverge after canonical put failure" {
    // Caches stage fine; canonical then refuses the put.
    var canonical = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    canonical.fail_put = true;
    canonical.error_kind = .canonical;

    var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer cache.deinit();

    const caches = [_]RefStore{cache.refStore()};
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
        .cache_failure_policy = .lax,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    try std.testing.expectError(error.SimulatedCanonicalFailure, rs.put(std.testing.allocator, "k", "v"));

    // get sees the speculative cache value.
    const got = try rs.get(std.testing.allocator, "k", null);
    defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("v", got.?.value);

    // list reads from canonical — sees nothing.
    const keys = try rs.list(std.testing.allocator);
    defer RefStore.freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 0), keys.len);
}

test "WriteThroughRefStore: speculative-only entry vanishes after cache loss" {
    // Reproduces the spec §7.1 claim: no canonical record was ever
    // cache-only, so dropping a cache that held a speculative entry
    // (canonical put failed under .lax) leaves the system in the
    // correct "key never existed" state.
    var canonical = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    canonical.fail_put = true;
    canonical.error_kind = .canonical;

    // Lifetime 1: write fails canonical; cache holds a speculative entry.
    {
        var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
        defer cache.deinit();

        const caches = [_]RefStore{cache.refStore()};
        var composite = sideshowdb.WriteThroughRefStore.init(.{
            .gpa = std.testing.allocator,
            .canonical = canonical.refStore(),
            .caches = &caches,
            .cache_failure_policy = .lax,
        });
        defer composite.deinit();
        const rs = composite.refStore();

        try std.testing.expectError(error.SimulatedCanonicalFailure, rs.put(std.testing.allocator, "k", "v"));

        // Confirm the cache holds the speculative entry before we drop it.
        const got = try cache.refStore().get(std.testing.allocator, "k", null);
        defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
        try std.testing.expect(got != null);
    }

    // Lifetime 2: fresh cache, same (failing) canonical. A read for
    // "k" must return null — the speculative entry is gone, and
    // canonical never had it. This proves no canonical record was
    // ever cache-only.
    {
        // Canonical reads still succeed (FailingRefStore's get returns null by default).
        canonical.fail_put = false; // read path was never blocked anyway, but be explicit.
        var fresh_cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
        defer fresh_cache.deinit();

        const caches = [_]RefStore{fresh_cache.refStore()};
        var composite = sideshowdb.WriteThroughRefStore.init(.{
            .gpa = std.testing.allocator,
            .canonical = canonical.refStore(),
            .caches = &caches,
            .cache_failure_policy = .lax,
        });
        defer composite.deinit();
        const rs = composite.refStore();

        const got = try rs.get(std.testing.allocator, "k", null);
        try std.testing.expect(got == null);
    }
}

test "WriteThroughRefStore: cache loss recovery rebuilds via canonical fall-through" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    {
        var cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
        defer cache.deinit();
        const caches = [_]RefStore{cache.refStore()};
        var composite = sideshowdb.WriteThroughRefStore.init(.{
            .gpa = std.testing.allocator,
            .canonical = canonical.refStore(),
            .caches = &caches,
        });
        defer composite.deinit();
        const rs = composite.refStore();

        const v = try rs.put(std.testing.allocator, "persisted", "hello");
        std.testing.allocator.free(v);
    }

    {
        var fresh_cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
        defer fresh_cache.deinit();
        const caches = [_]RefStore{fresh_cache.refStore()};
        var composite = sideshowdb.WriteThroughRefStore.init(.{
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

        const cache_got = try fresh_cache.refStore().get(std.testing.allocator, "persisted", null);
        defer if (cache_got) |r| RefStore.freeReadResult(std.testing.allocator, r);
        try std.testing.expect(cache_got != null);
        try std.testing.expectEqualStrings("hello", cache_got.?.value);
    }
}

test "WriteThroughRefStore: refill is not a repair mechanism (later-cache hit, earlier cache stays degraded)" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    var sick_cache = FailingRefStore.init(.{ .gpa = std.testing.allocator });
    defer sick_cache.deinit();
    sick_cache.fail_get = true;
    sick_cache.error_kind = .cache;
    // sick_cache also captures put calls so we can prove no refill happened.
    sick_cache.delegate_put = true;

    var warm_cache = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer warm_cache.deinit();
    {
        const v = try warm_cache.refStore().put(std.testing.allocator, "k", "warm-val");
        std.testing.allocator.free(v);
    }

    const caches = [_]RefStore{ sick_cache.refStore(), warm_cache.refStore() };
    var composite = sideshowdb.WriteThroughRefStore.init(.{
        .gpa = std.testing.allocator,
        .canonical = canonical.refStore(),
        .caches = &caches,
        .cache_failure_policy = .lax,
    });
    defer composite.deinit();
    const rs = composite.refStore();

    sick_cache.put_call_count = 0;

    const got = try rs.get(std.testing.allocator, "k", null);
    defer if (got) |r| RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("warm-val", got.?.value);

    // No back-fill into sick_cache.
    try std.testing.expectEqual(@as(usize, 0), sick_cache.put_call_count);
}

test "WriteThroughRefStore: zero-cache composite is a thin pass-through" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();

    var composite = sideshowdb.WriteThroughRefStore.init(.{
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

test "WriteThroughRefStore: invalid key rejected before any backend is touched" {
    var canonical = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer canonical.deinit();
    var counting = CountingRefStore.init(.{ .gpa = std.testing.allocator });
    defer counting.deinit();
    counting.inner = canonical.refStore();

    var composite = sideshowdb.WriteThroughRefStore.init(.{
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

    fn vtPut(ctx: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.PutResult {
        const self: *CountingRefStore = @ptrCast(@alignCast(ctx));
        self.calls.put += 1;
        return .{ .version = try self.inner.put(gpa, key, value) };
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
/// exactly which side of the composite raised the error. Can also
/// be configured to delegate `put` to an internal `MemoryRefStore`
/// when only the get/delete failure paths are under test.
const FailingRefStore = struct {
    pub const Options = struct { gpa: Allocator };
    pub const ErrorKind = enum { canonical, cache, out_of_memory };

    gpa: Allocator,
    fail_put: bool = false,
    fail_get: bool = false,
    fail_delete: bool = false,
    delegate_put: bool = false,
    error_kind: ErrorKind = .canonical,
    delegate: sideshowdb.MemoryRefStore = undefined,
    delegate_initialized: bool = false,
    put_call_count: usize = 0,

    pub fn init(opts: Options) FailingRefStore {
        return .{ .gpa = opts.gpa };
    }

    pub fn deinit(self: *FailingRefStore) void {
        if (self.delegate_initialized) self.delegate.deinit();
    }

    pub fn refStore(self: *FailingRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn ensureDelegate(self: *FailingRefStore) void {
        if (!self.delegate_initialized) {
            self.delegate = sideshowdb.MemoryRefStore.init(.{ .gpa = self.gpa });
            self.delegate_initialized = true;
        }
    }

    const vtable: RefStore.VTable = .{
        .put = vtPut,
        .get = vtGet,
        .delete = vtDelete,
        .list = vtList,
        .history = vtHistory,
    };

    fn vtPut(ctx: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.PutResult {
        const self: *FailingRefStore = @ptrCast(@alignCast(ctx));
        self.put_call_count += 1;
        if (self.fail_put) {
            return errorFor(self.error_kind);
        }
        if (self.delegate_put) {
            self.ensureDelegate();
            return .{ .version = try self.delegate.put(gpa, key, value) };
        }
        return error.SimulatedNotConfigured;
    }

    fn vtGet(ctx: *anyopaque, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        const self: *FailingRefStore = @ptrCast(@alignCast(ctx));
        if (self.fail_get) return errorFor(self.error_kind);
        if (self.delegate_initialized) return self.delegate.get(gpa, key, version);
        return null;
    }

    fn vtDelete(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *FailingRefStore = @ptrCast(@alignCast(ctx));
        if (self.fail_delete) return errorFor(self.error_kind);
        if (self.delegate_initialized) return self.delegate.delete(key);
    }

    fn vtList(_: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        return try gpa.alloc([]u8, 0);
    }

    fn vtHistory(_: *anyopaque, gpa: Allocator, _: []const u8) anyerror![]RefStore.VersionId {
        return try gpa.alloc(RefStore.VersionId, 0);
    }

    fn errorFor(kind: ErrorKind) anyerror {
        return switch (kind) {
            .canonical => error.SimulatedCanonicalFailure,
            .cache => error.SimulatedCacheFailure,
            .out_of_memory => error.OutOfMemory,
        };
    }
};
