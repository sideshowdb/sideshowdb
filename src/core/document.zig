const std = @import("std");
const RefStore = @import("storage/ref_store.zig").RefStore;

const Allocator = std.mem.Allocator;

pub const default_namespace = "default";

pub const Identity = struct {
    namespace: []const u8 = default_namespace,
    doc_type: []const u8,
    id: []const u8,
};

pub const PutRequest = struct {
    json: []const u8,
    namespace: ?[]const u8 = null,
    doc_type: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

pub const GetRequest = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    version: ?[]const u8 = null,
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
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, request.json, .{});
    errdefer parsed.deinit();

    return if (looksLikeEnvelope(parsed.value))
        try prepareEnvelopePut(parsed, request)
    else
        try preparePayloadPut(parsed, request);
}

fn prepareEnvelopePut(parsed: std.json.Parsed(std.json.Value), request: PutRequest) !PreparedPut {
    if (parsed.value != .object) return error.InvalidDocument;
    const object = parsed.value.object;

    if (object.get("version") != null) return error.VersionIsOutputOnly;

    const data = object.get("data") orelse return error.InvalidDocument;
    const identity: Identity = .{
        .namespace = try mergeOptionalString(
            request.namespace,
            getOptionalString(object, "namespace"),
            true,
        ),
        .doc_type = try mergeOptionalString(
            request.doc_type,
            getOptionalString(object, "type"),
            false,
        ),
        .id = try mergeOptionalString(
            request.id,
            getOptionalString(object, "id"),
            false,
        ),
    };
    try validateIdentity(identity);

    return .{
        .parsed = parsed,
        .identity = identity,
        .data = data,
    };
}

fn preparePayloadPut(parsed: std.json.Parsed(std.json.Value), request: PutRequest) !PreparedPut {
    const identity: Identity = .{
        .namespace = request.namespace orelse default_namespace,
        .doc_type = request.doc_type orelse return error.MissingIdentity,
        .id = request.id orelse return error.MissingIdentity,
    };
    try validateIdentity(identity);

    return .{
        .parsed = parsed,
        .identity = identity,
        .data = parsed.value,
    };
}

fn parseStoredEnvelope(value: std.json.Value) !ParsedStored {
    if (value != .object) return error.InvalidDocument;
    const object = value.object;

    const namespace = getRequiredString(object, "namespace") orelse return error.InvalidDocument;
    const doc_type = getRequiredString(object, "type") orelse return error.InvalidDocument;
    const id = getRequiredString(object, "id") orelse return error.InvalidDocument;
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

fn looksLikeEnvelope(value: std.json.Value) bool {
    if (value != .object) return false;
    const object = value.object;
    return object.contains("data") or
        object.contains("namespace") or
        object.contains("type") or
        object.contains("id") or
        object.contains("version");
}

fn mergeOptionalString(
    cli_value: ?[]const u8,
    envelope_value: ?[]const u8,
    comptime allow_default: bool,
) ![]const u8 {
    if (cli_value) |cli| {
        if (envelope_value) |env| {
            if (!std.mem.eql(u8, cli, env)) return error.ConflictingIdentity;
            return cli;
        }
        return cli;
    }
    if (envelope_value) |env| return env;
    if (allow_default) return default_namespace;
    return error.MissingIdentity;
}

fn getOptionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn getRequiredString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return getOptionalString(object, field);
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
    version: ?[]const u8,
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

test "payload requests require explicit identity" {
    try std.testing.expectError(
        error.MissingIdentity,
        preparePut(std.testing.allocator, .{
            .json = "{\"title\":\"missing identity\"}",
            .doc_type = "issue",
        }),
    );
}

test "envelope requests reject version input and conflicting identity" {
    try std.testing.expectError(
        error.VersionIsOutputOnly,
        preparePut(std.testing.allocator, .{
            .json =
                \\{
                \\  "type": "issue",
                \\  "id": "doc-1",
                \\  "version": "abc",
                \\  "data": {}
                \\}
            ,
        }),
    );

    try std.testing.expectError(
        error.ConflictingIdentity,
        preparePut(std.testing.allocator, .{
            .json =
                \\{
                \\  "type": "issue",
                \\  "id": "doc-1",
                \\  "data": {}
                \\}
            ,
            .id = "doc-2",
        }),
    );
}
