//! Unit tests for `HttpTransport`, `RecordingTransport`, and `StdHttpTransport`.

const std = @import("std");
const Io = std.Io;
const http_transport = @import("http_transport");
const std_http_transport = @import("std_http_transport");

test "recording_transport_round_trip" {
    const gpa = std.testing.allocator;
    var rec = http_transport.RecordingTransport.init(gpa, 200, "canned-bytes");
    defer rec.deinit();

    const transport = rec.transport();
    var resp = try transport.request(.GET, "https://example/x", &.{}, null, gpa);
    defer resp.deinit(gpa);

    try std.testing.expectEqual(http_transport.Method.GET, rec.last_method.?);
    try std.testing.expectEqualStrings("https://example/x", rec.last_url.?);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("canned-bytes", resp.body);
}

const LoopbackMode = enum { get_ok, post_echo, rate };

const LoopbackTask = struct {
    server: std.Io.net.Server,
    io: Io,
    mode: LoopbackMode,
    gpa: std.mem.Allocator,
};

fn loopbackServerMain(task: *LoopbackTask) void {
    const io = task.io;
    var stream = task.server.accept(io) catch return;
    defer stream.close(io);

    var buf_in: [8192]u8 = undefined;
    var buf_out: [8192]u8 = undefined;
    var nr = stream.reader(io, &buf_in);
    var nw = stream.writer(io, &buf_out);
    var srv = std.http.Server.init(&nr.interface, &nw.interface);
    var req = srv.receiveHead() catch return;

    switch (task.mode) {
        .get_ok => {
            req.respond("ok", .{
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "ETag", .value = "\"abc\"" },
                },
            }) catch return;
        },
        .post_echo => {
            var body_read: [4096]u8 = undefined;
            const rdr = req.readerExpectNone(&body_read);
            var accum: Io.Writer.Allocating = .init(task.gpa);
            defer accum.deinit();
            _ = Io.Reader.streamRemaining(rdr, &accum.writer) catch return;
            const echoed = accum.toOwnedSlice() catch return;
            defer task.gpa.free(echoed);
            req.respond(echoed, .{ .keep_alive = false }) catch return;
        },
        .rate => {
            req.respond("x", .{
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "X-RateLimit-Remaining", .value = "4999" },
                    .{ .name = "X-RateLimit-Reset", .value = "1700000000" },
                },
            }) catch return;
        },
    }
}

test "std_http_transport_get_loopback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);

    const port = server.socket.address.getPort();

    var task: LoopbackTask = .{
        .server = server,
        .io = io,
        .mode = .get_ok,
        .gpa = gpa,
    };
    const thread = try std.Thread.spawn(.{}, loopbackServerMain, .{&task});
    defer thread.join();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var std_t: std_http_transport.StdHttpTransport = .{ .client = &client };
    const transport = std_t.transport();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{port});
    defer gpa.free(url);

    var resp = try transport.request(.GET, url, &.{}, null, gpa);
    defer resp.deinit(gpa);

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("ok", resp.body);
    try std.testing.expectEqualStrings("\"abc\"", resp.etag.?);
}

test "std_http_transport_post_with_body" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var task: LoopbackTask = .{
        .server = server,
        .io = io,
        .mode = .post_echo,
        .gpa = gpa,
    };
    const thread = try std.Thread.spawn(.{}, loopbackServerMain, .{&task});
    defer thread.join();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var std_t: std_http_transport.StdHttpTransport = .{ .client = &client };
    const transport = std_t.transport();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/echo", .{port});
    defer gpa.free(url);

    var resp = try transport.request(.POST, url, &.{}, "hello-body", gpa);
    defer resp.deinit(gpa);

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expectEqualStrings("hello-body", resp.body);
}

test "std_http_transport_records_rate_limit_headers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var task: LoopbackTask = .{
        .server = server,
        .io = io,
        .mode = .rate,
        .gpa = gpa,
    };
    const thread = try std.Thread.spawn(.{}, loopbackServerMain, .{&task});
    defer thread.join();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var std_t: std_http_transport.StdHttpTransport = .{ .client = &client };
    const transport = std_t.transport();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/rate", .{port});
    defer gpa.free(url);

    var resp = try transport.request(.GET, url, &.{}, null, gpa);
    defer resp.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 4999), resp.rate_limit.remaining.?);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), resp.rate_limit.reset_unix.?);
}
