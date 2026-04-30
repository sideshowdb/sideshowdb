//! Unit tests for the REST-backed GitHub API `RefStore`.

const std = @import("std");
const credential_provider = @import("credential_provider");
const github_api_ref_store = @import("github_api_ref_store");
const http_transport = @import("http_transport");

const GitHubApiRefStore = github_api_ref_store.GitHubApiRefStore;

fn freePutResult(gpa: std.mem.Allocator, result: anytype) void {
    gpa.free(result.version);
    if (result.tree_sha) |sha| gpa.free(sha);
}

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

const StaticBearerProvider = struct {
    token: []const u8,

    fn provider(self: *StaticBearerProvider) credential_provider.CredentialProvider {
        return .{
            .ctx = @ptrCast(self),
            .get_fn = get,
        };
    }

    fn get(
        _: *anyopaque,
        gpa: std.mem.Allocator,
    ) credential_provider.CredentialError!credential_provider.Credential {
        return .{ .bearer = try gpa.dupe(u8, "tok-123") };
    }
};

const QueuedResponse = struct {
    status: u16,
    body: []const u8,
    headers: []const http_transport.Header = &.{},
    rate_limit: http_transport.RateLimitInfo = .{},
    etag: ?[]const u8 = null,
};

const RequestRecord = struct {
    method: http_transport.Method,
    url: []u8,
    body: ?[]u8,
    headers: []http_transport.Header,
};

const QueuedTransport = struct {
    gpa: std.mem.Allocator,
    responses: []const QueuedResponse,
    next_response: usize = 0,
    records: [32]RequestRecord = undefined,
    record_count: usize = 0,

    fn init(gpa: std.mem.Allocator, responses: []const QueuedResponse) QueuedTransport {
        return .{
            .gpa = gpa,
            .responses = responses,
        };
    }

    fn deinit(self: *QueuedTransport) void {
        for (self.records[0..self.record_count]) |record| {
            self.gpa.free(record.url);
            if (record.body) |body| self.gpa.free(body);
            for (record.headers) |header| {
                self.gpa.free(header.name);
                self.gpa.free(header.value);
            }
            self.gpa.free(record.headers);
        }
    }

    fn transport(self: *QueuedTransport) http_transport.HttpTransport {
        return .{
            .ctx = @ptrCast(self),
            .request_fn = request,
        };
    }

    fn request(
        ctx: *anyopaque,
        method: http_transport.Method,
        url: []const u8,
        headers: []const http_transport.Header,
        body: ?[]const u8,
        gpa: std.mem.Allocator,
    ) !http_transport.Response {
        const self: *QueuedTransport = @ptrCast(@alignCast(ctx));
        if (self.record_count >= self.records.len) return error.TooManyRequestsRecorded;
        if (self.next_response >= self.responses.len) return error.NoQueuedResponse;

        var copied_headers = try self.gpa.alloc(http_transport.Header, headers.len);
        errdefer self.gpa.free(copied_headers);
        for (headers, 0..) |header, i| {
            copied_headers[i] = .{
                .name = try self.gpa.dupe(u8, header.name),
                .value = try self.gpa.dupe(u8, header.value),
            };
        }

        self.records[self.record_count] = .{
            .method = method,
            .url = try self.gpa.dupe(u8, url),
            .body = if (body) |b| try self.gpa.dupe(u8, b) else null,
            .headers = copied_headers,
        };
        self.record_count += 1;

        const response = self.responses[self.next_response];
        self.next_response += 1;
        var response_headers = try gpa.alloc(http_transport.Header, response.headers.len);
        errdefer gpa.free(response_headers);
        for (response.headers, 0..) |header, i| {
            response_headers[i] = .{
                .name = try gpa.dupe(u8, header.name),
                .value = try gpa.dupe(u8, header.value),
            };
        }
        return .{
            .status = response.status,
            .headers = response_headers,
            .body = try gpa.dupe(u8, response.body),
            .etag = response.etag,
            .rate_limit = response.rate_limit,
        };
    }
};

