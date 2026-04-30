//! REST-backed `RefStore` implementation for GitHub's Git Database API.

const std = @import("std");
const credential_provider = @import("credential_provider");
const http_transport = @import("http_transport");
const RefStore = @import("ref_store.zig").RefStore;

const CredentialProvider = credential_provider.CredentialProvider;
const HttpTransport = http_transport.HttpTransport;

/// Remote-backed RefStore over a single GitHub ref.
pub const GitHubApiRefStore = struct {
    pub const default_api_base = "https://api.github.com";
    pub const default_ref_name = "refs/sideshowdb/documents";
    pub const default_user_agent = "sideshowdb";
    pub const default_retry_concurrent_writes: u8 = 3;
    pub const default_blob_limit_bytes: usize = 100 * 1024 * 1024;

    pub const Options = struct {
        owner: []const u8,
        repo: []const u8,
        ref_name: ?[]const u8 = null,
        api_base: []const u8 = default_api_base,
        user_agent: []const u8 = default_user_agent,
        retry_concurrent_writes: u8 = default_retry_concurrent_writes,
        blob_limit_bytes: usize = default_blob_limit_bytes,
        transport: HttpTransport,
        credentials: CredentialProvider,
    };

    owner: []const u8,
    repo: []const u8,
    ref_name: []const u8,
    api_base: []const u8,
    user_agent: []const u8,
    retry_concurrent_writes: u8,
    blob_limit_bytes: usize,
    transport: HttpTransport,
    credentials: CredentialProvider,

    /// Builds a store view over the configured GitHub repository/ref.
    /// Construction is pure: it validates config and performs no HTTP.
    pub fn init(options: Options) error{InvalidConfig}!GitHubApiRefStore {
        if (options.owner.len == 0) return error.InvalidConfig;
        if (options.repo.len == 0) return error.InvalidConfig;
        if (options.api_base.len == 0) return error.InvalidConfig;
        if (options.user_agent.len == 0) return error.InvalidConfig;

        return .{
            .owner = options.owner,
            .repo = options.repo,
            .ref_name = options.ref_name orelse default_ref_name,
            .api_base = options.api_base,
            .user_agent = options.user_agent,
            .retry_concurrent_writes = options.retry_concurrent_writes,
            .blob_limit_bytes = options.blob_limit_bytes,
            .transport = options.transport,
            .credentials = options.credentials,
        };
    }

    /// Writes `value` to `key`, returning the new commit SHA.
    pub fn put(
        self: *GitHubApiRefStore,
        gpa: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
    ) anyerror!RefStore.VersionId {
        _ = key;
        _ = value;

        var credential = self.credentials.get(gpa) catch |err| switch (err) {
            error.AuthMissing => return error.AuthMissing,
            else => |e| return e,
        };
        defer credential.deinit(gpa);

        switch (credential) {
            .none => return error.AuthMissing,
            .bearer, .basic => return error.NotImplemented,
        }
    }
};
