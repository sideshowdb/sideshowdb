//! Opt-in live integration tests against a real GitHub repository.
//!
//! Skipped unless both environment variables are set:
//!   GITHUB_TEST_TOKEN  — personal access token with repo/contents scope
//!   GITHUB_TEST_REPO   — target repository in "owner/repo" format
//!
//! Run with:
//!   zig build test:github-live

const std = @import("std");
const credential_source_env = @import("credential_source_env");
const github_api_ref_store = @import("github_api_ref_store");
const http_transport = @import("http_transport");
const std_http_transport = @import("std_http_transport");

const GitHubApiRefStore = github_api_ref_store.GitHubApiRefStore;
const StdHttpTransport = std_http_transport.StdHttpTransport;
const EnvSource = credential_source_env.EnvSource;

test "put/get/list/delete round-trip against live GitHub" {
    const repo_raw = std.c.getenv("GITHUB_TEST_REPO") orelse return error.SkipZigTest;
    _ = std.c.getenv("GITHUB_TEST_TOKEN") orelse return error.SkipZigTest;
    const repo_str = std.mem.sliceTo(repo_raw, 0);

    const slash = std.mem.indexOf(u8, repo_str, "/") orelse return error.SkipZigTest;
    const owner = repo_str[0..slash];
    const repo = repo_str[slash + 1 ..];
    if (owner.len == 0 or repo.len == 0) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const ref_name = "refs/sideshowdb/live-test";

    const io = std.testing.io;
    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();
    var transport_impl: StdHttpTransport = .{ .client = &http_client };

    var env_src = try EnvSource.init("GITHUB_TEST_TOKEN");
    defer env_src.deinit();

    var gh_store = try GitHubApiRefStore.init(.{
        .owner = owner,
        .repo = repo,
        .ref_name = ref_name,
        .transport = transport_impl.transport(),
        .credentials = env_src.provider(),
    });
    defer gh_store.deinitCaches(gpa);

    const store = gh_store.refStore();

    // put
    const put1 = try store.put(gpa, "live-test/a.txt", "hello-live");
    _ = put1;

    // get — value must match
    const read1 = try store.get(gpa, "live-test/a.txt", null);
    try std.testing.expect(read1 != null);
    try std.testing.expectEqualStrings("hello-live", read1.?.value);

    // overwrite
    const put2 = try store.put(gpa, "live-test/a.txt", "world-live");
    _ = put2;

    // get — must reflect overwrite
    const read2 = try store.get(gpa, "live-test/a.txt", null);
    try std.testing.expect(read2 != null);
    try std.testing.expectEqualStrings("world-live", read2.?.value);

    // list — key must appear
    const keys = try store.list(gpa);
    var found = false;
    for (keys) |k| {
        if (std.mem.eql(u8, k, "live-test/a.txt")) found = true;
    }
    try std.testing.expect(found);

    // delete
    try store.delete(gpa, "live-test/a.txt");

    // get — must be gone
    const read3 = try store.get(gpa, "live-test/a.txt", null);
    try std.testing.expect(read3 == null);
}
