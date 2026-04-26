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

test "DocumentStore persists namespaced documents and reads explicit versions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);

    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    var git_store = sideshowdb.GitRefStore.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .repo_path = repo_path,
        .ref_name = "refs/sideshowdb/documents",
    });
    var document_store = sideshowdb.DocumentStore.init(git_store.refStore());

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
