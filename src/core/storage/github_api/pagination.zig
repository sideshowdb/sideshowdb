const std = @import("std");

/// Absolute URL from a GitHub `Link` response header with `rel="next"`.
/// The `value` slice aliases the parsed header buffer until that buffer is freed.
pub const LinkNextUrl = struct {
    value: []const u8,
};

/// Absolute URL from `rel="prev"`.
pub const LinkPrevUrl = struct {
    value: []const u8,
};

/// Absolute URL from `rel="first"`.
pub const LinkFirstUrl = struct {
    value: []const u8,
};

/// Absolute URL from `rel="last"`.
pub const LinkLastUrl = struct {
    value: []const u8,
};

pub const LinkRels = struct {
    next: ?LinkNextUrl = null,
    prev: ?LinkPrevUrl = null,
    first: ?LinkFirstUrl = null,
    last: ?LinkLastUrl = null,
};

pub fn parseLinkHeader(header: []const u8) LinkRels {
    var rels = LinkRels{};
    var parts = std.mem.splitScalar(u8, header, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) continue;
        const lt = std.mem.indexOfScalar(u8, part, '<') orelse continue;
        const gt = std.mem.indexOfScalarPos(u8, part, lt + 1, '>') orelse continue;
        const url = part[lt + 1 .. gt];
        const rel_marker = "rel=\"";
        const rel_pos = std.mem.indexOf(u8, part, rel_marker) orelse continue;
        const rel_start = rel_pos + rel_marker.len;
        const rel_end = std.mem.indexOfScalarPos(u8, part, rel_start, '"') orelse continue;
        const rel = part[rel_start..rel_end];
        if (std.mem.eql(u8, rel, "next")) rels.next = .{ .value = url };
        if (std.mem.eql(u8, rel, "prev")) rels.prev = .{ .value = url };
        if (std.mem.eql(u8, rel, "first")) rels.first = .{ .value = url };
        if (std.mem.eql(u8, rel, "last")) rels.last = .{ .value = url };
    }
    return rels;
}
