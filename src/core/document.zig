const std = @import("std");
const RefStore = @import("storage/ref_store.zig").RefStore;

const Allocator = std.mem.Allocator;
const base64 = std.base64.url_safe_no_pad;

pub const default_namespace = "default";
pub const default_page_size: usize = 50;
pub const max_page_size: usize = 200;

pub const Identity = struct {
    namespace: []const u8 = default_namespace,
    doc_type: []const u8,
    id: []const u8,
};

pub const CollectionMode = enum {
    summary,
    detailed,
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

pub const GetRequest = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    version: ?RefStore.VersionId = null,
};

pub const ListRequest = struct {
    namespace: ?[]const u8 = null,
    doc_type: ?[]const u8 = null,
    limit: ?usize = null,
    cursor: ?[]const u8 = null,
    mode: CollectionMode = .summary,
};

pub const DeleteRequest = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
};

pub const HistoryRequest = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    limit: ?usize = null,
    cursor: ?[]const u8 = null,
    mode: CollectionMode = .summary,
};

pub const DocumentMetadata = struct {
    namespace: []const u8,
    doc_type: []const u8,
    id: []const u8,
    version: []const u8,

    pub fn deinit(self: DocumentMetadata, gpa: Allocator) void {
        gpa.free(self.namespace);
        gpa.free(self.doc_type);
        gpa.free(self.id);
        gpa.free(self.version);
    }
};

pub const SummaryListResult = struct {
    kind: []const u8 = "summary",
    items: []DocumentMetadata,
    next_cursor: ?[]u8,

    pub fn deinit(self: SummaryListResult, gpa: Allocator) void {
        for (self.items) |item| item.deinit(gpa);
        gpa.free(self.items);
        if (self.next_cursor) |cursor| gpa.free(cursor);
    }
};

pub const DetailedListResult = struct {
    kind: []const u8 = "detailed",
    items: [][]u8,
    next_cursor: ?[]u8,

    pub fn deinit(self: DetailedListResult, gpa: Allocator) void {
        for (self.items) |item| gpa.free(item);
        gpa.free(self.items);
        if (self.next_cursor) |cursor| gpa.free(cursor);
    }
};

pub const SummaryHistoryResult = struct {
    kind: []const u8 = "summary",
    items: []DocumentMetadata,
    next_cursor: ?[]u8,

    pub fn deinit(self: SummaryHistoryResult, gpa: Allocator) void {
        for (self.items) |item| item.deinit(gpa);
        gpa.free(self.items);
        if (self.next_cursor) |cursor| gpa.free(cursor);
    }
};

pub const DetailedHistoryResult = struct {
    kind: []const u8 = "detailed",
    items: [][]u8,
    next_cursor: ?[]u8,

    pub fn deinit(self: DetailedHistoryResult, gpa: Allocator) void {
        for (self.items) |item| gpa.free(item);
        gpa.free(self.items);
        if (self.next_cursor) |cursor| gpa.free(cursor);
    }
};

pub const ListResult = union(enum) {
    summary: SummaryListResult,
    detailed: DetailedListResult,

    pub fn deinit(self: ListResult, gpa: Allocator) void {
        switch (self) {
            .summary => |page| page.deinit(gpa),
            .detailed => |page| page.deinit(gpa),
        }
    }
};

pub const HistoryResult = union(enum) {
    summary: SummaryHistoryResult,
    detailed: DetailedHistoryResult,

    pub fn deinit(self: HistoryResult, gpa: Allocator) void {
        switch (self) {
            .summary => |page| page.deinit(gpa),
            .detailed => |page| page.deinit(gpa),
        }
    }
};

pub const DeleteResult = struct {
    namespace: []u8,
    doc_type: []u8,
    id: []u8,
    deleted: bool,

    pub fn deinit(self: DeleteResult, gpa: Allocator) void {
        gpa.free(self.namespace);
        gpa.free(self.doc_type);
        gpa.free(self.id);
    }
};

