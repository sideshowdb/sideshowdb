//! REST-backed `RefStore` implementation for GitHub's Git Database API.

const std = @import("std");
const credential_provider = @import("credential_provider");
const github_json = @import("github_api/json.zig");
const pagination = @import("github_api/pagination.zig");
const http_transport = @import("http_transport");
const RefStore = @import("ref_store.zig").RefStore;

const Allocator = std.mem.Allocator;
const CredentialProvider = credential_provider.CredentialProvider;
const Credential = credential_provider.Credential;
const Header = http_transport.Header;
const HttpTransport = http_transport.HttpTransport;
const Method = http_transport.Method;
const RateLimitInfo = http_transport.RateLimitInfo;
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
    /// Default base delay for concurrent-write retry backoff.
    pub const default_retry_backoff_base_ns: u64 = 1_000_000;
    /// Maximum delay for concurrent-write retry backoff.
    pub const max_retry_backoff_ns: u64 = 1_000_000_000;
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
        /// Base delay for exponential concurrent-write retry backoff.
        retry_backoff_base_ns: u64 = default_retry_backoff_base_ns,
        /// Optional IO backend used to sleep between concurrent-write retries.
        retry_io: ?std.Io = null,
        /// Maximum value bytes accepted before creating an upstream blob.
        blob_limit_bytes: usize = default_blob_limit_bytes,
        /// Maximum history entries returned in one call.
        history_limit: usize = 100,
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
    retry_backoff_base_ns: u64,
    retry_io: ?std.Io,
    blob_limit_bytes: usize,
    history_limit: usize,
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
            .retry_backoff_base_ns = options.retry_backoff_base_ns,
            .retry_io = options.retry_io,
            .blob_limit_bytes = options.blob_limit_bytes,
            .history_limit = options.history_limit,
            .transport = options.transport,
            .credentials = options.credentials,
        };
    }

    /// Returns a type-erased `RefStore` view over this GitHub store.
    pub fn refStore(self: *GitHubApiRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: RefStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .delete = vtableDelete,
        .list = vtableList,
        .history = vtableHistory,
    };

    fn vtablePut(ctx: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.PutResult {
        const self: *GitHubApiRefStore = @ptrCast(@alignCast(ctx));
        return self.put(gpa, key, value);
    }

    fn vtableGet(ctx: *anyopaque, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        const self: *GitHubApiRefStore = @ptrCast(@alignCast(ctx));
        return self.get(gpa, key, version);
    }

    fn vtableDelete(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *GitHubApiRefStore = @ptrCast(@alignCast(ctx));
        return self.delete(key);
    }

    fn vtableList(ctx: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        const self: *GitHubApiRefStore = @ptrCast(@alignCast(ctx));
        return self.list(gpa);
    }

    fn vtableHistory(ctx: *anyopaque, gpa: Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        const self: *GitHubApiRefStore = @ptrCast(@alignCast(ctx));
        return self.history(gpa, key);
    }

    /// Writes `value` to `key`, returning the full GitHub write result.
    pub fn put(
        self: *GitHubApiRefStore,
        gpa: Allocator,
        key: []const u8,
        value: []const u8,
    ) anyerror!RefStore.PutResult {
        try RefStore.validateKey(key);
        if (value.len > self.blob_limit_bytes) return error.ValueTooLarge;

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

        var attempt: u8 = 0;
        while (attempt <= self.retry_concurrent_writes) : (attempt += 1) {
            return self.putExistingRef(gpa, key, value, credential) catch |err| switch (err) {
                error.ConcurrentUpdate => {
                    if (attempt == self.retry_concurrent_writes) return error.ConcurrentUpdate;
                    sleepBeforeConcurrentRetry(self.retry_io, self.retry_backoff_base_ns, attempt);
                    continue;
                },
                else => |e| return e,
            };
        }
        return error.ConcurrentUpdate;
    }

    /// Reads `key` from either the latest tip or a pinned commit version.
    pub fn get(
        self: *GitHubApiRefStore,
        gpa: Allocator,
        key: []const u8,
        version: ?RefStore.VersionId,
    ) anyerror!?RefStore.ReadResult {
        try RefStore.validateKey(key);

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

        const commit_sha = if (version) |requested_version|
            try gpa.dupe(u8, requested_version)
        else
            (try self.readTipCommitSha(gpa, credential) orelse return null);
        defer gpa.free(commit_sha);

        return try self.readBlobForKeyAtCommit(gpa, key, commit_sha, credential);
    }

    /// Lists all keys currently present at the latest ref tip.
    pub fn list(self: *GitHubApiRefStore, gpa: Allocator) anyerror![][]u8 {
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

        const commit_sha = (try self.readTipCommitSha(gpa, credential)) orelse return try gpa.alloc([]u8, 0);
        defer gpa.free(commit_sha);

        const commit_path = try std.fmt.allocPrint(gpa, "/git/commits/{s}", .{commit_sha});
        defer gpa.free(commit_path);
        var commit_resp = try self.requestGitHub(gpa, .GET, commit_path, credential, null);
        defer commit_resp.deinit(gpa);
        try mapGitHubStatus(commit_resp, 200);

        const tree_sha = try github_json.parseCommitTreeSha(gpa, commit_resp.body);
        defer gpa.free(tree_sha);

        const tree_path = try std.fmt.allocPrint(gpa, "/git/trees/{s}?recursive=1", .{tree_sha});
        defer gpa.free(tree_path);
        var tree_resp = try self.requestGitHub(gpa, .GET, tree_path, credential, null);
        defer tree_resp.deinit(gpa);
        try mapGitHubStatus(tree_resp, 200);

        return github_json.parseTreeBlobPaths(gpa, tree_resp.body);
    }

    /// Removes `key` at the current ref tip by rewriting the tree and advancing the ref; no-op if absent.
    pub fn delete(self: *GitHubApiRefStore, key: []const u8) anyerror!void {
        try RefStore.validateKey(key);
        const gpa = std.heap.smp_allocator;

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

        const parent_sha = (try self.readTipCommitSha(gpa, credential)) orelse return;
        defer gpa.free(parent_sha);

        const commit_path = try std.fmt.allocPrint(gpa, "/git/commits/{s}", .{parent_sha});
        defer gpa.free(commit_path);
        var commit_resp = try self.requestGitHub(gpa, .GET, commit_path, credential, null);
        defer commit_resp.deinit(gpa);
        try mapGitHubStatus(commit_resp, 200);
        const base_tree_sha = try github_json.parseCommitTreeSha(gpa, commit_resp.body);
        defer gpa.free(base_tree_sha);

        const tree_path = try std.fmt.allocPrint(gpa, "/git/trees/{s}?recursive=1", .{base_tree_sha});
        defer gpa.free(tree_path);
        var tree_resp = try self.requestGitHub(gpa, .GET, tree_path, credential, null);
        defer tree_resp.deinit(gpa);
        try mapGitHubStatus(tree_resp, 200);

        const entries = try github_json.parseTreeBlobEntries(gpa, tree_resp.body);
        defer github_json.freeTreeBlobEntries(gpa, entries);

        var keep_count: usize = 0;
        var found_key = false;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, key)) {
                found_key = true;
                continue;
            }
            keep_count += 1;
        }
        if (!found_key) return;

        const kept_entries = try gpa.alloc(github_json.TreeBlobEntry, keep_count);
        defer gpa.free(kept_entries);
        var out_index: usize = 0;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.path, key)) continue;
            kept_entries[out_index] = entry;
            out_index += 1;
        }

        const tree_body = try github_json.encodeCreateTreeEntriesRequest(gpa, kept_entries);
        defer gpa.free(tree_body);
        var new_tree_resp = try self.requestGitHub(gpa, .POST, "/git/trees", credential, tree_body);
        defer new_tree_resp.deinit(gpa);
        try mapGitHubStatus(new_tree_resp, 201);
        const new_tree_sha = try github_json.parseSha(gpa, new_tree_resp.body);
        defer gpa.free(new_tree_sha);

        const message = try std.fmt.allocPrint(gpa, "delete {s}", .{key});
        defer gpa.free(message);
        const create_commit_body = try github_json.encodeCreateCommitRequest(gpa, message, new_tree_sha, parent_sha);
        defer gpa.free(create_commit_body);
        var create_commit_resp = try self.requestGitHub(gpa, .POST, "/git/commits", credential, create_commit_body);
        defer create_commit_resp.deinit(gpa);
        try mapGitHubStatus(create_commit_resp, 201);
        const new_commit_sha = try github_json.parseSha(gpa, create_commit_resp.body);
        defer gpa.free(new_commit_sha);

        const update_ref_body = try github_json.encodeUpdateRefRequest(gpa, new_commit_sha);
        defer gpa.free(update_ref_body);
        const update_ref_path = try std.fmt.allocPrint(gpa, "/git/refs/{s}", .{self.ref_name});
        defer gpa.free(update_ref_path);
        var update_ref_resp = try self.requestGitHub(gpa, .PATCH, update_ref_path, credential, update_ref_body);
        defer update_ref_resp.deinit(gpa);
        try mapGitHubStatus(update_ref_resp, 200);
    }

    /// Returns commit SHAs where `key` exists as a blob, newest first, following `Link` pagination up to `history_limit`.
    pub fn history(self: *GitHubApiRefStore, gpa: Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        try RefStore.validateKey(key);

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

        var versions = std.array_list.Managed(RefStore.VersionId).init(gpa);
        defer {
            for (versions.items) |version| gpa.free(version);
            versions.deinit();
        }

        var next_url = try std.fmt.allocPrint(gpa, "{s}/repos/{s}/{s}/commits?path={s}&sha={s}", .{
            self.api_base, self.owner, self.repo, key, self.ref_name,
        });
        defer gpa.free(next_url);

        while (versions.items.len < self.history_limit) {
            var resp = try self.requestGitHubAbsolute(gpa, .GET, next_url, credential, null);
            defer resp.deinit(gpa);
            try mapGitHubStatus(resp, 200);

            const commit_shas = try github_json.parseCommitShas(gpa, resp.body);
            defer {
                for (commit_shas) |sha| gpa.free(sha);
                gpa.free(commit_shas);
            }

            for (commit_shas) |commit_sha| {
                if (versions.items.len >= self.history_limit) break;

                const commit_path = try std.fmt.allocPrint(gpa, "/git/commits/{s}", .{commit_sha});
                defer gpa.free(commit_path);
                var commit_resp = try self.requestGitHub(gpa, .GET, commit_path, credential, null);
                defer commit_resp.deinit(gpa);
                try mapGitHubStatus(commit_resp, 200);
                const tree_sha = try github_json.parseCommitTreeSha(gpa, commit_resp.body);
                defer gpa.free(tree_sha);

                const tree_path = try std.fmt.allocPrint(gpa, "/git/trees/{s}?recursive=1", .{tree_sha});
                defer gpa.free(tree_path);
                var tree_resp = try self.requestGitHub(gpa, .GET, tree_path, credential, null);
                defer tree_resp.deinit(gpa);
                try mapGitHubStatus(tree_resp, 200);
                const blob = try github_json.parseTreeBlobShaByPath(gpa, tree_resp.body, key);
                if (blob) |blob_sha| gpa.free(blob_sha) else continue;

                try versions.append(try gpa.dupe(u8, commit_sha));
            }

            if (versions.items.len >= self.history_limit) break;
            const link_header = responseHeader(resp.headers, "Link") orelse break;
            const rels = pagination.parseLinkHeader(link_header);
            const next = rels.next orelse break;
            gpa.free(next_url);
            next_url = try gpa.dupe(u8, next.value);
        }

        return try versions.toOwnedSlice();
    }

    fn putExistingRef(
        self: *GitHubApiRefStore,
        gpa: Allocator,
        key: []const u8,
        value: []const u8,
        credential: Credential,
    ) !RefStore.PutResult {
        var last_rate_limit: ?RateLimitInfo = null;

        const ref_path = try std.fmt.allocPrint(gpa, "/git/ref/{s}", .{self.ref_name});
        defer gpa.free(ref_path);

        var ref_resp = try self.requestGitHub(gpa, .GET, ref_path, credential, null);
        defer ref_resp.deinit(gpa);
        recordRateLimit(&last_rate_limit, ref_resp.rate_limit);

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
                recordRateLimit(&last_rate_limit, commit_resp.rate_limit);
                try mapGitHubStatus(commit_resp, 200);

                base_tree_sha = try github_json.parseCommitTreeSha(gpa, commit_resp.body);
            },
            404 => {},
            else => try mapGitHubStatus(ref_resp, 200),
        }

        const blob_body = try github_json.encodeCreateBlobRequest(gpa, value);
        defer gpa.free(blob_body);
        var blob_resp = try self.requestGitHub(gpa, .POST, "/git/blobs", credential, blob_body);
        defer blob_resp.deinit(gpa);
        recordRateLimit(&last_rate_limit, blob_resp.rate_limit);
        try mapGitHubStatus(blob_resp, 201);

        const blob_sha = try github_json.parseSha(gpa, blob_resp.body);
        defer gpa.free(blob_sha);

        const tree_body = try github_json.encodeCreateTreeRequest(gpa, base_tree_sha, key, blob_sha);
        defer gpa.free(tree_body);
        var tree_resp = try self.requestGitHub(gpa, .POST, "/git/trees", credential, tree_body);
        defer tree_resp.deinit(gpa);
        recordRateLimit(&last_rate_limit, tree_resp.rate_limit);
        try mapGitHubStatus(tree_resp, 201);

        const tree_sha = try github_json.parseSha(gpa, tree_resp.body);
        errdefer gpa.free(tree_sha);

        const message = try std.fmt.allocPrint(gpa, "put {s}", .{key});
        defer gpa.free(message);
        const create_commit_body = try github_json.encodeCreateCommitRequest(gpa, message, tree_sha, parent_sha);
        defer gpa.free(create_commit_body);
        var create_commit_resp = try self.requestGitHub(gpa, .POST, "/git/commits", credential, create_commit_body);
        defer create_commit_resp.deinit(gpa);
        recordRateLimit(&last_rate_limit, create_commit_resp.rate_limit);
        try mapGitHubStatus(create_commit_resp, 201);

        const new_commit_sha = try github_json.parseSha(gpa, create_commit_resp.body);
        errdefer gpa.free(new_commit_sha);

        if (parent_sha) |_| {
            const update_ref_body = try github_json.encodeUpdateRefRequest(gpa, new_commit_sha);
            defer gpa.free(update_ref_body);
            const update_ref_path = try std.fmt.allocPrint(gpa, "/git/refs/{s}", .{self.ref_name});
            defer gpa.free(update_ref_path);
            var update_ref_resp = try self.requestGitHub(gpa, .PATCH, update_ref_path, credential, update_ref_body);
            defer update_ref_resp.deinit(gpa);
            recordRateLimit(&last_rate_limit, update_ref_resp.rate_limit);
            try mapGitHubStatus(update_ref_resp, 200);
        } else {
            const create_ref_body = try github_json.encodeCreateRefRequest(gpa, self.ref_name, new_commit_sha);
            defer gpa.free(create_ref_body);
            var create_ref_resp = try self.requestGitHub(gpa, .POST, "/git/refs", credential, create_ref_body);
            defer create_ref_resp.deinit(gpa);
            recordRateLimit(&last_rate_limit, create_ref_resp.rate_limit);
            try mapGitHubStatus(create_ref_resp, 201);
        }

        return .{
            .version = new_commit_sha,
            .tree_sha = tree_sha,
            .rate_limit = if (last_rate_limit) |rate| .{
                .remaining = rate.remaining,
                .reset_unix = rate.reset_unix,
            } else null,
        };
    }

    fn readTipCommitSha(self: *GitHubApiRefStore, gpa: Allocator, credential: Credential) !?[]u8 {
        const ref_path = try std.fmt.allocPrint(gpa, "/git/ref/{s}", .{self.ref_name});
        defer gpa.free(ref_path);

        var ref_resp = try self.requestGitHub(gpa, .GET, ref_path, credential, null);
        defer ref_resp.deinit(gpa);
        switch (ref_resp.status) {
            200 => return try github_json.parseRefCommitSha(gpa, ref_resp.body),
            404 => return null,
            else => try mapGitHubStatus(ref_resp, 200),
        }
        unreachable;
    }

    fn readBlobForKeyAtCommit(
        self: *GitHubApiRefStore,
        gpa: Allocator,
        key: []const u8,
        commit_sha: []const u8,
        credential: Credential,
    ) !?RefStore.ReadResult {
        const commit_path = try std.fmt.allocPrint(gpa, "/git/commits/{s}", .{commit_sha});
        defer gpa.free(commit_path);
        var commit_resp = try self.requestGitHub(gpa, .GET, commit_path, credential, null);
        defer commit_resp.deinit(gpa);
        switch (commit_resp.status) {
            200 => {},
            404 => return null,
            else => try mapGitHubStatus(commit_resp, 200),
        }

        const tree_sha = try github_json.parseCommitTreeSha(gpa, commit_resp.body);
        defer gpa.free(tree_sha);

        const tree_path = try std.fmt.allocPrint(gpa, "/git/trees/{s}?recursive=1", .{tree_sha});
        defer gpa.free(tree_path);
        var tree_resp = try self.requestGitHub(gpa, .GET, tree_path, credential, null);
        defer tree_resp.deinit(gpa);
        try mapGitHubStatus(tree_resp, 200);

        const blob_sha = (try github_json.parseTreeBlobShaByPath(gpa, tree_resp.body, key)) orelse return null;
        defer gpa.free(blob_sha);

        const blob_path = try std.fmt.allocPrint(gpa, "/git/blobs/{s}", .{blob_sha});
        defer gpa.free(blob_path);
        var blob_resp = try self.requestGitHub(gpa, .GET, blob_path, credential, null);
        defer blob_resp.deinit(gpa);
        try mapGitHubStatus(blob_resp, 200);

        const value = try github_json.parseBlobContent(gpa, blob_resp.body);
        return .{
            .value = value,
            .version = try gpa.dupe(u8, commit_sha),
        };
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

        var attempts: u2 = 0;
        while (attempts < 2) : (attempts += 1) {
            var response = self.transport.request(method, url, headers, body, gpa) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.TransportError,
            };
            if (response.status < 500) return response;
            response.deinit(gpa);
        }
        return error.UpstreamUnavailable;
    }

    fn requestGitHubAbsolute(
        self: *GitHubApiRefStore,
        gpa: Allocator,
        method: Method,
        url: []const u8,
        credential: Credential,
        body: ?[]const u8,
    ) !Response {
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

        var attempts: u2 = 0;
        while (attempts < 2) : (attempts += 1) {
            var response = self.transport.request(method, url, headers, body, gpa) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.TransportError,
            };
            if (response.status < 500) return response;
            response.deinit(gpa);
        }
        return error.UpstreamUnavailable;
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

