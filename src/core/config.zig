//! Unified SideshowDB configuration model.

const std = @import("std");
const serde = @import("serde");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const SkipMode = serde.SkipMode;

pub const max_file_bytes: usize = 16 * 1024;

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

pub const ConfigError = error{
    UnknownConfigKey,
    InvalidConfigValue,
} || Allocator.Error;

pub const Config = struct {
    refstore: RefStoreConfig = .{},
    credentials: CredentialConfig = .{},

    pub const serde = .{
        .deny_unknown_fields = true,
    };

    /// Frees string fields owned by a Config mutated through setPath.
    /// ParsedConfig values remain arena-owned and should be released through ParsedConfig.deinit.
    pub fn deinit(self: *Config, gpa: Allocator) void {
        self.refstore.deinit(gpa);
    }
};

pub const RefStoreConfig = struct {
    kind: ?RefStoreKind = null,
    repo: ?[]const u8 = null,
    ref_name: ?[]const u8 = null,
    api_base: ?[]const u8 = null,
    credential_helper: ?CredentialHelper = null,
    repo_owned: bool = false,
    ref_name_owned: bool = false,
    api_base_owned: bool = false,

    pub const serde = .{
        .deny_unknown_fields = true,
        .skip = .{
            .repo_owned = SkipMode.always,
            .ref_name_owned = SkipMode.always,
            .api_base_owned = SkipMode.always,
        },
    };

    pub fn deinit(self: *RefStoreConfig, gpa: Allocator) void {
        if (self.repo_owned) {
            if (self.repo) |value| gpa.free(value);
        }
        if (self.ref_name_owned) {
            if (self.ref_name) |value| gpa.free(value);
        }
        if (self.api_base_owned) {
            if (self.api_base) |value| gpa.free(value);
        }
        self.* = .{};
    }
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
    repo_owned: bool = false,
    ref_name_owned: bool = false,
    api_base_owned: bool = false,

    pub fn deinit(self: *ResolvedRefStoreConfig, gpa: Allocator) void {
        if (self.repo_owned) {
            if (self.repo) |value| gpa.free(value);
        }
        if (self.ref_name_owned) gpa.free(self.ref_name);
        if (self.api_base_owned) gpa.free(self.api_base);
        self.* = defaults.refstore;
    }
};

