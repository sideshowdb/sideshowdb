//! WASM `HttpTransport` that delegates HTTP to the embedder via
//! `sideshowdb_host_http_request`.
//!
//! The host receives a packed header blob, optional request body bytes, and a
//! guest-owned response scratch buffer. The host writes a raw `HTTP/1.x`
//! response (status line + headers + `\r\n\r\n` + body) into that buffer and
//! sets `*response_actual_len_out` to the number of bytes written.

const std = @import("std");
const builtin = @import("builtin");
const http_transport = @import("http_transport.zig");
const Allocator = std.mem.Allocator;

comptime {
    if (builtin.os.tag != .freestanding and builtin.os.tag != .wasi) {
        @compileError("host_http_transport is only built for wasm32-freestanding and wasm32-wasi");
    }
}

extern fn sideshowdb_host_http_request(
    method: u32,
    url_ptr: u32,
    url_len: u32,
    headers_ptr: u32,
    headers_len: u32,
    body_ptr: u32,
    body_len: u32,
    response_buf_ptr: u32,
    response_buf_capacity: u32,
    response_actual_len_out_ptr: u32,
) i32;

/// Errors specific to the host HTTP bridge.
pub const HostHttpTransportError = error{
    /// The host reported that `response_buf_capacity` was too small; grow and retry.
    ResponseTooLarge,
    /// The host import returned a non-success status code.
    HostFailure,
    /// The bytes returned by the host were not a parseable HTTP response.
    InvalidResponse,
};

/// WASM `HttpTransport` backed by `sideshowdb_host_http_request`.
pub const HostHttpTransport = struct {
    initial_response_capacity: usize,

    /// Configuration for `HostHttpTransport.init`.
    pub const Options = struct {
        /// Initial guest buffer size for the host-written HTTP response.
        initial_response_capacity: usize = 64 * 1024,
    };

    /// Builds a transport with the given response buffer sizing policy.
    pub fn init(options: Options) HostHttpTransport {
        return .{ .initial_response_capacity = options.initial_response_capacity };
    }

    /// Returns an `HttpTransport` vtable backed by this bridge.
    pub fn transport(self: *HostHttpTransport) http_transport.HttpTransport {
        return .{
            .ctx = @ptrCast(self),
            .request_fn = dispatch,
        };
    }

    fn dispatch(
        ctx: *anyopaque,
        method: http_transport.Method,
        url: []const u8,
        headers: []const http_transport.Header,
        body: ?[]const u8,
        gpa: Allocator,
    ) !http_transport.Response {
        const self: *HostHttpTransport = @ptrCast(@alignCast(ctx));
        return self.dispatchInner(method, url, headers, body, gpa);
    }

    fn dispatchInner(
        self: *HostHttpTransport,
        method: http_transport.Method,
        url: []const u8,
        headers: []const http_transport.Header,
        body: ?[]const u8,
        gpa: Allocator,
    ) !http_transport.Response {
        const headers_blob = try packHeaders(gpa, headers);
        defer gpa.free(headers_blob);

        const body_ptr: u32 = if (body) |b| @intFromPtr(b.ptr) else 0;
        const body_len: u32 = if (body) |b| @truncate(b.len) else 0;

        var cap: usize = self.initial_response_capacity;
        const max_cap = 16 * 1024 * 1024;
        while (cap <= max_cap) {
            const response_buf = try gpa.alloc(u8, cap);
            defer gpa.free(response_buf);

            var actual_len: u32 = 0;
            const rc = sideshowdb_host_http_request(
                @intFromEnum(method),
                @intFromPtr(url.ptr),
                @truncate(url.len),
                @intFromPtr(headers_blob.ptr),
                @truncate(headers_blob.len),
                body_ptr,
                body_len,
                @intFromPtr(response_buf.ptr),
                @truncate(response_buf.len),
                @intFromPtr(&actual_len),
            );
            if (rc == -2) {
                if (cap > max_cap / 2) return HostHttpTransportError.ResponseTooLarge;
                cap *= 2;
                continue;
            }
            if (rc != 0) return HostHttpTransportError.HostFailure;
            if (actual_len > response_buf.len) return HostHttpTransportError.InvalidResponse;

            const filled = response_buf[0..actual_len];
            if (actual_len == response_buf.len and !looksCompleteHttpMessage(filled)) {
                if (cap > max_cap / 2) return HostHttpTransportError.ResponseTooLarge;
                cap *= 2;
                continue;
            }

            return parseHttpResponse(gpa, filled);
        }
        return HostHttpTransportError.ResponseTooLarge;
    }
};

fn looksCompleteHttpMessage(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "\r\n\r\n") != null;
}

fn packHeaders(gpa: Allocator, headers: []const http_transport.Header) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeU32Le(&out, gpa, @truncate(headers.len));
    for (headers) |h| {
        try writeU32Le(&out, gpa, @truncate(h.name.len));
        try writeU32Le(&out, gpa, @truncate(h.value.len));
        try out.appendSlice(gpa, h.name);
        try out.appendSlice(gpa, h.value);
    }
    return try out.toOwnedSlice(gpa);
}

fn writeU32Le(list: *std.ArrayList(u8), gpa: Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try list.appendSlice(gpa, &buf);
}

fn parseHttpResponse(gpa: Allocator, raw: []const u8) !http_transport.Response {
    const sep = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return HostHttpTransportError.InvalidResponse;
    const head_blob = raw[0 .. sep + 4];
    const body = raw[sep + 4 ..];

    const head = std.http.Client.Response.Head.parse(head_blob) catch return HostHttpTransportError.InvalidResponse;

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

    var hit = head.iterateHeaders();
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

    const owned_body = try gpa.dupe(u8, body);
    errdefer gpa.free(owned_body);

    const status_u16: u16 = @intCast(@intFromEnum(head.status));
    const owned_headers = try resp_headers.toOwnedSlice(gpa);

    return .{
        .status = status_u16,
        .headers = owned_headers,
        .body = owned_body,
        .etag = etag,
        .rate_limit = rate,
    };
}
