//! Unit tests for `HttpTransport` and `RecordingTransport`.

const std = @import("std");
const http_transport = @import("http_transport");

test "recording_transport_round_trip" {
    const gpa = std.testing.allocator;
    var rec = http_transport.RecordingTransport.init(gpa, 200, "canned-bytes");
    defer rec.deinit();

    const transport = rec.transport();
    const resp = try transport.request(.GET, "https://example/x", &.{}, null, gpa);
    defer gpa.free(resp.body);

    try std.testing.expectEqual(http_transport.Method.GET, rec.last_method.?);
    try std.testing.expectEqualStrings("https://example/x", rec.last_url.?);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("canned-bytes", resp.body);
}
