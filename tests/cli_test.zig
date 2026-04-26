const std = @import("std");
const sideshowdb = @import("sideshowdb");
const cli = @import("sideshowdb_cli_app");
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

test "CLI doc put/get normalizes namespace and supports versioned reads" {
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

    const put_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "doc", "put", "--type", "issue", "--id", "cli-1" },
        "{\"title\":\"hello from cli\"}",
    );
    defer put_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), put_result.exit_code);
    try std.testing.expect(put_result.stderr.len == 0);

    var put_json = try std.json.parseFromSlice(std.json.Value, gpa, put_result.stdout, .{});
    defer put_json.deinit();
    try std.testing.expectEqualStrings("default", put_json.value.object.get("namespace").?.string);
    const written_version = put_json.value.object.get("version").?.string;

    const get_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "doc", "get", "--type", "issue", "--id", "cli-1", "--version", written_version },
        "",
    );
    defer get_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), get_result.exit_code);

    var get_json = try std.json.parseFromSlice(std.json.Value, gpa, get_result.stdout, .{});
    defer get_json.deinit();
    try std.testing.expectEqualStrings("hello from cli", get_json.value.object.get("data").?.object.get("title").?.string);
}

test "CLI usage failures return the shared usage message" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const missing_args = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{"sideshowdb"},
        "",
    );
    defer missing_args.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), missing_args.exit_code);
    try std.testing.expectEqualStrings(cli.usage_message, missing_args.stderr);

    const invalid_put_args = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshowdb", "doc", "put", "--type" },
        "",
    );
    defer invalid_put_args.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), invalid_put_args.exit_code);
    try std.testing.expectEqualStrings(cli.usage_message, invalid_put_args.stderr);
}
