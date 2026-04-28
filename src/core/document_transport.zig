//! JSON wire-format adapters between transport surfaces (CLI, WASM bridge)
//! and the `DocumentStore` API. Inputs are single JSON request objects
//! containing identity overrides plus the user's document JSON.

const std = @import("std");
const document = @import("document.zig");

const Allocator = std.mem.Allocator;

/// Decode a transport-layer put request and forward it to `store.put`.
///
/// Expected JSON shape:
/// ```
/// {
///   "json": "<document json>",
///   "namespace": "...",   // optional
///   "type": "...",        // optional
///   "id": "..."           // optional
/// }
/// ```
///
/// Errors: any `document.Error`, plus `error.InvalidDocument` when the
/// transport object is not an object or is missing the required `json`
/// field.
pub fn handlePut(
    gpa: Allocator,
    store: document.DocumentStore,
    request_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, request_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDocument;
    const object = parsed.value.object;

    const input_json = try getRequiredString(object, "json");
    return store.put(gpa, document.PutRequest.fromOverrides(
        input_json,
        getOptionalString(object, "namespace"),
        getOptionalString(object, "type"),
        getOptionalString(object, "id"),
    ));
}

/// Decode a transport-layer get request and forward it to `store.get`.
///
/// Expected JSON shape:
/// ```
/// {
///   "type": "...",
///   "id": "...",
///   "namespace": "...",  // optional
///   "version": "..."     // optional, pins to a historical VersionId
/// }
/// ```
///
/// Errors: any `document.Error`, plus `error.InvalidDocument` when the
/// transport object is malformed or missing required fields.
pub fn handleGet(
    gpa: Allocator,
    store: document.DocumentStore,
    request_json: []const u8,
) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, request_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDocument;
    const object = parsed.value.object;

    return store.get(gpa, .{
        .namespace = getOptionalString(object, "namespace"),
        .doc_type = try getRequiredString(object, "type"),
        .id = try getRequiredString(object, "id"),
        .version = getOptionalString(object, "version"),
    });
}

/// Decode a transport-layer list request, execute `store.list`, and return
/// the JSON-encoded page result.
///
/// Expected JSON shape:
/// `{"namespace":"...","type":"...","limit":50,"cursor":"...","mode":"summary"}`
/// with every field optional except that invalid types or mode strings are
/// rejected as `error.InvalidDocument`.
pub fn handleList(
    gpa: Allocator,
    store: document.DocumentStore,
    request_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, request_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDocument;
    const object = parsed.value.object;

    const result = try store.list(gpa, .{
        .namespace = getOptionalString(object, "namespace"),
        .doc_type = getOptionalString(object, "type"),
        .limit = try getOptionalLimit(object, "limit"),
        .cursor = getOptionalString(object, "cursor"),
        .mode = try getOptionalMode(object, "mode"),
    });
    defer result.deinit(gpa);
    return encodeListResultJson(gpa, result);
}

/// Decode a transport-layer delete request, execute `store.delete`, and
/// return the JSON-encoded delete result.
///
/// Expected JSON shape:
/// `{"type":"...","id":"...","namespace":"..."}` where `namespace`
/// is optional.
pub fn handleDelete(
    gpa: Allocator,
    store: document.DocumentStore,
    request_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, request_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDocument;
    const object = parsed.value.object;

    const result = try store.delete(gpa, .{
        .namespace = getOptionalString(object, "namespace"),
        .doc_type = try getRequiredString(object, "type"),
        .id = try getRequiredString(object, "id"),
    });
    defer result.deinit(gpa);
    return encodeDeleteResultJson(gpa, result);
}

