//! JSON request and response helpers for GitHub's Git Database API.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TreeBlobEntry = struct {
    path: []u8,
    mode: []u8,
    sha: []u8,
};

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

pub fn parseCommitShas(gpa: Allocator, body: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .array => |arr| arr,
        else => return error.InvalidResponse,
    };

    var shas = std.array_list.Managed([]u8).init(gpa);
    defer {
        for (shas.items) |sha| gpa.free(sha);
        shas.deinit();
    }
    for (root.items) |item| {
        const obj = try expectObject(item);
        const sha = try expectString(obj.get("sha") orelse return error.InvalidResponse);
        try shas.append(try gpa.dupe(u8, sha));
    }
    return try shas.toOwnedSlice();
}

/// Parses a `GET /git/trees/{sha}?recursive=1` response for the blob SHA at `path`.
pub fn parseTreeBlobShaByPath(gpa: Allocator, body: []const u8, path: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const root = try expectObject(parsed.value);
    const tree_value = root.get("tree") orelse return error.InvalidResponse;
    const tree_array = switch (tree_value) {
        .array => |array| array,
        else => return error.InvalidResponse,
    };

    for (tree_array.items) |entry_value| {
        const entry = try expectObject(entry_value);
        const entry_type = try expectString(entry.get("type") orelse continue);
        if (!std.mem.eql(u8, entry_type, "blob")) continue;

        const entry_path = try expectString(entry.get("path") orelse continue);
        if (!std.mem.eql(u8, entry_path, path)) continue;

        const blob_sha = try expectString(entry.get("sha") orelse return error.InvalidResponse);
        return try gpa.dupe(u8, blob_sha);
    }

    return null;
}

/// Parses a `GET /git/blobs/{sha}` response and returns decoded bytes.
pub fn parseBlobContent(gpa: Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const root = try expectObject(parsed.value);
    const encoding = try expectString(root.get("encoding") orelse return error.InvalidResponse);
    if (!std.mem.eql(u8, encoding, "base64")) return error.InvalidResponse;

    const encoded = try expectString(root.get("content") orelse return error.InvalidResponse);
    var compact = std.array_list.Managed(u8).init(gpa);
    defer compact.deinit();
    for (encoded) |byte| {
        if (byte == '\n' or byte == '\r') continue;
        try compact.append(byte);
    }

    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(compact.items);
    const decoded = try gpa.alloc(u8, decoded_len);
    errdefer gpa.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, compact.items);
    return decoded;
}

/// Parses a recursive tree response and returns sorted blob paths.
pub fn parseTreeBlobPaths(gpa: Allocator, body: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const root = try expectObject(parsed.value);
    const tree_value = root.get("tree") orelse return error.InvalidResponse;
    const tree_array = switch (tree_value) {
        .array => |array| array,
        else => return error.InvalidResponse,
    };

    var paths = std.array_list.Managed([]u8).init(gpa);
    defer {
        for (paths.items) |path| gpa.free(path);
        paths.deinit();
    }

    for (tree_array.items) |entry_value| {
        const entry = try expectObject(entry_value);
        const entry_type = try expectString(entry.get("type") orelse continue);
        if (!std.mem.eql(u8, entry_type, "blob")) continue;
        const entry_path = try expectString(entry.get("path") orelse return error.InvalidResponse);
        try paths.append(try gpa.dupe(u8, entry_path));
    }

    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    return try paths.toOwnedSlice();
}

/// Parses a recursive tree response and returns blob entries.
pub fn parseTreeBlobEntries(gpa: Allocator, body: []const u8) ![]TreeBlobEntry {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    const root = try expectObject(parsed.value);
    const tree_value = root.get("tree") orelse return error.InvalidResponse;
    const tree_array = switch (tree_value) {
        .array => |array| array,
        else => return error.InvalidResponse,
    };

    var entries = std.array_list.Managed(TreeBlobEntry).init(gpa);
    defer {
        for (entries.items) |entry| {
            gpa.free(entry.path);
            gpa.free(entry.mode);
            gpa.free(entry.sha);
        }
        entries.deinit();
    }

    for (tree_array.items) |entry_value| {
        const entry = try expectObject(entry_value);
        const entry_type = try expectString(entry.get("type") orelse continue);
        if (!std.mem.eql(u8, entry_type, "blob")) continue;

        const path = try expectString(entry.get("path") orelse return error.InvalidResponse);
        const mode = try expectString(entry.get("mode") orelse return error.InvalidResponse);
        const sha = try expectString(entry.get("sha") orelse return error.InvalidResponse);
        try entries.append(.{
            .path = try gpa.dupe(u8, path),
            .mode = try gpa.dupe(u8, mode),
            .sha = try gpa.dupe(u8, sha),
        });
    }

    return try entries.toOwnedSlice();
}

pub fn freeTreeBlobEntries(gpa: Allocator, entries: []TreeBlobEntry) void {
    for (entries) |entry| {
        gpa.free(entry.path);
        gpa.free(entry.mode);
        gpa.free(entry.sha);
    }
    gpa.free(entries);
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

pub fn encodeCreateTreeEntriesRequest(gpa: Allocator, entries: []const TreeBlobEntry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{ .writer = &out.writer };
    try stringify.beginObject();
    try stringify.objectField("tree");
    try stringify.beginArray();
    for (entries) |entry| {
        try stringify.beginObject();
        try stringify.objectField("path");
        try stringify.write(entry.path);
        try stringify.objectField("mode");
        try stringify.write(entry.mode);
        try stringify.objectField("type");
        try stringify.write("blob");
        try stringify.objectField("sha");
        try stringify.write(entry.sha);
        try stringify.endObject();
    }
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
