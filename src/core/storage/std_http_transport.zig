//! Native `HttpTransport` backed by `std.http.Client` (cleartext or TLS).
//!
//! Used by GitHub API RefStore on desktop and server targets. Not linked into
//! `wasm32-freestanding` builds.

const std = @import("std");
const http_transport = @import("http_transport");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Uri = std.Uri;

/// Thin wrapper around `std.http.Client` implementing `HttpTransport`.
pub const StdHttpTransport = struct {
    client: *std.http.Client,

    /// Returns an `HttpTransport` vtable backed by this client.
    pub fn transport(self: *StdHttpTransport) http_transport.HttpTransport {
        return .{
            .ctx = @ptrCast(self),
            .request_fn = send,
        };
    }

    fn send(
        ctx: *anyopaque,
        method: http_transport.Method,
        url: []const u8,
        headers: []const http_transport.Header,
        body: ?[]const u8,
        gpa: Allocator,
    ) anyerror!http_transport.Response {
        const self: *StdHttpTransport = @ptrCast(@alignCast(ctx));
        return self.sendInner(method, url, headers, body, gpa) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.TlsInitializationFailed,
            error.CertificateBundleLoadFailure,
            => return http_transport.StdTransportError.TlsFailure,
            error.HttpHeadersInvalid,
            error.UnsupportedUriScheme,
            error.UriMissingHost,
            => return http_transport.StdTransportError.InvalidResponse,
            else => return http_transport.StdTransportError.TransportFailure,
        };
    }

    fn sendInner(
        self: *StdHttpTransport,
        method: http_transport.Method,
        url: []const u8,
        headers: []const http_transport.Header,
        body: ?[]const u8,
        gpa: Allocator,
    ) !http_transport.Response {
        const client = self.client;
        const uri = try Uri.parse(url);

        var extra_storage: std.ArrayList(std.http.Header) = .empty;
        defer {
            for (extra_storage.items) |h| {
                gpa.free(h.name);
                gpa.free(h.value);
            }
            extra_storage.deinit(gpa);
        }
        try extra_storage.ensureTotalCapacityPrecise(gpa, headers.len);
        for (headers) |h| {
            try extra_storage.append(gpa, .{
                .name = try gpa.dupe(u8, h.name),
                .value = try gpa.dupe(u8, h.value),
            });
        }

        var req = try client.request(toStdMethod(method), uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .extra_headers = extra_storage.items,
        });
        defer req.deinit();

        if (body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var bw = try req.sendBodyUnflushed(&.{});
            try bw.writer.writeAll(payload);
            try bw.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var redirect_buf: [8192]u8 = undefined;
        var http_resp = try req.receiveHead(&redirect_buf);

        var resp_headers: std.ArrayList(http_transport.Header) = .empty;
        errdefer {
            for (resp_headers.items) |h| {
                gpa.free(h.name);
                gpa.free(h.value);
            }
            resp_headers.deinit(gpa);
        }

        var etag: ?[]const u8 = null;
        var rate: http_transport.RateLimitInfo = .{};

        var hit = http_resp.head.iterateHeaders();
        while (hit.next()) |h| {
            const name_dup = try gpa.dupe(u8, h.name);
            errdefer gpa.free(name_dup);
            const value_dup = try gpa.dupe(u8, h.value);
            errdefer gpa.free(value_dup);
            try resp_headers.append(gpa, .{ .name = name_dup, .value = value_dup });

            if (std.ascii.eqlIgnoreCase(h.name, "etag")) {
                etag = resp_headers.items[resp_headers.items.len - 1].value;
            } else if (std.ascii.eqlIgnoreCase(h.name, "x-ratelimit-remaining")) {
                rate.remaining = std.fmt.parseInt(u32, std.mem.trim(u8, h.value, " \t"), 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(h.name, "x-ratelimit-reset")) {
                rate.reset_unix = std.fmt.parseInt(i64, std.mem.trim(u8, h.value, " \t"), 10) catch null;
            }
        }

        var transfer_buf: [8192]u8 = undefined;
        const body_reader = http_resp.reader(&transfer_buf);
        var body_out: Io.Writer.Allocating = .init(gpa);
        defer body_out.deinit();
        _ = try Io.Reader.streamRemaining(body_reader, &body_out.writer);
        const owned_body = try body_out.toOwnedSlice();

        const status_u16: u16 = @intCast(@intFromEnum(http_resp.head.status));
        const owned_header_slice = try resp_headers.toOwnedSlice(gpa);

        return .{
            .status = status_u16,
            .headers = owned_header_slice,
            .body = owned_body,
            .etag = etag,
            .rate_limit = rate,
        };
    }
};

fn toStdMethod(method: http_transport.Method) std.http.Method {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .PATCH => .PATCH,
        .PUT => .PUT,
        .DELETE => .DELETE,
    };
}
