//! Credential plumbing for remote-backed `RefStore` implementations.
//!
//! Defines the `Credential` value, the `CredentialProvider` vtable, and
//! `CredentialSpec` plus `fromSpec` so callers can describe a credential
//! source declaratively (CLI flag, config field, host capability) and let the
//! storage layer resolve it. Per-source modules under
//! `src/core/storage/credential_sources/` plug into this surface.

const std = @import("std");
const Allocator = std.mem.Allocator;

const explicit_source = @import("credential_source_explicit");
const env_source = @import("credential_source_env");

/// HTTP basic auth pair returned by the `git credential fill` source.
pub const BasicCreds = struct {
    user: []const u8,
    password: []const u8,
};

/// Resolved credential value handed to the GitHub API RefStore. Owned by the
/// caller — call `deinit` with the same allocator passed to `provider.get`.
pub const Credential = union(enum) {
    bearer: []const u8,
    basic: BasicCreds,
    none: void,

    /// Frees any allocator-owned bytes inside the credential.
    pub fn deinit(self: *Credential, gpa: Allocator) void {
        switch (self.*) {
            .bearer => |tok| gpa.free(tok),
            .basic => |creds| {
                gpa.free(creds.user);
                gpa.free(creds.password);
            },
            .none => {},
        }
        self.* = .{ .none = {} };
    }
};

/// Errors a credential source may return.
pub const CredentialError = error{
    /// The configuration that named this source is malformed (e.g. empty
    /// explicit token, unset env var name).
    InvalidConfig,
    /// This source is unavailable on the current platform / process. The
    /// `auto` walker treats this as a fall-through signal.
    HelperUnavailable,
    /// A helper produced no usable credential (e.g. `gh` is logged out).
    AuthInvalid,
    /// A helper failed for reasons that do not map to the above (timeout,
    /// IO error, malformed output).
    TransportError,
    /// No source produced a credential; surfaced by the auto walker when
    /// every probed source signalled `HelperUnavailable`.
    AuthMissing,
} || Allocator.Error;

/// Future configuration for the OS keychain source. Filled in when the
/// dedicated source ticket lands; carried here so `CredentialSpec` stays
/// stable.
pub const KeychainConfig = struct {
    service: ?[]const u8 = null,
    account: ?[]const u8 = null,
};

/// Declarative description of a credential source. Resolved into a live
/// `CredentialProvider` by `fromSpec`.
pub const CredentialSpec = union(enum) {
    auto,
    env: []const u8,
    explicit: []const u8,
    gh_helper,
    git_helper,
    keychain: KeychainConfig,
    host_capability,
};

/// Optional knobs accepted by `fromSpec` (timeout overrides, custom
/// executable lookups). Empty by default — populated as later tasks land.
pub const SpecOptions = struct {};

/// Target-agnostic credential provider surface.
///
/// Sources implement `get_fn` and hand back a vtable. The `auto` walker
/// composes several providers behind a single `CredentialProvider`.
pub const CredentialProvider = struct {
    ctx: *anyopaque,
    get_fn: *const fn (ctx: *anyopaque, gpa: Allocator) CredentialError!Credential,

    /// Resolves a credential, allocating into `gpa`. Caller must `deinit`
    /// the returned `Credential` with the same allocator.
    pub fn get(self: CredentialProvider, gpa: Allocator) CredentialError!Credential {
        return self.get_fn(self.ctx, gpa);
    }
};

/// Owning wrapper produced by `fromSpec`. Holds whatever per-source state
/// the spec required so the caller does not have to track each source type
/// directly. The wrapper must remain at a stable address for the lifetime
/// of any `CredentialProvider` borrowed from it.
pub const ProviderHandle = struct {
    backing: Backing,

    const Backing = union(enum) {
        none,
        explicit: explicit_source.ExplicitSource,
        env: env_source.EnvSource,
    };

    /// Returns a `CredentialProvider` whose vtable borrows the per-source
    /// state stored inside this handle. The handle must outlive the
    /// returned provider.
    pub fn provider(self: *ProviderHandle) CredentialProvider {
        return switch (self.backing) {
            .explicit => |*src| src.provider(),
            .env => |*src| src.provider(),
            .none => unreachable,
        };
    }

    /// Releases per-source state. Safe to call multiple times.
    pub fn deinit(self: *ProviderHandle) void {
        switch (self.backing) {
            .explicit => |*src| src.deinit(),
            .env => |*src| src.deinit(),
            .none => {},
        }
        self.backing = .{ .none = {} };
    }
};

/// Builds a `ProviderHandle` from a declarative spec.
///
/// Only the `explicit` branch is wired in this initial drop; the env, gh,
/// git, host_capability, keychain, and auto branches return
/// `error.HelperUnavailable` until their dedicated source modules land.
pub fn fromSpec(spec: CredentialSpec, opts: SpecOptions) CredentialError!ProviderHandle {
    _ = opts;
    switch (spec) {
        .explicit => |token| {
            const src = try explicit_source.ExplicitSource.init(token);
            return .{ .backing = .{ .explicit = src } };
        },
        .env => |var_name| {
            const src = try env_source.EnvSource.init(var_name);
            return .{ .backing = .{ .env = src } };
        },
        .auto, .gh_helper, .git_helper, .keychain, .host_capability => {
            return error.HelperUnavailable;
        },
    }
}

test {
    _ = explicit_source;
    _ = env_source;
}
