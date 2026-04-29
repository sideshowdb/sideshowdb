//! Shared `RefStore` parity harness.
//!
//! Every concrete `RefStore` backend must satisfy the same observable
//! contract — put/get/overwrite/delete/list/history semantics, opaque
//! version identifiers, and rejection of malformed keys. This harness
//! exercises that contract against any backend exposed through
//! `sideshowdb.RefStore`. Backend-specific tests construct their store,
//! pass the resulting view to `exerciseRefStore`, and add only the
//! checks that are unique to that backend.

const std = @import("std");
const sideshowdb = @import("sideshowdb");

/// Inputs needed to drive the shared `RefStore` parity scenario.
pub const Harness = struct {
    gpa: std.mem.Allocator,
    ref_store: sideshowdb.RefStore,
};

/// Run the cross-backend `RefStore` parity scenario against `h.ref_store`.
///
/// Covers: empty-store reads, first put, overwrite, multi-key list,
/// missing-key history, delete, idempotent delete, explicit-version reads
/// after delete, and invalid-key rejection.
pub fn exerciseRefStore(h: Harness) !void {
    const rs = h.ref_store;

    {
        const keys = try rs.list(h.gpa);
        defer sideshowdb.RefStore.freeKeys(h.gpa, keys);
        try std.testing.expectEqual(@as(usize, 0), keys.len);
    }
    {
        const v = try rs.get(h.gpa, "a/x.txt", null);
        try std.testing.expect(v == null);
    }
    {
        const versions = try rs.history(h.gpa, "a/x.txt");
        defer sideshowdb.RefStore.freeVersions(h.gpa, versions);
        try std.testing.expectEqual(@as(usize, 0), versions.len);
    }

    const first_version = try rs.put(h.gpa, "a/x.txt", "hello");
    defer h.gpa.free(first_version);
    {
        const v = try rs.get(h.gpa, "a/x.txt", null);
        defer if (v) |r| sideshowdb.RefStore.freeReadResult(h.gpa, r);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("hello", v.?.value);
        try std.testing.expectEqualStrings(first_version, v.?.version);
    }

    const second_version = try rs.put(h.gpa, "a/x.txt", "world");
    defer h.gpa.free(second_version);
    {
        const v = try rs.get(h.gpa, "a/x.txt", null);
        defer if (v) |r| sideshowdb.RefStore.freeReadResult(h.gpa, r);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("world", v.?.value);
        try std.testing.expectEqualStrings(second_version, v.?.version);
    }
    {
        const versions = try rs.history(h.gpa, "a/x.txt");
        defer sideshowdb.RefStore.freeVersions(h.gpa, versions);
        try std.testing.expectEqual(@as(usize, 2), versions.len);
        try std.testing.expectEqualStrings(second_version, versions[0]);
        try std.testing.expectEqualStrings(first_version, versions[1]);
    }

    const third_version = try rs.put(h.gpa, "b/y.txt", "ok");
    defer h.gpa.free(third_version);
    {
        const keys = try rs.list(h.gpa);
        defer sideshowdb.RefStore.freeKeys(h.gpa, keys);
        try std.testing.expectEqual(@as(usize, 2), keys.len);
        var saw_a = false;
        var saw_b = false;
        for (keys) |k| {
            if (std.mem.eql(u8, k, "a/x.txt")) saw_a = true;
            if (std.mem.eql(u8, k, "b/y.txt")) saw_b = true;
        }
        try std.testing.expect(saw_a and saw_b);
    }
    {
        const versions = try rs.history(h.gpa, "missing.txt");
        defer sideshowdb.RefStore.freeVersions(h.gpa, versions);
        try std.testing.expectEqual(@as(usize, 0), versions.len);
    }

    try rs.delete("a/x.txt");
    {
        const v = try rs.get(h.gpa, "a/x.txt", null);
        try std.testing.expect(v == null);
    }
    {
        const keys = try rs.list(h.gpa);
        defer sideshowdb.RefStore.freeKeys(h.gpa, keys);
        try std.testing.expectEqual(@as(usize, 1), keys.len);
        try std.testing.expectEqualStrings("b/y.txt", keys[0]);
    }
    {
        const versions = try rs.history(h.gpa, "a/x.txt");
        defer sideshowdb.RefStore.freeVersions(h.gpa, versions);
        try std.testing.expectEqual(@as(usize, 2), versions.len);
        try std.testing.expectEqualStrings(second_version, versions[0]);
        try std.testing.expectEqualStrings(first_version, versions[1]);
    }

    try rs.delete("a/x.txt");

    {
        const v = try rs.get(h.gpa, "a/x.txt", first_version);
        defer if (v) |r| sideshowdb.RefStore.freeReadResult(h.gpa, r);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("hello", v.?.value);
        try std.testing.expectEqualStrings(first_version, v.?.version);
    }

    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "/leading", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "trailing/", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "a//b", "x"));
    try std.testing.expectError(error.InvalidKey, rs.history(h.gpa, ""));
}