const FailingTransport = struct {
    calls: u32 = 0,

    fn transport(self: *FailingTransport) http_transport.HttpTransport {
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
        _: std.mem.Allocator,
    ) !http_transport.Response {
        const self: *FailingTransport = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return error.TransportFailure;
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

test "put_happy_path_existing_ref" {
    const gpa = std.testing.allocator;

    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = "{\"ref\":\"refs/sideshowdb/documents\",\"object\":{\"type\":\"commit\",\"sha\":\"aaa\"}}" },
        .{ .status = 200, .body = "{\"sha\":\"aaa\",\"tree\":{\"sha\":\"bbb\"}}" },
        .{ .status = 201, .body = "{\"sha\":\"ccc\"}" },
        .{ .status = 201, .body = "{\"sha\":\"ddd\"}" },
        .{ .status = 201, .body = "{\"sha\":\"eee\"}" },
        .{ .status = 200, .body = "{\"ref\":\"refs/sideshowdb/documents\",\"object\":{\"type\":\"commit\",\"sha\":\"eee\"}}" },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();

    var creds = StaticBearerProvider{ .token = "tok-123" };
    var store = try GitHubApiRefStore.init(.{
        .owner = "sideshowdb",
        .repo = "metrics-store",
        .transport = transport.transport(),
        .credentials = creds.provider(),
    });

    const result = try store.put(gpa, "doc-1", "value-1");
    defer freePutResult(gpa, result);

    try std.testing.expectEqualStrings("eee", result.version);
    try std.testing.expectEqual(@as(usize, 6), transport.record_count);

    try expectRequest(
        transport.records[0],
        .GET,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/ref/refs/sideshowdb/documents",
        null,
    );
    try expectRequest(
        transport.records[1],
        .GET,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/commits/aaa",
        null,
    );
    try expectRequest(
        transport.records[2],
        .POST,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/blobs",
        "{\"content\":\"dmFsdWUtMQ==\",\"encoding\":\"base64\"}",
    );
    try expectRequest(
        transport.records[3],
        .POST,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/trees",
        "{\"base_tree\":\"bbb\",\"tree\":[{\"path\":\"doc-1\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"ccc\"}]}",
    );
    try expectRequest(
        transport.records[4],
        .POST,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/commits",
        "{\"message\":\"put doc-1\",\"tree\":\"ddd\",\"parents\":[\"aaa\"]}",
    );
    try expectRequest(
        transport.records[5],
        .PATCH,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/refs/refs/sideshowdb/documents",
        "{\"sha\":\"eee\",\"force\":false}",
    );

    try expectHeader(transport.records[0], "Authorization", "Bearer tok-123");
    try expectHeader(transport.records[0], "Accept", "application/vnd.github+json");
    try expectHeader(transport.records[0], "X-GitHub-Api-Version", "2022-11-28");
    try expectHeader(transport.records[0], "User-Agent", "sideshowdb");
}

test "put_first_write_creates_ref" {
    const gpa = std.testing.allocator;

    const responses = [_]QueuedResponse{
        .{ .status = 404, .body = "{\"message\":\"Not Found\"}" },
        .{ .status = 201, .body = "{\"sha\":\"ccc\"}" },
        .{ .status = 201, .body = "{\"sha\":\"ddd\"}" },
        .{ .status = 201, .body = "{\"sha\":\"eee\"}" },
        .{ .status = 201, .body = "{\"ref\":\"refs/sideshowdb/documents\",\"object\":{\"type\":\"commit\",\"sha\":\"eee\"}}" },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();

    var creds = StaticBearerProvider{ .token = "tok-123" };
    var store = try GitHubApiRefStore.init(.{
        .owner = "sideshowdb",
        .repo = "metrics-store",
        .transport = transport.transport(),
        .credentials = creds.provider(),
    });

    const result = try store.put(gpa, "doc-1", "value-1");
    defer freePutResult(gpa, result);

    try std.testing.expectEqualStrings("eee", result.version);
    try std.testing.expectEqual(@as(usize, 5), transport.record_count);

    try expectRequest(
        transport.records[0],
        .GET,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/ref/refs/sideshowdb/documents",
        null,
    );
    try expectRequest(
        transport.records[1],
        .POST,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/blobs",
        "{\"content\":\"dmFsdWUtMQ==\",\"encoding\":\"base64\"}",
    );
    try expectRequest(
        transport.records[2],
        .POST,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/trees",
        "{\"tree\":[{\"path\":\"doc-1\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"ccc\"}]}",
    );
    try expectRequest(
        transport.records[3],
        .POST,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/commits",
        "{\"message\":\"put doc-1\",\"tree\":\"ddd\",\"parents\":[]}",
    );
    try expectRequest(
        transport.records[4],
        .POST,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/refs",
        "{\"ref\":\"refs/sideshowdb/documents\",\"sha\":\"eee\"}",
    );
}

test "put_401_returns_auth_invalid" {
    var transport = QueuedTransport.init(std.testing.allocator, &.{
        .{ .status = 401, .body = "{\"message\":\"Bad credentials\"}" },
    });
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    try std.testing.expectError(error.AuthInvalid, store.put(std.testing.allocator, "doc-1", "value-1"));
    try std.testing.expectEqual(@as(usize, 1), transport.record_count);
}

test "put_403_insufficient_scope" {
    var transport = QueuedTransport.init(std.testing.allocator, &.{
        .{ .status = 403, .body = "{\"message\":\"Resource not accessible by personal access token\"}" },
    });
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    try std.testing.expectError(error.InsufficientScope, store.put(std.testing.allocator, "doc-1", "value-1"));
    try std.testing.expectEqual(@as(usize, 1), transport.record_count);
}

test "put_403_rate_limited" {
    var transport = QueuedTransport.init(std.testing.allocator, &.{
        .{
            .status = 403,
            .body = "{\"message\":\"API rate limit exceeded\"}",
            .rate_limit = .{ .remaining = 0, .reset_unix = 1_700_000_000 },
        },
    });
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    try std.testing.expectError(error.RateLimited, store.put(std.testing.allocator, "doc-1", "value-1"));
    try std.testing.expectEqual(@as(usize, 1), transport.record_count);
}

test "put_5xx_returns_upstream_unavailable" {
    var transport = QueuedTransport.init(std.testing.allocator, &.{
        .{ .status = 503, .body = "{\"message\":\"Service Unavailable\"}" },
        .{ .status = 503, .body = "{\"message\":\"Service Unavailable\"}" },
    });
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    try std.testing.expectError(error.UpstreamUnavailable, store.put(std.testing.allocator, "doc-1", "value-1"));
    try std.testing.expectEqual(@as(usize, 2), transport.record_count);
}

test "put_value_too_large_pre_check" {
    const gpa = std.testing.allocator;
    var transport = CountingTransport{};
    var creds = StaticBearerProvider{ .token = "tok-123" };
    var store = try GitHubApiRefStore.init(.{
        .owner = "sideshowdb",
        .repo = "metrics-store",
        .blob_limit_bytes = 4,
        .transport = transport.transport(),
        .credentials = creds.provider(),
    });

    try std.testing.expectError(error.ValueTooLarge, store.put(gpa, "doc-1", "12345"));
    try std.testing.expectEqual(@as(u32, 0), transport.calls);
}

test "put_concurrent_update_retries_then_succeeds" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("parent-x") },
        .{ .status = 200, .body = commitBody("tree-x") },
        .{ .status = 201, .body = shaBody("blob-1") },
        .{ .status = 201, .body = shaBody("tree-1") },
        .{ .status = 201, .body = shaBody("commit-1") },
        .{ .status = 422, .body = "{\"message\":\"Reference update failed: not a fast-forward\"}" },
        .{ .status = 200, .body = refBody("parent-y") },
        .{ .status = 200, .body = commitBody("tree-y") },
        .{ .status = 201, .body = shaBody("blob-2") },
        .{ .status = 201, .body = shaBody("tree-2") },
        .{ .status = 201, .body = shaBody("commit-2") },
        .{ .status = 200, .body = refBody("commit-2") },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const result = try store.put(gpa, "doc-1", "value-1");
    defer freePutResult(gpa, result);

    try std.testing.expectEqualStrings("commit-2", result.version);
    try std.testing.expectEqual(@as(usize, 12), transport.record_count);
}

