//! `EnvSource` — a `CredentialProvider` source that reads a bearer token
//! from a named environment variable (e.g. `GITHUB_TOKEN`).
//!
//! The lookup is parameterised so tests can inject a stub map without
//! mutating process-wide state. Production callers use `init`, which binds
//! the lookup to libc `getenv`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const credential_provider = @import("credential_provider");

/// Pluggable env-variable lookup. Returns an allocator-owned value or
/// `null` when the variable is absent.
pub const EnvLookup = struct {
    ctx: *anyopaque,
    lookup_fn: *const fn (
        ctx: *anyopaque,
        gpa: Allocator,
        name: []const u8,
    ) anyerror!?[]u8,
};

/// Reads a bearer token from a named environment variable.
pub const EnvSource = struct {
    var_name: []const u8,
    lookup: EnvLookup,

    /// Creates an `EnvSource` bound to libc `getenv`.
    /// Returns `error.InvalidConfig` when `var_name` is empty.
    pub fn init(var_name: []const u8) credential_provider.CredentialError!EnvSource {
        if (var_name.len == 0) return error.InvalidConfig;
        return .{ .var_name = var_name, .lookup = defaultLookup() };
    }

    /// Test-only entry point: builds an `EnvSource` whose env reads go
    /// through `lookup` instead of the process environment.
    pub fn initWithLookup(
        var_name: []const u8,
        lookup: EnvLookup,
    ) credential_provider.CredentialError!EnvSource {
        if (var_name.len == 0) return error.InvalidConfig;
        return .{ .var_name = var_name, .lookup = lookup };
    }

    /// No-op; declared for symmetry with sources that own state.
    pub fn deinit(self: *EnvSource) void {
        self.* = .{ .var_name = "", .lookup = defaultLookup() };
    }

    /// Returns a `CredentialProvider` vtable backed by this source.
    pub fn provider(self: *EnvSource) credential_provider.CredentialProvider {
        return .{
            .ctx = @ptrCast(self),
            .get_fn = envGet,
        };
    }

    fn envGet(
        ctx: *anyopaque,
        gpa: Allocator,
    ) credential_provider.CredentialError!credential_provider.Credential {
        const self: *EnvSource = @ptrCast(@alignCast(ctx));
        const value = self.lookup.lookup_fn(self.lookup.ctx, gpa, self.var_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TransportError,
        };
        const v = value orelse return error.HelperUnavailable;
        if (v.len == 0) {
            gpa.free(v);
            return error.HelperUnavailable;
        }
        return .{ .bearer = v };
    }
};

var default_lookup_sentinel: u8 = 0;

fn defaultLookup() EnvLookup {
    return .{ .ctx = @ptrCast(&default_lookup_sentinel), .lookup_fn = stdProcessLookup };
}

fn stdProcessLookup(
    ctx: *anyopaque,
    gpa: Allocator,
    name: []const u8,
) anyerror!?[]u8 {
    _ = ctx;
    const z_name = try gpa.dupeZ(u8, name);
    defer gpa.free(z_name);
    const raw = std.c.getenv(z_name.ptr) orelse return null;
    return try gpa.dupe(u8, std.mem.sliceTo(raw, 0));
}
