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

const StaticBearerProvider = struct {
    token: []const u8,

    fn provider(self: *StaticBearerProvider) credential_provider.CredentialProvider {
        return .{
            .ctx = @ptrCast(self),
            .get_fn = get,
        };
    }

    fn get(
        ctx: *anyopaque,
        gpa: std.mem.Allocator,
    ) credential_provider.CredentialError!credential_provider.Credential {
        const self: *StaticBearerProvider = @ptrCast(@alignCast(ctx));
        return .{ .bearer = try gpa.dupe(u8, self.token) };
    }
};

const QueuedResponse = struct {
    status: u16,
    body: []const u8,
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
    records: [16]RequestRecord = undefined,
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
        return .{
            .status = response.status,
            .headers = try gpa.alloc(http_transport.Header, 0),
            .body = try gpa.dupe(u8, response.body),
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

    const version = try store.put(gpa, "doc-1", "value-1");
    defer gpa.free(version);

    try std.testing.expectEqualStrings("eee", version);
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

fn expectHeader(record: RequestRecord, name: []const u8, value: []const u8) !void {
    for (record.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            try std.testing.expectEqualStrings(value, header.value);
            return;
        }
    }
    return error.HeaderNotFound;
}
