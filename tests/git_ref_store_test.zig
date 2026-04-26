//! Integration test for `GitRefStore`. Builds a real ephemeral git repo,
//! drives the store through the abstract `RefStore` interface, and verifies
//! both sideshowdb-visible state and the underlying git history.

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
    const result = try std.process.run(gpa, io, .{ .argv = argv, .environ_map = env });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("argv[0]={s} stderr: {s}", .{ argv[0], result.stderr });
        return error.HelperCommandFailed;
    }
}

test "GitRefStore: put/get/overwrite/delete/list with history" {
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

    // ── 1. ref does not exist yet
    {
        const keys = try rs.list(gpa);
        defer sideshowdb.RefStore.freeKeys(gpa, keys);
        try std.testing.expectEqual(@as(usize, 0), keys.len);
    }
    {
        const v = try rs.get(gpa, "a/x.txt");
        try std.testing.expect(v == null);
    }

    // ── 2. first put creates the ref
    try rs.put("a/x.txt", "hello");
    {
        const v = try rs.get(gpa, "a/x.txt");
        defer if (v) |b| gpa.free(b);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("hello", v.?);
    }

    // ── 3. overwrite
    try rs.put("a/x.txt", "world");
    {
        const v = try rs.get(gpa, "a/x.txt");
        defer if (v) |b| gpa.free(b);
        try std.testing.expectEqualStrings("world", v.?);
    }

    // ── 4. second key + list
    try rs.put("b/y.txt", "ok");
    {
        const keys = try rs.list(gpa);
        defer sideshowdb.RefStore.freeKeys(gpa, keys);
        try std.testing.expectEqual(@as(usize, 2), keys.len);
        // order-independent membership check
        var saw_a = false;
        var saw_b = false;
        for (keys) |k| {
            if (std.mem.eql(u8, k, "a/x.txt")) saw_a = true;
            if (std.mem.eql(u8, k, "b/y.txt")) saw_b = true;
        }
        try std.testing.expect(saw_a and saw_b);
    }

    // ── 5. delete
    try rs.delete("a/x.txt");
    {
        const v = try rs.get(gpa, "a/x.txt");
        try std.testing.expect(v == null);
    }
    {
        const keys = try rs.list(gpa);
        defer sideshowdb.RefStore.freeKeys(gpa, keys);
        try std.testing.expectEqual(@as(usize, 1), keys.len);
        try std.testing.expectEqualStrings("b/y.txt", keys[0]);
    }

    // ── 6. delete is idempotent
    try rs.delete("a/x.txt");

    // ── 7. history is preserved: ref-name should reach >=4 commits
    //        (put hello, overwrite world, put b/y.txt, delete a/x.txt)
    {
        const result = try std.process.run(gpa, io, .{
            .argv = &.{ "git", "-C", repo_path, "rev-list", "--count", "refs/sideshowdb/test" },
            .environ_map = &env,
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
        const count_str = std.mem.trim(u8, result.stdout, " \n\r");
        const count = try std.fmt.parseInt(u32, count_str, 10);
        try std.testing.expect(count >= 4);
    }

    // ── 8. invalid keys reject up front
    try std.testing.expectError(error.InvalidKey, rs.put("", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put("/leading", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put("trailing/", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put("a//b", "x"));
}
