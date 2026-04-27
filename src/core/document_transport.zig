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
