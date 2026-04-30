//! Unit tests for `CredentialProvider` and the per-source modules under
//! `src/core/storage/credential_sources/`.

const std = @import("std");
const builtin = @import("builtin");
const credential_provider = @import("credential_provider");
const explicit_source = @import("credential_source_explicit");
const env_source = @import("credential_source_env");

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
