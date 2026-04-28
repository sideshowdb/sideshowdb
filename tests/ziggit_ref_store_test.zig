const std = @import("std");
const sideshowdb = @import("src/core/storage.zig");
const parity = @import("ref_store_parity.zig");
const ziggit = @import("ziggit.zig");

test "ZiggitRefStore: parity harness" {
    _ = ziggit.Repository;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const repo_path = try std.fs.path.join(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(repo_path);

    var store = sideshowdb.ZiggitRefStore.init(.{
        .gpa = std.testing.allocator,
        .repo_path = repo_path,
        .ref_name = "refs/sideshowdb/test",
    });

    try parity.exerciseRefStore(.{
        .gpa = std.testing.allocator,
        .ref_store = store.refStore(),
    });
}

test "ZiggitRefStore: history treats metacharacters in keys literally" {
    _ = ziggit.Repository;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const repo_path = try std.fs.path.join(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(repo_path);

    var store = sideshowdb.ZiggitRefStore.init(.{
        .gpa = std.testing.allocator,
        .repo_path = repo_path,
        .ref_name = "refs/sideshowdb/test",
    });
    const rs = store.refStore();

    const literal_version = try rs.put(std.testing.allocator, "a/file[1].txt", "literal");
    defer std.testing.allocator.free(literal_version);
    const wildcard_match_version = try rs.put(std.testing.allocator, "a/file1.txt", "wildcard-match");
    defer std.testing.allocator.free(wildcard_match_version);

    const versions = try rs.history(std.testing.allocator, "a/file[1].txt");
    defer sideshowdb.RefStore.freeVersions(std.testing.allocator, versions);

    try std.testing.expectEqual(@as(usize, 1), versions.len);
    try std.testing.expectEqualStrings(literal_version, versions[0]);
    try std.testing.expect(!std.mem.eql(u8, wildcard_match_version, versions[0]));
}
