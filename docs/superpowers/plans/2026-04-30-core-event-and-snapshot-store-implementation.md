# Core Event And Snapshot Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first Zig core `EventStore` and `SnapshotStore` over existing `RefStore` backends.

**Architecture:** `EventStore` stores namespaced aggregate streams as canonical JSONL blobs under a caller-provided `RefStore` for `refs/sideshowdb/events`. `SnapshotStore` stores revision-addressed snapshot JSON blobs under a caller-provided `RefStore` for `refs/sideshowdb/snapshots`. Both layers stay backend-neutral and use `MemoryRefStore` in unit tests.

**Tech Stack:** Zig 0.16, `std.json`, `std.StringHashMapUnmanaged`, `RefStore`, `MemoryRefStore`, beads (`bd`).

---

## Context

Approved design:

- `docs/superpowers/specs/2026-04-30-event-and-snapshot-store-design.md`

Requirements:

- `docs/development/specs/event-and-snapshot-store-ears.md`

Tracking issue:

- `sideshowdb-yik`

Worktree:

- `.worktrees/core-event-snapshot-store`

## File Structure

- Modify `src/core/event.zig`
  - Replace the placeholder event type with stream identity, event envelope, batch parser helpers, append/load results, and `EventStore`.
  - Owns event JSON canonicalization, JSONL parsing, JSON batch parsing, stream key derivation, duplicate detection, and expected revision checks.
- Create `src/core/snapshot.zig`
  - Defines snapshot records, metadata, requests/results, key derivation, canonicalization, conflict detection, and `SnapshotStore`.
- Modify `src/core/root.zig`
  - Re-export `event`, `EventStore`, `StreamIdentity`, `EventEnvelope`, `snapshot`, and `SnapshotStore`.
  - Update top module docs so they no longer describe event support as a placeholder.
- Create `tests/event_store_test.zig`
  - Drives `EventStore` through `MemoryRefStore`.
  - Covers EARS `EVT-STORE-001` through `EVT-STORE-019`.
- Create `tests/snapshot_store_test.zig`
  - Drives `SnapshotStore` through `MemoryRefStore`.
  - Covers EARS `SNAP-STORE-001` through `SNAP-STORE-013`.
- Modify `build.zig`
  - Register and run the two new test modules in `zig build test`.
- Modify `docs/superpowers/specs/2026-04-30-event-and-snapshot-store-design.md`
  - Change status from `Proposed` to `Approved`.

## Task 1: Event Identity, Envelope, And Batch Parsers

**Files:**

- Modify: `src/core/event.zig`
- Create: `tests/event_store_test.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write failing event parser and identity tests**

Create `tests/event_store_test.zig` with these initial tests:

```zig
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
```

- [ ] **Step 2: Wire the event tests into `build.zig`**

Add this block after `run_document_tests` is created:

```zig
    const event_store_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/event_store_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
        },
    });
    const event_store_tests = b.addTest(.{ .root_module = event_store_test_mod });
    const run_event_store_tests = b.addRunArtifact(event_store_tests);
```

Add this dependency near the other test dependencies:

```zig
    test_step.dependOn(&run_event_store_tests.step);
```

- [ ] **Step 3: Run the failing tests**

Run:

```bash
zig build test
```

Expected: failure because `parseJsonlBatch`, `parseJsonBatch`, `deriveStreamKey`, and `validateStreamIdentity` are not defined yet.

- [ ] **Step 4: Replace the placeholder event module**

Replace `src/core/event.zig` with this implementation skeleton and parser logic:

```zig
//! Core event store primitives layered over `RefStore`.

const std = @import("std");
const RefStore = @import("storage/ref_store.zig").RefStore;

const Allocator = std.mem.Allocator;

/// Logical identity of one append-only event stream.
pub const StreamIdentity = struct {
    namespace: []const u8,
    aggregate_type: []const u8,
    aggregate_id: []const u8,
};

/// One validated event envelope. String slices and JSON payload strings are
/// owned by the enclosing `ParsedEventBatch` or `EventStream`.
pub const EventEnvelope = struct {
    event_id: []const u8,
    event_type: []const u8,
    namespace: []const u8,
    aggregate_type: []const u8,
    aggregate_id: []const u8,
    timestamp: []const u8,
    payload_json: []const u8,
    metadata_json: ?[]const u8 = null,

    /// Return this event's stream identity as borrowed slices.
    pub fn identity(self: EventEnvelope) StreamIdentity {
        return .{
            .namespace = self.namespace,
            .aggregate_type = self.aggregate_type,
            .aggregate_id = self.aggregate_id,
        };
    }
};