/// Decode a transport-layer history request, execute `store.history`, and
/// return the JSON-encoded page result.
///
/// Expected JSON shape:
/// `{"type":"...","id":"...","namespace":"...","limit":50,"cursor":"...","mode":"summary"}`
/// where `namespace`, `limit`, `cursor`, and `mode` are optional.
pub fn handleHistory(
    gpa: Allocator,
    store: document.DocumentStore,
    request_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, request_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDocument;
    const object = parsed.value.object;

    const result = try store.history(gpa, .{
        .namespace = getOptionalString(object, "namespace"),
        .doc_type = try getRequiredString(object, "type"),
        .id = try getRequiredString(object, "id"),
        .limit = try getOptionalLimit(object, "limit"),
        .cursor = getOptionalString(object, "cursor"),
        .mode = try getOptionalMode(object, "mode"),
    });
    defer result.deinit(gpa);
    return encodeHistoryResultJson(gpa, result);
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

fn getOptionalMode(object: std.json.ObjectMap, field: []const u8) !document.CollectionMode {
    const value = getOptionalString(object, field) orelse return .summary;
    if (std.mem.eql(u8, value, "summary")) return .summary;
    if (std.mem.eql(u8, value, "detailed")) return .detailed;
    return error.InvalidDocument;
}

fn getOptionalLimit(object: std.json.ObjectMap, field: []const u8) !?usize {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |n| std.math.cast(usize, n) orelse return error.InvalidDocument,
        .string => |s| std.fmt.parseInt(usize, s, 10) catch return error.InvalidDocument,
        else => error.InvalidDocument,
    };
}

/// Encode a `DocumentStore.list` page into the shared transport JSON shape.
/// Caller owns the returned slice.
pub fn encodeListResultJson(gpa: Allocator, result: document.ListResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
    };

    try stringify.beginObject();
    switch (result) {
        .summary => |page| {
            try writePagePreamble(&stringify, page.kind);
            try stringify.beginArray();
            for (page.items) |item| try writeMetadata(&stringify, item);
            try stringify.endArray();
            try writeNextCursor(&stringify, page.next_cursor);
        },
        .detailed => |page| {
            try writePagePreamble(&stringify, page.kind);
            try writeDetailedItems(gpa, &stringify, page.items);
            try writeNextCursor(&stringify, page.next_cursor);
        },
    }
    try stringify.endObject();

    return out.toOwnedSlice();
}

/// Encode a `DocumentStore.history` page into the shared transport JSON shape.
/// Caller owns the returned slice.
pub fn encodeHistoryResultJson(gpa: Allocator, result: document.HistoryResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
    };

    try stringify.beginObject();
    switch (result) {
        .summary => |page| {
            try writePagePreamble(&stringify, page.kind);
            try stringify.beginArray();
            for (page.items) |item| try writeMetadata(&stringify, item);
            try stringify.endArray();
            try writeNextCursor(&stringify, page.next_cursor);
        },
        .detailed => |page| {
            try writePagePreamble(&stringify, page.kind);
            try writeDetailedItems(gpa, &stringify, page.items);
            try writeNextCursor(&stringify, page.next_cursor);
        },
    }
    try stringify.endObject();

    return out.toOwnedSlice();
}

/// Encode a `DocumentStore.delete` result object as transport JSON.
/// Caller owns the returned slice.
pub fn encodeDeleteResultJson(gpa: Allocator, result: document.DeleteResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
    };

    try stringify.beginObject();
    try stringify.objectField("namespace");
    try stringify.write(result.namespace);
    try stringify.objectField("type");
    try stringify.write(result.doc_type);
    try stringify.objectField("id");
    try stringify.write(result.id);
    try stringify.objectField("deleted");
    try stringify.write(result.deleted);
    try stringify.endObject();

    return out.toOwnedSlice();
}

fn writePagePreamble(stringify: *std.json.Stringify, kind: []const u8) !void {
    try stringify.objectField("kind");
    try stringify.write(kind);
    try stringify.objectField("items");
}

fn writeMetadata(stringify: *std.json.Stringify, item: document.DocumentMetadata) !void {
    try stringify.beginObject();
    try stringify.objectField("namespace");
    try stringify.write(item.namespace);
    try stringify.objectField("type");
    try stringify.write(item.doc_type);
    try stringify.objectField("id");
    try stringify.write(item.id);
    try stringify.objectField("version");
    try stringify.write(item.version);
    try stringify.endObject();
}

fn writeDetailedItems(
    gpa: Allocator,
    stringify: *std.json.Stringify,
    items: [][]u8,
) !void {
    try stringify.beginArray();
    for (items) |item| {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, item, .{});
        defer parsed.deinit();
        try stringify.write(parsed.value);
    }
    try stringify.endArray();
}

fn writeNextCursor(stringify: *std.json.Stringify, next_cursor: ?[]const u8) !void {
    try stringify.objectField("next_cursor");
    if (next_cursor) |cursor| {
        try stringify.write(cursor);
    } else {
        try stringify.write(null);
    }
}