test "put_concurrent_update_exhausts_retries" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("parent-1") },
        .{ .status = 200, .body = commitBody("tree-1") },
        .{ .status = 201, .body = shaBody("blob-1") },
        .{ .status = 201, .body = shaBody("tree-new-1") },
        .{ .status = 201, .body = shaBody("commit-1") },
        .{ .status = 422, .body = "{\"message\":\"Reference update failed: not a fast-forward\"}" },
        .{ .status = 200, .body = refBody("parent-2") },
        .{ .status = 200, .body = commitBody("tree-2") },
        .{ .status = 201, .body = shaBody("blob-2") },
        .{ .status = 201, .body = shaBody("tree-new-2") },
        .{ .status = 201, .body = shaBody("commit-2") },
        .{ .status = 422, .body = "{\"message\":\"Reference update failed: not a fast-forward\"}" },
        .{ .status = 200, .body = refBody("parent-3") },
        .{ .status = 200, .body = commitBody("tree-3") },
        .{ .status = 201, .body = shaBody("blob-3") },
        .{ .status = 201, .body = shaBody("tree-new-3") },
        .{ .status = 201, .body = shaBody("commit-3") },
        .{ .status = 422, .body = "{\"message\":\"Reference update failed: not a fast-forward\"}" },
        .{ .status = 200, .body = refBody("parent-4") },
        .{ .status = 200, .body = commitBody("tree-4") },
        .{ .status = 201, .body = shaBody("blob-4") },
        .{ .status = 201, .body = shaBody("tree-new-4") },
        .{ .status = 201, .body = shaBody("commit-4") },
        .{ .status = 422, .body = "{\"message\":\"Reference update failed: not a fast-forward\"}" },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    try std.testing.expectError(error.ConcurrentUpdate, store.put(gpa, "doc-1", "value-1"));
    try std.testing.expectEqual(@as(usize, 24), transport.record_count);
}

