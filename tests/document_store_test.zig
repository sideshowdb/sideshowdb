const std = @import("std");
const sideshowdb = @import("sideshowdb");
const Environ = std.process.Environ;

fn isGitAvailable(gpa: std.mem.Allocator, io: std.Io, env: *const Environ.Map) bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "--version" },
        .environ_map = env,
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn runOk(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const Environ.Map,
    argv: []const []const u8,
) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .environ_map = env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.HelperCommandFailed;
    }
}

fn expectStringField(value: std.json.Value, field: []const u8, expected: []const u8) !void {
    const actual = value.object.get(field) orelse return error.MissingField;
    try std.testing.expectEqualStrings(expected, actual.string);
}

const TestContext = struct {
    env: Environ.Map,
    tmp: std.testing.TmpDir,
    repo_path: []u8,
    git_store: sideshowdb.GitRefStore,

    fn init(gpa: std.mem.Allocator, io: std.Io) !TestContext {
        var env = try Environ.createMap(std.testing.environ, gpa);
        errdefer env.deinit();

        if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        const repo_path = try std.fs.path.join(gpa, &.{
            cwd,
            ".zig-cache",
            "tmp",
            &tmp.sub_path,
        });
        errdefer gpa.free(repo_path);

        try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

        const git_store = sideshowdb.GitRefStore.init(.{
            .gpa = gpa,
            .io = io,
            .parent_env = &env,
            .repo_path = repo_path,
            .ref_name = "refs/sideshowdb/documents",
        });

        const ctx: TestContext = .{
            .env = env,
            .tmp = tmp,
            .repo_path = repo_path,
            .git_store = git_store,
        };
        return ctx;
    }

    fn deinit(self: *TestContext, gpa: std.mem.Allocator) void {
        self.tmp.cleanup();
        gpa.free(self.repo_path);
        self.env.deinit();
    }

    fn documentStore(self: *TestContext) sideshowdb.DocumentStore {
        self.git_store.parent_env = &self.env;
        return sideshowdb.DocumentStore.init(self.git_store.refStore());
    }
};

fn expectMetadata(
    item: sideshowdb.document.DocumentMetadata,
    namespace: []const u8,
    doc_type: []const u8,
    id: []const u8,
) !void {
    try std.testing.expectEqualStrings(namespace, item.namespace);
    try std.testing.expectEqualStrings(doc_type, item.doc_type);
    try std.testing.expectEqualStrings(id, item.id);
    try std.testing.expect(item.version.len > 0);
}

