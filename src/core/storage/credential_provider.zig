//! Credential plumbing for remote-backed `RefStore` implementations.
//!
//! Defines the `Credential` value, the `CredentialProvider` vtable, and
//! `CredentialSpec` plus `fromSpec` so callers can describe a credential
//! source declaratively (CLI flag, config field, host capability) and let the
//! storage layer resolve it. Per-source modules under
//! `src/core/storage/credential_sources/` plug into this surface.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

const explicit_source = @import("credential_source_explicit");
const env_source = @import("credential_source_env");
const gh_helper = @import("credential_source_gh_helper");
const git_helper = @import("credential_source_git_helper");
const host_capability_source = @import("credential_source_host_capability");
const auto_walker = @import("credential_source_auto");

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

/// Default environment variable consulted by the `auto` walker on native
/// targets when no explicit `env: []const u8` arm is supplied.
pub const default_auto_env_var: []const u8 = "GITHUB_TOKEN";

/// Optional knobs accepted by `fromSpec`. Empty defaults keep callers that
/// only need `.explicit` / `.env` source-compatible; the helper-backed and
/// host-backed arms surface `error.InvalidConfig` when their required
/// dependencies are absent.
pub const SpecOptions = struct {
    /// Allocator used for any heap state owned by the returned
    /// `ProviderHandle` (sub-providers for the `auto` walker, owned slice
    /// of vtables, etc.). Must outlive the handle.
    gpa: Allocator,
    /// Async/blocking IO context. Required for sources that spawn
    /// subprocesses (`gh_helper`, `git_helper`, and the native `auto`
    /// chain).
    io: ?Io = null,
    /// Borrowed parent environment for subprocess sources. Must outlive
    /// the returned handle.
    parent_env: ?*const Environ.Map = null,
    /// Optional dispatcher override for `host_capability` (test seam).
    /// `null` selects the platform-default dispatcher.
    host_dispatcher: ?host_capability_source.HostDispatcher = null,
    /// Opaque context passed back to `host_dispatcher` on every call.
    /// Ignored when `host_dispatcher` is `null`.
    host_dispatcher_ctx: ?*anyopaque = null,
    /// Override for the env-var name consulted by the `.auto` walker.
    /// Defaults to `default_auto_env_var` (`GITHUB_TOKEN`).
    auto_env_var: []const u8 = default_auto_env_var,
};

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

const is_wasm = switch (builtin.os.tag) {
    .freestanding, .wasi => true,
    else => false,
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
        gh_helper: gh_helper.GhHelperSource,
        git_helper: git_helper.GitHelperSource,
        host_capability: host_capability_source.HostCapabilitySource,
        auto: AutoBundle,
    };

    /// Heap-allocated sub-source storage for the `.auto` chain. The
    /// handle owns both `entries` (the per-source state) and `vtables`
    /// (the `CredentialProvider` slice handed to `AutoSource`); both
    /// arrays share the same length and are freed together by
    /// `deinit`.
    const AutoBundle = struct {
        gpa: Allocator,
        entries: []AutoEntry,
        vtables: []CredentialProvider,
        walker: auto_walker.AutoSource,
    };

    /// Per-slot variant for `AutoBundle.entries`. Mirrors the source
    /// types the native and WASM `auto` chains can include.
    const AutoEntry = union(enum) {
        env: env_source.EnvSource,
        gh_helper: gh_helper.GhHelperSource,
        git_helper: git_helper.GitHelperSource,
        host_capability: host_capability_source.HostCapabilitySource,
    };

    /// Returns a `CredentialProvider` whose vtable borrows the per-source
    /// state stored inside this handle. The handle must outlive the
    /// returned provider.
    pub fn provider(self: *ProviderHandle) CredentialProvider {
        return switch (self.backing) {
            .explicit => |*src| src.provider(),
            .env => |*src| src.provider(),
            .gh_helper => |*src| src.provider(),
            .git_helper => |*src| src.provider(),
            .host_capability => |*src| src.provider(),
            .auto => |*bundle| bundle.walker.provider(),
            .none => unreachable,
        };
    }

    /// Releases per-source state. Safe to call multiple times.
    pub fn deinit(self: *ProviderHandle) void {
        switch (self.backing) {
            .explicit => |*src| src.deinit(),
            .env => |*src| src.deinit(),
            .gh_helper => |*src| src.deinit(),
            .git_helper => |*src| src.deinit(),
            .host_capability => |*src| src.deinit(),
            .auto => |*bundle| {
                deinitAutoEntries(bundle.entries);
                bundle.gpa.free(bundle.entries);
                bundle.gpa.free(bundle.vtables);
                bundle.walker.deinit();
            },
            .none => {},
        }
        self.backing = .{ .none = {} };
    }
};

/// Runs `deinit` on each `AutoEntry` in `entries`, dispatching on the
/// active union tag. Shared between `ProviderHandle.deinit` (full
/// teardown) and `buildAutoChain*` errdefers (partial teardown when
/// later construction steps fail).
fn deinitAutoEntries(entries: []ProviderHandle.AutoEntry) void {
    for (entries) |*entry| {
        switch (entry.*) {
            .env => |*src| src.deinit(),
            .gh_helper => |*src| src.deinit(),
            .git_helper => |*src| src.deinit(),
            .host_capability => |*src| src.deinit(),
        }
    }
}