/// Parsed single-stream batch. Owns all event strings.
pub const ParsedEventBatch = struct {
    identity: StreamIdentity,
    events: []EventEnvelope,
    arena: std.heap.ArenaAllocator,

    /// Release all memory owned by the parsed batch.
    pub fn deinit(self: *ParsedEventBatch, gpa: Allocator) void {
        _ = gpa;
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Loaded event stream. Owns all event strings.
pub const EventStream = struct {
    identity: StreamIdentity,
    events: []EventEnvelope,
    revision: u64,
    arena: std.heap.ArenaAllocator,

    /// Release all memory owned by the loaded stream.
    pub fn deinit(self: *EventStream, gpa: Allocator) void {
        _ = gpa;
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Append request accepted by `EventStore`.
pub const AppendRequest = struct {
    identity: StreamIdentity,
    expected_revision: ?u64 = null,
    events: []const EventEnvelope,
};

/// Result of a successful append.
pub const AppendResult = struct {
    revision: u64,
    version: RefStore.VersionId,

    /// Release allocator-owned result fields.
    pub fn deinit(self: AppendResult, gpa: Allocator) void {
        gpa.free(self.version);
    }
};

/// Validate stream identity fields before key derivation or storage I/O.
pub fn validateStreamIdentity(identity: StreamIdentity) error{InvalidStreamIdentity}!void {
    try validateSegment(identity.namespace);
    try validateSegment(identity.aggregate_type);
    try validateSegment(identity.aggregate_id);
}

fn validateSegment(segment: []const u8) error{InvalidStreamIdentity}!void {
    if (segment.len == 0) return error.InvalidStreamIdentity;
    if (std.mem.indexOfScalar(u8, segment, '/') != null) return error.InvalidStreamIdentity;
    if (std.mem.indexOfScalar(u8, segment, 0) != null) return error.InvalidStreamIdentity;
}

/// Derive the canonical `RefStore` key for an event stream.
pub fn deriveStreamKey(gpa: Allocator, identity: StreamIdentity) ![]u8 {
    try validateStreamIdentity(identity);
    return std.fmt.allocPrint(
        gpa,
        "{s}/{s}/{s}.jsonl",
        .{ identity.namespace, identity.aggregate_type, identity.aggregate_id },
    );
}

/// Parse line-oriented JSONL into a validated single-stream batch.
pub fn parseJsonlBatch(gpa: Allocator, bytes: []const u8) !ParsedEventBatch {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var events: std.ArrayList(EventEnvelope) = .empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        try events.append(aa, try parseEnvelope(aa, line));
    }

    return finishParsedBatch(gpa, &arena, &events);
}

/// Parse a JSON object containing an `events` array into a validated batch.
pub fn parseJsonBatch(gpa: Allocator, bytes: []const u8) !ParsedEventBatch {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, bytes, .{});
    if (parsed.value != .object) return error.InvalidEvent;
    const raw_events = parsed.value.object.get("events") orelse return error.EmptyBatch;
    if (raw_events != .array) return error.InvalidEvent;

    var events: std.ArrayList(EventEnvelope) = .empty;
    for (raw_events.array.items) |item| {
        try events.append(aa, try envelopeFromValue(aa, item));
    }

    return finishParsedBatch(gpa, &arena, &events);
}

fn finishParsedBatch(
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    events: *std.ArrayList(EventEnvelope),
) !ParsedEventBatch {
    _ = gpa;
    if (events.items.len == 0) return error.EmptyBatch;
    const identity = events.items[0].identity();
    try validateStreamIdentity(identity);

    var seen: std.StringHashMapUnmanaged(void) = .{};
    for (events.items) |event| {
        if (!sameIdentity(identity, event.identity())) return error.MixedStreamBatch;
        const gop = try seen.getOrPut(arena.allocator(), event.event_id);
        if (gop.found_existing) return error.DuplicateEventId;
    }

    return .{
        .identity = identity,
        .events = try events.toOwnedSlice(arena.allocator()),
        .arena = arena.*,
    };
}

fn parseEnvelope(aa: Allocator, bytes: []const u8) !EventEnvelope {
    var parsed = try std.json.parseFromSlice(std.json.Value, aa, bytes, .{});
    return envelopeFromValue(aa, parsed.value);
}

fn envelopeFromValue(aa: Allocator, value: std.json.Value) !EventEnvelope {
    if (value != .object) return error.InvalidEvent;
    const object = value.object;

    const event_id = try requiredString(object, "event_id");
    const event_type = try requiredString(object, "event_type");
    const namespace = try requiredString(object, "namespace");
    const aggregate_type = try requiredString(object, "aggregate_type");
    const aggregate_id = try requiredString(object, "aggregate_id");
    const timestamp = try requiredString(object, "timestamp");
    const payload = object.get("payload") orelse return error.InvalidEvent;
    const metadata = object.get("metadata");

    var payload_writer: std.Io.Writer.Allocating = .init(aa);
    try std.json.Stringify.value(payload, .{ .writer = &payload_writer.writer });
    const payload_json = try payload_writer.toOwnedSlice();

    var metadata_json: ?[]const u8 = null;
    if (metadata) |metadata_value| {
        var metadata_writer: std.Io.Writer.Allocating = .init(aa);
        try std.json.Stringify.value(metadata_value, .{ .writer = &metadata_writer.writer });
        metadata_json = try metadata_writer.toOwnedSlice();
    }

    const envelope: EventEnvelope = .{
        .event_id = try aa.dupe(u8, event_id),
        .event_type = try aa.dupe(u8, event_type),
        .namespace = try aa.dupe(u8, namespace),
        .aggregate_type = try aa.dupe(u8, aggregate_type),
        .aggregate_id = try aa.dupe(u8, aggregate_id),
        .timestamp = try aa.dupe(u8, timestamp),
        .payload_json = payload_json,
        .metadata_json = metadata_json,
    };
    try validateEvent(envelope);
    return envelope;
}

fn requiredString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.InvalidEvent;
    return switch (value) {
        .string => |s| s,
        else => error.InvalidEvent,
    };
}

fn validateEvent(event: EventEnvelope) !void {
    if (event.event_id.len == 0) return error.InvalidEvent;
    if (event.event_type.len == 0) return error.InvalidEvent;
    if (event.timestamp.len == 0) return error.InvalidEvent;
    validateStreamIdentity(event.identity()) catch return error.InvalidStreamIdentity;
}

fn sameIdentity(lhs: StreamIdentity, rhs: StreamIdentity) bool {
    return std.mem.eql(u8, lhs.namespace, rhs.namespace) and
        std.mem.eql(u8, lhs.aggregate_type, rhs.aggregate_type) and
        std.mem.eql(u8, lhs.aggregate_id, rhs.aggregate_id);
}
```

- [ ] **Step 5: Run parser tests**

Run:

```bash
zig build test
```

Expected: the new parser tests pass or reveal minor Zig API adjustments. Fix only compile/API mismatches needed for Task 1.

- [ ] **Step 6: Commit Task 1**

Run:

```bash
git add src/core/event.zig tests/event_store_test.zig build.zig
git commit -m "feat(eventstore): parse event batches"
```

## Task 2: EventStore Append And Load

**Files:**

- Modify: `src/core/event.zig`
- Modify: `tests/event_store_test.zig`

- [ ] **Step 1: Add failing EventStore append/load tests**

Append these tests to `tests/event_store_test.zig`:

```zig
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
```

- [ ] **Step 2: Run tests to confirm EventStore is missing**

Run:

```bash
zig build test
```

Expected: compile failure because `EventStore` is not defined.

- [ ] **Step 3: Implement EventStore append/load**

Add this to `src/core/event.zig` after `AppendResult`:

```zig
/// Append-only event stream store over a `RefStore`.
pub const EventStore = struct {
    ref_store: RefStore,

    /// Build an event store over a caller-owned `RefStore`.
    pub fn init(ref_store: RefStore) EventStore {
        return .{ .ref_store = ref_store };
    }

    /// Append one single-stream batch after duplicate and revision checks.
    pub fn append(self: EventStore, gpa: Allocator, request: AppendRequest) !AppendResult {
        if (request.events.len == 0) return error.EmptyBatch;
        try validateStreamIdentity(request.identity);
        try validateAppendEvents(request.identity, request.events);

        const key = try deriveStreamKey(gpa, request.identity);
        defer gpa.free(key);

        var existing = try self.load(gpa, request.identity);
        defer existing.deinit(gpa);

        if (request.expected_revision) |expected| {
            if (existing.revision != expected) return error.WrongExpectedRevision;
        }

        try rejectExistingDuplicates(gpa, existing.events, request.events);

        const encoded = try encodeStream(gpa, existing.events, request.events);
        defer gpa.free(encoded);

        const version = try self.ref_store.put(gpa, key, encoded);
        return .{
            .revision = existing.revision + @as(u64, @intCast(request.events.len)),
            .version = version,
        };
    }

    /// Load all events for one stream. Missing streams return an empty stream.
    pub fn load(self: EventStore, gpa: Allocator, identity: StreamIdentity) !EventStream {
        return self.loadFromRevision(gpa, identity, 1);
    }

    /// Load events whose one-based revision is at least `start_revision`.
    pub fn loadFromRevision(
        self: EventStore,
        gpa: Allocator,
        identity: StreamIdentity,
        start_revision: u64,
    ) !EventStream {
        if (start_revision == 0) return error.InvalidRevision;
        try validateStreamIdentity(identity);

        const key = try deriveStreamKey(gpa, identity);
        defer gpa.free(key);

        const read = try self.ref_store.get(gpa, key, null);
        defer if (read) |result| RefStore.freeReadResult(gpa, result);

        if (read == null) return emptyStream(gpa, identity);

        var parsed = try parseJsonlBatch(gpa, read.?.value);
        errdefer parsed.deinit(gpa);

        if (!sameIdentity(identity, parsed.identity)) return error.InvalidEvent;

        const skip: usize = if (start_revision <= 1) 0 else @intCast(start_revision - 1);
        if (skip >= parsed.events.len) {
            const revision: u64 = @intCast(parsed.events.len);
            parsed.deinit(gpa);
            var arena = std.heap.ArenaAllocator.init(gpa);
            const aa = arena.allocator();
            return .{
                .identity = try cloneIdentity(aa, identity),
                .events = try aa.alloc(EventEnvelope, 0),
                .revision = revision,
                .arena = arena,
            };
        }

        const revision: u64 = @intCast(parsed.events.len);
        const selected = parsed.events[skip..];
        const owned = try parsed.arena.allocator().dupe(EventEnvelope, selected);
        parsed.events = owned;
        return .{
            .identity = parsed.identity,
            .events = parsed.events,
            .revision = revision,
            .arena = parsed.arena,
        };
    }
};
```

Add these helpers near the bottom of `src/core/event.zig`:

```zig
fn validateAppendEvents(identity: StreamIdentity, events: []const EventEnvelope) !void {
    var seen = std.StringHashMapUnmanaged(void){};
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    for (events) |event| {
        try validateEvent(event);
        if (!sameIdentity(identity, event.identity())) return error.MixedStreamBatch;
        const gop = try seen.getOrPut(arena.allocator(), event.event_id);
        if (gop.found_existing) return error.DuplicateEventId;
    }
}

fn rejectExistingDuplicates(
    gpa: Allocator,
    existing: []const EventEnvelope,
    incoming: []const EventEnvelope,
) !void {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(gpa);
    for (existing) |event| {
        try seen.put(gpa, event.event_id, {});
    }
    for (incoming) |event| {
        if (seen.contains(event.event_id)) return error.DuplicateEventId;
    }
}

fn encodeStream(
    gpa: Allocator,
    existing: []const EventEnvelope,
    incoming: []const EventEnvelope,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (existing) |event| try writeEventJsonl(&out.writer, event);
    for (incoming) |event| try writeEventJsonl(&out.writer, event);
    return out.toOwnedSlice();
}

fn writeEventJsonl(writer: *std.Io.Writer, event: EventEnvelope) !void {
    try writer.writeAll("{\"event_id\":");
    try std.json.Stringify.value(event.event_id, .{ .writer = writer });
    try writer.writeAll(",\"event_type\":");
    try std.json.Stringify.value(event.event_type, .{ .writer = writer });
    try writer.writeAll(",\"namespace\":");
    try std.json.Stringify.value(event.namespace, .{ .writer = writer });
    try writer.writeAll(",\"aggregate_type\":");
    try std.json.Stringify.value(event.aggregate_type, .{ .writer = writer });
    try writer.writeAll(",\"aggregate_id\":");
    try std.json.Stringify.value(event.aggregate_id, .{ .writer = writer });
    try writer.writeAll(",\"timestamp\":");
    try std.json.Stringify.value(event.timestamp, .{ .writer = writer });
    try writer.writeAll(",\"payload\":");
    try writer.writeAll(event.payload_json);
    if (event.metadata_json) |metadata_json| {
        try writer.writeAll(",\"metadata\":");
        try writer.writeAll(metadata_json);
    }
    try writer.writeAll("}\n");
}

fn emptyStream(gpa: Allocator, identity: StreamIdentity) !EventStream {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();
    return .{
        .identity = try cloneIdentity(aa, identity),
        .events = try aa.alloc(EventEnvelope, 0),
        .revision = 0,
        .arena = arena,
    };
}

fn cloneIdentity(aa: Allocator, identity: StreamIdentity) !StreamIdentity {
    return .{
        .namespace = try aa.dupe(u8, identity.namespace),
        .aggregate_type = try aa.dupe(u8, identity.aggregate_type),
        .aggregate_id = try aa.dupe(u8, identity.aggregate_id),
    };
}
```

If Zig rejects `std.heap.page_allocator` in `validateAppendEvents`, change the helper signature to accept `gpa` and call it as `try validateAppendEvents(gpa, request.identity, request.events)`.

- [ ] **Step 4: Run EventStore tests**

Run:

```bash
zig build test
```

Expected: all event tests pass after small Zig API corrections.

- [ ] **Step 5: Commit Task 2**

Run:

```bash
git add src/core/event.zig tests/event_store_test.zig
git commit -m "feat(eventstore): append and load streams"
```

## Task 3: SnapshotStore

**Files:**

- Create: `src/core/snapshot.zig`
- Create: `tests/snapshot_store_test.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write failing snapshot tests**

Create `tests/snapshot_store_test.zig`:

```zig
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
```

- [ ] **Step 2: Wire snapshot tests into `build.zig`**

Add this block after the event store test module:

```zig
    const snapshot_store_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/snapshot_store_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
        },
    });
    const snapshot_store_tests = b.addTest(.{ .root_module = snapshot_store_test_mod });
    const run_snapshot_store_tests = b.addRunArtifact(snapshot_store_tests);
```

Add this dependency:

```zig
    test_step.dependOn(&run_snapshot_store_tests.step);
```

- [ ] **Step 3: Run tests to confirm SnapshotStore is missing**

Run:

```bash
zig build test
```

Expected: compile failure because `sideshowdb.snapshot` is not exported and `src/core/snapshot.zig` does not exist.

- [ ] **Step 4: Implement `src/core/snapshot.zig`**

Create `src/core/snapshot.zig` with:

```zig
//! Core snapshot store primitives layered over `RefStore`.

const std = @import("std");
const event = @import("event.zig");
const RefStore = @import("storage/ref_store.zig").RefStore;

const Allocator = std.mem.Allocator;

/// One stored snapshot record.
pub const SnapshotRecord = struct {
    namespace: []const u8,
    aggregate_type: []const u8,
    aggregate_id: []const u8,
    revision: u64,
    up_to_event_id: []const u8,
    state_json: []const u8,
    metadata_json: ?[]const u8 = null,

    /// Release fields owned by records returned from `SnapshotStore`.
    pub fn deinit(self: SnapshotRecord, gpa: Allocator) void {
        gpa.free(self.namespace);
        gpa.free(self.aggregate_type);
        gpa.free(self.aggregate_id);
        gpa.free(self.up_to_event_id);
        gpa.free(self.state_json);
        if (self.metadata_json) |metadata_json| gpa.free(metadata_json);
    }

    /// Return the event stream identity for this snapshot.
    pub fn identity(self: SnapshotRecord) event.StreamIdentity {
        return .{
            .namespace = self.namespace,
            .aggregate_type = self.aggregate_type,
            .aggregate_id = self.aggregate_id,
        };
    }
};

/// Metadata returned when listing snapshots.
pub const SnapshotMetadata = struct {
    namespace: []u8,
    aggregate_type: []u8,
    aggregate_id: []u8,
    revision: u64,
    up_to_event_id: []u8,
};

/// Put request for one snapshot.
pub const PutSnapshotRequest = struct {
    identity: event.StreamIdentity,
    record: SnapshotRecord,
};

/// Result of a successful snapshot write.
pub const SnapshotWriteResult = struct {
    revision: u64,
    version: RefStore.VersionId,
    idempotent: bool,

    /// Release allocator-owned result fields.
    pub fn deinit(self: SnapshotWriteResult, gpa: Allocator) void {
        gpa.free(self.version);
    }
};

/// Free a list returned by `SnapshotStore.list`.
pub fn freeSnapshotMetadataList(gpa: Allocator, items: []SnapshotMetadata) void {
    for (items) |item| {
        gpa.free(item.namespace);
        gpa.free(item.aggregate_type);
        gpa.free(item.aggregate_id);
        gpa.free(item.up_to_event_id);
    }
    gpa.free(items);
}

/// Revision-addressed snapshot store over a `RefStore`.
pub const SnapshotStore = struct {
    ref_store: RefStore,

    /// Build a snapshot store over a caller-owned `RefStore`.
    pub fn init(ref_store: RefStore) SnapshotStore {
        return .{ .ref_store = ref_store };
    }

    /// Store one snapshot. Existing identical content is idempotent;
    /// conflicting content for the same revision is rejected.
    pub fn put(self: SnapshotStore, gpa: Allocator, request: PutSnapshotRequest) !SnapshotWriteResult {
        try validateRecord(request.identity, request.record);
        const key = try deriveSnapshotKey(gpa, request.identity, request.record.revision);
        defer gpa.free(key);

        const encoded = try encodeSnapshot(gpa, request.record);
        defer gpa.free(encoded);

        const existing = try self.ref_store.get(gpa, key, null);
        defer if (existing) |read| RefStore.freeReadResult(gpa, read);
        if (existing) |read| {
            if (!std.mem.eql(u8, read.value, encoded)) return error.SnapshotConflict;
            return .{
                .revision = request.record.revision,
                .version = try gpa.dupe(u8, read.version),
                .idempotent = true,
            };
        }

        const version = try self.ref_store.put(gpa, key, encoded);
        return .{
            .revision = request.record.revision,
            .version = version,
            .idempotent = false,
        };
    }

    /// Return the highest-revision snapshot for `identity`.
    pub fn getLatest(self: SnapshotStore, gpa: Allocator, identity: event.StreamIdentity) !?SnapshotRecord {
        const items = try self.list(gpa, identity);
        defer freeSnapshotMetadataList(gpa, items);
        if (items.len == 0) return null;
        return self.getExact(gpa, identity, items[0].revision);
    }

    /// Return the highest snapshot revision less than or equal to `revision`.
    pub fn getAtOrBefore(self: SnapshotStore, gpa: Allocator, identity: event.StreamIdentity, revision: u64) !?SnapshotRecord {
        const items = try self.list(gpa, identity);
        defer freeSnapshotMetadataList(gpa, items);
        for (items) |item| {
            if (item.revision <= revision) return self.getExact(gpa, identity, item.revision);
        }
        return null;
    }

    /// List snapshot metadata newest-first by revision.
    pub fn list(self: SnapshotStore, gpa: Allocator, identity: event.StreamIdentity) ![]SnapshotMetadata {
        try event.validateStreamIdentity(identity);
        const prefix = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}/", .{
            identity.namespace,
            identity.aggregate_type,
            identity.aggregate_id,
        });
        defer gpa.free(prefix);

        const keys = try self.ref_store.list(gpa);
        defer RefStore.freeKeys(gpa, keys);

        var out: std.ArrayList(SnapshotMetadata) = .empty;
        errdefer freeSnapshotMetadataList(gpa, out.items);

        for (keys) |key| {
            if (!std.mem.startsWith(u8, key, prefix)) continue;
            const revision = parseRevisionFromKey(key[prefix.len..]) catch continue;
            const record = (try self.getExact(gpa, identity, revision)) orelse continue;
            defer record.deinit(gpa);
            try out.append(gpa, .{
                .namespace = try gpa.dupe(u8, record.namespace),
                .aggregate_type = try gpa.dupe(u8, record.aggregate_type),
                .aggregate_id = try gpa.dupe(u8, record.aggregate_id),
                .revision = record.revision,
                .up_to_event_id = try gpa.dupe(u8, record.up_to_event_id),
            });
        }

        std.sort.block(SnapshotMetadata, out.items, {}, struct {
            fn lessThan(_: void, lhs: SnapshotMetadata, rhs: SnapshotMetadata) bool {
                return lhs.revision > rhs.revision;
            }
        }.lessThan);

        return out.toOwnedSlice(gpa);
    }

    fn getExact(self: SnapshotStore, gpa: Allocator, identity: event.StreamIdentity, revision: u64) !?SnapshotRecord {
        const key = try deriveSnapshotKey(gpa, identity, revision);
        defer gpa.free(key);
        const read = try self.ref_store.get(gpa, key, null);
        defer if (read) |result| RefStore.freeReadResult(gpa, result);
        if (read == null) return null;
        return parseSnapshot(gpa, read.?.value);
    }
};

/// Derive the canonical snapshot key.
pub fn deriveSnapshotKey(gpa: Allocator, identity: event.StreamIdentity, revision: u64) ![]u8 {
    try event.validateStreamIdentity(identity);
    if (revision == 0) return error.InvalidSnapshot;
    return std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{d}.json", .{
        identity.namespace,
        identity.aggregate_type,
        identity.aggregate_id,
        revision,
    });
}

fn validateRecord(identity: event.StreamIdentity, record: SnapshotRecord) !void {
    try event.validateStreamIdentity(identity);
    if (record.revision == 0) return error.InvalidSnapshot;
    if (record.up_to_event_id.len == 0) return error.InvalidSnapshot;
    if (!std.mem.eql(u8, identity.namespace, record.namespace)) return error.InvalidSnapshot;
    if (!std.mem.eql(u8, identity.aggregate_type, record.aggregate_type)) return error.InvalidSnapshot;
    if (!std.mem.eql(u8, identity.aggregate_id, record.aggregate_id)) return error.InvalidSnapshot;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = std.json.parseFromSlice(std.json.Value, arena.allocator(), record.state_json, .{}) catch return error.InvalidSnapshot;
}

fn encodeSnapshot(gpa: Allocator, record: SnapshotRecord) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"namespace\":");
    try std.json.Stringify.value(record.namespace, .{ .writer = &out.writer });
    try out.writer.writeAll(",\"aggregate_type\":");
    try std.json.Stringify.value(record.aggregate_type, .{ .writer = &out.writer });
    try out.writer.writeAll(",\"aggregate_id\":");
    try std.json.Stringify.value(record.aggregate_id, .{ .writer = &out.writer });
    try out.writer.print(",\"revision\":{d}", .{record.revision});
    try out.writer.writeAll(",\"up_to_event_id\":");
    try std.json.Stringify.value(record.up_to_event_id, .{ .writer = &out.writer });
    try out.writer.writeAll(",\"state\":");
    try out.writer.writeAll(record.state_json);
    if (record.metadata_json) |metadata_json| {
        try out.writer.writeAll(",\"metadata\":");
        try out.writer.writeAll(metadata_json);
    }
    try out.writer.writeAll("}");
    return out.toOwnedSlice();
}

fn parseSnapshot(gpa: Allocator, bytes: []const u8) !SnapshotRecord {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSnapshot;
    const object = parsed.value.object;
    const revision_value = object.get("revision") orelse return error.InvalidSnapshot;
    const revision: u64 = switch (revision_value) {
        .integer => |n| std.math.cast(u64, n) orelse return error.InvalidSnapshot,
        else => return error.InvalidSnapshot,
    };
    const state = object.get("state") orelse return error.InvalidSnapshot;
    var state_writer: std.Io.Writer.Allocating = .init(gpa);
    defer state_writer.deinit();
    try std.json.Stringify.value(state, .{ .writer = &state_writer.writer });
    return .{
        .namespace = try gpa.dupe(u8, try requiredString(object, "namespace")),
        .aggregate_type = try gpa.dupe(u8, try requiredString(object, "aggregate_type")),
        .aggregate_id = try gpa.dupe(u8, try requiredString(object, "aggregate_id")),
        .revision = revision,
        .up_to_event_id = try gpa.dupe(u8, try requiredString(object, "up_to_event_id")),
        .state_json = try state_writer.toOwnedSlice(),
        .metadata_json = null,
    };
}

fn requiredString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.InvalidSnapshot;
    return switch (value) {
        .string => |s| s,
        else => error.InvalidSnapshot,
    };
}

fn parseRevisionFromKey(file_name: []const u8) !u64 {
    if (!std.mem.endsWith(u8, file_name, ".json")) return error.InvalidSnapshot;
    return std.fmt.parseInt(u64, file_name[0 .. file_name.len - ".json".len], 10);
}
```

- [ ] **Step 5: Run snapshot tests**

Run:

```bash
zig build test
```

Expected: snapshot tests pass after Zig API corrections.

- [ ] **Step 6: Commit Task 3**

Run:

```bash
git add src/core/snapshot.zig tests/snapshot_store_test.zig build.zig
git commit -m "feat(snapshotstore): store revision snapshots"
```

## Task 4: Public Core Re-Exports And Documentation Status

**Files:**

- Modify: `src/core/root.zig`
- Modify: `docs/superpowers/specs/2026-04-30-event-and-snapshot-store-design.md`

- [ ] **Step 1: Add failing root export checks**

Add this test to `tests/event_store_test.zig`:

```zig
test "root module re-exports core event and snapshot store types" {
    _ = sideshowdb.EventStore;
    _ = sideshowdb.SnapshotStore;
    _ = sideshowdb.StreamIdentity;
    _ = sideshowdb.EventEnvelope;
}
```

- [ ] **Step 2: Run tests to confirm exports are missing**

Run:

```bash
zig build test
```

Expected: compile failure for missing root exports.

- [ ] **Step 3: Update `src/core/root.zig` exports and docs**

Change the file header to:

```zig
//! Core sideshowdb library.
//!
//! This module exposes the shared storage abstractions plus the first core
//! document, event, and snapshot stores used by native, WASM, and binding
//! surfaces.
```

Replace the old event re-export block with:

```zig
/// Event store types and helpers. See `event.zig`.
pub const event = @import("event.zig");

/// Convenience re-export of `event.StreamIdentity`.
pub const StreamIdentity = event.StreamIdentity;

/// Convenience re-export of `event.EventEnvelope`.
pub const EventEnvelope = event.EventEnvelope;

/// Convenience re-export of `event.EventStore`.
pub const EventStore = event.EventStore;

/// Snapshot store types and helpers. See `snapshot.zig`.
pub const snapshot = @import("snapshot.zig");

/// Convenience re-export of `snapshot.SnapshotStore`.
pub const SnapshotStore = snapshot.SnapshotStore;
```

Update the `test` block to include:

```zig
    _ = snapshot;
```

- [ ] **Step 4: Mark the design as approved**

In `docs/superpowers/specs/2026-04-30-event-and-snapshot-store-design.md`, change:

```markdown
Status: Proposed
```

to:

```markdown
Status: Approved
```

- [ ] **Step 5: Run root export tests**

Run:

```bash
zig build test
zig build check:core-docs
```

Expected: both commands pass.

- [ ] **Step 6: Commit Task 4**

Run:

```bash
git add src/core/root.zig docs/superpowers/specs/2026-04-30-event-and-snapshot-store-design.md tests/event_store_test.zig
git commit -m "feat(core): export event and snapshot stores"
```

## Task 5: Final Verification And Beads Update

**Files:**

- Modify: `.beads/issues.jsonl` through `bd`

- [ ] **Step 1: Run the full verification suite**

Run:

```bash
zig build test
zig build wasm
zig build check:core-docs
git diff --check HEAD
```

Expected:

- `zig build test` exits `0`
- `zig build wasm` exits `0`
- `zig build check:core-docs` prints `ok: every public declaration under src/core has a /// doc-comment.`
- `git diff --check HEAD` exits `0`

- [ ] **Step 2: Confirm requirements coverage**

Run:

```bash
rg -n "EVT-STORE-|SNAP-STORE-" docs/development/specs/event-and-snapshot-store-ears.md
rg -n "expected revision|DuplicateEventId|SnapshotConflict|newest-first" tests/event_store_test.zig tests/snapshot_store_test.zig
```

Expected: every EARS identifier remains in the requirements file, and tests mention the core behaviors from the approved design.

- [ ] **Step 3: Update beads issue notes**

Run:

```bash
bd update sideshowdb-yik --notes "Implemented core EventStore and SnapshotStore over RefStore. Verification: zig build test; zig build wasm; zig build check:core-docs; git diff --check HEAD. Follow-up epic remains sideshowdb-asz." --json
```

- [ ] **Step 4: Close the implementation issue**

Run:

```bash
bd close sideshowdb-yik --reason "Implemented core EventStore and SnapshotStore over RefStore with tests and requirements coverage." --json
```

- [ ] **Step 5: Commit beads update**

Run:

```bash
git add .beads/issues.jsonl
git commit -m "chore(beads): close core event store issue"
```

- [ ] **Step 6: Push code and beads state**

Run:

```bash
git pull --rebase
bd dolt push
git push
git status --short --branch
```

Expected: the branch is up to date with `origin/feature/core-event-snapshot-store` and the worktree has no uncommitted files.

## Self-Review Checklist

- `EVT-STORE-001` through `EVT-STORE-019` map to Task 1 and Task 2.
- `SNAP-STORE-001` through `SNAP-STORE-013` map to Task 3.
- The public re-export requirement implied by core usability maps to Task 4.
- No CLI, WASM, TypeScript, projection, upcaster, indexing, cross-stream, or remote-sync work is implemented in this plan; those are tracked by `sideshowdb-asz` follow-ups.
- Every task has a fresh test command and a commit checkpoint.