test "put_transport_error_returns_transport_error" {
    var transport = FailingTransport{};
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    try std.testing.expectError(error.TransportError, store.put(std.testing.allocator, "doc-1", "value-1"));
    try std.testing.expectEqual(@as(u32, 1), transport.calls);
}

test "put_4xx_other_returns_invalid_request" {
    var transport = QueuedTransport.init(std.testing.allocator, &.{
        .{ .status = 422, .body = "{\"message\":\"Validation Failed\"}" },
    });
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    try std.testing.expectError(error.InvalidRequest, store.put(std.testing.allocator, "doc-1", "value-1"));
    try std.testing.expectEqual(@as(usize, 1), transport.record_count);
}

test "put_carries_rate_limit_headers" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 404, .body = "{\"message\":\"Not Found\"}" },
        .{ .status = 201, .body = shaBody("blob-1") },
        .{ .status = 201, .body = shaBody("tree-1") },
        .{ .status = 201, .body = shaBody("commit-1") },
        .{
            .status = 201,
            .body = refBody("commit-1"),
            .rate_limit = .{ .remaining = 4500, .reset_unix = 1_700_000_000 },
        },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const result = try store.put(gpa, "doc-1", "value-1");
    defer freePutResult(gpa, result);

    try std.testing.expectEqualStrings("commit-1", result.version);
    try std.testing.expect(result.rate_limit != null);
    try std.testing.expectEqual(@as(?u32, 4500), result.rate_limit.?.remaining);
    try std.testing.expectEqual(@as(?i64, 1_700_000_000), result.rate_limit.?.reset_unix);
}

