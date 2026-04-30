//! Integration tests for the in-memory `RefStore`. Drives the store through
//! the shared parity harness, plus memory-specific checks (volatility,
//! version-id determinism, post-delete history retention).

const std = @import("std");
const sideshowdb = @import("sideshowdb");
const parity = @import("ref_store_parity.zig");

fn putVersion(rs: sideshowdb.RefStore, gpa: std.mem.Allocator, key: []const u8, value: []const u8) !sideshowdb.RefStore.VersionId {
    const result = try rs.put(gpa, key, value);
    if (result.tree_sha) |sha| gpa.free(sha);
    return result.version;
}

test "MemoryRefStore: parity harness" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();

    try parity.exerciseRefStore(.{
        .gpa = std.testing.allocator,
        .ref_store = store.refStore(),
    });
}

test "MemoryRefStore: empty value round-trips" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();
    const rs = store.refStore();

    const version = try putVersion(rs, std.testing.allocator, "k", "");
    defer std.testing.allocator.free(version);

    const got = try rs.get(std.testing.allocator, "k", null);
    defer if (got) |r| sideshowdb.RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("", got.?.value);
    try std.testing.expectEqualStrings(version, got.?.version);
}

test "MemoryRefStore: version ids are unique across puts" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();
    const rs = store.refStore();

    const v1 = try putVersion(rs, std.testing.allocator, "k", "a");
    defer std.testing.allocator.free(v1);
    const v2 = try putVersion(rs, std.testing.allocator, "k", "b");
    defer std.testing.allocator.free(v2);
    const v3 = try putVersion(rs, std.testing.allocator, "other", "c");
    defer std.testing.allocator.free(v3);

    try std.testing.expect(!std.mem.eql(u8, v1, v2));
    try std.testing.expect(!std.mem.eql(u8, v2, v3));
    try std.testing.expect(!std.mem.eql(u8, v1, v3));
}

test "MemoryRefStore: get with explicit version returns historical value" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();
    const rs = store.refStore();

    const v1 = try putVersion(rs, std.testing.allocator, "k", "first");
    defer std.testing.allocator.free(v1);
    const v2 = try putVersion(rs, std.testing.allocator, "k", "second");
    defer std.testing.allocator.free(v2);

    const at_v1 = try rs.get(std.testing.allocator, "k", v1);
    defer if (at_v1) |r| sideshowdb.RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(at_v1 != null);
    try std.testing.expectEqualStrings("first", at_v1.?.value);
    try std.testing.expectEqualStrings(v1, at_v1.?.version);

    const at_v2 = try rs.get(std.testing.allocator, "k", v2);
    defer if (at_v2) |r| sideshowdb.RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(at_v2 != null);
    try std.testing.expectEqualStrings("second", at_v2.?.value);
}

test "MemoryRefStore: get returns null for unknown version on known key" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();
    const rs = store.refStore();

    const v1 = try putVersion(rs, std.testing.allocator, "k", "x");
    defer std.testing.allocator.free(v1);

    const got = try rs.get(std.testing.allocator, "k", "no-such-version");
    try std.testing.expect(got == null);
}

test "MemoryRefStore: delete is idempotent on missing key" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();
    const rs = store.refStore();

    try rs.delete("never-existed");
    try rs.delete("never-existed");
}

test "MemoryRefStore: put after delete revives key in list" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();
    const rs = store.refStore();

    const v1 = try putVersion(rs, std.testing.allocator, "k", "x");
    defer std.testing.allocator.free(v1);
    try rs.delete("k");

    {
        const keys = try rs.list(std.testing.allocator);
        defer sideshowdb.RefStore.freeKeys(std.testing.allocator, keys);
        try std.testing.expectEqual(@as(usize, 0), keys.len);
    }

    const v2 = try putVersion(rs, std.testing.allocator, "k", "y");
    defer std.testing.allocator.free(v2);

    {
        const keys = try rs.list(std.testing.allocator);
        defer sideshowdb.RefStore.freeKeys(std.testing.allocator, keys);
        try std.testing.expectEqual(@as(usize, 1), keys.len);
        try std.testing.expectEqualStrings("k", keys[0]);
    }

    const got = try rs.get(std.testing.allocator, "k", null);
    defer if (got) |r| sideshowdb.RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("y", got.?.value);
}

test "MemoryRefStore: history is newest-first across many puts" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();
    const rs = store.refStore();

    const values = [_][]const u8{ "a", "b", "c", "d", "e" };
    var puts: [5]sideshowdb.RefStore.VersionId = undefined;
    for (values, 0..) |v, i| {
        puts[i] = try putVersion(rs, std.testing.allocator, "k", v);
    }
    defer for (puts) |p| std.testing.allocator.free(p);

    const hist = try rs.history(std.testing.allocator, "k");
    defer sideshowdb.RefStore.freeVersions(std.testing.allocator, hist);
    try std.testing.expectEqual(@as(usize, 5), hist.len);
    try std.testing.expectEqualStrings(puts[4], hist[0]);
    try std.testing.expectEqualStrings(puts[3], hist[1]);
    try std.testing.expectEqualStrings(puts[2], hist[2]);
    try std.testing.expectEqualStrings(puts[1], hist[3]);
    try std.testing.expectEqualStrings(puts[0], hist[4]);
}

test "MemoryRefStore: unicode key round-trips" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();
    const rs = store.refStore();

    const key = "café/🦄";
    const v = try putVersion(rs, std.testing.allocator, key, "value");
    defer std.testing.allocator.free(v);

    const got = try rs.get(std.testing.allocator, key, null);
    defer if (got) |r| sideshowdb.RefStore.freeReadResult(std.testing.allocator, r);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("value", got.?.value);
}

test "MemoryRefStore: list returns sorted keys" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();
    const rs = store.refStore();

    const v_b = try putVersion(rs, std.testing.allocator, "b", "1");
    defer std.testing.allocator.free(v_b);
    const v_a = try putVersion(rs, std.testing.allocator, "a", "1");
    defer std.testing.allocator.free(v_a);
    const v_c = try putVersion(rs, std.testing.allocator, "c", "1");
    defer std.testing.allocator.free(v_c);

    const keys = try rs.list(std.testing.allocator);
    defer sideshowdb.RefStore.freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqualStrings("a", keys[0]);
    try std.testing.expectEqualStrings("b", keys[1]);
    try std.testing.expectEqualStrings("c", keys[2]);
}

test "MemoryRefStore: get with key containing null byte returns InvalidKey" {
    var store = sideshowdb.MemoryRefStore.init(.{
        .gpa = std.testing.allocator,
    });
    defer store.deinit();
    const rs = store.refStore();

    const bad = [_]u8{ 'a', 0, 'b' };
    try std.testing.expectError(error.InvalidKey, rs.put(std.testing.allocator, &bad, "x"));
}