pub const ResolvedConfig = struct {
    refstore: ResolvedRefStoreConfig,

    pub fn deinit(self: *ResolvedConfig, gpa: Allocator) void {
        self.refstore.deinit(gpa);
    }
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

pub const ConfigRow = struct {
    key: []const u8,
    value: []const u8,

    pub fn deinit(self: ConfigRow, gpa: Allocator) void {
        gpa.free(self.key);
        gpa.free(self.value);
    }
};

pub const ParsedConfig = struct {
    value: Config,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedConfig, gpa: Allocator) void {
        self.value.deinit(gpa);
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

pub fn loadFile(gpa: Allocator, io: std.Io, path: []const u8) !ParsedConfig {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return parseToml(gpa, ""),
        else => return err,
    };
    defer gpa.free(bytes);
    return parseToml(gpa, bytes);
}

pub fn saveFile(gpa: Allocator, io: std.Io, path: []const u8, config: Config) !void {
    const bytes = try renderToml(gpa, config);
    defer gpa.free(bytes);

    const dirname = std.fs.path.dirname(path) orelse ".";
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dirname, .{});
    defer dir.close(io);

    const basename = std.fs.path.basename(path);
    var atomic_file = try dir.createFileAtomic(io, basename, .{
        .make_path = false,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic_file.replace(io);
}

pub fn loadLocal(gpa: Allocator, io: std.Io, repo_path: []const u8) !ParsedConfig {
    const path = try localConfigPath(gpa, repo_path);
    defer gpa.free(path);
    return loadFile(gpa, io, path);
}

pub fn loadGlobal(gpa: Allocator, io: std.Io, env: *const Environ.Map) !ParsedConfig {
    const path = try globalConfigPath(gpa, env);
    defer gpa.free(path);
    return loadFile(gpa, io, path);
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

fn parseRefStoreKind(value: []const u8) ?RefStoreKind {
    if (std.mem.eql(u8, value, "subprocess")) return .subprocess;
    if (std.mem.eql(u8, value, "github")) return .github;
    return null;
}

pub fn parseRefStoreKindPublic(value: []const u8) ?RefStoreKind {
    return parseRefStoreKind(value);
}

fn parseCredentialHelper(value: []const u8) ?CredentialHelper {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "env")) return .env;
    if (std.mem.eql(u8, value, "gh")) return .gh;
    if (std.mem.eql(u8, value, "git")) return .git;
    return null;
}

pub fn parseCredentialHelperPublic(value: []const u8) ?CredentialHelper {
    return parseCredentialHelper(value);
}

fn refStoreKindName(value: RefStoreKind) []const u8 {
    return switch (value) {
        .subprocess => "subprocess",
        .github => "github",
    };
}

fn credentialHelperName(value: CredentialHelper) []const u8 {
    return switch (value) {
        .auto => "auto",
        .env => "env",
        .gh => "gh",
        .git => "git",
    };
}

fn replaceOwnedString(gpa: Allocator, slot: *?[]const u8, owned: *bool, value: []const u8) Allocator.Error!void {
    const duplicate = try gpa.dupe(u8, value);
    if (owned.*) {
        if (slot.*) |old| gpa.free(old);
    }
    slot.* = duplicate;
    owned.* = true;
}

fn clearOwnedString(gpa: Allocator, slot: *?[]const u8, owned: *bool) void {
    if (owned.*) {
        if (slot.*) |old| gpa.free(old);
    }
    slot.* = null;
    owned.* = false;
}

pub fn setPath(gpa: Allocator, cfg: *Config, key: []const u8, value: []const u8) ConfigError!void {
    if (std.mem.eql(u8, key, "refstore.kind")) {
        cfg.refstore.kind = parseRefStoreKind(value) orelse return error.InvalidConfigValue;
    } else if (std.mem.eql(u8, key, "refstore.repo")) {
        try replaceOwnedString(gpa, &cfg.refstore.repo, &cfg.refstore.repo_owned, value);
    } else if (std.mem.eql(u8, key, "refstore.ref_name")) {
        try replaceOwnedString(gpa, &cfg.refstore.ref_name, &cfg.refstore.ref_name_owned, value);
    } else if (std.mem.eql(u8, key, "refstore.api_base")) {
        try replaceOwnedString(gpa, &cfg.refstore.api_base, &cfg.refstore.api_base_owned, value);
    } else if (std.mem.eql(u8, key, "refstore.credential_helper")) {
        cfg.refstore.credential_helper = parseCredentialHelper(value) orelse return error.InvalidConfigValue;
    } else {
        return error.UnknownConfigKey;
    }
}

pub fn getPath(gpa: Allocator, cfg: Config, key: []const u8) ConfigError!?[]const u8 {
    _ = gpa;
    if (std.mem.eql(u8, key, "refstore.kind")) return if (cfg.refstore.kind) |value| refStoreKindName(value) else null;
    if (std.mem.eql(u8, key, "refstore.repo")) return cfg.refstore.repo;
    if (std.mem.eql(u8, key, "refstore.ref_name")) return cfg.refstore.ref_name;
    if (std.mem.eql(u8, key, "refstore.api_base")) return cfg.refstore.api_base;
    if (std.mem.eql(u8, key, "refstore.credential_helper")) return if (cfg.refstore.credential_helper) |value| credentialHelperName(value) else null;
    return error.UnknownConfigKey;
}

pub fn unsetPath(gpa: Allocator, cfg: *Config, key: []const u8) ConfigError!void {
    if (std.mem.eql(u8, key, "refstore.kind")) {
        cfg.refstore.kind = null;
    } else if (std.mem.eql(u8, key, "refstore.repo")) {
        clearOwnedString(gpa, &cfg.refstore.repo, &cfg.refstore.repo_owned);
    } else if (std.mem.eql(u8, key, "refstore.ref_name")) {
        clearOwnedString(gpa, &cfg.refstore.ref_name, &cfg.refstore.ref_name_owned);
    } else if (std.mem.eql(u8, key, "refstore.api_base")) {
        clearOwnedString(gpa, &cfg.refstore.api_base, &cfg.refstore.api_base_owned);
    } else if (std.mem.eql(u8, key, "refstore.credential_helper")) {
        cfg.refstore.credential_helper = null;
    } else {
        return error.UnknownConfigKey;
    }
}

pub const ResolveInputs = struct {
    global: Config = .{},
    local: Config = .{},
    env: *const Environ.Map,
    cli_refstore: ?RefStoreKind = null,
    cli_repo: ?[]const u8 = null,
    cli_ref_name: ?[]const u8 = null,
    cli_api_base: ?[]const u8 = null,
    cli_credential_helper: ?CredentialHelper = null,
};

pub fn resolveLayers(gpa: Allocator, inputs: ResolveInputs) ConfigError!ResolvedConfig {
    var result = defaults;
    errdefer result.deinit(gpa);

    try applyConfigLayer(gpa, &result, inputs.global);
    try applyConfigLayer(gpa, &result, inputs.local);

    if (inputs.cli_refstore == null) {
        if (inputs.env.get("SIDESHOWDB_REFSTORE")) |value| result.refstore.kind = parseRefStoreKind(value) orelse return error.InvalidConfigValue;
    }
    if (inputs.cli_repo == null) {
        if (inputs.env.get("SIDESHOWDB_REPO")) |value| try setResolvedRepo(gpa, &result, value);
    }
    if (inputs.cli_ref_name == null) {
        if (inputs.env.get("SIDESHOWDB_REF")) |value| try setResolvedRefName(gpa, &result, value);
    }
    if (inputs.cli_api_base == null) {
        if (inputs.env.get("SIDESHOWDB_API_BASE")) |value| try setResolvedApiBase(gpa, &result, value);
    }
    if (inputs.cli_credential_helper == null) {
        if (inputs.env.get("SIDESHOWDB_CREDENTIAL_HELPER")) |value| result.refstore.credential_helper = parseCredentialHelper(value) orelse return error.InvalidConfigValue;
    }

    if (inputs.cli_refstore) |value| result.refstore.kind = value;
    if (inputs.cli_repo) |value| try setResolvedRepo(gpa, &result, value);
    if (inputs.cli_ref_name) |value| try setResolvedRefName(gpa, &result, value);
    if (inputs.cli_api_base) |value| try setResolvedApiBase(gpa, &result, value);
    if (inputs.cli_credential_helper) |value| result.refstore.credential_helper = value;

    return result;
}

fn applyConfigLayer(gpa: Allocator, result: *ResolvedConfig, layer: Config) Allocator.Error!void {
    if (layer.refstore.kind) |value| result.refstore.kind = value;
    if (layer.refstore.repo) |value| try setResolvedRepo(gpa, result, value);
    if (layer.refstore.ref_name) |value| try setResolvedRefName(gpa, result, value);
    if (layer.refstore.api_base) |value| try setResolvedApiBase(gpa, result, value);
    if (layer.refstore.credential_helper) |value| result.refstore.credential_helper = value;
}

fn setResolvedRepo(gpa: Allocator, resolved: *ResolvedConfig, value: []const u8) Allocator.Error!void {
    const duplicate = try gpa.dupe(u8, value);
    if (resolved.refstore.repo_owned) {
        if (resolved.refstore.repo) |old| gpa.free(old);
    }
    resolved.refstore.repo = duplicate;
    resolved.refstore.repo_owned = true;
}

fn setResolvedRefName(gpa: Allocator, resolved: *ResolvedConfig, value: []const u8) Allocator.Error!void {
    const duplicate = try gpa.dupe(u8, value);
    if (resolved.refstore.ref_name_owned) gpa.free(resolved.refstore.ref_name);
    resolved.refstore.ref_name = duplicate;
    resolved.refstore.ref_name_owned = true;
}

fn setResolvedApiBase(gpa: Allocator, resolved: *ResolvedConfig, value: []const u8) Allocator.Error!void {
    const duplicate = try gpa.dupe(u8, value);
    if (resolved.refstore.api_base_owned) gpa.free(resolved.refstore.api_base);
    resolved.refstore.api_base = duplicate;
    resolved.refstore.api_base_owned = true;
}

pub fn listFlattened(gpa: Allocator, cfg: Config) ConfigError![]ConfigRow {
    const keys = [_][]const u8{
        "refstore.api_base",
        "refstore.credential_helper",
        "refstore.kind",
        "refstore.ref_name",
        "refstore.repo",
    };
    var rows = std.ArrayList(ConfigRow).empty;
    errdefer {
        for (rows.items) |row| row.deinit(gpa);
        rows.deinit(gpa);
    }

    for (keys) |key| {
        if ((try getPath(gpa, cfg, key))) |value| {
            var key_copy: ?[]u8 = try gpa.dupe(u8, key);
            errdefer if (key_copy) |copy| gpa.free(copy);
            var value_copy: ?[]u8 = try gpa.dupe(u8, value);
            errdefer if (value_copy) |copy| gpa.free(copy);
            try rows.append(gpa, .{
                .key = key_copy.?,
                .value = value_copy.?,
            });
            key_copy = null;
            value_copy = null;
        }
    }

    return try rows.toOwnedSlice(gpa);
}

pub fn freeConfigRows(gpa: Allocator, rows: []ConfigRow) void {
    for (rows) |row| row.deinit(gpa);
    gpa.free(rows);
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

test "renderToml omits ownership marker fields" {
    const gpa = std.testing.allocator;
    var config: Config = .{};
    defer config.deinit(gpa);
    try setPath(gpa, &config, "refstore.repo", "owner/repo");

    const bytes = try renderToml(gpa, config);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "repo_owned") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "ref_name_owned") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "api_base_owned") == null);
}

