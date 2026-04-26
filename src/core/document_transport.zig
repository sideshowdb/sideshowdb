const std = @import("std");
const document = @import("document.zig");

const Allocator = std.mem.Allocator;

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
    const req_namespace = getOptionalString(object, "namespace");
    const req_doc_type = getOptionalString(object, "type");
    const req_id = getOptionalString(object, "id");

    const put_request: document.PutRequest =
        if (req_doc_type != null and req_id != null)
            .{ .payload = .{
                .json = input_json,
                .namespace = req_namespace,
                .doc_type = req_doc_type.?,
                .id = req_id.?,
            } }
        else
            .{ .envelope = .{
                .json = input_json,
                .namespace = req_namespace,
                .doc_type = req_doc_type,
                .id = req_id,
            } };
    return store.put(gpa, put_request);
}

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
