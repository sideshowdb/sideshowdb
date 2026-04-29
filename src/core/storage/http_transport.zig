//! HTTP transport abstraction for remote-backed `RefStore` implementations.
//!
//! Native builds use `std_http_transport.zig`; WASM uses `host_http_transport.zig`.
//! Callers depend on this interface so GitHub API logic stays target-agnostic.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// HTTP verb supported by `HttpTransport`.
pub const Method = enum {
    GET,
    POST,
    PATCH,
    PUT,
    DELETE,
};

/// Single HTTP header name/value pair.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Parsed upstream rate limit metadata when GitHub-style headers are present.
pub const RateLimitInfo = struct {
    remaining: ?u32 = null,
    reset_unix: ?i64 = null,
};

/// Normalized HTTP response returned by `HttpTransport.request`.
///
/// `body` is owned by the caller and must be freed with the same `gpa` passed
/// to `request`. Header slices may alias the body buffer in real transports;
/// tests use empty `headers` unless stated otherwise.
pub const Response = struct {
    status: u16,
    headers: []Header,
    body: []u8,
    etag: ?[]const u8,
    rate_limit: RateLimitInfo,

    /// Frees `body` and every duplicated `headers` name/value (including empty
    /// slices produced by `RecordingTransport`).
    pub fn deinit(self: *Response, gpa: Allocator) void {
        gpa.free(self.body);
        for (self.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.headers);
        self.* = undefined;
    }
};

/// Errors returned by `StdHttpTransport` when the stack cannot produce a usable
/// HTTP exchange.
pub const StdTransportError = error{
    TransportFailure,
    TlsFailure,
    InvalidResponse,
};

/// Target-agnostic HTTP client surface used by GitHub API RefStore.
pub const HttpTransport = struct {
    ctx: *anyopaque,
    request_fn: *const fn (
        ctx: *anyopaque,
        method: Method,
        url: []const u8,
        headers: []const Header,
        body: ?[]const u8,
        gpa: Allocator,
    ) anyerror!Response,

    /// Issues one HTTP request using the configured backend.
    pub fn request(
        self: HttpTransport,
        method: Method,
        url: []const u8,
        headers: []const Header,
        body: ?[]const u8,
        gpa: Allocator,
    ) !Response {
        return self.request_fn(self.ctx, method, url, headers, body, gpa);
    }
};

/// Test fake that records the last request and returns a canned `Response`.
pub const RecordingTransport = struct {
    gpa: Allocator,
    last_method: ?Method = null,
    last_url: ?[]u8 = null,
    template_status: u16,
    template_body: []const u8,

    /// Builds a recorder that responds with `template_status` / `template_body`.
    pub fn init(allocator: Allocator, template_status: u16, template_body: []const u8) RecordingTransport {
        return .{
            .gpa = allocator,
            .last_method = null,
            .last_url = null,
            .template_status = template_status,
            .template_body = template_body,
        };
    }

    /// Releases duplicated URL state captured from the last request.
    pub fn deinit(self: *RecordingTransport) void {
        if (self.last_url) |u| self.gpa.free(u);
        self.last_url = null;
    }

    /// Returns an `HttpTransport` vtable backed by this recorder.
    pub fn transport(self: *RecordingTransport) HttpTransport {
        return .{
            .ctx = @ptrCast(self),
            .request_fn = recordingRequest,
        };
    }

    fn recordingRequest(
        ctx: *anyopaque,
        method: Method,
        url: []const u8,
        headers: []const Header,
        body: ?[]const u8,
        gpa: Allocator,
    ) !Response {
        _ = headers;
        _ = body;
        const self: *RecordingTransport = @alignCast(@ptrCast(ctx));
        if (self.last_url) |old| self.gpa.free(old);
        self.last_method = method;
        self.last_url = try self.gpa.dupe(u8, url);
        const owned_body = try gpa.dupe(u8, self.template_body);
        errdefer gpa.free(owned_body);
        const owned_headers = try gpa.alloc(Header, 0);
        return .{
            .status = self.template_status,
            .headers = owned_headers,
            .body = owned_body,
            .etag = null,
            .rate_limit = .{},
        };
    }
};
