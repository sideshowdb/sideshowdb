//! Unit tests for `CredentialProvider` and the per-source modules under
//! `src/core/storage/credential_sources/`.

const std = @import("std");
const builtin = @import("builtin");
const credential_provider = @import("credential_provider");
const explicit_source = @import("credential_source_explicit");
const env_source = @import("credential_source_env");
const gh_helper = @import("credential_source_gh_helper");
const auto_walker = @import("credential_source_auto");
const Environ = std.process.Environ;

test "explicit_source_returns_token" {
    const gpa = std.testing.allocator;

    var src = try explicit_source.ExplicitSource.init("tok-123");
    var provider = src.provider();

    var cred = try provider.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expect(cred == .bearer);
    try std.testing.expectEqualStrings("tok-123", cred.bearer);
}

test "explicit_source_empty_token_is_invalid_config" {
    const result = explicit_source.ExplicitSource.init("");
    try std.testing.expectError(error.InvalidConfig, result);
}

test "credential_provider_fromSpec_explicit_returns_token" {
    const gpa = std.testing.allocator;

    var holder = try credential_provider.fromSpec(
        .{ .explicit = "spec-token" },
        .{},
    );
    defer holder.deinit();

    const provider = holder.provider();
    var cred = try provider.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expect(cred == .bearer);
    try std.testing.expectEqualStrings("spec-token", cred.bearer);
}

test "credential_provider_fromSpec_explicit_rejects_empty" {
    const result = credential_provider.fromSpec(
        .{ .explicit = "" },
        .{},
    );
    try std.testing.expectError(error.InvalidConfig, result);
}

const StubEnv = struct {
    name: []const u8,
    value: ?[]const u8,

    fn lookup(ctx: *anyopaque, gpa: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
        const self: *StubEnv = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, self.name, name)) return null;
        const v = self.value orelse return null;
        return try gpa.dupe(u8, v);
    }
};

test "env_source_reads_named_var" {
    const gpa = std.testing.allocator;

    var stub: StubEnv = .{ .name = "SHEDB_TEST_TOKEN", .value = "from-env" };
    var src = try env_source.EnvSource.initWithLookup(
        "SHEDB_TEST_TOKEN",
        .{ .ctx = @ptrCast(&stub), .lookup_fn = StubEnv.lookup },
    );
    var provider = src.provider();

    var cred = try provider.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expect(cred == .bearer);
    try std.testing.expectEqualStrings("from-env", cred.bearer);
}

test "env_source_missing_returns_helper_unavailable" {
    const gpa = std.testing.allocator;

    var stub: StubEnv = .{ .name = "SHEDB_TEST_TOKEN", .value = null };
    var src = try env_source.EnvSource.initWithLookup(
        "SHEDB_TEST_TOKEN",
        .{ .ctx = @ptrCast(&stub), .lookup_fn = StubEnv.lookup },
    );
    var provider = src.provider();

    const result = provider.get(gpa);
    try std.testing.expectError(error.HelperUnavailable, result);
}

test "env_source_empty_var_name_is_invalid_config" {
    const result = env_source.EnvSource.init("");
    try std.testing.expectError(error.InvalidConfig, result);
}

test "gh_helper_returns_token_from_stub" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var src = try gh_helper.GhHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/bin/echo",
        .args = &.{"tok-from-stub"},
    });
    defer src.deinit();
    var provider = src.provider();

    var cred = try provider.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expect(cred == .bearer);
    try std.testing.expectEqualStrings("tok-from-stub", cred.bearer);
}

test "gh_helper_missing_executable_returns_helper_unavailable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var src = try gh_helper.GhHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/nonexistent/path/to/gh-bin-9b8c7",
        .args = &.{},
    });
    defer src.deinit();
    var provider = src.provider();

    const result = provider.get(gpa);
    try std.testing.expectError(error.HelperUnavailable, result);
}

test "gh_helper_exit_nonzero_returns_auth_invalid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var src = try gh_helper.GhHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/bin/sh",
        .args = &.{ "-c", "exit 1" },
    });
    defer src.deinit();
    var provider = src.provider();

    const result = provider.get(gpa);
    try std.testing.expectError(error.AuthInvalid, result);
}

test "gh_helper_empty_stdout_returns_auth_invalid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var src = try gh_helper.GhHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/bin/sh",
        .args = &.{ "-c", "exit 0" },
    });
    defer src.deinit();
    var provider = src.provider();

    const result = provider.get(gpa);
    try std.testing.expectError(error.AuthInvalid, result);
}

test "gh_helper_init_rejects_empty_executable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = gh_helper.GhHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "",
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

const MockProvider = struct {
    outcome: Outcome,

    const Outcome = union(enum) {
        unavailable,
        auth_invalid,
        success: []const u8,
    };

    fn provider(self: *MockProvider) credential_provider.CredentialProvider {
        return .{ .ctx = @ptrCast(self), .get_fn = mockGet };
    }

    fn mockGet(
        ctx: *anyopaque,
        gpa: std.mem.Allocator,
    ) credential_provider.CredentialError!credential_provider.Credential {
        const self: *MockProvider = @ptrCast(@alignCast(ctx));
        switch (self.outcome) {
            .unavailable => return error.HelperUnavailable,
            .auth_invalid => return error.AuthInvalid,
            .success => |tok| return .{ .bearer = try gpa.dupe(u8, tok) },
        }
    }
};

test "auto_walker_picks_first_available" {
    const gpa = std.testing.allocator;

    var first: MockProvider = .{ .outcome = .unavailable };
    var second: MockProvider = .{ .outcome = .unavailable };
    var third: MockProvider = .{ .outcome = .{ .success = "tok-from-third" } };

    const sources: [3]credential_provider.CredentialProvider = .{
        first.provider(),
        second.provider(),
        third.provider(),
    };
    var walker = try auto_walker.AutoSource.init(&sources);
    var provider = walker.provider();

    var cred = try provider.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expect(cred == .bearer);
    try std.testing.expectEqualStrings("tok-from-third", cred.bearer);
}

test "auto_walker_returns_auth_missing_when_all_sources_unavailable" {
    const gpa = std.testing.allocator;

    var first: MockProvider = .{ .outcome = .unavailable };
    var second: MockProvider = .{ .outcome = .unavailable };

    const sources: [2]credential_provider.CredentialProvider = .{
        first.provider(),
        second.provider(),
    };
    var walker = try auto_walker.AutoSource.init(&sources);
    var provider = walker.provider();

    const result = provider.get(gpa);
    try std.testing.expectError(error.AuthMissing, result);
}

test "auto_walker_short_circuits_on_auth_invalid" {
    const gpa = std.testing.allocator;

    var first: MockProvider = .{ .outcome = .auth_invalid };
    var second: MockProvider = .{ .outcome = .{ .success = "should-not-be-reached" } };

    const sources: [2]credential_provider.CredentialProvider = .{
        first.provider(),
        second.provider(),
    };
    var walker = try auto_walker.AutoSource.init(&sources);
    var provider = walker.provider();

    const result = provider.get(gpa);
    try std.testing.expectError(error.AuthInvalid, result);
}

test "auto_walker_init_rejects_empty_chain" {
    const result = auto_walker.AutoSource.init(&.{});
    try std.testing.expectError(error.InvalidConfig, result);
}