test "DocumentStore persists namespaced documents and reads explicit versions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var test_ctx = try TestContext.init(gpa, io);
    defer test_ctx.deinit(gpa);
    const document_store = test_ctx.documentStore();

    const first_json = try document_store.put(
        gpa,
        .{ .payload = .{
            .json = "{\"title\":\"First\"}",
            .doc_type = "issue",
            .id = "doc-1",
        } },
    );
    defer gpa.free(first_json);

    var first = try std.json.parseFromSlice(std.json.Value, gpa, first_json, .{});
    defer first.deinit();
    try expectStringField(first.value, "namespace", "default");
    try expectStringField(first.value, "type", "issue");
    try expectStringField(first.value, "id", "doc-1");
    const first_version = first.value.object.get("version").?.string;

    const default_second_json = try document_store.put(
        gpa,
        .{ .envelope = .{
            .json =
            \\{
            \\  "type": "issue",
            \\  "id": "doc-1",
            \\  "data": {
            \\    "title": "Second default"
            \\  }
            \\}
            ,
        } },
    );
    defer gpa.free(default_second_json);

    var default_second = try std.json.parseFromSlice(std.json.Value, gpa, default_second_json, .{});
    defer default_second.deinit();
    try expectStringField(default_second.value, "namespace", "default");
    const second_version = default_second.value.object.get("version").?.string;
    try std.testing.expect(!std.mem.eql(u8, first_version, second_version));

    const namespaced_json = try document_store.put(
        gpa,
        .{ .payload = .{
            .json = "{\"title\":\"Team doc\"}",
            .namespace = "team-a",
            .doc_type = "issue",
            .id = "doc-1",
        } },
    );
    defer gpa.free(namespaced_json);

    var namespaced = try std.json.parseFromSlice(std.json.Value, gpa, namespaced_json, .{});
    defer namespaced.deinit();
    try expectStringField(namespaced.value, "namespace", "team-a");

    const latest_json = try document_store.get(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
    });
    defer if (latest_json) |bytes| gpa.free(bytes);
    try std.testing.expect(latest_json != null);

    var latest = try std.json.parseFromSlice(std.json.Value, gpa, latest_json.?, .{});
    defer latest.deinit();
    try expectStringField(latest.value, "namespace", "default");
    const latest_version = latest.value.object.get("version").?.string;
    try std.testing.expect(!std.mem.eql(u8, latest_version, first_version));
    try std.testing.expectEqualStrings(
        "Second default",
        latest.value.object.get("data").?.object.get("title").?.string,
    );

    const historical_json = try document_store.get(gpa, .{
        .namespace = "default",
        .doc_type = "issue",
        .id = "doc-1",
        .version = first_version,
    });
    defer if (historical_json) |bytes| gpa.free(bytes);
    try std.testing.expect(historical_json != null);

    var historical = try std.json.parseFromSlice(std.json.Value, gpa, historical_json.?, .{});
    defer historical.deinit();
    try expectStringField(historical.value, "namespace", "default");
    try expectStringField(historical.value, "version", first_version);
    try std.testing.expectEqualStrings(
        "First",
        historical.value.object.get("data").?.object.get("title").?.string,
    );

    const second_historical_json = try document_store.get(gpa, .{
        .namespace = "default",
        .doc_type = "issue",
        .id = "doc-1",
        .version = second_version,
    });
    defer if (second_historical_json) |bytes| gpa.free(bytes);
    try std.testing.expect(second_historical_json != null);

    const namespaced_latest = try document_store.get(gpa, .{
        .namespace = "team-a",
        .doc_type = "issue",
        .id = "doc-1",
    });
    defer if (namespaced_latest) |bytes| gpa.free(bytes);
    try std.testing.expect(namespaced_latest != null);

    const missing_version = try document_store.get(gpa, .{
        .namespace = "default",
        .doc_type = "issue",
        .id = "doc-1",
        .version = "deadbeef",
    });
    try std.testing.expect(missing_version == null);
}

test "DocumentStore list summary paginates and filters by namespace and type" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var test_ctx = try TestContext.init(gpa, io);
    defer test_ctx.deinit(gpa);
    const document_store = test_ctx.documentStore();

    const doc_one = try document_store.put(gpa, .{ .payload = .{
        .json = "{\"title\":\"alpha\"}",
        .doc_type = "issue",
        .id = "alpha",
    } });
    defer gpa.free(doc_one);

    const doc_two = try document_store.put(gpa, .{ .payload = .{
        .json = "{\"title\":\"beta\"}",
        .doc_type = "note",
        .id = "beta",
    } });
    defer gpa.free(doc_two);

    const doc_three = try document_store.put(gpa, .{ .payload = .{
        .json = "{\"title\":\"gamma\"}",
        .namespace = "team-a",
        .doc_type = "issue",
        .id = "gamma",
    } });
    defer gpa.free(doc_three);

    const first_page = try document_store.list(gpa, .{
        .limit = 1,
        .mode = .summary,
    });
    defer first_page.deinit(gpa);

    var first_cursor: ?[]const u8 = null;
    switch (first_page) {
        .summary => |page| {
            try std.testing.expectEqualStrings("summary", page.kind);
            try std.testing.expectEqual(@as(usize, 1), page.items.len);
            try expectMetadata(page.items[0], "default", "issue", "alpha");
            try std.testing.expect(page.next_cursor != null);
            first_cursor = page.next_cursor;
        },
        else => return error.UnexpectedDetailedPage,
    }

    const second_page = try document_store.list(gpa, .{
        .limit = 1,
        .cursor = first_cursor,
        .mode = .summary,
    });
    defer second_page.deinit(gpa);
    switch (second_page) {
        .summary => |page| {
            try std.testing.expectEqual(@as(usize, 1), page.items.len);
            try expectMetadata(page.items[0], "default", "note", "beta");
            try std.testing.expect(page.next_cursor != null);
        },
        else => return error.UnexpectedDetailedPage,
    }

    const filtered = try document_store.list(gpa, .{
        .namespace = "team-a",
        .doc_type = "issue",
        .mode = .summary,
    });
    defer filtered.deinit(gpa);
    switch (filtered) {
        .summary => |page| {
            try std.testing.expectEqual(@as(usize, 1), page.items.len);
            try expectMetadata(page.items[0], "team-a", "issue", "gamma");
            try std.testing.expect(page.next_cursor == null);
        },
        else => return error.UnexpectedDetailedPage,
    }
}

