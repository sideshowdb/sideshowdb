//! JSON request and response helpers for GitHub's Git Database API.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Parses a `GET /git/ref/{ref}` response and returns the target commit SHA.
pub fn parseRefCommitSha(gpa: Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const root = try expectObject(parsed.value);
    const object_value = root.get("object") orelse return error.InvalidResponse;
    const object = try expectObject(object_value);
    const sha = try expectString(object.get("sha") orelse return error.InvalidResponse);
    return try gpa.dupe(u8, sha);
}

/// Parses a `GET /git/commits/{sha}` response and returns the tree SHA.
pub fn parseCommitTreeSha(gpa: Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const root = try expectObject(parsed.value);
    const tree_value = root.get("tree") orelse return error.InvalidResponse;
    const tree = try expectObject(tree_value);
    const sha = try expectString(tree.get("sha") orelse return error.InvalidResponse);
    return try gpa.dupe(u8, sha);
}

/// Parses a GitHub response object with a top-level `sha` string.
pub fn parseSha(gpa: Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const root = try expectObject(parsed.value);
    const sha = try expectString(root.get("sha") orelse return error.InvalidResponse);
    return try gpa.dupe(u8, sha);
}

/// Encodes a `POST /git/blobs` request with base64 content.
pub fn encodeCreateBlobRequest(gpa: Allocator, value: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(value.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    defer gpa.free(encoded);
    const encoded_content = std.base64.standard.Encoder.encode(encoded, value);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("content");
    try stringify.write(encoded_content);
    try stringify.objectField("encoding");
    try stringify.write("base64");
    try stringify.endObject();
    return out.toOwnedSlice();
}

/// Encodes a `POST /git/trees` request for one blob entry.
pub fn encodeCreateTreeRequest(
    gpa: Allocator,
    base_tree: ?[]const u8,
    path: []const u8,
    blob_sha: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    if (base_tree) |sha| {
        try stringify.objectField("base_tree");
        try stringify.write(sha);
    }
    try stringify.objectField("tree");
    try stringify.beginArray();
    try stringify.beginObject();
    try stringify.objectField("path");
    try stringify.write(path);
    try stringify.objectField("mode");
    try stringify.write("100644");
    try stringify.objectField("type");
    try stringify.write("blob");
    try stringify.objectField("sha");
    try stringify.write(blob_sha);
    try stringify.endObject();
    try stringify.endArray();
    try stringify.endObject();
    return out.toOwnedSlice();
}

/// Encodes a `POST /git/commits` request.
pub fn encodeCreateCommitRequest(
    gpa: Allocator,
    message: []const u8,
    tree_sha: []const u8,
    parent_sha: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("message");
    try stringify.write(message);
    try stringify.objectField("tree");
    try stringify.write(tree_sha);
    try stringify.objectField("parents");
    try stringify.beginArray();
    if (parent_sha) |sha| try stringify.write(sha);
    try stringify.endArray();
    try stringify.endObject();
    return out.toOwnedSlice();
}

/// Encodes a `PATCH /git/refs/{ref}` request.
pub fn encodeUpdateRefRequest(gpa: Allocator, commit_sha: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("sha");
    try stringify.write(commit_sha);
    try stringify.objectField("force");
    try stringify.write(false);
    try stringify.endObject();
    return out.toOwnedSlice();
}

/// Encodes a `POST /git/refs` request.
pub fn encodeCreateRefRequest(
    gpa: Allocator,
    ref_name: []const u8,
    commit_sha: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("ref");
    try stringify.write(ref_name);
    try stringify.objectField("sha");
    try stringify.write(commit_sha);
    try stringify.endObject();
    return out.toOwnedSlice();
}

fn expectObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidResponse,
    };
}

fn expectString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidResponse,
    };
}
