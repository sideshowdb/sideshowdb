//! Unified SideshowDB configuration model.

const std = @import("std");
const serde = @import("serde");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

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

    pub const serde = .{
        .deny_unknown_fields = true,
    };
};

pub const RefStoreConfig = struct {
    kind: ?RefStoreKind = null,
    repo: ?[]const u8 = null,
    ref_name: ?[]const u8 = null,
    api_base: ?[]const u8 = null,
    credential_helper: ?CredentialHelper = null,

    pub const serde = .{
        .deny_unknown_fields = true,
    };
};

pub const CredentialConfig = struct {
    helper: ?CredentialHelper = null,

    pub const serde = .{
        .deny_unknown_fields = true,
    };
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

pub const ParsedConfig = struct {
    value: Config,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedConfig, gpa: Allocator) void {
        _ = gpa;
        self.arena.deinit();
    }
};

pub fn parseToml(gpa: Allocator, bytes: []const u8) !ParsedConfig {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const value = try serde.toml.fromSlice(Config, arena.allocator(), bytes);
    return .{
        .value = value,
        .arena = arena,
    };
}

pub fn renderToml(gpa: Allocator, config: Config) ![]u8 {
    return serde.toml.toSlice(gpa, config);
}

pub fn localConfigPath(gpa: Allocator, repo_path: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ repo_path, ".sideshowdb", "config.toml" });
}

pub fn globalConfigPath(gpa: Allocator, env: *const Environ.Map) ![]u8 {
    if (env.get("SIDESHOWDB_CONFIG_DIR")) |dir| {
        return std.fs.path.join(gpa, &.{ dir, "config.toml" });
    }
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len != 0) {
            return std.fs.path.join(gpa, &.{ xdg, "sideshowdb", "config.toml" });
        }
    }
    if (env.get("APPDATA")) |appdata| {
        return std.fs.path.join(gpa, &.{ appdata, "sideshowdb", "config.toml" });
    }
    if (env.get("HOME")) |home| {
        return std.fs.path.join(gpa, &.{ home, ".config", "sideshowdb", "config.toml" });
    }
    return error.NoHomeDir;
}

test "defaults are stable" {
    try std.testing.expectEqual(RefStoreKind.subprocess, defaults.refstore.kind);
    try std.testing.expectEqualStrings("refs/sideshowdb/documents", defaults.refstore.ref_name);
    _ = serde;
}

test "parseToml reads refstore fields" {
    const gpa = std.testing.allocator;
    const source =
        \\[refstore]
        \\kind = "github"
        \\repo = "sideshowdb/sideshowdb"
        \\ref_name = "refs/sideshowdb/test"
        \\api_base = "https://github.example.com/api/v3"
        \\credential_helper = "gh"
        \\
    ;

    var parsed = try parseToml(gpa, source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(RefStoreKind.github, parsed.value.refstore.kind.?);
    try std.testing.expectEqualStrings("sideshowdb/sideshowdb", parsed.value.refstore.repo.?);
    try std.testing.expectEqualStrings("refs/sideshowdb/test", parsed.value.refstore.ref_name.?);
    try std.testing.expectEqualStrings("https://github.example.com/api/v3", parsed.value.refstore.api_base.?);
    try std.testing.expectEqual(CredentialHelper.gh, parsed.value.refstore.credential_helper.?);
}

test "renderToml emits parseable config" {
    const gpa = std.testing.allocator;
    const bytes = try renderToml(gpa, .{
        .refstore = .{
            .kind = .github,
            .repo = "owner/repo",
            .ref_name = "refs/sideshowdb/docs",
            .credential_helper = .env,
        },
    });
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "[refstore]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "kind") != null);

    var parsed = try parseToml(gpa, bytes);
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(RefStoreKind.github, parsed.value.refstore.kind.?);
    try std.testing.expectEqual(CredentialHelper.env, parsed.value.refstore.credential_helper.?);
}

fn expectParseFailure(source: []const u8) !void {
    var parsed = parseToml(std.testing.allocator, source) catch return;
    parsed.deinit(std.testing.allocator);
    return error.ExpectedParseFailure;
}

test "parseToml rejects unknown top-level fields" {
    try expectParseFailure(
        \\unknown = "value"
        \\
    );
}

test "parseToml rejects unknown refstore fields" {
    try expectParseFailure(
        \\[refstore]
        \\kind = "github"
        \\unknown = "value"
        \\
    );
}

test "parseToml rejects invalid enum values" {
    try expectParseFailure(
        \\[refstore]
        \\kind = "banana"
        \\
    );
}

test "parseToml rejects malformed TOML" {
    try expectParseFailure(
        \\[refstore
        \\kind = "github"
        \\
    );
}

test "local and global paths follow project conventions" {
    const gpa = std.testing.allocator;
    const local = try localConfigPath(gpa, "/tmp/repo");
    defer gpa.free(local);
    const expected_local = try std.fs.path.join(gpa, &.{ "/tmp/repo", ".sideshowdb", "config.toml" });
    defer gpa.free(expected_local);
    try std.testing.expectEqualStrings(expected_local, local);

    var env = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_CONFIG_DIR", "/tmp/sideshow-config");
    const global = try globalConfigPath(gpa, &env);
    defer gpa.free(global);
    const expected_global = try std.fs.path.join(gpa, &.{ "/tmp/sideshow-config", "config.toml" });
    defer gpa.free(expected_global);
    try std.testing.expectEqualStrings(expected_global, global);
}

test "globalConfigPath falls back to XDG_CONFIG_HOME" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", "/tmp/xdg");

    const global = try globalConfigPath(gpa, &env);
    defer gpa.free(global);

    const expected = try std.fs.path.join(gpa, &.{ "/tmp/xdg", "sideshowdb", "config.toml" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, global);
}

test "globalConfigPath falls back to APPDATA before HOME" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("APPDATA", "/tmp/appdata");
    try env.put("HOME", "/tmp/home");

    const global = try globalConfigPath(gpa, &env);
    defer gpa.free(global);

    const expected = try std.fs.path.join(gpa, &.{ "/tmp/appdata", "sideshowdb", "config.toml" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, global);
}

test "globalConfigPath falls back to HOME config directory" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", "/tmp/home");

    const global = try globalConfigPath(gpa, &env);
    defer gpa.free(global);

    const expected = try std.fs.path.join(gpa, &.{ "/tmp/home", ".config", "sideshowdb", "config.toml" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, global);
}
