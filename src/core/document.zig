//! JSON document store layered over a `RefStore`.
//!
//! Documents are addressed by an `Identity` (`namespace`, `doc_type`, `id`)
//! and stored as JSON envelopes that include identity plus a `data`
//! payload. The store does not own its `RefStore`; the caller manages that
//! lifetime.

const std = @import("std");
const RefStore = @import("storage/ref_store.zig").RefStore;

const Allocator = std.mem.Allocator;

/// Default namespace used when the caller does not specify one.
pub const default_namespace = "default";

/// Logical address of a stored JSON document.
///
/// Identity is composed from a `namespace`, a `doc_type`, and a unique
/// `id`. Each segment must be non-empty and must not contain `/` or null
/// bytes; `validateIdentity` rejects violations with `error.InvalidIdentity`.
pub const Identity = struct {
    namespace: []const u8 = default_namespace,
    doc_type: []const u8,
    id: []const u8,
};

/// Input shape accepted by `DocumentStore.put`.
///
/// Two variants:
/// - `payload`: raw JSON content plus explicit identity fields. The JSON
///   becomes the document's `data` verbatim.
/// - `envelope`: a JSON object that already carries identity (`type`, `id`,
///   optional `namespace`). Per-field overrides take precedence and must
///   not disagree with the embedded identity.
pub const PutRequest = union(enum) {
    /// Raw JSON payload. Identity (`doc_type`, `id`) is fully specified in the
    /// request; the JSON content becomes the document `data` verbatim.
    payload: Payload,
    /// JSON that already carries identity fields (`type`, `id`, `data`).
    /// The optional per-field overrides take precedence and must not conflict.
    envelope: Envelope,

    /// Raw JSON payload form. Identity is fully specified by the request
    /// fields; the JSON content becomes the document's `data` verbatim.
    pub const Payload = struct {
        json: []const u8,
        namespace: ?[]const u8 = null,
        doc_type: []const u8,
        id: []const u8,
    };

    /// Envelope form. Identity is expected inside the JSON; the optional
    /// per-field overrides take precedence and must not conflict with the
    /// embedded identity (otherwise `error.ConflictingIdentity`).
    pub const Envelope = struct {
        json: []const u8,
        namespace: ?[]const u8 = null,
        doc_type: ?[]const u8 = null,
        id: ?[]const u8 = null,
    };

    /// Build a `PutRequest` from optional override fields such as those
    /// provided by a CLI or transport layer. When both `doc_type` and `id`
    /// are present the request is `.payload` (raw JSON + explicit identity);
    /// otherwise it is `.envelope` (identity is expected inside the JSON,
    /// with the supplied fields acting as optional overrides).
    pub fn fromOverrides(
        json: []const u8,
        namespace: ?[]const u8,
        doc_type: ?[]const u8,
        id: ?[]const u8,
    ) PutRequest {
        if (doc_type != null and id != null) {
            return .{ .payload = .{
                .json = json,
                .namespace = namespace,
                .doc_type = doc_type.?,
                .id = id.?,
            } };
        }
        return .{ .envelope = .{
            .json = json,
            .namespace = namespace,
            .doc_type = doc_type,
            .id = id,
        } };
    }
};

/// Read request shape for `DocumentStore.get`.
///
/// `namespace` defaults to `default_namespace` when null. `version` pins
/// the read to a historical `RefStore.VersionId`; when null, the latest
/// reachable version is read.
pub const GetRequest = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    version: ?RefStore.VersionId = null,
};

/// Errors returned by the document layer.
///
/// - `ConflictingIdentity`: an envelope and an override field disagreed.
/// - `InvalidDocument`: JSON is not an object, or is missing `data`.
/// - `InvalidIdentity`: a segment is empty or contains `/` or a null byte.
/// - `MissingIdentity`: no identity supplied via override or envelope.
/// - `VersionIsOutputOnly`: input JSON contained a `version` field, which
///   is reserved for store-controlled output.
pub const Error = error{
    ConflictingIdentity,
    InvalidDocument,
    InvalidIdentity,
    MissingIdentity,
    VersionIsOutputOnly,
};

/// JSON document store layered over a `RefStore`.
///
/// Documents are addressed by `namespace/doc_type/id.json` keys and
/// stored as JSON envelopes containing identity plus a `data` payload.
/// The store does not own its `RefStore`; the caller manages lifetime.
pub const DocumentStore = struct {
    ref_store: RefStore,

    /// Build a store backed by `ref_store`. No allocation; the store
    /// borrows `ref_store` and the caller must keep it alive for the
    /// store's lifetime.
    pub fn init(ref_store: RefStore) DocumentStore {
        return .{ .ref_store = ref_store };
    }

    /// Store the document described by `request` and return the encoded
    /// envelope (with version) for the caller. Allocations come from
    /// `gpa`; the caller owns the returned slice.
    ///
    /// Errors: any variant of `Error` plus any allocator or underlying
    /// `RefStore.put` error.
    ///
    /// Example (from `tests/document_store_test.zig`):
    /// ```
    /// const stored = try store.put(gpa, .{ .payload = .{
    ///     .json = "{\"title\":\"hi\"}",
    ///     .doc_type = "issue",
    ///     .id = "doc-1",
    /// }});
    /// defer gpa.free(stored);
    /// ```
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

    /// Fetch a document by identity. Returns null if absent. When
    /// `request.version` is null the latest reachable version is read;
    /// otherwise the read is pinned to that `VersionId`. Caller owns the
    /// returned slice.
    ///
    /// Errors: any variant of `Error` plus any allocator or underlying
    /// `RefStore.get` error.
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
    override: ?[]const u8,
    envelope_value: ?[]const u8,
    default_value: ?[]const u8,
) ![]const u8 {
    if (override) |o| {
        if (envelope_value) |e| {
            if (!std.mem.eql(u8, o, e)) return error.ConflictingIdentity;
        }
        return o;
    }
    return envelope_value orelse default_value orelse error.MissingIdentity;
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

/// Compute the canonical `RefStore` key for `identity`, formatted as
/// `<namespace>/<doc_type>/<id>.json`. Caller owns the returned slice.
///
/// Errors:
/// - `InvalidIdentity` if any segment is empty or contains `/` or a null
///   byte.
/// - any allocator error from `std.fmt.allocPrint`.
///
/// Example (from `test "deriveKey uses default namespace and json suffix"`):
/// ```
/// const key = try deriveKey(gpa, .{ .doc_type = "issue", .id = "doc-1" });
/// // -> "default/issue/doc-1.json"
/// ```
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