test "get_returns_blob_bytes_for_known_key" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("aaa") },
        .{ .status = 200, .body = commitBody("bbb") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"ccc"}],"truncated":false}
        ) },
        .{ .status = 200, .body = blobBody("aGVsbG8=") },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const result = try store.get(gpa, "doc-1", null);
    try std.testing.expect(result != null);
    defer if (result) |read| {
        gpa.free(read.value);
        gpa.free(read.version);
    };

    try std.testing.expectEqualStrings("hello", result.?.value);
    try std.testing.expectEqualStrings("aaa", result.?.version);
    try std.testing.expectEqual(@as(usize, 4), transport.record_count);
}

test "get_returns_null_when_key_absent" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("aaa") },
        .{ .status = 200, .body = commitBody("bbb") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-2","mode":"100644","type":"blob","sha":"zzz"}],"truncated":false}
        ) },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const result = try store.get(gpa, "doc-1", null);
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(usize, 3), transport.record_count);
}

test "get_returns_null_when_ref_missing" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 404, .body = "{\"message\":\"Not Found\"}" },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const result = try store.get(gpa, "doc-1", null);
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(usize, 1), transport.record_count);
}

test "get_warm_cache_serves_304" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("aaa"), .etag = "\"ref-etag-1\"" },
        .{ .status = 200, .body = commitBody("bbb") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"ccc"}],"truncated":false}
        ) },
        .{ .status = 200, .body = blobBody("aGVsbG8=") },
        .{ .status = 304, .body = "" },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();

    var store = try initGitHubStore(transport.transport(), true, 256 * 1024);
    defer store.deinitCaches(gpa);

    const first = try store.get(gpa, "doc-1", null);
    defer if (first) |read| {
        gpa.free(read.value);
        gpa.free(read.version);
    };
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("hello", first.?.value);
    try std.testing.expectEqual(@as(usize, 4), transport.record_count);

    const second = try store.get(gpa, "doc-1", null);
    defer if (second) |read| {
        gpa.free(read.value);
        gpa.free(read.version);
    };
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("hello", second.?.value);
    try std.testing.expectEqual(@as(usize, 5), transport.record_count);

    try expectHeader(transport.records[4], "If-None-Match", "\"ref-etag-1\"");
}

test "list_hits_cache_after_get_warmed_tip" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("aaa"), .etag = "\"etag-1\"" },
        .{ .status = 200, .body = commitBody("bbb") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"ccc"}],"truncated":false}
        ) },
        .{ .status = 200, .body = blobBody("aGVsbG8=") },
        .{ .status = 304, .body = "" },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();

    var store = try initGitHubStore(transport.transport(), true, 256 * 1024);
    defer store.deinitCaches(gpa);

    const warmed = try store.get(gpa, "doc-1", null);
    defer if (warmed) |read| {
        gpa.free(read.value);
        gpa.free(read.version);
    };
    const keys = try store.list(gpa);
    defer {
        for (keys) |k| {
            gpa.free(k);
        }
        gpa.free(keys);
    }

    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqualStrings("doc-1", keys[0]);
    try std.testing.expectEqual(@as(usize, 5), transport.record_count);
    try expectHeader(transport.records[4], "If-None-Match", "\"etag-1\"");
}

test "get_reuses_cached_tree_and_blob_after_tip_commit_changes" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("commit-1"), .etag = "\"e1\"" },
        .{ .status = 200, .body = commitBody("tree-shared") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-shared"}],"truncated":false}
        ) },
        .{ .status = 200, .body = blobBody("cXVv") },
        .{ .status = 200, .body = refBody("commit-2"), .etag = "\"e2\"" },
        .{ .status = 200, .body = commitBody("tree-shared") },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();

    var store = try initGitHubStore(transport.transport(), true, 256 * 1024);
    defer store.deinitCaches(gpa);

    const first = try store.get(gpa, "doc-1", null);
    defer if (first) |read| {
        gpa.free(read.value);
        gpa.free(read.version);
    };
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("quo", first.?.value);

    const second = try store.get(gpa, "doc-1", null);
    defer if (second) |read| {
        gpa.free(read.value);
        gpa.free(read.version);
    };
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("quo", second.?.value);
    try std.testing.expectEqual(@as(usize, 6), transport.record_count);
}