/// Builds a `ProviderHandle` from a declarative spec.
///
/// All seven `CredentialSpec` arms are wired except `.keychain`, which
/// returns `error.HelperUnavailable` until the OS-keychain source ticket
/// lands. Helper-backed arms (`.gh_helper`, `.git_helper`, native `.auto`)
/// require `opts.io` and `opts.parent_env`; missing either yields
/// `error.InvalidConfig`.
pub fn fromSpec(spec: CredentialSpec, opts: SpecOptions) CredentialError!ProviderHandle {
    switch (spec) {
        .explicit => |token| {
            const src = try explicit_source.ExplicitSource.init(token);
            return .{ .backing = .{ .explicit = src } };
        },
        .env => |var_name| {
            const src = try env_source.EnvSource.init(var_name);
            return .{ .backing = .{ .env = src } };
        },
        .gh_helper => {
            const src = try buildGhHelper(opts);
            return .{ .backing = .{ .gh_helper = src } };
        },
        .git_helper => {
            const src = try buildGitHelper(opts);
            return .{ .backing = .{ .git_helper = src } };
        },
        .host_capability => {
            const src = try buildHostCapability(opts);
            return .{ .backing = .{ .host_capability = src } };
        },
        .auto => {
            const bundle = try buildAutoChain(opts);
            return .{ .backing = .{ .auto = bundle } };
        },
        .keychain => return error.HelperUnavailable,
    }
}

fn buildGhHelper(opts: SpecOptions) CredentialError!gh_helper.GhHelperSource {
    const io = opts.io orelse return error.InvalidConfig;
    const env = opts.parent_env orelse return error.InvalidConfig;
    return gh_helper.GhHelperSource.init(.{
        .gpa = opts.gpa,
        .io = io,
        .parent_env = env,
    });
}

fn buildGitHelper(opts: SpecOptions) CredentialError!git_helper.GitHelperSource {
    const io = opts.io orelse return error.InvalidConfig;
    const env = opts.parent_env orelse return error.InvalidConfig;
    return git_helper.GitHelperSource.init(.{
        .gpa = opts.gpa,
        .io = io,
        .parent_env = env,
    });
}

fn buildHostCapability(opts: SpecOptions) CredentialError!host_capability_source.HostCapabilitySource {
    if (opts.host_dispatcher) |dispatcher| {
        return host_capability_source.HostCapabilitySource.initWithDispatcher(
            .{ .gpa = opts.gpa },
            dispatcher,
            opts.host_dispatcher_ctx,
        );
    }
    return host_capability_source.HostCapabilitySource.init(.{ .gpa = opts.gpa });
}

fn buildAutoChain(opts: SpecOptions) CredentialError!ProviderHandle.AutoBundle {
    if (is_wasm) return buildAutoChainWasm(opts);
    return buildAutoChainNative(opts);
}

fn buildAutoChainWasm(opts: SpecOptions) CredentialError!ProviderHandle.AutoBundle {
    const entries = try opts.gpa.alloc(ProviderHandle.AutoEntry, 1);
    errdefer opts.gpa.free(entries);

    entries[0] = .{ .host_capability = try buildHostCapability(opts) };
    errdefer deinitAutoEntries(entries[0..1]);

    const vtables = try opts.gpa.alloc(CredentialProvider, 1);
    errdefer opts.gpa.free(vtables);
    vtables[0] = entries[0].host_capability.provider();

    const walker = try auto_walker.AutoSource.init(vtables);
    return .{
        .gpa = opts.gpa,
        .entries = entries,
        .vtables = vtables,
        .walker = walker,
    };
}

fn buildAutoChainNative(opts: SpecOptions) CredentialError!ProviderHandle.AutoBundle {
    const io = opts.io orelse return error.InvalidConfig;
    const env = opts.parent_env orelse return error.InvalidConfig;

    const entries = try opts.gpa.alloc(ProviderHandle.AutoEntry, 3);
    errdefer opts.gpa.free(entries);

    entries[0] = .{ .env = try env_source.EnvSource.init(opts.auto_env_var) };
    errdefer deinitAutoEntries(entries[0..1]);

    entries[1] = .{ .gh_helper = try gh_helper.GhHelperSource.init(.{
        .gpa = opts.gpa,
        .io = io,
        .parent_env = env,
    }) };
    errdefer deinitAutoEntries(entries[0..2]);

    entries[2] = .{ .git_helper = try git_helper.GitHelperSource.init(.{
        .gpa = opts.gpa,
        .io = io,
        .parent_env = env,
    }) };
    errdefer deinitAutoEntries(entries[0..3]);

    const vtables = try opts.gpa.alloc(CredentialProvider, entries.len);
    errdefer opts.gpa.free(vtables);
    vtables[0] = entries[0].env.provider();
    vtables[1] = entries[1].gh_helper.provider();
    vtables[2] = entries[2].git_helper.provider();

    const walker = try auto_walker.AutoSource.init(vtables);
    return .{
        .gpa = opts.gpa,
        .entries = entries,
        .vtables = vtables,
        .walker = walker,
    };
}

/// Re-export of `AutoSource` for callers that need to compose a custom
/// fall-through chain. `fromSpec(.auto, ...)` now picks the per-platform
/// default chain documented in the GitHub API RefStore ADR § 3.
pub const AutoSource = auto_walker.AutoSource;

test {
    _ = explicit_source;
    _ = env_source;
    _ = gh_helper;
    _ = git_helper;
    _ = host_capability_source;
    _ = auto_walker;
}
