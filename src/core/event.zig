//! Core event store primitives layered over `RefStore`.

const std = @import("std");
const RefStore = @import("storage/ref_store.zig").RefStore;

const Allocator = std.mem.Allocator;

/// Legacy compatibility event shape for existing cross-module tests.
pub const Event = struct {
    event_id: []const u8,
    event_type: []const u8,
    aggregate_id: []const u8,
    timestamp_ms: i64,

    /// Build an `Event` from raw fields.
    pub fn init(
        event_id: []const u8,
        event_type: []const u8,
        aggregate_id: []const u8,
        timestamp_ms: i64,
    ) Event {
        return .{
            .event_id = event_id,
            .event_type = event_type,
            .aggregate_id = aggregate_id,
            .timestamp_ms = timestamp_ms,
        };
    }
};

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
        try validateAppendEvents(gpa, request.identity, request.events);

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
    const parsed = try std.json.parseFromSlice(std.json.Value, aa, bytes, .{});
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
    try std.json.Stringify.value(payload, .{}, &payload_writer.writer);
    const payload_json = try payload_writer.toOwnedSlice();

    var metadata_json: ?[]const u8 = null;
    if (metadata) |metadata_value| {
        var metadata_writer: std.Io.Writer.Allocating = .init(aa);
        try std.json.Stringify.value(metadata_value, .{}, &metadata_writer.writer);
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

fn validateAppendEvents(gpa: Allocator, identity: StreamIdentity, events: []const EventEnvelope) !void {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(gpa);
    for (events) |event| {
        try validateEvent(event);
        if (!sameIdentity(identity, event.identity())) return error.MixedStreamBatch;
        const gop = try seen.getOrPut(gpa, event.event_id);
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
    try std.json.Stringify.value(event.event_id, .{}, writer);
    try writer.writeAll(",\"event_type\":");
    try std.json.Stringify.value(event.event_type, .{}, writer);
    try writer.writeAll(",\"namespace\":");
    try std.json.Stringify.value(event.namespace, .{}, writer);
    try writer.writeAll(",\"aggregate_type\":");
    try std.json.Stringify.value(event.aggregate_type, .{}, writer);
    try writer.writeAll(",\"aggregate_id\":");
    try std.json.Stringify.value(event.aggregate_id, .{}, writer);
    try writer.writeAll(",\"timestamp\":");
    try std.json.Stringify.value(event.timestamp, .{}, writer);
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