test "get_with_known_version_returns_historical_blob" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = commitBody("bbb") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"ccc"}],"truncated":false}
        ) },
        .{ .status = 200, .body = blobBody("dmVyc2lvbmVk") },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const result = try store.get(gpa, "doc-1", "aaa");
    try std.testing.expect(result != null);
    defer if (result) |read| {
        gpa.free(read.value);
        gpa.free(read.version);
    };

    try std.testing.expectEqualStrings("versioned", result.?.value);
    try std.testing.expectEqualStrings("aaa", result.?.version);
    try std.testing.expectEqual(@as(usize, 3), transport.record_count);
    try expectRequest(
        transport.records[0],
        .GET,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/commits/aaa",
        null,
    );
}

test "get_with_unknown_version_returns_null" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 404, .body = "{\"message\":\"Not Found\"}" },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const result = try store.get(gpa, "doc-1", "missing-version");
    try std.testing.expect(result == null);
    try std.testing.expectEqual(@as(usize, 1), transport.record_count);
}

test "list_returns_all_blob_entries_in_path_order" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("aaa") },
        .{ .status = 200, .body = commitBody("bbb") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"c/doc-3","mode":"100644","type":"blob","sha":"s3"},{"path":"a/doc-1","mode":"100644","type":"blob","sha":"s1"},{"path":"b","mode":"040000","type":"tree","sha":"t1"},{"path":"b/doc-2","mode":"100644","type":"blob","sha":"s2"}],"truncated":false}
        ) },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const keys = try store.list(gpa);
    defer {
        for (keys) |key| gpa.free(key);
        gpa.free(keys);
    }

    try std.testing.expectEqual(@as(usize, 3), keys.len);
    try std.testing.expectEqualStrings("a/doc-1", keys[0]);
    try std.testing.expectEqualStrings("b/doc-2", keys[1]);
    try std.testing.expectEqualStrings("c/doc-3", keys[2]);
    try std.testing.expectEqual(@as(usize, 3), transport.record_count);
}

test "list_returns_empty_when_ref_missing" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 404, .body = "{\"message\":\"Not Found\"}" },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const keys = try store.list(gpa);
    defer gpa.free(keys);

    try std.testing.expectEqual(@as(usize, 0), keys.len);
    try std.testing.expectEqual(@as(usize, 1), transport.record_count);
}

test "delete_known_key_advances_ref" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("parent-1") },
        .{ .status = 200, .body = commitBody("tree-1") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-1"},{"path":"doc-2","mode":"100644","type":"blob","sha":"blob-2"}],"truncated":false}
        ) },
        .{ .status = 201, .body = shaBody("tree-2") },
        .{ .status = 201, .body = shaBody("commit-2") },
        .{ .status = 200, .body = refBody("commit-2") },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    try store.delete(gpa, "doc-1");

    try std.testing.expectEqual(@as(usize, 6), transport.record_count);
    try expectRequest(
        transport.records[3],
        .POST,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/trees",
        "{\"tree\":[{\"path\":\"doc-2\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"blob-2\"}]}",
    );
    try expectRequest(
        transport.records[4],
        .POST,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/commits",
        "{\"message\":\"delete doc-1\",\"tree\":\"tree-2\",\"parents\":[\"parent-1\"]}",
    );
}

test "delete_known_key_with_read_caching_same_request_count" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("parent-1") },
        .{ .status = 200, .body = commitBody("tree-1") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-1"},{"path":"doc-2","mode":"100644","type":"blob","sha":"blob-2"}],"truncated":false}
        ) },
        .{ .status = 201, .body = shaBody("tree-2") },
        .{ .status = 201, .body = shaBody("commit-2") },
        .{ .status = 200, .body = refBody("commit-2") },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), true, 256 * 1024);
    defer store.deinitCaches(gpa);

    try store.delete(gpa, "doc-1");

    try std.testing.expectEqual(@as(usize, 6), transport.record_count);
    try expectRequest(
        transport.records[3],
        .POST,
        "https://api.github.com/repos/sideshowdb/metrics-store/git/trees",
        "{\"tree\":[{\"path\":\"doc-2\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"blob-2\"}]}",
    );
}