test "saveFile writes parseable config atomically without leftover temp files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cfg" });
    defer gpa.free(config_dir);
    const config_path = try std.fs.path.join(gpa, &.{ config_dir, "config.toml" });
    defer gpa.free(config_path);

    try saveFile(gpa, io, config_path, .{
        .refstore = .{
            .kind = .github,
            .repo = "owner/repo",
            .credential_helper = .env,
        },
    });

    var parsed = try loadFile(gpa, io, config_path);
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(RefStoreKind.github, parsed.value.refstore.kind.?);
    try std.testing.expectEqualStrings("owner/repo", parsed.value.refstore.repo.?);
    try std.testing.expectEqual(CredentialHelper.env, parsed.value.refstore.credential_helper.?);

    var dir = try std.Io.Dir.cwd().openDir(io, config_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var entries: usize = 0;
    while (try it.next(io)) |entry| {
        entries += 1;
        try std.testing.expectEqualStrings("config.toml", entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), entries);
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

test "parseToml rejects ownership marker fields" {
    try expectParseFailure(
        \\[refstore]
        \\repo_owned = true
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

test "loadFile rejects config files over max_file_bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "oversized.toml" });
    defer gpa.free(path);

    const bytes = try gpa.alloc(u8, max_file_bytes + 1);
    defer gpa.free(bytes);
    @memset(bytes, '#');
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
    });

    try std.testing.expectError(error.StreamTooLong, loadFile(gpa, io, path));
}

