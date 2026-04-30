//! Unit tests for `HostCapabilitySource`. The dispatcher is injected so
//! these run on native targets without a WASM runtime; the WASM-side
//! integration test lives in `tests/wasm_exports_test.zig`.

const std = @import("std");
const credential_provider = @import("credential_provider");
const host_capability = @import("credential_source_host_capability");

const HostCapabilitySource = host_capability.HostCapabilitySource;

const StubResponse = union(enum) {
    success: []const u8,
    unavailable,
    too_small: usize,
    transport_error: i32,
    /// Simulates a misbehaving host: returns rc=0 but sets `actual_len`
    /// to a value larger than the supplied buffer capacity. The source must
    /// detect this and return `error.TransportError`.
    success_overreport_len,
};

const Stub = struct {
    response: StubResponse,
    follow_up: ?StubResponse = null,
    calls: u32 = 0,
    last_provider: []const u8 = "",
    last_scope: []const u8 = "",
    last_capacity: usize = 0,

    var active: ?*Stub = null;

    fn install(self: *Stub) void {
        active = self;
    }

    fn uninstall() void {
        active = null;
    }

    fn dispatch(
        provider_ptr: [*]const u8,
        provider_len: usize,
        scope_ptr: [*]const u8,
        scope_len: usize,
        out_buf_ptr: [*]u8,
        out_capacity: usize,
        out_actual_len: *u32,
    ) i32 {
        const self = active.?;
        self.calls += 1;
        self.last_provider = provider_ptr[0..provider_len];
        self.last_scope = scope_ptr[0..scope_len];
        self.last_capacity = out_capacity;

        const r: StubResponse = if (self.calls == 1) self.response else (self.follow_up orelse self.response);
        switch (r) {
            .success => |bytes| {
                if (bytes.len > out_capacity) {
                    out_actual_len.* = @truncate(bytes.len);
                    return host_capability.rc_too_small;
                }
                @memcpy(out_buf_ptr[0..bytes.len], bytes);
                out_actual_len.* = @truncate(bytes.len);
                return 0;
            },
            .unavailable => {
                out_actual_len.* = 0;
                return host_capability.rc_unavailable;
            },
            .too_small => |required| {
                out_actual_len.* = @truncate(required);
                return host_capability.rc_too_small;
            },
            .transport_error => |code| {
                out_actual_len.* = 0;
                return code;
            },
            .success_overreport_len => {
                // Write one byte so the return is rc=0, but lie about actual_len.
                out_buf_ptr[0] = 'x';
                out_actual_len.* = @truncate(out_capacity + 1);
                return 0;
            },
        }
    }
};

test "host_capability_returns_bearer_on_success" {
    const gpa = std.testing.allocator;

    var stub: Stub = .{ .response = .{ .success = "from-host" } };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
    });
    defer src.deinit();

    var p = src.provider();
    var cred = try p.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expect(cred == .bearer);
    try std.testing.expectEqualStrings("from-host", cred.bearer);
    try std.testing.expectEqual(@as(u32, 1), stub.calls);
}

test "host_capability_returns_helper_unavailable_on_minus_one" {
    const gpa = std.testing.allocator;

    var stub: Stub = .{ .response = .unavailable };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
    });
    defer src.deinit();

    var p = src.provider();
    try std.testing.expectError(error.HelperUnavailable, p.get(gpa));
}

test "host_capability_returns_auth_invalid_on_empty_success" {
    const gpa = std.testing.allocator;

    var stub: Stub = .{ .response = .{ .success = "" } };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
    });
    defer src.deinit();

    var p = src.provider();
    try std.testing.expectError(error.AuthInvalid, p.get(gpa));
}

test "host_capability_returns_auth_invalid_on_whitespace_only_success" {
    const gpa = std.testing.allocator;

    var stub: Stub = .{ .response = .{ .success = " \t\r\n" } };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
    });
    defer src.deinit();

    var p = src.provider();
    try std.testing.expectError(error.AuthInvalid, p.get(gpa));
}

