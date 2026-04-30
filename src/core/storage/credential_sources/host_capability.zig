//! `HostCapabilitySource` — a `CredentialProvider` source that delegates
//! credential resolution to the embedder via a synchronous host call.
//!
//! On WASM targets the default dispatcher invokes the
//! `sideshowdb_host_get_credential` host import. On native targets the
//! source compiles, but its default dispatcher returns
//! `error.HelperUnavailable` so the auto walker treats the missing host as
//! a fall-through. Tests inject a custom dispatcher to exercise the buffer
//! sizing and error-mapping logic without a real WASM runtime.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const credential_provider = @import("credential_provider");

/// Default provider key passed to the host dispatcher.
pub const default_provider: []const u8 = "github";
/// Default scope hint passed to the host dispatcher.
pub const default_scope: []const u8 = "";
/// Default initial response-buffer size. Doubles on the buffer-too-small
/// signal until `max_buffer_bytes` is reached.
pub const default_initial_buffer_bytes: usize = 1024;
/// Hard ceiling on the response buffer; the host cannot demand more than
/// this many bytes for a single credential.
pub const max_buffer_bytes: usize = 64 * 1024;
/// Host return code for "credential is unavailable for this provider+scope".
pub const rc_unavailable: i32 = -1;
/// Host return code for "buffer too small; required length written to
/// `out_actual_len`". Caller retries with a larger buffer.
pub const rc_too_small: i32 = -2;

const is_wasm = switch (builtin.os.tag) {
    .freestanding, .wasi => true,
    else => false,
};

const wasm_externs = if (is_wasm) struct {
    extern fn sideshowdb_host_get_credential(
        provider_ptr: [*]const u8,
        provider_len: usize,
        scope_ptr: [*]const u8,
        scope_len: usize,
        out_buf_ptr: [*]u8,
        out_capacity: usize,
        out_actual_len: *u32,
    ) i32;
} else struct {};

/// Function pointer signature implemented by the host import (and by test
/// stubs). The dispatcher writes up to `out_capacity` bytes into the
/// caller-owned buffer and sets `out_actual_len.*` to the number of bytes
/// the host wanted to write. Returns 0 on success, `rc_unavailable` (-1)
/// when the host has no credential for this provider+scope,
/// `rc_too_small` (-2) when `out_capacity` was too small for the
/// credential, and any other negative value for host-side transport
/// failures.
pub const HostDispatcher = *const fn (
    provider_ptr: [*]const u8,
    provider_len: usize,
    scope_ptr: [*]const u8,
    scope_len: usize,
    out_buf_ptr: [*]u8,
    out_capacity: usize,
    out_actual_len: *u32,
) i32;

/// Returns the platform-default dispatcher. WASM targets bind to a thin
/// wrapper around the real `sideshowdb_host_get_credential` host import;
/// native targets bind to a stub that always reports
/// `error.HelperUnavailable` because the host extern is not linkable
/// outside WASM.
///
/// Example (from `test "host_capability_native_default_dispatcher_returns_helper_unavailable"`):
/// ```
/// var src = try HostCapabilitySource.init(.{
///     .gpa = gpa,
///     .dispatcher = defaultDispatcher(),
/// });
/// ```
pub fn defaultDispatcher() HostDispatcher {
    return if (is_wasm) &wasmDispatcher else &nativeStubDispatcher;
}

fn wasmDispatcher(
    provider_ptr: [*]const u8,
    provider_len: usize,
    scope_ptr: [*]const u8,
    scope_len: usize,
    out_buf_ptr: [*]u8,
    out_capacity: usize,
    out_actual_len: *u32,
) i32 {
    if (!is_wasm) unreachable;
    return wasm_externs.sideshowdb_host_get_credential(
        provider_ptr,
        provider_len,
        scope_ptr,
        scope_len,
        out_buf_ptr,
        out_capacity,
        out_actual_len,
    );
}

fn nativeStubDispatcher(
    provider_ptr: [*]const u8,
    provider_len: usize,
    scope_ptr: [*]const u8,
    scope_len: usize,
    out_buf_ptr: [*]u8,
    out_capacity: usize,
    out_actual_len: *u32,
) i32 {
    _ = provider_ptr;
    _ = provider_len;
    _ = scope_ptr;
    _ = scope_len;
    _ = out_buf_ptr;
    _ = out_capacity;
    out_actual_len.* = 0;
    return rc_unavailable;
}