test "setPath getPath unsetPath operate on supported keys" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(gpa);

    try setPath(gpa, &cfg, "refstore.kind", "github");
    try setPath(gpa, &cfg, "refstore.repo", "owner/repo");
    try setPath(gpa, &cfg, "refstore.ref_name", "refs/sideshowdb/demo");
    try setPath(gpa, &cfg, "refstore.api_base", "https://api.github.com");
    try setPath(gpa, &cfg, "refstore.credential_helper", "git");

    try std.testing.expectEqualStrings("github", (try getPath(gpa, cfg, "refstore.kind")).?);
    try std.testing.expectEqualStrings("owner/repo", (try getPath(gpa, cfg, "refstore.repo")).?);
    try std.testing.expectEqualStrings("refs/sideshowdb/demo", (try getPath(gpa, cfg, "refstore.ref_name")).?);
    try std.testing.expectEqualStrings("https://api.github.com", (try getPath(gpa, cfg, "refstore.api_base")).?);
    try std.testing.expectEqualStrings("git", (try getPath(gpa, cfg, "refstore.credential_helper")).?);

    try unsetPath(gpa, &cfg, "refstore.kind");
    try unsetPath(gpa, &cfg, "refstore.repo");
    try unsetPath(gpa, &cfg, "refstore.ref_name");
    try unsetPath(gpa, &cfg, "refstore.api_base");
    try unsetPath(gpa, &cfg, "refstore.credential_helper");

    try std.testing.expectEqual(@as(?[]const u8, null), try getPath(gpa, cfg, "refstore.kind"));
    try std.testing.expectEqual(@as(?[]const u8, null), try getPath(gpa, cfg, "refstore.repo"));
    try std.testing.expectEqual(@as(?[]const u8, null), try getPath(gpa, cfg, "refstore.ref_name"));
    try std.testing.expectEqual(@as(?[]const u8, null), try getPath(gpa, cfg, "refstore.api_base"));
    try std.testing.expectEqual(@as(?[]const u8, null), try getPath(gpa, cfg, "refstore.credential_helper"));
}

