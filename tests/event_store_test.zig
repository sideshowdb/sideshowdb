const std = @import("std");
const sideshowdb = @import("sideshowdb");

const event_jsonl =
    \\{"event_id":"evt-1","event_type":"IssueOpened","namespace":"default","aggregate_type":"issue","aggregate_id":"issue-1","timestamp":"2026-04-30T12:00:00Z","payload":{"title":"First"}}
    \\{"event_id":"evt-2","event_type":"IssueRenamed","namespace":"default","aggregate_type":"issue","aggregate_id":"issue-1","timestamp":"2026-04-30T12:01:00Z","payload":{"title":"Second"}}
    \\
;

const event_json_batch =
    \\{
    \\  "events": [
    \\    {
    \\      "event_id": "evt-1",
    \\      "event_type": "IssueOpened",
    \\      "namespace": "default",
    \\      "aggregate_type": "issue",
    \\      "aggregate_id": "issue-1",
    \\      "timestamp": "2026-04-30T12:00:00Z",
    \\      "payload": { "title": "First" }
    \\    }
    \\  ]
    \\}
;

test "parseJsonlBatch returns a single-stream batch in input order" {
    const gpa = std.testing.allocator;

    var batch = try sideshowdb.event.parseJsonlBatch(gpa, event_jsonl);
    defer batch.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), batch.events.len);
    try std.testing.expectEqualStrings("default", batch.identity.namespace);
    try std.testing.expectEqualStrings("issue", batch.identity.aggregate_type);
    try std.testing.expectEqualStrings("issue-1", batch.identity.aggregate_id);
    try std.testing.expectEqualStrings("evt-1", batch.events[0].event_id);
    try std.testing.expectEqualStrings("evt-2", batch.events[1].event_id);
}

test "parseJsonBatch accepts an events array" {
    const gpa = std.testing.allocator;

    var batch = try sideshowdb.event.parseJsonBatch(gpa, event_json_batch);
    defer batch.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), batch.events.len);
    try std.testing.expectEqualStrings("IssueOpened", batch.events[0].event_type);
    try std.testing.expectEqualStrings("2026-04-30T12:00:00Z", batch.events[0].timestamp);
}

test "parseJsonlBatch rejects an empty batch" {
    try std.testing.expectError(
        error.EmptyBatch,
        sideshowdb.event.parseJsonlBatch(std.testing.allocator, "\n\n"),
    );
}

test "parseJsonBatch rejects mixed stream identities" {
    const mixed =
        \\{
        \\  "events": [
        \\    {
        \\      "event_id": "evt-1",
        \\      "event_type": "IssueOpened",
        \\      "namespace": "default",
        \\      "aggregate_type": "issue",
        \\      "aggregate_id": "issue-1",
        \\      "timestamp": "2026-04-30T12:00:00Z",
        \\      "payload": {}
        \\    },
        \\    {
        \\      "event_id": "evt-2",
        \\      "event_type": "IssueOpened",
        \\      "namespace": "default",
        \\      "aggregate_type": "issue",
        \\      "aggregate_id": "issue-2",
        \\      "timestamp": "2026-04-30T12:01:00Z",
        \\      "payload": {}
        \\    }
        \\  ]
        \\}
    ;

    try std.testing.expectError(
        error.MixedStreamBatch,
        sideshowdb.event.parseJsonBatch(std.testing.allocator, mixed),
    );
}

test "parseJsonBatch rejects duplicate event ids in one batch" {
    const duplicate =
        \\{
        \\  "events": [
        \\    {
        \\      "event_id": "evt-1",
        \\      "event_type": "IssueOpened",
        \\      "namespace": "default",
        \\      "aggregate_type": "issue",
        \\      "aggregate_id": "issue-1",
        \\      "timestamp": "2026-04-30T12:00:00Z",
        \\      "payload": {}
        \\    },
        \\    {
        \\      "event_id": "evt-1",
        \\      "event_type": "IssueRenamed",
        \\      "namespace": "default",
        \\      "aggregate_type": "issue",
        \\      "aggregate_id": "issue-1",
        \\      "timestamp": "2026-04-30T12:01:00Z",
        \\      "payload": {}
        \\    }
        \\  ]
        \\}
    ;

    try std.testing.expectError(
        error.DuplicateEventId,
        sideshowdb.event.parseJsonBatch(std.testing.allocator, duplicate),
    );
}