test "delete_absent_key_returns_null_no_commit" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = refBody("parent-1") },
        .{ .status = 200, .body = commitBody("tree-1") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-2","mode":"100644","type":"blob","sha":"blob-2"}],"truncated":false}
        ) },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    try store.delete(gpa, "doc-1");
    try std.testing.expectEqual(@as(usize, 3), transport.record_count);
}

test "history_returns_commits_touching_key" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = commitsBody(&.{ "commit-3", "commit-2", "commit-1" }) },
        .{ .status = 200, .body = commitBody("tree-3") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-3"}],"truncated":false}
        ) },
        .{ .status = 200, .body = commitBody("tree-2") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-2"}],"truncated":false}
        ) },
        .{ .status = 200, .body = commitBody("tree-1") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-1"}],"truncated":false}
        ) },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const versions = try store.history(gpa, "doc-1");
    defer {
        for (versions) |version| gpa.free(version);
        gpa.free(versions);
    }

    try std.testing.expectEqual(@as(usize, 3), versions.len);
    try std.testing.expectEqualStrings("commit-3", versions[0]);
    try std.testing.expectEqualStrings("commit-2", versions[1]);
    try std.testing.expectEqualStrings("commit-1", versions[2]);
}

test "history_with_read_caching_matches_uncached_results" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 200, .body = commitsBody(&.{ "commit-3", "commit-2", "commit-1" }) },
        .{ .status = 200, .body = commitBody("tree-3") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-3"}],"truncated":false}
        ) },
        .{ .status = 200, .body = commitBody("tree-2") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-2"}],"truncated":false}
        ) },
        .{ .status = 200, .body = commitBody("tree-1") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-1"}],"truncated":false}
        ) },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), true, 256 * 1024);
    defer store.deinitCaches(gpa);

    const versions = try store.history(gpa, "doc-1");
    defer {
        for (versions) |version| gpa.free(version);
        gpa.free(versions);
    }

    try std.testing.expectEqual(@as(usize, 3), versions.len);
    try std.testing.expectEqualStrings("commit-3", versions[0]);
    try std.testing.expectEqualStrings("commit-2", versions[1]);
    try std.testing.expectEqualStrings("commit-1", versions[2]);
    try std.testing.expectEqual(@as(usize, 7), transport.record_count);
}

test "history_follows_link_rel_next" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{
            .status = 200,
            .body = commitsBody(&.{"commit-2"}),
            .headers = &.{
                .{ .name = "Link", .value = "<https://api.github.com/repos/sideshowdb/metrics-store/commits?page=2>; rel=\"next\"" },
            },
        },
        .{ .status = 200, .body = commitBody("tree-2") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-2"}],"truncated":false}
        ) },
        .{ .status = 200, .body = commitsBody(&.{"commit-1"}) },
        .{ .status = 200, .body = commitBody("tree-1") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-1"}],"truncated":false}
        ) },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const versions = try store.history(gpa, "doc-1");
    defer {
        for (versions) |version| gpa.free(version);
        gpa.free(versions);
    }

    try std.testing.expectEqual(@as(usize, 2), versions.len);
    try std.testing.expectEqualStrings("https://api.github.com/repos/sideshowdb/metrics-store/commits?path=doc-1&sha=refs/sideshowdb/documents", transport.records[0].url);
    try std.testing.expectEqualStrings("https://api.github.com/repos/sideshowdb/metrics-store/commits?page=2", transport.records[3].url);
}

