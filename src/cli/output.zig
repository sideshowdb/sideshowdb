const std = @import("std");
const sideshowdb = @import("sideshowdb");

const Allocator = std.mem.Allocator;
const document = sideshowdb.document;

pub fn renderEnvelopeJson(gpa: Allocator, encoded: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, encoded, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDocument;
    const object = parsed.value.object;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;

    try writer.print("namespace: {s}\n", .{object.get("namespace").?.string});
    try writer.print("type: {s}\n", .{object.get("type").?.string});
    try writer.print("id: {s}\n", .{object.get("id").?.string});
    if (object.get("version")) |version| {
        try writer.print("version: {s}\n", .{version.string});
    }
    if (object.get("data")) |data| {
        const data_json = try stringifyJsonValue(gpa, data);
        defer gpa.free(data_json);
        try writer.print("data: {s}\n", .{data_json});
    }

    return out.toOwnedSlice();
}

pub fn renderDeleteResult(gpa: Allocator, result: document.DeleteResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;

    try writer.print("namespace: {s}\n", .{result.namespace});
    try writer.print("type: {s}\n", .{result.doc_type});
    try writer.print("id: {s}\n", .{result.id});
    try writer.print("deleted: {}\n", .{result.deleted});

    return out.toOwnedSlice();
}

pub fn renderListResult(gpa: Allocator, result: document.ListResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("NAMESPACE\tTYPE\tID\tVERSION\n");
    switch (result) {
        .summary => |page| {
            for (page.items) |item| {
                try writer.print("{s}\t{s}\t{s}\t{s}\n", .{
                    item.namespace,
                    item.doc_type,
                    item.id,
                    item.version,
                });
            }
            if (page.next_cursor) |cursor| try writer.print("next_cursor: {s}\n", .{cursor});
        },
        .detailed => |page| {
            for (page.items) |encoded| try writeDetailedRow(gpa, writer, encoded);
            if (page.next_cursor) |cursor| try writer.print("next_cursor: {s}\n", .{cursor});
        },
    }

    return out.toOwnedSlice();
}

pub fn renderHistoryResult(gpa: Allocator, result: document.HistoryResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("NAMESPACE\tTYPE\tID\tVERSION\n");
    switch (result) {
        .summary => |page| {
            for (page.items) |item| {
                try writer.print("{s}\t{s}\t{s}\t{s}\n", .{
                    item.namespace,
                    item.doc_type,
                    item.id,
                    item.version,
                });
            }
            if (page.next_cursor) |cursor| try writer.print("next_cursor: {s}\n", .{cursor});
        },
        .detailed => |page| {
            for (page.items) |encoded| try writeDetailedRow(gpa, writer, encoded);
            if (page.next_cursor) |cursor| try writer.print("next_cursor: {s}\n", .{cursor});
        },
    }

    return out.toOwnedSlice();
}

fn writeDetailedRow(
    gpa: Allocator,
    writer: anytype,
    encoded: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, encoded, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidDocument;
    const object = parsed.value.object;
    try writer.print("{s}\t{s}\t{s}\t{s}\n", .{
        object.get("namespace").?.string,
        object.get("type").?.string,
        object.get("id").?.string,
        object.get("version").?.string,
    });
}

fn stringifyJsonValue(gpa: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
    };
    try stringify.write(value);
    return out.toOwnedSlice();
}
