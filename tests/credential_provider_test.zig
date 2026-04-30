//! Unit tests for `CredentialProvider` and the per-source modules under
//! `src/core/storage/credential_sources/`.

const std = @import("std");
const builtin = @import("builtin");
const credential_provider = @import("credential_provider");
const explicit_source = @import("credential_source_explicit");
const env_source = @import("credential_source_env");
const gh_helper = @import("credential_source_gh_helper");
const git_helper = @import("credential_source_git_helper");
const auto_walker = @import("credential_source_auto");
const host_capability_source = @import("credential_source_host_capability");
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
        .{ .gpa = gpa },
    );
    defer holder.deinit();

    const provider = holder.provider();
    var cred = try provider.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expect(cred == .bearer);
    try std.testing.expectEqualStrings("spec-token", cred.bearer);
}

test "credential_provider_fromSpec_explicit_rejects_empty" {
    const gpa = std.testing.allocator;

    const result = credential_provider.fromSpec(
        .{ .explicit = "" },
        .{ .gpa = gpa },
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

test "git_helper_protocol_round_trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const tmp_dir_path = try std.fs.path.join(gpa, &.{
        cwd_path,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(tmp_dir_path);
    const stdin_capture_path = try std.fs.path.join(gpa, &.{ tmp_dir_path, "stdin.txt" });
    defer gpa.free(stdin_capture_path);

    const shell_script = try std.fmt.allocPrint(
        gpa,
        "cat > {s}; printf 'username=alice\\npassword=hunter2\\n'",
        .{stdin_capture_path},
    );
    defer gpa.free(shell_script);

    var src = try git_helper.GitHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/bin/sh",
        .args = &.{ "-c", shell_script },
        .protocol = "https",
        .host = "github.com",
    });
    defer src.deinit();
    var provider = src.provider();

    var cred = try provider.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expect(cred == .basic);
    try std.testing.expectEqualStrings("alice", cred.basic.user);
    try std.testing.expectEqualStrings("hunter2", cred.basic.password);

    const captured = try std.Io.Dir.cwd().readFileAlloc(
        io,
        stdin_capture_path,
        gpa,
        .limited(4096),
    );
    defer gpa.free(captured);
    try std.testing.expectEqualStrings("protocol=https\nhost=github.com\n\n", captured);
}

test "git_helper_protocol_round_trip_custom_host" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    const tmp_dir_path = try std.fs.path.join(gpa, &.{
        cwd_path,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(tmp_dir_path);
    const stdin_capture_path = try std.fs.path.join(gpa, &.{ tmp_dir_path, "stdin.txt" });
    defer gpa.free(stdin_capture_path);

    const shell_script = try std.fmt.allocPrint(
        gpa,
        "cat > {s}; printf 'username=bob\\npassword=s3cret\\n'",
        .{stdin_capture_path},
    );
    defer gpa.free(shell_script);

    var src = try git_helper.GitHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/bin/sh",
        .args = &.{ "-c", shell_script },
        .protocol = "http",
        .host = "ghe.example.com",
    });
    defer src.deinit();
    var provider = src.provider();

    var cred = try provider.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expectEqualStrings("bob", cred.basic.user);
    try std.testing.expectEqualStrings("s3cret", cred.basic.password);

    const captured = try std.Io.Dir.cwd().readFileAlloc(
        io,
        stdin_capture_path,
        gpa,
        .limited(4096),
    );
    defer gpa.free(captured);
    try std.testing.expectEqualStrings("protocol=http\nhost=ghe.example.com\n\n", captured);
}

test "git_helper_missing_executable_returns_helper_unavailable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var src = try git_helper.GitHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/nonexistent/path/to/git-bin-7d2c1",
        .args = &.{ "credential", "fill" },
    });
    defer src.deinit();
    var provider = src.provider();

    const result = provider.get(gpa);
    try std.testing.expectError(error.HelperUnavailable, result);
}

test "git_helper_non_zero_exit_returns_auth_invalid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var src = try git_helper.GitHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/bin/sh",
        .args = &.{ "-c", "cat > /dev/null; exit 1" },
    });
    defer src.deinit();
    var provider = src.provider();

    const result = provider.get(gpa);
    try std.testing.expectError(error.AuthInvalid, result);
}

test "git_helper_empty_username_returns_helper_unavailable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var src = try git_helper.GitHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/bin/sh",
        .args = &.{ "-c", "cat > /dev/null" },
    });
    defer src.deinit();
    var provider = src.provider();

    const result = provider.get(gpa);
    try std.testing.expectError(error.HelperUnavailable, result);
}

test "git_helper_missing_password_returns_auth_invalid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var src = try git_helper.GitHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/bin/sh",
        .args = &.{ "-c", "cat > /dev/null; printf 'username=alice\\n'" },
    });
    defer src.deinit();
    var provider = src.provider();

    const result = provider.get(gpa);
    try std.testing.expectError(error.AuthInvalid, result);
}

test "git_helper_empty_executable_name_rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = git_helper.GitHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "",
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "git_helper_empty_protocol_rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = git_helper.GitHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .protocol = "",
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "git_helper_empty_host_rejected" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = git_helper.GitHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .host = "",
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "git_helper_handles_extra_lines" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var src = try git_helper.GitHelperSource.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .executable_name = "/bin/sh",
        .args = &.{
            "-c",
            "cat > /dev/null; printf 'protocol=https\\nhost=github.com\\nusername=alice\\npassword=hunter2\\nquit=1\\n'",
        },
    });
    defer src.deinit();
    var provider = src.provider();

    var cred = try provider.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expect(cred == .basic);
    try std.testing.expectEqualStrings("alice", cred.basic.user);
    try std.testing.expectEqualStrings("hunter2", cred.basic.password);
}

