const std = @import("std");

pub const LinkRels = struct {
    next: ?[]const u8 = null,
    prev: ?[]const u8 = null,
    first: ?[]const u8 = null,
    last: ?[]const u8 = null,
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
        if (std.mem.eql(u8, rel, "next")) rels.next = url;
        if (std.mem.eql(u8, rel, "prev")) rels.prev = url;
        if (std.mem.eql(u8, rel, "first")) rels.first = url;
        if (std.mem.eql(u8, rel, "last")) rels.last = url;
    }
    return rels;
}