pub const Error = error{
    ConflictingIdentity,
    InvalidDocument,
    InvalidCursor,
    InvalidIdentity,
    InvalidLimit,
    MissingIdentity,
    UnsupportedMode,
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

    pub fn list(self: DocumentStore, gpa: Allocator, request: ListRequest) !ListResult {
        const page_size = try resolveLimit(request.limit);
        const keys = try self.ref_store.list(gpa);
        defer RefStore.freeKeys(gpa, keys);

        std.mem.sort([]u8, keys, {}, lessThanKey);

        const start_after = try decodeCursor(gpa, request.cursor);
        defer if (start_after) |cursor| gpa.free(cursor);

        return switch (request.mode) {
            .summary => try buildSummaryListResult(
                self,
                gpa,
                request,
                keys,
                page_size,
                start_after,
            ),
            .detailed => try buildDetailedListResult(
                self,
                gpa,
                request,
                keys,
                page_size,
                start_after,
            ),
        };
    }

    pub fn delete(self: DocumentStore, gpa: Allocator, request: DeleteRequest) !DeleteResult {
        const identity: Identity = .{
            .namespace = request.namespace orelse default_namespace,
            .doc_type = request.doc_type,
            .id = request.id,
        };
        try validateIdentity(identity);

        const key = try deriveKey(gpa, identity);
        defer gpa.free(key);

        const existing = try self.ref_store.get(gpa, key, null);
        defer if (existing) |result| RefStore.freeReadResult(gpa, result);

        if (existing != null) {
            try self.ref_store.delete(key);
        }

        return .{
            .namespace = try gpa.dupe(u8, identity.namespace),
            .doc_type = try gpa.dupe(u8, identity.doc_type),
            .id = try gpa.dupe(u8, identity.id),
            .deleted = existing != null,
        };
    }

    pub fn history(self: DocumentStore, gpa: Allocator, request: HistoryRequest) !HistoryResult {
        const page_size = try resolveLimit(request.limit);
        const identity: Identity = .{
            .namespace = request.namespace orelse default_namespace,
            .doc_type = request.doc_type,
            .id = request.id,
        };
        try validateIdentity(identity);

        const key = try deriveKey(gpa, identity);
        defer gpa.free(key);

        const versions = try self.ref_store.history(gpa, key);
        defer RefStore.freeVersions(gpa, versions);

        const start_after = try decodeCursor(gpa, request.cursor);
        defer if (start_after) |cursor| gpa.free(cursor);

        return switch (request.mode) {
            .summary => try buildSummaryHistoryResult(
                gpa,
                identity,
                versions,
                page_size,
                start_after,
            ),
            .detailed => try buildDetailedHistoryResult(
                self,
                gpa,
                identity,
                versions,
                page_size,
                start_after,
            ),
        };
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

fn resolveLimit(limit: ?usize) !usize {
    const resolved = limit orelse default_page_size;
    if (resolved > max_page_size) return error.InvalidLimit;
    return resolved;
}

fn buildSummaryListResult(
    self: DocumentStore,
    gpa: Allocator,
    request: ListRequest,
    keys: [][]u8,
    page_size: usize,
    start_after: ?[]const u8,
) !ListResult {
    var items: std.ArrayList(DocumentMetadata) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(gpa);
        items.deinit(gpa);
    }

    var next_cursor: ?[]u8 = null;
    var last_emitted_key: ?[]const u8 = null;
    if (page_size != 0) {
        for (keys) |key| {
            const identity = try parseKey(key);
            if (!matchesListFilter(identity, request)) continue;
            if (start_after) |cursor| {
                if (std.mem.order(u8, key, cursor) != .gt) continue;
            }

            const read_result = (try self.ref_store.get(gpa, key, null)) orelse continue;
            defer RefStore.freeReadResult(gpa, read_result);

            if (items.items.len < page_size) {
                try items.append(gpa, try duplicateMetadata(gpa, identity, read_result.version));
                last_emitted_key = key;
                continue;
            }

            next_cursor = try encodeCursor(gpa, last_emitted_key.?);
            break;
        }
    }

    return .{ .summary = .{
        .items = try items.toOwnedSlice(gpa),
        .next_cursor = next_cursor,
    } };
}

fn buildDetailedListResult(
    self: DocumentStore,
    gpa: Allocator,
    request: ListRequest,
    keys: [][]u8,
    page_size: usize,
    start_after: ?[]const u8,
) !ListResult {
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |item| gpa.free(item);
        items.deinit(gpa);
    }

    var next_cursor: ?[]u8 = null;
    var last_emitted_key: ?[]const u8 = null;
    if (page_size != 0) {
        for (keys) |key| {
            const identity = try parseKey(key);
            if (!matchesListFilter(identity, request)) continue;
            if (start_after) |cursor| {
                if (std.mem.order(u8, key, cursor) != .gt) continue;
            }

            const read_result = (try self.ref_store.get(gpa, key, null)) orelse continue;
            defer RefStore.freeReadResult(gpa, read_result);

            if (items.items.len < page_size) {
                try items.append(
                    gpa,
                    try encodeStoredReadResult(gpa, read_result.value, read_result.version),
                );
                last_emitted_key = key;
                continue;
            }

            next_cursor = try encodeCursor(gpa, last_emitted_key.?);
            break;
        }
    }

    return .{ .detailed = .{
        .items = try items.toOwnedSlice(gpa),
        .next_cursor = next_cursor,
    } };
}