test "DocumentStore delete is idempotent and reports deleted state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var test_ctx = try TestContext.init(gpa, io);
    defer test_ctx.deinit(gpa);
    const document_store = test_ctx.documentStore();

    const created = try document_store.put(gpa, .{ .payload = .{
        .json = "{\"title\":\"to delete\"}",
        .doc_type = "issue",
        .id = "doc-1",
    } });
    defer gpa.free(created);

    const deleted = try document_store.delete(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
    });
    defer deleted.deinit(gpa);
    try std.testing.expect(deleted.deleted);
    try std.testing.expectEqualStrings("default", deleted.namespace);
    try std.testing.expectEqualStrings("issue", deleted.doc_type);
    try std.testing.expectEqualStrings("doc-1", deleted.id);

    const deleted_again = try document_store.delete(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
    });
    defer deleted_again.deinit(gpa);
    try std.testing.expect(!deleted_again.deleted);

    const missing = try document_store.get(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
    });
    try std.testing.expect(missing == null);
}

test "DocumentStore history summary uses newest first and empty page for missing identity" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var test_ctx = try TestContext.init(gpa, io);
    defer test_ctx.deinit(gpa);
    const document_store = test_ctx.documentStore();

    const first_json = try document_store.put(gpa, .{ .payload = .{
        .json = "{\"title\":\"first\"}",
        .doc_type = "issue",
        .id = "doc-1",
    } });
    defer gpa.free(first_json);
    var first = try std.json.parseFromSlice(std.json.Value, gpa, first_json, .{});
    defer first.deinit();
    const first_version = first.value.object.get("version").?.string;

    const second_json = try document_store.put(gpa, .{ .payload = .{
        .json = "{\"title\":\"second\"}",
        .doc_type = "issue",
        .id = "doc-1",
    } });
    defer gpa.free(second_json);
    var second = try std.json.parseFromSlice(std.json.Value, gpa, second_json, .{});
    defer second.deinit();
    const second_version = second.value.object.get("version").?.string;

    const history = try document_store.history(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
        .mode = .summary,
    });
    defer history.deinit(gpa);

    var history_cursor: ?[]const u8 = null;
    switch (history) {
        .summary => |page| {
            try std.testing.expectEqualStrings("summary", page.kind);
            try std.testing.expectEqual(@as(usize, 2), page.items.len);
            try std.testing.expectEqualStrings(second_version, page.items[0].version);
            try std.testing.expectEqualStrings(first_version, page.items[1].version);
            try std.testing.expect(page.next_cursor == null);
        },
        else => return error.UnexpectedDetailedPage,
    }

    const paged_history = try document_store.history(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
        .limit = 1,
        .mode = .summary,
    });
    defer paged_history.deinit(gpa);
    switch (paged_history) {
        .summary => |page| {
            try std.testing.expectEqual(@as(usize, 1), page.items.len);
            try std.testing.expectEqualStrings(second_version, page.items[0].version);
            try std.testing.expect(page.next_cursor != null);
            history_cursor = page.next_cursor;
        },
        else => return error.UnexpectedDetailedPage,
    }

    const paged_history_second = try document_store.history(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
        .limit = 1,
        .cursor = history_cursor,
        .mode = .summary,
    });
    defer paged_history_second.deinit(gpa);
    switch (paged_history_second) {
        .summary => |page| {
            try std.testing.expectEqual(@as(usize, 1), page.items.len);
            try std.testing.expectEqualStrings(first_version, page.items[0].version);
            try std.testing.expect(page.next_cursor == null);
        },
        else => return error.UnexpectedDetailedPage,
    }

    const missing_history = try document_store.history(gpa, .{
        .doc_type = "issue",
        .id = "missing",
        .mode = .summary,
    });
    defer missing_history.deinit(gpa);
    switch (missing_history) {
        .summary => |page| {
            try std.testing.expectEqual(@as(usize, 0), page.items.len);
            try std.testing.expect(page.next_cursor == null);
        },
        else => return error.UnexpectedDetailedPage,
    }
}

