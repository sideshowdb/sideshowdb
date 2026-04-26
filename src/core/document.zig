const std = @import("std");
const RefStore = @import("storage/ref_store.zig").RefStore;

const Allocator = std.mem.Allocator;

pub const default_namespace = "default";

pub const Identity = struct {
    namespace: []const u8 = default_namespace,
    doc_type: []const u8,
    id: []const u8,
};

pub const PutRequest = union(enum) {
    /// Raw JSON payload. Identity (`doc_type`, `id`) is fully specified in the
    /// request; the JSON content becomes the document `data` verbatim.
    payload: Payload,
    /// JSON that already carries identity fields (`type`, `id`, `data`).
    /// The optional per-field overrides take precedence and must not conflict.
    envelope: Envelope,

    pub const Payload = struct {
        json: []const u8,
        namespace: ?[]const u8 = null,
        doc_type: []const u8,
        id: []const u8,
    };

    pub const Envelope = struct {
        json: []const u8,
        namespace: ?[]const u8 = null,
        doc_type: ?[]const u8 = null,
        id: ?[]const u8 = null,
    };
};

pub const GetRequest = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    version: ?RefStore.VersionId = null,
};

pub const Error = error{
    ConflictingIdentity,
    InvalidDocument,
    InvalidIdentity,
    MissingIdentity,
    VersionIsOutputOnly,
};

pub const DocumentStore = struct {
    ref_store: RefStore,

    pub fn init(ref_store: RefStore) DocumentStore {
        return .{ .ref_store = ref_store };
    }

    pub fn put(self: DocumentStore, gpa: Allocator, request: PutRequest) ![]u8 {
        var prepared = try preparePut(gpa, request);
        defer prepared.parsed.deinit();

        const key = try deriveKey(gpa, prepared.identity);
        defer gpa.free(key);

        const stored_json = try encodeEnvelope(gpa, prepared.identity, null, prepared.data);
        defer gpa.free(stored_json);

        const version = try self.ref_store.put(gpa, key, stored_json);
        defer gpa.free(version);

        return encodeEnvelope(gpa, prepared.identity, version, prepared.data);
    }

    pub fn get(self: DocumentStore, gpa: Allocator, request: GetRequest) !?[]u8 {
        const identity: Identity = .{
            .namespace = request.namespace orelse default_namespace,
            .doc_type = request.doc_type,
            .id = request.id,
        };
        try validateIdentity(identity);

        const key = try deriveKey(gpa, identity);
        defer gpa.free(key);

        const read_result = try self.ref_store.get(gpa, key, request.version);
        if (read_result == null) return null;
        defer RefStore.freeReadResult(gpa, read_result.?);

        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, read_result.?.value, .{});
        defer parsed.deinit();

        const stored = try parseStoredEnvelope(parsed.value);
        return try encodeEnvelope(gpa, stored.identity, read_result.?.version, stored.data);
    }
};

const PreparedPut = struct {
    parsed: std.json.Parsed(std.json.Value),
    identity: Identity,
    data: std.json.Value,
};

const ParsedStored = struct {
    identity: Identity,
    data: std.json.Value,
};

fn preparePut(gpa: Allocator, request: PutRequest) !PreparedPut {
    return switch (request) {
        .payload => |r| try preparePayloadPut(gpa, r),
        .envelope => |r| try prepareEnvelopePut(gpa, r),
    };
}

fn prepareEnvelopePut(gpa: Allocator, request: PutRequest.Envelope) !PreparedPut {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, request.json, .{});
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDocument;
    const object = parsed.value.object;

    if (object.get("version") != null) return error.VersionIsOutputOnly;

    const data = object.get("data") orelse return error.InvalidDocument;
    const identity: Identity = .{
        .namespace = try mergeField(
            request.namespace,
            getOptionalString(object, "namespace"),
            default_namespace,
        ),
        .doc_type = try mergeField(
            request.doc_type,
            getOptionalString(object, "type"),
            null,
        ),
        .id = try mergeField(
            request.id,
            getOptionalString(object, "id"),
            null,
        ),
    };
    try validateIdentity(identity);

    return .{
        .parsed = parsed,
        .identity = identity,
        .data = data,
    };
}