fn mapGitHubStatus(response: Response, expected: u16) !void {
    if (response.status == expected) return;
    switch (response.status) {
        401 => return error.AuthInvalid,
        403 => {
            if (response.rate_limit.remaining == 0) return error.RateLimited;
            if (std.mem.indexOf(u8, response.body, "Resource not accessible by personal access token") != null) {
                return error.InsufficientScope;
            }
            return error.InvalidRequest;
        },
        422 => {
            if (std.mem.indexOf(u8, response.body, "not a fast-forward") != null) {
                return error.ConcurrentUpdate;
            }
            return error.InvalidRequest;
        },
        400...400, 402, 404...421, 423...499 => return error.InvalidRequest,
        500...599 => return error.UpstreamUnavailable,
        else => return error.InvalidResponse,
    }
}

fn recordRateLimit(current: *?RateLimitInfo, next: RateLimitInfo) void {
    if (next.remaining != null or next.reset_unix != null) current.* = next;
}

fn sleepBeforeConcurrentRetry(io: ?std.Io, base_ns: u64, attempt: u8) void {
    if (base_ns == 0) return;
    const retry_io = io orelse return;
    const shift: u6 = @intCast(@min(attempt, 20));
    const delay = std.math.shl(u64, base_ns, shift);
    std.Io.sleep(
        retry_io,
        .fromNanoseconds(@intCast(@min(delay, GitHubApiRefStore.max_retry_backoff_ns))),
        .awake,
    ) catch {};
}

fn responseHeader(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}
