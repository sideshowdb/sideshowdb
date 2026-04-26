//! Cross-module integration tests. Runs against the public `sideshowdb`
//! module the same way downstream consumers would import it.

const std = @import("std");
const Io = std.Io;
const sideshowdb = @import("sideshowdb");

test "public module exposes version" {
    try std.testing.expectEqual(@as(usize, 0), sideshowdb.version.major);
}

test "public module exposes banner" {
    try std.testing.expect(sideshowdb.banner.len > 0);
}

test "writeBanner works through public import" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try sideshowdb.writeBanner(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "sideshowdb") != null);
}

test "Event placeholder is reachable" {
    const e = sideshowdb.Event.init("evt-x", "Touched", "agg-x", 7);
    try std.testing.expectEqual(@as(i64, 7), e.timestamp_ms);
}