test "host_capability_trims_trailing_whitespace_and_nul" {
    const gpa = std.testing.allocator;

    var stub: Stub = .{ .response = .{ .success = "tok-trimmed\n\x00" } };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
    });
    defer src.deinit();

    var p = src.provider();
    var cred = try p.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expectEqualStrings("tok-trimmed", cred.bearer);
}

test "host_capability_returns_transport_error_on_unknown_negative" {
    const gpa = std.testing.allocator;

    var stub: Stub = .{ .response = .{ .transport_error = -42 } };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
    });
    defer src.deinit();

    var p = src.provider();
    try std.testing.expectError(error.TransportError, p.get(gpa));
}

test "host_capability_grows_buffer_on_too_small" {
    const gpa = std.testing.allocator;

    // First call: signal too-small with a required capacity larger than the
    // initial buffer. Second call: serve the credential.
    var stub: Stub = .{
        .response = .{ .too_small = 5000 },
        .follow_up = .{ .success = "long-token" },
    };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
        .initial_buffer_bytes = 16,
    });
    defer src.deinit();

    var p = src.provider();
    var cred = try p.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expectEqualStrings("long-token", cred.bearer);
    try std.testing.expectEqual(@as(u32, 2), stub.calls);
    try std.testing.expectEqual(@as(usize, 5000), stub.last_capacity);
}

test "host_capability_returns_transport_error_when_growth_exceeds_cap" {
    const gpa = std.testing.allocator;

    var stub: Stub = .{
        .response = .{ .too_small = host_capability.max_buffer_bytes + 1 },
    };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
    });
    defer src.deinit();

    var p = src.provider();
    try std.testing.expectError(error.TransportError, p.get(gpa));
}

test "host_capability_returns_transport_error_when_too_small_lies" {
    const gpa = std.testing.allocator;

    // Host signals too-small but reports a required length that fits in
    // the current buffer. That's a host bug; the source must surface it
    // rather than spinning forever.
    var stub: Stub = .{ .response = .{ .too_small = 4 } };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
        .initial_buffer_bytes = 16,
    });
    defer src.deinit();

    var p = src.provider();
    try std.testing.expectError(error.TransportError, p.get(gpa));
}

test "host_capability_passes_provider_and_scope_to_host" {
    const gpa = std.testing.allocator;

    var stub: Stub = .{ .response = .{ .success = "ok" } };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
        .provider = "gitlab",
        .scope = "repo:read",
    });
    defer src.deinit();

    var p = src.provider();
    var cred = try p.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expectEqualStrings("gitlab", stub.last_provider);
    try std.testing.expectEqualStrings("repo:read", stub.last_scope);
}

test "host_capability_init_rejects_empty_provider" {
    const gpa = std.testing.allocator;

    const result = HostCapabilitySource.init(.{
        .gpa = gpa,
        .provider = "",
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "host_capability_init_rejects_zero_buffer" {
    const gpa = std.testing.allocator;

    const result = HostCapabilitySource.init(.{
        .gpa = gpa,
        .initial_buffer_bytes = 0,
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "host_capability_init_allows_empty_scope" {
    const gpa = std.testing.allocator;

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .scope = "",
    });
    defer src.deinit();
}

test "host_capability_native_default_dispatcher_returns_helper_unavailable" {
    const gpa = std.testing.allocator;

    // Default dispatcher on native targets reports unavailable so the
    // auto-walker treats the host as a fall-through.
    var src = try HostCapabilitySource.init(.{ .gpa = gpa });
    defer src.deinit();

    var p = src.provider();
    try std.testing.expectError(error.HelperUnavailable, p.get(gpa));
}

test "host_capability_guards_against_overreported_actual_len" {
    const gpa = std.testing.allocator;

    // Host returns rc=0 but sets actual_len > buf.len — a host bug that
    // would cause out-of-bounds reads if trusted. The source must surface
    // this as TransportError rather than accessing memory past the buffer.
    var stub: Stub = .{ .response = .success_overreport_len };
    stub.install();
    defer Stub.uninstall();

    var src = try HostCapabilitySource.init(.{
        .gpa = gpa,
        .dispatcher = &Stub.dispatch,
    });
    defer src.deinit();

    var p = src.provider();
    try std.testing.expectError(error.TransportError, p.get(gpa));
}
