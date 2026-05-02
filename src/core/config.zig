//! Unified SideshowDB configuration model.

const std = @import("std");
const serde = @import("serde");

pub const RefStoreKind = enum {
    subprocess,
    github,
};

pub const CredentialHelper = enum {
    auto,
    env,
    gh,
    git,
};

pub const Config = struct {
    refstore: RefStoreConfig = .{},
    credentials: CredentialConfig = .{},
};

pub const RefStoreConfig = struct {
    kind: ?RefStoreKind = null,
    repo: ?[]const u8 = null,
    ref_name: ?[]const u8 = null,
    api_base: ?[]const u8 = null,
    credential_helper: ?CredentialHelper = null,
};

pub const CredentialConfig = struct {
    helper: ?CredentialHelper = null,
};

pub const ResolvedRefStoreConfig = struct {
    kind: RefStoreKind,
    repo: ?[]const u8,
    ref_name: []const u8,
    api_base: []const u8,
    credential_helper: CredentialHelper,
};

pub const ResolvedConfig = struct {
    refstore: ResolvedRefStoreConfig,
};

pub const defaults: ResolvedConfig = .{
    .refstore = .{
        .kind = .subprocess,
        .repo = null,
        .ref_name = "refs/sideshowdb/documents",
        .api_base = "https://api.github.com",
        .credential_helper = .auto,
    },
};

test "defaults are stable" {
    try std.testing.expectEqual(RefStoreKind.subprocess, defaults.refstore.kind);
    try std.testing.expectEqualStrings("refs/sideshowdb/documents", defaults.refstore.ref_name);
    _ = serde;
}