test "setPath frees repeated owned string overwrites" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(gpa);

    try setPath(gpa, &cfg, "refstore.repo", "owner/one");
    try setPath(gpa, &cfg, "refstore.repo", "owner/two");
    try setPath(gpa, &cfg, "refstore.ref_name", "refs/sideshowdb/one");
    try setPath(gpa, &cfg, "refstore.ref_name", "refs/sideshowdb/two");
    try setPath(gpa, &cfg, "refstore.api_base", "https://one.example/api");
    try setPath(gpa, &cfg, "refstore.api_base", "https://two.example/api");

    try std.testing.expectEqualStrings("owner/two", cfg.refstore.repo.?);
    try std.testing.expectEqualStrings("refs/sideshowdb/two", cfg.refstore.ref_name.?);
    try std.testing.expectEqualStrings("https://two.example/api", cfg.refstore.api_base.?);
}

test "setPath rejects unknown keys and invalid values" {
    var cfg: Config = .{};
    try std.testing.expectError(error.UnknownConfigKey, setPath(std.testing.allocator, &cfg, "github.token", "secret"));
    try std.testing.expectError(error.InvalidConfigValue, setPath(std.testing.allocator, &cfg, "refstore.kind", "banana"));
    try std.testing.expectError(error.InvalidConfigValue, setPath(std.testing.allocator, &cfg, "refstore.credential_helper", "keychain"));
}

test "getPath and unsetPath reject unknown keys" {
    var cfg: Config = .{};
    try std.testing.expectError(error.UnknownConfigKey, getPath(std.testing.allocator, cfg, "github.token"));
    try std.testing.expectError(error.UnknownConfigKey, unsetPath(std.testing.allocator, &cfg, "github.token"));
}

test "public parse wrappers accept known values and reject unknown values" {
    try std.testing.expectEqual(RefStoreKind.subprocess, parseRefStoreKindPublic("subprocess").?);
    try std.testing.expectEqual(RefStoreKind.github, parseRefStoreKindPublic("github").?);
    try std.testing.expectEqual(@as(?RefStoreKind, null), parseRefStoreKindPublic("banana"));

    try std.testing.expectEqual(CredentialHelper.auto, parseCredentialHelperPublic("auto").?);
    try std.testing.expectEqual(CredentialHelper.env, parseCredentialHelperPublic("env").?);
    try std.testing.expectEqual(CredentialHelper.gh, parseCredentialHelperPublic("gh").?);
    try std.testing.expectEqual(CredentialHelper.git, parseCredentialHelperPublic("git").?);
    try std.testing.expectEqual(@as(?CredentialHelper, null), parseCredentialHelperPublic("keychain"));
}

