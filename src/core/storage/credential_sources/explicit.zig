//! `ExplicitSource` — a `CredentialProvider` source that yields a fixed
//! bearer token supplied at construction. Used by tests, the CLI's
//! `--credential-helper explicit` mode, and any host that injects a token
//! through configuration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const credential_provider = @import("credential_provider");

/// Static-token credential source. Borrows the token slice; callers must
/// keep it valid for the lifetime of the source.
pub const ExplicitSource = struct {
    token: []const u8,

    /// Returns an `ExplicitSource` wrapping `token`.
    ///
    /// `error.InvalidConfig` is returned when `token` is empty so the auto
    /// walker reports a misconfigured explicit credential as a hard failure
    /// rather than silently falling through.
    pub fn init(token: []const u8) credential_provider.CredentialError!ExplicitSource {
        if (token.len == 0) return error.InvalidConfig;
        return .{ .token = token };
    }

    /// Currently a no-op; declared for symmetry with sources that own
    /// allocator-backed state.
    pub fn deinit(self: *ExplicitSource) void {
        self.* = .{ .token = "" };
    }

    /// Returns a `CredentialProvider` vtable backed by this source.
    pub fn provider(self: *ExplicitSource) credential_provider.CredentialProvider {
        return .{
            .ctx = @ptrCast(self),
            .get_fn = explicitGet,
        };
    }

    fn explicitGet(
        ctx: *anyopaque,
        gpa: Allocator,
    ) credential_provider.CredentialError!credential_provider.Credential {
        const self: *ExplicitSource = @ptrCast(@alignCast(ctx));
        const owned = try gpa.dupe(u8, self.token);
        return .{ .bearer = owned };
    }
};