fn preparePayloadPut(gpa: Allocator, request: PutRequest.Payload) !PreparedPut {
    const identity: Identity = .{
        .namespace = request.namespace orelse default_namespace,
        .doc_type = request.doc_type,
        .id = request.id,
    };
    try validateIdentity(identity);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, request.json, .{});
    errdefer parsed.deinit();

    return .{
        .parsed = parsed,
        .identity = identity,
        .data = parsed.value,
    };
}

fn parseStoredEnvelope(value: std.json.Value) !ParsedStored {
    if (value != .object) return error.InvalidDocument;
    const object = value.object;

    const namespace = try getRequiredString(object, "namespace");
    const doc_type = try getRequiredString(object, "type");
    const id = try getRequiredString(object, "id");
    const data = object.get("data") orelse return error.InvalidDocument;

    const identity: Identity = .{
        .namespace = namespace,
        .doc_type = doc_type,
        .id = id,
    };
    try validateIdentity(identity);

    return .{
        .identity = identity,
        .data = data,
    };
}

fn mergeField(
    primary: ?[]const u8,
    secondary: ?[]const u8,
    fallback: ?[]const u8,
) ![]const u8 {
    if (primary) |p| {
        if (secondary) |s| {
            if (!std.mem.eql(u8, p, s)) return error.ConflictingIdentity;
        }
        return p;
    }
    return secondary orelse fallback orelse error.MissingIdentity;
}

fn getOptionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn getRequiredString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    return getOptionalString(object, field) orelse error.InvalidDocument;
}

fn validateIdentity(identity: Identity) !void {
    try validateSegment(identity.namespace);
    try validateSegment(identity.doc_type);
    try validateSegment(identity.id);
}

fn validateSegment(segment: []const u8) !void {
    if (segment.len == 0) return error.InvalidIdentity;
    if (std.mem.indexOfScalar(u8, segment, '/') != null) return error.InvalidIdentity;
    if (std.mem.indexOfScalar(u8, segment, 0) != null) return error.InvalidIdentity;
}

pub fn deriveKey(gpa: Allocator, identity: Identity) ![]u8 {
    try validateIdentity(identity);
    return std.fmt.allocPrint(gpa, "{s}/{s}/{s}.json", .{
        identity.namespace,
        identity.doc_type,
        identity.id,
    });
}

fn encodeEnvelope(
    gpa: Allocator,
    identity: Identity,
    version: ?RefStore.VersionId,
    data: std.json.Value,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
    };

    try stringify.beginObject();
    try stringify.objectField("namespace");
    try stringify.write(identity.namespace);
    try stringify.objectField("type");
    try stringify.write(identity.doc_type);
    try stringify.objectField("id");
    try stringify.write(identity.id);
    if (version) |resolved_version| {
        try stringify.objectField("version");
        try stringify.write(resolved_version);
    }
    try stringify.objectField("data");
    try stringify.write(data);
    try stringify.endObject();

    return out.toOwnedSlice();
}

test "deriveKey uses default namespace and json suffix" {
    const key = try deriveKey(std.testing.allocator, .{
        .doc_type = "issue",
        .id = "doc-1",
    });
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("default/issue/doc-1.json", key);
}

test "envelope requests require identity in json" {
    try std.testing.expectError(
        error.MissingIdentity,
        preparePut(std.testing.allocator, .{ .envelope = .{
            .json = "{\"type\":\"issue\",\"data\":{\"title\":\"missing id\"}}",
        } }),
    );
}

test "envelope requests reject version input and conflicting identity" {
    try std.testing.expectError(
        error.VersionIsOutputOnly,
        preparePut(std.testing.allocator, .{ .envelope = .{
            .json =
            \\{
            \\  "type": "issue",
            \\  "id": "doc-1",
            \\  "version": "abc",
            \\  "data": {}
            \\}
            ,
        } }),
    );

    try std.testing.expectError(
        error.ConflictingIdentity,
        preparePut(std.testing.allocator, .{ .envelope = .{
            .json =
            \\{
            \\  "type": "issue",
            \\  "id": "doc-1",
            \\  "data": {}
            \\}
            ,
            .id = "doc-2",
        } }),
    );
}