test "setPath and unsetPath preserve parsed config ownership" {
    const gpa = std.testing.allocator;
    const source =
        \\[refstore]
        \\repo = "parsed/repo"
        \\ref_name = "refs/sideshowdb/parsed"
        \\api_base = "https://parsed.example/api"
        \\
    ;

    var parsed = try parseToml(gpa, source);
    defer parsed.deinit(gpa);
    defer parsed.value.deinit(gpa);

    try setPath(gpa, &parsed.value, "refstore.repo", "owned/repo");
    try std.testing.expectEqualStrings("owned/repo", parsed.value.refstore.repo.?);

    try unsetPath(gpa, &parsed.value, "refstore.repo");
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.refstore.repo);

    try setPath(gpa, &parsed.value, "refstore.ref_name", "refs/sideshowdb/owned");
    try std.testing.expectEqualStrings("refs/sideshowdb/owned", parsed.value.refstore.ref_name.?);
    try std.testing.expectEqualStrings("https://parsed.example/api", parsed.value.refstore.api_base.?);
}

test "ParsedConfig deinit frees setPath owned replacements" {
    const gpa = std.testing.allocator;
    const source =
        \\[refstore]
        \\repo = "parsed/repo"
        \\
    ;

    var parsed = try parseToml(gpa, source);
    defer parsed.deinit(gpa);

    try setPath(gpa, &parsed.value, "refstore.repo", "owned/repo");
    try setPath(gpa, &parsed.value, "refstore.ref_name", "refs/sideshowdb/owned");
    try setPath(gpa, &parsed.value, "refstore.api_base", "https://owned.example/api");
}

test "resolveLayers applies global local env and cli precedence" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const global: Config = .{ .refstore = .{
        .kind = .github,
        .repo = "global/repo",
        .ref_name = "refs/sideshowdb/global",
        .api_base = "https://global.example/api",
        .credential_helper = .gh,
    } };
    const local: Config = .{ .refstore = .{
        .kind = .subprocess,
        .repo = "local/repo",
        .ref_name = "refs/sideshowdb/local",
        .api_base = "https://local.example/api",
        .credential_helper = .git,
    } };

    var resolved = try resolveLayers(gpa, .{
        .global = global,
        .local = local,
        .env = &env,
    });
    defer resolved.deinit(gpa);
    try std.testing.expectEqual(RefStoreKind.subprocess, resolved.refstore.kind);
    try std.testing.expectEqualStrings("local/repo", resolved.refstore.repo.?);
    try std.testing.expectEqualStrings("refs/sideshowdb/local", resolved.refstore.ref_name);
    try std.testing.expectEqualStrings("https://local.example/api", resolved.refstore.api_base);
    try std.testing.expectEqual(CredentialHelper.git, resolved.refstore.credential_helper);

    try env.put("SIDESHOWDB_REFSTORE", "github");
    try env.put("SIDESHOWDB_REPO", "env/repo");
    try env.put("SIDESHOWDB_REF", "refs/sideshowdb/env");
    try env.put("SIDESHOWDB_API_BASE", "https://env.example/api");
    try env.put("SIDESHOWDB_CREDENTIAL_HELPER", "env");
    resolved.deinit(gpa);
    resolved = try resolveLayers(gpa, .{
        .global = global,
        .local = local,
        .env = &env,
    });
    try std.testing.expectEqual(RefStoreKind.github, resolved.refstore.kind);
    try std.testing.expectEqualStrings("env/repo", resolved.refstore.repo.?);
    try std.testing.expectEqualStrings("refs/sideshowdb/env", resolved.refstore.ref_name);
    try std.testing.expectEqualStrings("https://env.example/api", resolved.refstore.api_base);
    try std.testing.expectEqual(CredentialHelper.env, resolved.refstore.credential_helper);

    resolved.deinit(gpa);
    resolved = try resolveLayers(gpa, .{
        .global = global,
        .local = local,
        .env = &env,
        .cli_refstore = .subprocess,
        .cli_repo = "cli/repo",
    });
    try std.testing.expectEqual(RefStoreKind.subprocess, resolved.refstore.kind);
    try std.testing.expectEqualStrings("cli/repo", resolved.refstore.repo.?);
}

