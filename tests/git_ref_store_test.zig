//! Integration test for `GitRefStore`. Builds a real ephemeral git repo,
//! drives the store through the abstract `RefStore` interface, and verifies
//! both sideshowdb-visible state and the underlying git history.

const std = @import("std");
const sideshowdb = @import("sideshowdb");
const parity = @import("ref_store_parity.zig");
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
    const result = try std.process.run(gpa, io, .{ .argv = argv, .environ_map = env });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("argv[0]={s} stderr: {s}", .{ argv[0], result.stderr });
        return error.HelperCommandFailed;
    }
}

fn countCommits(ctx: *const anyopaque, repo_path: []const u8) !u32 {
    const env: *const Environ.Map = @ptrCast(@alignCast(ctx));

    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "git", "-C", repo_path, "rev-list", "--count", "refs/sideshowdb/test" },
        .environ_map = env,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    const count_str = std.mem.trim(u8, result.stdout, " \n\r");
    return try std.fmt.parseInt(u32, count_str, 10);
}

test "GitRefStore: parity harness" {
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

    var store = sideshowdb.GitRefStore.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .repo_path = repo_path,
        .ref_name = "refs/sideshowdb/test",
    });

    try parity.exerciseRefStore(.{
        .gpa = gpa,
        .ref_store = store.refStore(),
        .repo_path = repo_path,
        .count_commits = countCommits,
        .ctx = &env,
    });
}

test "GitRefStore: history treats metacharacters in keys literally" {
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

    var store = sideshowdb.GitRefStore.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .repo_path = repo_path,
        .ref_name = "refs/sideshowdb/test",
    });
    const rs = store.refStore();

    const literal_version = try rs.put(gpa, "a/file[1].txt", "literal");
    defer gpa.free(literal_version);
    const wildcard_match_version = try rs.put(gpa, "a/file1.txt", "wildcard-match");
    defer gpa.free(wildcard_match_version);

    const versions = try rs.history(gpa, "a/file[1].txt");
    defer sideshowdb.RefStore.freeVersions(gpa, versions);

    try std.testing.expectEqual(@as(usize, 1), versions.len);
    try std.testing.expectEqualStrings(literal_version, versions[0]);
    try std.testing.expect(!std.mem.eql(u8, wildcard_match_version, versions[0]));
}