test "history_respects_history_limit" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{
            .status = 200,
            .body = commitsBody(&.{ "commit-3", "commit-2", "commit-1" }),
            .headers = &.{
                .{ .name = "Link", .value = "<https://api.github.com/repos/sideshowdb/metrics-store/commits?page=2>; rel=\"next\"" },
            },
        },
        .{ .status = 200, .body = commitBody("tree-3") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-3"}],"truncated":false}
        ) },
        .{ .status = 200, .body = commitBody("tree-2") },
        .{ .status = 200, .body = treeBody(
            \\{"tree":[{"path":"doc-1","mode":"100644","type":"blob","sha":"blob-2"}],"truncated":false}
        ) },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var creds = StaticBearerProvider{ .token = "tok-123" };
    var store = try GitHubApiRefStore.init(.{
        .owner = "sideshowdb",
        .repo = "metrics-store",
        .history_limit = 2,
        .transport = transport.transport(),
        .credentials = creds.provider(),
    });

    const versions = try store.history(gpa, "doc-1");
    defer {
        for (versions) |version| gpa.free(version);
        gpa.free(versions);
    }

    try std.testing.expectEqual(@as(usize, 2), versions.len);
    try std.testing.expectEqual(@as(usize, 5), transport.record_count);
}

test "refstore_vtable_put_wires_to_github_put" {
    const gpa = std.testing.allocator;
    const responses = [_]QueuedResponse{
        .{ .status = 404, .body = "{\"message\":\"Not Found\"}" },
        .{ .status = 201, .body = shaBody("blob-1") },
        .{ .status = 201, .body = shaBody("tree-1") },
        .{ .status = 201, .body = shaBody("commit-1") },
        .{ .status = 201, .body = refBody("commit-1") },
    };
    var transport = QueuedTransport.init(gpa, &responses);
    defer transport.deinit();
    var store = try initGitHubStore(transport.transport(), false, 256 * 1024);

    const ref_store = store.refStore();
    const result = try ref_store.put(gpa, "doc-1", "value-1");
    defer freePutResult(gpa, result);

    try std.testing.expectEqualStrings("commit-1", result.version);
}

fn expectRequest(
    record: RequestRecord,
    method: http_transport.Method,
    url: []const u8,
    body: ?[]const u8,
) !void {
    try std.testing.expectEqual(method, record.method);
    try std.testing.expectEqualStrings(url, record.url);
    if (body) |expected| {
        try std.testing.expect(record.body != null);
        try std.testing.expectEqualStrings(expected, record.body.?);
    } else {
        try std.testing.expect(record.body == null);
    }
}

fn initGitHubStore(
    transport: http_transport.HttpTransport,
    enable_read_caching: bool,
    object_cache_max_bytes_per_kind: usize,
) !GitHubApiRefStore {
    var creds = StaticBearerProvider{ .token = "tok-123" };
    return GitHubApiRefStore.init(.{
        .owner = "sideshowdb",
        .repo = "metrics-store",
        .enable_read_caching = enable_read_caching,
        .object_cache_max_bytes_per_kind = object_cache_max_bytes_per_kind,
        .transport = transport,
        .credentials = creds.provider(),
    });
}

fn refBody(comptime sha: []const u8) []const u8 {
    return "{\"ref\":\"refs/sideshowdb/documents\",\"object\":{\"type\":\"commit\",\"sha\":\"" ++ sha ++ "\"}}";
}

fn commitBody(comptime tree_sha: []const u8) []const u8 {
    return "{\"sha\":\"commit\",\"tree\":{\"sha\":\"" ++ tree_sha ++ "\"}}";
}

fn shaBody(comptime sha: []const u8) []const u8 {
    return "{\"sha\":\"" ++ sha ++ "\"}";
}

fn treeBody(comptime body: []const u8) []const u8 {
    return body;
}

fn blobBody(comptime encoded: []const u8) []const u8 {
    return "{\"content\":\"" ++ encoded ++ "\",\"encoding\":\"base64\"}";
}

fn commitsBody(comptime shas: []const []const u8) []const u8 {
    comptime var out: []const u8 = "[";
    inline for (shas, 0..) |sha, i| {
        if (i > 0) out = out ++ ",";
        out = out ++ "{\"sha\":\"" ++ sha ++ "\"}";
    }
    out = out ++ "]";
    return out;
}

fn expectHeader(record: RequestRecord, name: []const u8, value: []const u8) !void {
    for (record.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            try std.testing.expectEqualStrings(value, header.value);
            return;
        }
    }
    return error.HeaderNotFound;
}