test "parseJsonBatch rejects missing required envelope fields" {
    const missing_payload =
        \\{
        \\  "events": [
        \\    {
        \\      "event_id": "evt-1",
        \\      "event_type": "IssueOpened",
        \\      "namespace": "default",
        \\      "aggregate_type": "issue",
        \\      "aggregate_id": "issue-1",
        \\      "timestamp": "2026-04-30T12:00:00Z"
        \\    }
        \\  ]
        \\}
    ;

    try std.testing.expectError(
        error.InvalidEvent,
        sideshowdb.event.parseJsonBatch(std.testing.allocator, missing_payload),
    );
}

test "stream identity derives the canonical event stream key" {
    const gpa = std.testing.allocator;

    const key = try sideshowdb.event.deriveStreamKey(gpa, .{
        .namespace = "default",
        .aggregate_type = "issue",
        .aggregate_id = "issue-1",
    });
    defer gpa.free(key);

    try std.testing.expectEqualStrings("default/issue/issue-1.jsonl", key);
}

test "stream identity rejects invalid key segments" {
    try std.testing.expectError(
        error.InvalidStreamIdentity,
        sideshowdb.event.validateStreamIdentity(.{
            .namespace = "default",
            .aggregate_type = "issue",
            .aggregate_id = "bad/id",
        }),
    );
}

fn oneEvent(id: []const u8) sideshowdb.event.EventEnvelope {
    return .{
        .event_id = id,
        .event_type = "IssueOpened",
        .namespace = "default",
        .aggregate_type = "issue",
        .aggregate_id = "issue-1",
        .timestamp = "2026-04-30T12:00:00Z",
        .payload_json = "{\"title\":\"First\"}",
    };
}

test "EventStore appends one event to an empty stream" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    const event = oneEvent("evt-1");
    const result = try store.append(std.testing.allocator, .{
        .identity = event.identity(),
        .expected_revision = 0,
        .events = &.{event},
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1), result.revision);

    var stream = try store.load(std.testing.allocator, event.identity());
    defer stream.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), stream.revision);
    try std.testing.expectEqualStrings("evt-1", stream.events[0].event_id);
}

test "EventStore appends batches in request order" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    var batch = try sideshowdb.event.parseJsonlBatch(std.testing.allocator, event_jsonl);
    defer batch.deinit(std.testing.allocator);

    const result = try store.append(std.testing.allocator, .{
        .identity = batch.identity,
        .expected_revision = 0,
        .events = batch.events,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), result.revision);

    var stream = try store.load(std.testing.allocator, batch.identity);
    defer stream.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("evt-1", stream.events[0].event_id);
    try std.testing.expectEqualStrings("evt-2", stream.events[1].event_id);
}

test "EventStore enforces expected revision" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    const event = oneEvent("evt-1");
    const first = try store.append(std.testing.allocator, .{
        .identity = event.identity(),
        .expected_revision = 0,
        .events = &.{event},
    });
    defer first.deinit(std.testing.allocator);

    const second = oneEvent("evt-2");
    try std.testing.expectError(error.WrongExpectedRevision, store.append(std.testing.allocator, .{
        .identity = second.identity(),
        .expected_revision = 0,
        .events = &.{second},
    }));

    const ok = try store.append(std.testing.allocator, .{
        .identity = second.identity(),
        .expected_revision = 1,
        .events = &.{second},
    });
    defer ok.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), ok.revision);
}

