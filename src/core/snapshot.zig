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

        const put_result = try self.ref_store.put(gpa, key, encoded);
        errdefer RefStore.freePutResult(gpa, put_result);
        defer if (put_result.tree_sha) |sha| gpa.free(sha);
        return .{
            .revision = request.record.revision,
            .version = put_result.version,
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
        return try parseSnapshot(gpa, read.?.value);
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
    try std.json.Stringify.value(record.namespace, .{}, &out.writer);
    try out.writer.writeAll(",\"aggregate_type\":");
    try std.json.Stringify.value(record.aggregate_type, .{}, &out.writer);
    try out.writer.writeAll(",\"aggregate_id\":");
    try std.json.Stringify.value(record.aggregate_id, .{}, &out.writer);
    try out.writer.print(",\"revision\":{d}", .{record.revision});
    try out.writer.writeAll(",\"up_to_event_id\":");
    try std.json.Stringify.value(record.up_to_event_id, .{}, &out.writer);
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
    try std.json.Stringify.value(state, .{}, &state_writer.writer);

    var metadata_json: ?[]const u8 = null;
    if (object.get("metadata")) |metadata_value| {
        var metadata_writer: std.Io.Writer.Allocating = .init(gpa);
        defer metadata_writer.deinit();
        try std.json.Stringify.value(metadata_value, .{}, &metadata_writer.writer);
        metadata_json = try metadata_writer.toOwnedSlice();
    }

    return .{
        .namespace = try gpa.dupe(u8, try requiredString(object, "namespace")),
        .aggregate_type = try gpa.dupe(u8, try requiredString(object, "aggregate_type")),
        .aggregate_id = try gpa.dupe(u8, try requiredString(object, "aggregate_id")),
        .revision = revision,
        .up_to_event_id = try gpa.dupe(u8, try requiredString(object, "up_to_event_id")),
        .state_json = try state_writer.toOwnedSlice(),
        .metadata_json = metadata_json,
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
