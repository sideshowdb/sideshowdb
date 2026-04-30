//! Unit tests for the REST-backed GitHub API `RefStore`.

const std = @import("std");
const credential_provider = @import("credential_provider");
const github_api_ref_store = @import("github_api_ref_store");
const http_transport = @import("http_transport");

const GitHubApiRefStore = github_api_ref_store.GitHubApiRefStore;

const NoopCredentialProvider = struct {
    fn provider(self: *NoopCredentialProvider) credential_provider.CredentialProvider {
        return .{
            .ctx = @ptrCast(self),
            .get_fn = get,
        };
    }

    fn get(
        _: *anyopaque,
        _: std.mem.Allocator,
    ) credential_provider.CredentialError!credential_provider.Credential {
        return .{ .none = {} };
    }
};

const CountingTransport = struct {
    calls: u32 = 0,

    fn transport(self: *CountingTransport) http_transport.HttpTransport {
        return .{
            .ctx = @ptrCast(self),
            .request_fn = request,
        };
    }

    fn request(
        ctx: *anyopaque,
        _: http_transport.Method,
        _: []const u8,
        _: []const http_transport.Header,
        _: ?[]const u8,
        gpa: std.mem.Allocator,
    ) !http_transport.Response {
        const self: *CountingTransport = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return .{
            .status = 200,
            .headers = try gpa.alloc(http_transport.Header, 0),
            .body = try gpa.dupe(u8, "{}"),
            .etag = null,
            .rate_limit = .{},
        };
    }
};

fn initStore(owner: []const u8, repo: []const u8, ref_name: ?[]const u8) !GitHubApiRefStore {
    const gpa = std.testing.allocator;
    var transport_rec = http_transport.RecordingTransport.init(gpa, 200, "{}");
    var creds = NoopCredentialProvider{};
    return GitHubApiRefStore.init(.{
        .owner = owner,
        .repo = repo,
        .ref_name = ref_name,
        .transport = transport_rec.transport(),
        .credentials = creds.provider(),
    });
}

test "init_rejects_empty_owner" {
    const result = initStore("", "metrics-store", null);
    try std.testing.expectError(error.InvalidConfig, result);
}

test "init_rejects_empty_repo" {
    const result = initStore("sideshowdb", "", null);
    try std.testing.expectError(error.InvalidConfig, result);
}

test "init_default_ref_name" {
    const store = try initStore("sideshowdb", "metrics-store", null);

    try std.testing.expectEqualStrings("refs/sideshowdb/documents", store.ref_name);
}

test "init_records_owner_repo_ref" {
    const store = try initStore(
        "sideshowdb",
        "metrics-store",
        "refs/sideshowdb/documents",
    );

    try std.testing.expectEqualStrings("sideshowdb", store.owner);
    try std.testing.expectEqualStrings("metrics-store", store.repo);
    try std.testing.expectEqualStrings("refs/sideshowdb/documents", store.ref_name);
}

test "put_returns_auth_missing_when_provider_yields_none" {
    const gpa = std.testing.allocator;

    var transport = CountingTransport{};
    var creds = NoopCredentialProvider{};
    var store = try GitHubApiRefStore.init(.{
        .owner = "sideshowdb",
        .repo = "metrics-store",
        .transport = transport.transport(),
        .credentials = creds.provider(),
    });

    const result = store.put(gpa, "k", "v");
    try std.testing.expectError(error.AuthMissing, result);
    try std.testing.expectEqual(@as(u32, 0), transport.calls);
}
