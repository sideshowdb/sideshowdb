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
