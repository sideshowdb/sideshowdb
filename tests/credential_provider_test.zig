//! Unit tests for `CredentialProvider` and the per-source modules under
//! `src/core/storage/credential_sources/`.

const std = @import("std");
const credential_provider = @import("credential_provider");
const explicit_source = @import("credential_source_explicit");

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