test "resolveLayers owned result survives source cleanup" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_REPO", "env/repo");

    var local: Config = .{};
    defer local.deinit(gpa);
    try setPath(gpa, &local, "refstore.ref_name", "refs/sideshowdb/local");

    var resolved = try resolveLayers(gpa, .{
        .local = local,
        .env = &env,
        .cli_api_base = "https://cli.example/api",
    });
    defer resolved.deinit(gpa);

    env.deinit();
    env = std.process.Environ.Map.init(gpa);
    local.deinit(gpa);

    try std.testing.expectEqualStrings("env/repo", resolved.refstore.repo.?);
    try std.testing.expectEqualStrings("refs/sideshowdb/local", resolved.refstore.ref_name);
    try std.testing.expectEqualStrings("https://cli.example/api", resolved.refstore.api_base);
}

test "resolveLayers rejects invalid env refstore value" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_REFSTORE", "banana");

    try std.testing.expectError(error.InvalidConfigValue, resolveLayers(gpa, .{ .env = &env }));
}

test "resolveLayers skips lower precedence invalid env values when cli key is present" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_REFSTORE", "banana");
    try env.put("SIDESHOWDB_REPO", "env/repo");
    try env.put("SIDESHOWDB_REF", "refs/sideshowdb/env");
    try env.put("SIDESHOWDB_API_BASE", "https://env.example/api");
    try env.put("SIDESHOWDB_CREDENTIAL_HELPER", "keychain");

    var resolved = try resolveLayers(gpa, .{
        .env = &env,
        .cli_refstore = .subprocess,
        .cli_repo = "cli/repo",
        .cli_ref_name = "refs/sideshowdb/cli",
        .cli_api_base = "https://cli.example/api",
        .cli_credential_helper = .env,
    });
    defer resolved.deinit(gpa);

    try std.testing.expectEqual(RefStoreKind.subprocess, resolved.refstore.kind);
    try std.testing.expectEqualStrings("cli/repo", resolved.refstore.repo.?);
    try std.testing.expectEqualStrings("refs/sideshowdb/cli", resolved.refstore.ref_name);
    try std.testing.expectEqualStrings("https://cli.example/api", resolved.refstore.api_base);
    try std.testing.expectEqual(CredentialHelper.env, resolved.refstore.credential_helper);
}

test "resolveLayers rejects invalid env credential helper value" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_CREDENTIAL_HELPER", "keychain");

    try std.testing.expectError(error.InvalidConfigValue, resolveLayers(gpa, .{ .env = &env }));
}

test "listFlattened returns sorted supported keys with string values" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(gpa);
    try setPath(gpa, &cfg, "refstore.kind", "github");
    try setPath(gpa, &cfg, "refstore.repo", "owner/repo");
    try setPath(gpa, &cfg, "refstore.credential_helper", "env");

    const rows = try listFlattened(gpa, cfg);
    defer freeConfigRows(gpa, rows);

    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("refstore.credential_helper", rows[0].key);
    try std.testing.expectEqualStrings("env", rows[0].value);
    try std.testing.expectEqualStrings("refstore.kind", rows[1].key);
    try std.testing.expectEqualStrings("github", rows[1].value);
    try std.testing.expectEqualStrings("refstore.repo", rows[2].key);
    try std.testing.expectEqualStrings("owner/repo", rows[2].value);
}