/// Construction parameters for `HostCapabilitySource`.
pub const Config = struct {
    /// Allocator used for the working response buffer and the returned
    /// `Credential.bearer` slice.
    gpa: Allocator,
    /// Provider key passed to the host (e.g. `"github"`, `"gitlab"`).
    /// Must be non-empty.
    provider: []const u8 = default_provider,
    /// Scope hint passed to the host. Empty by default; embedder may use
    /// it to refine the lookup (e.g. `"repo:read"`).
    scope: []const u8 = default_scope,
    /// Initial buffer capacity. Must be non-zero.
    initial_buffer_bytes: usize = default_initial_buffer_bytes,
    /// Override for the host dispatcher. `null` selects
    /// `defaultDispatcher()`. Tests inject a stub that records arguments
    /// and produces deterministic outputs.
    dispatcher: ?HostDispatcher = null,
};

/// Source that resolves a bearer token by calling the host's credential
/// capability.
pub const HostCapabilitySource = struct {
    gpa: Allocator,
    provider_key: []const u8,
    scope: []const u8,
    initial_buffer_bytes: usize,
    dispatcher: HostDispatcher,

    /// Builds a `HostCapabilitySource` from `config`.
    ///
    /// Returns `error.InvalidConfig` when `provider` is empty or
    /// `initial_buffer_bytes` is zero. The empty scope is allowed and
    /// signals "no scope hint" to the host.
    ///
    /// Example (from `test "host_capability_returns_bearer_on_success"`):
    /// ```
    /// var src = try HostCapabilitySource.init(.{
    ///     .gpa = gpa,
    ///     .dispatcher = &Stub.dispatch,
    /// });
    /// defer src.deinit();
    /// ```
    pub fn init(config: Config) credential_provider.CredentialError!HostCapabilitySource {
        if (config.provider.len == 0) return error.InvalidConfig;
        if (config.initial_buffer_bytes == 0) return error.InvalidConfig;
        return .{
            .gpa = config.gpa,
            .provider_key = config.provider,
            .scope = config.scope,
            .initial_buffer_bytes = config.initial_buffer_bytes,
            .dispatcher = config.dispatcher orelse defaultDispatcher(),
        };
    }

    /// Currently a no-op; declared for symmetry with sources that own
    /// allocator-backed state.
    pub fn deinit(self: *HostCapabilitySource) void {
        self.* = undefined;
    }

    /// Returns a `CredentialProvider` vtable backed by this source.
    ///
    /// Example (from `test "host_capability_returns_bearer_on_success"`):
    /// ```
    /// var p = src.provider();
    /// var cred = try p.get(gpa);
    /// defer cred.deinit(gpa);
    /// ```
    pub fn provider(self: *HostCapabilitySource) credential_provider.CredentialProvider {
        return .{
            .ctx = @ptrCast(self),
            .get_fn = hostGet,
        };
    }

    fn hostGet(
        ctx: *anyopaque,
        gpa: Allocator,
    ) credential_provider.CredentialError!credential_provider.Credential {
        const self: *HostCapabilitySource = @ptrCast(@alignCast(ctx));

        var cap: usize = self.initial_buffer_bytes;
        if (cap > max_buffer_bytes) cap = max_buffer_bytes;

        var attempts: u8 = 0;
        while (attempts < 8) : (attempts += 1) {
            const buf = try self.gpa.alloc(u8, cap);

            var actual_len: u32 = 0;
            const rc = self.dispatcher(
                self.provider_key.ptr,
                self.provider_key.len,
                self.scope.ptr,
                self.scope.len,
                buf.ptr,
                buf.len,
                &actual_len,
            );

            if (rc == 0) {
                defer self.gpa.free(buf);
                if (actual_len > buf.len) return error.TransportError;
                const trimmed = std.mem.trim(u8, buf[0..actual_len], " \t\r\n\x00");
                if (trimmed.len == 0) return error.AuthInvalid;
                return .{ .bearer = try gpa.dupe(u8, trimmed) };
            }
            self.gpa.free(buf);
            if (rc == rc_unavailable) return error.HelperUnavailable;
            if (rc == rc_too_small) {
                const required: usize = actual_len;
                if (required <= cap) return error.TransportError;
                if (required > max_buffer_bytes) return error.TransportError;
                cap = required;
                continue;
            }
            return error.TransportError;
        }
        return error.TransportError;
    }
};
