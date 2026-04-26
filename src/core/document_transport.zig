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
    return store.put(gpa, .{
        .json = input_json,
        .namespace = getOptionalString(object, "namespace"),
        .doc_type = getOptionalString(object, "type"),
        .id = getOptionalString(object, "id"),
    });
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