test "EventStore rejects duplicate event id already in stream" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    const event = oneEvent("evt-1");
    const first = try store.append(std.testing.allocator, .{
        .identity = event.identity(),
        .expected_revision = 0,
        .events = &.{event},
    });
    defer first.deinit(std.testing.allocator);

    try std.testing.expectError(error.DuplicateEventId, store.append(std.testing.allocator, .{
        .identity = event.identity(),
        .expected_revision = 1,
        .events = &.{event},
    }));
}

test "EventStore load missing stream returns empty stream" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    var stream = try store.load(std.testing.allocator, .{
        .namespace = "default",
        .aggregate_type = "issue",
        .aggregate_id = "missing",
    });
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 0), stream.revision);
    try std.testing.expectEqual(@as(usize, 0), stream.events.len);
}

test "EventStore loadFromRevision uses one-based revisions" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    var batch = try sideshowdb.event.parseJsonlBatch(std.testing.allocator, event_jsonl);
    defer batch.deinit(std.testing.allocator);
    const result = try store.append(std.testing.allocator, .{
        .identity = batch.identity,
        .expected_revision = 0,
        .events = batch.events,
    });
    defer result.deinit(std.testing.allocator);

    var stream = try store.loadFromRevision(std.testing.allocator, batch.identity, 2);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 2), stream.revision);
    try std.testing.expectEqual(@as(usize, 1), stream.events.len);
    try std.testing.expectEqualStrings("evt-2", stream.events[0].event_id);
}

test "EventStore rejects loadFromRevision zero" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    try std.testing.expectError(error.InvalidRevision, store.loadFromRevision(std.testing.allocator, .{
        .namespace = "default",
        .aggregate_type = "issue",
        .aggregate_id = "issue-1",
    }, 0));
}

test "EventStore appends without revision check when expected_revision is null" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    const first = oneEvent("evt-1");
    const r1 = try store.append(std.testing.allocator, .{
        .identity = first.identity(),
        .expected_revision = null,
        .events = &.{first},
    });
    defer r1.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), r1.revision);

    const second = oneEvent("evt-2");
    const r2 = try store.append(std.testing.allocator, .{
        .identity = second.identity(),
        .expected_revision = null,
        .events = &.{second},
    });
    defer r2.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), r2.revision);
}

test "EventStore rejects empty batch via append directly" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    try std.testing.expectError(error.EmptyBatch, store.append(std.testing.allocator, .{
        .identity = .{
            .namespace = "default",
            .aggregate_type = "issue",
            .aggregate_id = "issue-1",
        },
        .events = &.{},
    }));
}

test "EventStore rejects mixed stream batch via append directly" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    const e1 = oneEvent("evt-1");
    const e2: sideshowdb.event.EventEnvelope = .{
        .event_id = "evt-2",
        .event_type = "IssueOpened",
        .namespace = "default",
        .aggregate_type = "issue",
        .aggregate_id = "issue-2",
        .timestamp = "2026-04-30T12:01:00Z",
        .payload_json = "{}",
    };

    try std.testing.expectError(error.MixedStreamBatch, store.append(std.testing.allocator, .{
        .identity = e1.identity(),
        .events = &.{ e1, e2 },
    }));
}

test "EventStore rejects duplicate event_id in batch via append directly" {
    var memory = sideshowdb.MemoryRefStore.init(.{ .gpa = std.testing.allocator });
    defer memory.deinit();
    var store = sideshowdb.event.EventStore.init(memory.refStore());

    const e = oneEvent("evt-1");
    try std.testing.expectError(error.DuplicateEventId, store.append(std.testing.allocator, .{
        .identity = e.identity(),
        .events = &.{ e, e },
    }));
}

test "root module re-exports core event and snapshot store types" {
    _ = sideshowdb.EventStore;
    _ = sideshowdb.SnapshotStore;
    _ = sideshowdb.StreamIdentity;
    _ = sideshowdb.EventEnvelope;
}
