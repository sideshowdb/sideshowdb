const std = @import("std");
const cache = @import("github_api_cache");

test "cache_test_etag_round_trip" {
    const gpa = std.testing.allocator;
    var tip: cache.RefTipCache = .{};
    defer tip.invalidate(gpa);

    try tip.record(gpa, "sha-aaa", "\"v1\"");
    const entry = tip.lookup().?;
    try std.testing.expectEqualStrings("sha-aaa", entry.commit_sha);
    try std.testing.expectEqualStrings("\"v1\"", entry.etag);

    tip.invalidate(gpa);
    try std.testing.expect(tip.lookup() == null);
}
