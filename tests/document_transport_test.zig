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
    if (result.term != .exited or result.term.exited != 0) return error.HelperCommandFailed;
}

test "document transport handles JSON requests for put and get" {
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
    const document_store = sideshowdb.DocumentStore.init(git_store.refStore());

    const put_response = try sideshowdb.document_transport.handlePut(
        gpa,
        document_store,
        "{\"json\":\"{\\\"title\\\":\\\"via transport\\\"}\",\"type\":\"issue\",\"id\":\"transport-1\"}",
    );
    defer gpa.free(put_response);

    var put_json = try std.json.parseFromSlice(std.json.Value, gpa, put_response, .{});
    defer put_json.deinit();
    const version = put_json.value.object.get("version").?.string;

    const get_request = try std.fmt.allocPrint(
        gpa,
        "{{\"type\":\"issue\",\"id\":\"transport-1\",\"version\":\"{s}\"}}",
        .{version},
    );
    defer gpa.free(get_request);
    const get_response = try sideshowdb.document_transport.handleGet(
        gpa,
        document_store,
        get_request,
    );
    defer if (get_response) |bytes| gpa.free(bytes);
    try std.testing.expect(get_response != null);
}
