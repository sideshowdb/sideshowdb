//! REST-backed `RefStore` implementation for GitHub's Git Database API.

const std = @import("std");
const credential_provider = @import("credential_provider");
const github_json = @import("github_api/json.zig");
const http_transport = @import("http_transport");
const RefStore = @import("ref_store.zig").RefStore;

const Allocator = std.mem.Allocator;
const CredentialProvider = credential_provider.CredentialProvider;
const Credential = credential_provider.Credential;
const Header = http_transport.Header;
const HttpTransport = http_transport.HttpTransport;
const Method = http_transport.Method;
const Response = http_transport.Response;

/// Remote-backed RefStore over a single GitHub ref.
pub const GitHubApiRefStore = struct {
    /// Default GitHub REST API base URL.
    pub const default_api_base = "https://api.github.com";
    /// Default ref namespace used for SideshowDB document data.
    pub const default_ref_name = "refs/sideshowdb/documents";
    /// Default user agent sent to GitHub.
    pub const default_user_agent = "sideshowdb";
    /// Default number of retries reserved for concurrent write conflicts.
    pub const default_retry_concurrent_writes: u8 = 3;
    /// GitHub's maximum blob size accepted by the Git Database API.
    pub const default_blob_limit_bytes: usize = 100 * 1024 * 1024;

    /// Constructor options for `GitHubApiRefStore`.
    pub const Options = struct {
        /// GitHub repository owner or organization.
        owner: []const u8,
        /// GitHub repository name.
        repo: []const u8,
        /// Fully-qualified ref name, e.g. `refs/sideshowdb/documents`.
        ref_name: ?[]const u8 = null,
        /// REST API base URL; defaults to public GitHub.
        api_base: []const u8 = default_api_base,
        /// User agent sent on every request.
        user_agent: []const u8 = default_user_agent,
        /// Retry budget for non-fast-forward ref updates.
        retry_concurrent_writes: u8 = default_retry_concurrent_writes,
        /// Maximum value bytes accepted before creating an upstream blob.
        blob_limit_bytes: usize = default_blob_limit_bytes,
        /// HTTP transport used for all GitHub API requests.
        transport: HttpTransport,
        /// Credential provider consulted before each operation.
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
        gpa: Allocator,
        key: []const u8,
        value: []const u8,
    ) anyerror!RefStore.VersionId {
        var credential = self.credentials.get(gpa) catch |err| switch (err) {
            error.AuthMissing => return error.AuthMissing,
            else => |e| return e,
        };
        defer credential.deinit(gpa);

        switch (credential) {
            .none => return error.AuthMissing,
            .basic => return error.NotImplemented,
            .bearer => {},
        }

        try RefStore.validateKey(key);
        return try self.putExistingRef(gpa, key, value, credential);
    }

    fn putExistingRef(
        self: *GitHubApiRefStore,
        gpa: Allocator,
        key: []const u8,
        value: []const u8,
        credential: Credential,
    ) !RefStore.VersionId {
        const ref_path = try std.fmt.allocPrint(gpa, "/git/ref/{s}", .{self.ref_name});
        defer gpa.free(ref_path);

        var ref_resp = try self.requestGitHub(gpa, .GET, ref_path, credential, null);
        defer ref_resp.deinit(gpa);

        var parent_sha: ?[]u8 = null;
        defer if (parent_sha) |sha| gpa.free(sha);

        var base_tree_sha: ?[]u8 = null;
        defer if (base_tree_sha) |sha| gpa.free(sha);

        switch (ref_resp.status) {
            200 => {
                parent_sha = try github_json.parseRefCommitSha(gpa, ref_resp.body);

                const commit_path = try std.fmt.allocPrint(gpa, "/git/commits/{s}", .{parent_sha.?});
                defer gpa.free(commit_path);
                var commit_resp = try self.requestGitHub(gpa, .GET, commit_path, credential, null);
                defer commit_resp.deinit(gpa);
                try expectStatus(commit_resp.status, 200);

                base_tree_sha = try github_json.parseCommitTreeSha(gpa, commit_resp.body);
            },
            404 => {},
            else => return error.InvalidRequest,
        }

        const blob_body = try github_json.encodeCreateBlobRequest(gpa, value);
        defer gpa.free(blob_body);
        var blob_resp = try self.requestGitHub(gpa, .POST, "/git/blobs", credential, blob_body);
        defer blob_resp.deinit(gpa);
        try expectStatus(blob_resp.status, 201);

        const blob_sha = try github_json.parseSha(gpa, blob_resp.body);
        defer gpa.free(blob_sha);

        const tree_body = try github_json.encodeCreateTreeRequest(gpa, base_tree_sha, key, blob_sha);
        defer gpa.free(tree_body);
        var tree_resp = try self.requestGitHub(gpa, .POST, "/git/trees", credential, tree_body);
        defer tree_resp.deinit(gpa);
        try expectStatus(tree_resp.status, 201);

        const tree_sha = try github_json.parseSha(gpa, tree_resp.body);
        defer gpa.free(tree_sha);

        const message = try std.fmt.allocPrint(gpa, "put {s}", .{key});
        defer gpa.free(message);
        const create_commit_body = try github_json.encodeCreateCommitRequest(gpa, message, tree_sha, parent_sha);
        defer gpa.free(create_commit_body);
        var create_commit_resp = try self.requestGitHub(gpa, .POST, "/git/commits", credential, create_commit_body);
        defer create_commit_resp.deinit(gpa);
        try expectStatus(create_commit_resp.status, 201);

        const new_commit_sha = try github_json.parseSha(gpa, create_commit_resp.body);
        errdefer gpa.free(new_commit_sha);

        if (parent_sha) |_| {
            const update_ref_body = try github_json.encodeUpdateRefRequest(gpa, new_commit_sha);
            defer gpa.free(update_ref_body);
            const update_ref_path = try std.fmt.allocPrint(gpa, "/git/refs/{s}", .{self.ref_name});
            defer gpa.free(update_ref_path);
            var update_ref_resp = try self.requestGitHub(gpa, .PATCH, update_ref_path, credential, update_ref_body);
            defer update_ref_resp.deinit(gpa);
            try expectStatus(update_ref_resp.status, 200);
        } else {
            const create_ref_body = try github_json.encodeCreateRefRequest(gpa, self.ref_name, new_commit_sha);
            defer gpa.free(create_ref_body);
            var create_ref_resp = try self.requestGitHub(gpa, .POST, "/git/refs", credential, create_ref_body);
            defer create_ref_resp.deinit(gpa);
            try expectStatus(create_ref_resp.status, 201);
        }

        return new_commit_sha;
    }

    fn requestGitHub(
        self: *GitHubApiRefStore,
        gpa: Allocator,
        method: Method,
        endpoint: []const u8,
        credential: Credential,
        body: ?[]const u8,
    ) !Response {
        const url = try self.formatUrl(gpa, endpoint);
        defer gpa.free(url);

        var auth_value: ?[]u8 = null;
        defer if (auth_value) |value| gpa.free(value);

        var headers = try gpa.alloc(Header, 4);
        defer gpa.free(headers);

        headers[0] = .{ .name = "Accept", .value = "application/vnd.github+json" };
        headers[1] = .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" };
        headers[2] = .{ .name = "User-Agent", .value = self.user_agent };
        headers[3] = switch (credential) {
            .bearer => |token| blk: {
                auth_value = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
                break :blk .{ .name = "Authorization", .value = auth_value.? };
            },
            .basic, .none => return error.AuthMissing,
        };

        return try self.transport.request(method, url, headers, body, gpa);
    }

    fn formatUrl(self: *GitHubApiRefStore, gpa: Allocator, endpoint: []const u8) ![]u8 {
        const sep = if (std.mem.endsWith(u8, self.api_base, "/")) "" else "/";
        return try std.fmt.allocPrint(
            gpa,
            "{s}{s}repos/{s}/{s}{s}",
            .{ self.api_base, sep, self.owner, self.repo, endpoint },
        );
    }
};

fn expectStatus(actual: u16, expected: u16) error{InvalidRequest}!void {
    if (actual != expected) return error.InvalidRequest;
}