fn buildSummaryHistoryResult(
    gpa: Allocator,
    identity: Identity,
    versions: []const RefStore.VersionId,
    page_size: usize,
    start_after: ?[]const u8,
) !HistoryResult {
    var items: std.ArrayList(DocumentMetadata) = .empty;
    errdefer {
        for (items.items) |item| item.deinit(gpa);
        items.deinit(gpa);
    }

    var next_cursor: ?[]u8 = null;
    var last_emitted_version: ?[]const u8 = null;
    if (page_size != 0) {
        var started = start_after == null;
        for (versions) |version| {
            if (!started) {
                if (std.mem.eql(u8, version, start_after.?)) {
                    started = true;
                }
                continue;
            }

            if (items.items.len < page_size) {
                try items.append(gpa, try duplicateMetadata(gpa, identity, version));
                last_emitted_version = version;
                continue;
            }

            next_cursor = try encodeCursor(gpa, last_emitted_version.?);
            break;
        }
    }

    return .{ .summary = .{
        .items = try items.toOwnedSlice(gpa),
        .next_cursor = next_cursor,
    } };
}

fn buildDetailedHistoryResult(
    self: DocumentStore,
    gpa: Allocator,
    identity: Identity,
    versions: []const RefStore.VersionId,
    page_size: usize,
    start_after: ?[]const u8,
) !HistoryResult {
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |item| gpa.free(item);
        items.deinit(gpa);
    }

    var next_cursor: ?[]u8 = null;
    var last_emitted_version: ?[]const u8 = null;
    if (page_size != 0) {
        var started = start_after == null;
        for (versions) |version| {
            if (!started) {
                if (std.mem.eql(u8, version, start_after.?)) {
                    started = true;
                }
                continue;
            }

            const json = (try self.get(gpa, .{
                .namespace = identity.namespace,
                .doc_type = identity.doc_type,
                .id = identity.id,
                .version = version,
            })) orelse continue;
            errdefer gpa.free(json);

            if (items.items.len < page_size) {
                try items.append(gpa, json);
                last_emitted_version = version;
                continue;
            }

            gpa.free(json);
            next_cursor = try encodeCursor(gpa, last_emitted_version.?);
            break;
        }
    }

    return .{ .detailed = .{
        .items = try items.toOwnedSlice(gpa),
        .next_cursor = next_cursor,
    } };
}

fn lessThanKey(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn matchesListFilter(identity: Identity, request: ListRequest) bool {
    if (request.namespace) |namespace| {
        if (!std.mem.eql(u8, identity.namespace, namespace)) return false;
    }
    if (request.doc_type) |doc_type| {
        if (!std.mem.eql(u8, identity.doc_type, doc_type)) return false;
    }
    return true;
}

fn parseKey(key: []const u8) !Identity {
    const namespace_end = std.mem.indexOfScalar(u8, key, '/') orelse return error.InvalidDocument;
    const remainder = key[(namespace_end + 1)..];
    const type_end = std.mem.indexOfScalar(u8, remainder, '/') orelse return error.InvalidDocument;

    const namespace = key[0..namespace_end];
    const doc_type = remainder[0..type_end];
    const file_name = remainder[(type_end + 1)..];

    if (!std.mem.endsWith(u8, file_name, ".json")) return error.InvalidDocument;
    const id = file_name[0 .. file_name.len - ".json".len];

    const identity: Identity = .{
        .namespace = namespace,
        .doc_type = doc_type,
        .id = id,
    };
    try validateIdentity(identity);
    return identity;
}

fn duplicateMetadata(gpa: Allocator, identity: Identity, version: []const u8) !DocumentMetadata {
    return .{
        .namespace = try gpa.dupe(u8, identity.namespace),
        .doc_type = try gpa.dupe(u8, identity.doc_type),
        .id = try gpa.dupe(u8, identity.id),
        .version = try gpa.dupe(u8, version),
    };
}

fn encodeStoredReadResult(
    gpa: Allocator,
    stored_json: []const u8,
    version: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, stored_json, .{});
    defer parsed.deinit();

    const stored = try parseStoredEnvelope(parsed.value);
    return encodeEnvelope(gpa, stored.identity, version, stored.data);
}

fn encodeCursor(gpa: Allocator, value: []const u8) ![]u8 {
    const encoded_len = base64.Encoder.calcSize(value.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    _ = base64.Encoder.encode(encoded, value);
    return encoded;
}

fn decodeCursor(gpa: Allocator, cursor: ?[]const u8) !?[]u8 {
    const encoded = cursor orelse return null;
    if (encoded.len == 0) return error.InvalidCursor;

    const decoded_len = base64.Decoder.calcSizeForSlice(encoded) catch return error.InvalidCursor;
    const decoded = try gpa.alloc(u8, decoded_len);
    errdefer gpa.free(decoded);

    base64.Decoder.decode(decoded, encoded) catch return error.InvalidCursor;
    if (decoded.len == 0) return error.InvalidCursor;
    return decoded;
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
