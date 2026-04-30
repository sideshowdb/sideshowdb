const std = @import("std");
const sideshowdb = @import("sideshowdb");

fn identity() sideshowdb.event.StreamIdentity {
    return .{
        .namespace = "default",
        .aggregate_type = "issue",
        .aggregate_id = "issue-1",
    };
}

fn snapshot(revision: u64, state_json: []const u8) sideshowdb.snapshot.SnapshotRecord {
    return .{
        .namespace = "default",
        .aggregate_type = "issue",
        .aggregate_id = "issue-1",
        .revision = revision,
        .up_to_event_id = "evt-42",
        .state_json = state_json,
        .metadata_json = "{\"source\":\"test\"}",
    };
}

test "SnapshotStore writes and reads latest snapshot" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    const write = try store.put(std.testing.allocator, .{
        .identity = identity(),
        .record = snapshot(2, "{\"status\":\"open\"}"),
    });
    defer write.deinit(std.testing.allocator);

    const latest = try store.getLatest(std.testing.allocator, identity());
    defer if (latest) |record| record.deinit(std.testing.allocator);

    try std.testing.expect(latest != null);
    try std.testing.expectEqual(@as(u64, 2), latest.?.revision);
    try std.testing.expectEqualStrings("{\"status\":\"open\"}", latest.?.state_json);
}

test "SnapshotStore reads at or before revision" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    const first = try store.put(std.testing.allocator, .{ .identity = identity(), .record = snapshot(2, "{\"n\":2}") });
    defer first.deinit(std.testing.allocator);
    const second = try store.put(std.testing.allocator, .{ .identity = identity(), .record = snapshot(5, "{\"n\":5}") });
    defer second.deinit(std.testing.allocator);

    const at_four = try store.getAtOrBefore(std.testing.allocator, identity(), 4);
    defer if (at_four) |record| record.deinit(std.testing.allocator);
    try std.testing.expect(at_four != null);
    try std.testing.expectEqual(@as(u64, 2), at_four.?.revision);
}

test "SnapshotStore lists snapshots newest first" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    const first = try store.put(std.testing.allocator, .{ .identity = identity(), .record = snapshot(2, "{\"n\":2}") });
    defer first.deinit(std.testing.allocator);
    const second = try store.put(std.testing.allocator, .{ .identity = identity(), .record = snapshot(5, "{\"n\":5}") });
    defer second.deinit(std.testing.allocator);

    const items = try store.list(std.testing.allocator, identity());
    defer sideshowdb.snapshot.freeSnapshotMetadataList(std.testing.allocator, items);

    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(u64, 5), items[0].revision);
    try std.testing.expectEqual(@as(u64, 2), items[1].revision);
}

test "SnapshotStore rejects revision zero" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    try std.testing.expectError(error.InvalidSnapshot, store.put(std.testing.allocator, .{
        .identity = identity(),
        .record = snapshot(0, "{}"),
    }));
}

test "SnapshotStore rejects identity mismatch" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    try std.testing.expectError(error.InvalidSnapshot, store.put(std.testing.allocator, .{
        .identity = .{ .namespace = "other", .aggregate_type = "issue", .aggregate_id = "issue-1" },
        .record = snapshot(1, "{}"),
    }));
}

test "SnapshotStore allows identical idempotent write and rejects conflict" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    const first = try store.put(std.testing.allocator, .{ .identity = identity(), .record = snapshot(1, "{\"n\":1}") });
    defer first.deinit(std.testing.allocator);
    const second = try store.put(std.testing.allocator, .{ .identity = identity(), .record = snapshot(1, "{\"n\":1}") });
    defer second.deinit(std.testing.allocator);

    try std.testing.expectError(error.SnapshotConflict, store.put(std.testing.allocator, .{
        .identity = identity(),
        .record = snapshot(1, "{\"n\":99}"),
    }));
}

test "SnapshotStore missing stream returns empty list and null latest" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    const latest = try store.getLatest(std.testing.allocator, identity());
    try std.testing.expect(latest == null);

    const items = try store.list(std.testing.allocator, identity());
    defer sideshowdb.snapshot.freeSnapshotMetadataList(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "SnapshotStore rejects empty up_to_event_id" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    const bad: sideshowdb.snapshot.SnapshotRecord = .{
        .namespace = "default",
        .aggregate_type = "issue",
        .aggregate_id = "issue-1",
        .revision = 1,
        .up_to_event_id = "",
        .state_json = "{}",
    };
    try std.testing.expectError(error.InvalidSnapshot, store.put(std.testing.allocator, .{
        .identity = identity(),
        .record = bad,
    }));
}

test "SnapshotStore rejects invalid key segment in identity" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    const bad_identity: sideshowdb.event.StreamIdentity = .{
        .namespace = "default",
        .aggregate_type = "issue",
        .aggregate_id = "bad/id",
    };
    const bad_record: sideshowdb.snapshot.SnapshotRecord = .{
        .namespace = "default",
        .aggregate_type = "issue",
        .aggregate_id = "bad/id",
        .revision = 1,
        .up_to_event_id = "evt-1",
        .state_json = "{}",
    };
    try std.testing.expectError(error.InvalidStreamIdentity, store.put(std.testing.allocator, .{
        .identity = bad_identity,
        .record = bad_record,
    }));
}

test "SnapshotStore idempotent write returns idempotent=true; first write returns idempotent=false" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    const first = try store.put(std.testing.allocator, .{
        .identity = identity(),
        .record = snapshot(3, "{\"n\":3}"),
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(!first.idempotent);

    const second = try store.put(std.testing.allocator, .{
        .identity = identity(),
        .record = snapshot(3, "{\"n\":3}"),
    });
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second.idempotent);
}

test "SnapshotStore preserves metadata on round-trip" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.snapshot.SnapshotStore.init(memory.refStore());

    const write = try store.put(std.testing.allocator, .{
        .identity = identity(),
        .record = snapshot(1, "{\"status\":\"open\"}"),
    });
    defer write.deinit(std.testing.allocator);

    const latest = try store.getLatest(std.testing.allocator, identity());
    defer if (latest) |record| record.deinit(std.testing.allocator);

    try std.testing.expect(latest != null);
    try std.testing.expect(latest.?.metadata_json != null);
    try std.testing.expectEqualStrings("{\"source\":\"test\"}", latest.?.metadata_json.?);
}