test "DocumentStore rejects oversized limits and invalid cursors" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var test_ctx = try TestContext.init(gpa, io);
    defer test_ctx.deinit(gpa);
    const document_store = test_ctx.documentStore();

    try std.testing.expectError(error.InvalidLimit, document_store.list(gpa, .{
        .limit = 201,
        .mode = .summary,
    }));

    try std.testing.expectError(error.InvalidCursor, document_store.history(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
        .cursor = "%%%bad%%%",
        .mode = .summary,
    }));
}

test "DocumentStore list detailed returns canonical envelopes with data" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var test_ctx = try TestContext.init(gpa, io);
    defer test_ctx.deinit(gpa);
    const document_store = test_ctx.documentStore();

    const created = try document_store.put(gpa, .{ .payload = .{
        .json = "{\"title\":\"detailed alpha\",\"labels\":[\"x\"]}",
        .doc_type = "issue",
        .id = "detail-1",
    } });
    defer gpa.free(created);

    const page = try document_store.list(gpa, .{
        .mode = .detailed,
        .limit = 1,
    });
    defer page.deinit(gpa);

    switch (page) {
        .detailed => |detailed| {
            try std.testing.expectEqualStrings("detailed", detailed.kind);
            try std.testing.expectEqual(@as(usize, 1), detailed.items.len);
            try std.testing.expect(detailed.next_cursor == null);

            var parsed = try std.json.parseFromSlice(std.json.Value, gpa, detailed.items[0], .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("default", parsed.value.object.get("namespace").?.string);
            try std.testing.expectEqualStrings("issue", parsed.value.object.get("type").?.string);
            try std.testing.expectEqualStrings("detail-1", parsed.value.object.get("id").?.string);
            try std.testing.expect(parsed.value.object.get("version") != null);
            try std.testing.expectEqualStrings(
                "detailed alpha",
                parsed.value.object.get("data").?.object.get("title").?.string,
            );
        },
        else => return error.UnexpectedSummaryPage,
    }
}

test "DocumentStore history detailed returns canonical envelopes newest first" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var test_ctx = try TestContext.init(gpa, io);
    defer test_ctx.deinit(gpa);
    const document_store = test_ctx.documentStore();

    const first_json = try document_store.put(gpa, .{ .payload = .{
        .json = "{\"title\":\"first detailed\"}",
        .doc_type = "issue",
        .id = "detail-history",
    } });
    defer gpa.free(first_json);

    const second_json = try document_store.put(gpa, .{ .payload = .{
        .json = "{\"title\":\"second detailed\"}",
        .doc_type = "issue",
        .id = "detail-history",
    } });
    defer gpa.free(second_json);

    const page = try document_store.history(gpa, .{
        .doc_type = "issue",
        .id = "detail-history",
        .mode = .detailed,
    });
    defer page.deinit(gpa);

    switch (page) {
        .detailed => |detailed| {
            try std.testing.expectEqualStrings("detailed", detailed.kind);
            try std.testing.expectEqual(@as(usize, 2), detailed.items.len);
            try std.testing.expect(detailed.next_cursor == null);

            var newest = try std.json.parseFromSlice(std.json.Value, gpa, detailed.items[0], .{});
            defer newest.deinit();
            try std.testing.expectEqualStrings(
                "second detailed",
                newest.value.object.get("data").?.object.get("title").?.string,
            );

            var oldest = try std.json.parseFromSlice(std.json.Value, gpa, detailed.items[1], .{});
            defer oldest.deinit();
            try std.testing.expectEqualStrings(
                "first detailed",
                oldest.value.object.get("data").?.object.get("title").?.string,
            );
        },
        else => return error.UnexpectedSummaryPage,
    }
}