const HostStub = struct {
    bearer: []const u8,
    calls: u32 = 0,

    fn dispatch(
        ctx: ?*anyopaque,
        provider_ptr: [*]const u8,
        provider_len: usize,
        scope_ptr: [*]const u8,
        scope_len: usize,
        out_buf_ptr: [*]u8,
        out_capacity: usize,
        out_actual_len: *u32,
    ) i32 {
        _ = provider_ptr;
        _ = provider_len;
        _ = scope_ptr;
        _ = scope_len;
        const self: *HostStub = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        if (self.bearer.len > out_capacity) {
            out_actual_len.* = @truncate(self.bearer.len);
            return host_capability_source.rc_too_small;
        }
        @memcpy(out_buf_ptr[0..self.bearer.len], self.bearer);
        out_actual_len.* = @truncate(self.bearer.len);
        return 0;
    }
};

test "fromSpec_constructs_gh_helper_provider" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var holder = try credential_provider.fromSpec(.gh_helper, .{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
    });
    defer holder.deinit();

    // Default `gh` executable is unlikely to be a working install in CI;
    // calling .get exercises only construction, not the subprocess. The
    // happy-path round trip is exercised in the gh_helper-specific tests
    // above where the executable is overridden to /bin/echo.
    _ = holder.provider();
}

test "fromSpec_gh_helper_rejects_missing_io" {
    const gpa = std.testing.allocator;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = credential_provider.fromSpec(.gh_helper, .{
        .gpa = gpa,
        .parent_env = &env,
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "fromSpec_gh_helper_rejects_missing_env" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const result = credential_provider.fromSpec(.gh_helper, .{
        .gpa = gpa,
        .io = io,
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "fromSpec_constructs_git_helper_provider" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var holder = try credential_provider.fromSpec(.git_helper, .{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
    });
    defer holder.deinit();

    _ = holder.provider();
}

test "fromSpec_git_helper_rejects_missing_io" {
    const gpa = std.testing.allocator;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = credential_provider.fromSpec(.git_helper, .{
        .gpa = gpa,
        .parent_env = &env,
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "fromSpec_git_helper_rejects_missing_env" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const result = credential_provider.fromSpec(.git_helper, .{
        .gpa = gpa,
        .io = io,
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "fromSpec_dispatches_host_capability_with_injected_dispatcher" {
    const gpa = std.testing.allocator;

    var stub: HostStub = .{ .bearer = "from-spec" };
    var holder = try credential_provider.fromSpec(.host_capability, .{
        .gpa = gpa,
        .host_dispatcher = &HostStub.dispatch,
        .host_dispatcher_ctx = @ptrCast(&stub),
    });
    defer holder.deinit();

    const provider = holder.provider();
    var cred = try provider.get(gpa);
    defer cred.deinit(gpa);

    try std.testing.expect(cred == .bearer);
    try std.testing.expectEqualStrings("from-spec", cred.bearer);
    try std.testing.expectEqual(@as(u32, 1), stub.calls);
}

test "fromSpec_dispatches_host_capability_default_dispatcher" {
    const gpa = std.testing.allocator;

    // No override → platform default. Native target's default dispatcher
    // returns rc_unavailable, which surfaces as HelperUnavailable. Proves
    // the default plumbed through from `fromSpec` to the source.
    var holder = try credential_provider.fromSpec(.host_capability, .{
        .gpa = gpa,
    });
    defer holder.deinit();

    const provider = holder.provider();
    try std.testing.expectError(error.HelperUnavailable, provider.get(gpa));
}

test "fromSpec_keychain_still_helper_unavailable" {
    const gpa = std.testing.allocator;

    // The .keychain arm is reserved for a future native source ticket;
    // until that lands, fromSpec must surface the missing helper rather
    // than constructing a half-wired source.
    const result = credential_provider.fromSpec(
        .{ .keychain = .{} },
        .{ .gpa = gpa },
    );
    try std.testing.expectError(error.HelperUnavailable, result);
}

test "fromSpec_auto_rejects_missing_io_on_native" {
    const gpa = std.testing.allocator;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = credential_provider.fromSpec(.auto, .{
        .gpa = gpa,
        .parent_env = &env,
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "fromSpec_auto_rejects_missing_env_on_native" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const result = credential_provider.fromSpec(.auto, .{
        .gpa = gpa,
        .io = io,
    });
    try std.testing.expectError(error.InvalidConfig, result);
}

test "fromSpec_auto_walks_native_chain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    // Use an env-var that almost certainly won't be set in the test
    // environment so the env arm reports HelperUnavailable, then the gh
    // arm runs `gh auth token`. We can't reliably assert success, but we
    // can prove the walker constructs and the env arm is consulted by
    // calling .get and accepting any of HelperUnavailable / AuthInvalid /
    // AuthMissing as valid outcomes — none of which require the test
    // host to have working creds.
    var holder = try credential_provider.fromSpec(.auto, .{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .auto_env_var = "SHEDB_TEST_AUTO_CHAIN_DOES_NOT_EXIST_QQ",
    });
    defer holder.deinit();

    const provider = holder.provider();
    const cred_or_err = provider.get(gpa);
    if (cred_or_err) |cred| {
        var c = cred;
        c.deinit(gpa);
    } else |err| switch (err) {
        error.HelperUnavailable, error.AuthInvalid, error.AuthMissing => {},
        else => return err,
    }
}
