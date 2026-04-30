//! `AutoSource` — composite `CredentialProvider` that probes a fixed
//! sequence of upstream sources and returns the first one that yields a
//! credential.
//!
//! - On `HelperUnavailable` the walker advances to the next source (the
//!   designated fall-through signal).
//! - Any other source error short-circuits the walk so a misconfigured
//!   token is surfaced rather than silently swapped for a fallback.
//! - When every probed source returns `HelperUnavailable` the walker
//!   returns `AuthMissing`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const credential_provider = @import("credential_provider");

/// Composite source over a borrowed slice of `CredentialProvider`s. The
/// underlying providers must outlive any `AutoSource` that references them.
pub const AutoSource = struct {
    sources: []const credential_provider.CredentialProvider,

    /// Builds an `AutoSource` over `sources`.
    /// Empty `sources` -> `error.InvalidConfig`.
    pub fn init(
        sources: []const credential_provider.CredentialProvider,
    ) credential_provider.CredentialError!AutoSource {
        if (sources.len == 0) return error.InvalidConfig;
        return .{ .sources = sources };
    }

    /// No-op; declared for symmetry with sources that own state.
    pub fn deinit(self: *AutoSource) void {
        self.* = .{ .sources = &.{} };
    }

    /// Returns a `CredentialProvider` vtable backed by this walker.
    pub fn provider(self: *AutoSource) credential_provider.CredentialProvider {
        return .{
            .ctx = @ptrCast(self),
            .get_fn = autoGet,
        };
    }

    fn autoGet(
        ctx: *anyopaque,
        gpa: Allocator,
    ) credential_provider.CredentialError!credential_provider.Credential {
        const self: *AutoSource = @ptrCast(@alignCast(ctx));
        for (self.sources) |source| {
            const cred = source.get(gpa) catch |err| switch (err) {
                error.HelperUnavailable => continue,
                else => return err,
            };
            return cred;
        }
        return error.AuthMissing;
    }
};
