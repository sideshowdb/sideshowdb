//! CLI backend selector for the document `RefStore`.
//!
//! Provides the `RefStoreBackend` enum, its parsing/precedence resolution,
//! and the `Selection` record that records which source ultimately picked
//! the backend (flag, environment, config, or built-in default).

const std = @import("std");

/// Concrete `RefStore` backends selectable from the CLI.
pub const RefStoreBackend = enum {
    /// Subprocess-driven git-backed refstore (native backend).
    subprocess,

    /// Parse a backend name. Returns `null` if `value` is not a known
    /// backend identifier.
    pub fn parse(value: []const u8) ?RefStoreBackend {
        if (std.mem.eql(u8, value, "subprocess")) return .subprocess;
        return null;
    }
};

/// Records which selection layer produced the resolved backend.
pub const SelectionSource = enum {
    /// Built-in default (`subprocess`).
    default,
    /// Loaded from `.sideshowdb/config.toml`.
    config,
    /// Read from the `SIDESHOWDB_REFSTORE` environment variable.
    environment,
    /// Supplied via the `--refstore` command-line flag.
    flag,
};

/// Resolved backend selection plus the layer it came from.
pub const Selection = struct {
    backend: RefStoreBackend,
    source: SelectionSource,
};

/// Errors returned when reading or parsing a backend selector.
pub const ResolveError = error{
    /// A selector named an unknown backend.
    InvalidRefStore,
    /// `.sideshowdb/config.toml` is malformed (missing `=`, unquoted
    /// value, or a value that is otherwise unparseable).
    InvalidRefStoreConfig,
    /// Reading the config file failed for an I/O reason other than
    /// "file not found" (which is treated as "no config").
    ConfigReadFailed,
    OutOfMemory,
};

/// Read `SIDESHOWDB_REFSTORE` from `env`. Returns null if the variable is
/// unset; returns `error.InvalidRefStore` if it is set to an unknown
/// backend name.
pub fn fromEnvironment(env: *const std.process.Environ.Map) ResolveError!?Selection {
    const value = env.get("SIDESHOWDB_REFSTORE") orelse return null;
    const backend = RefStoreBackend.parse(value) orelse return error.InvalidRefStore;
    return .{ .backend = backend, .source = .environment };
}

/// Read `.sideshowdb/config.toml` under `repo_path` and return the
/// `[storage] refstore = "..."` selection if present. Returns null if the
/// file is missing or has no `[storage]` table.
///
/// This parser intentionally supports a single documented case: a
/// `[storage]` table with a quoted `refstore` value. Any other shape
/// returns `error.InvalidRefStoreConfig`.
pub fn fromConfig(gpa: std.mem.Allocator, repo_path: []const u8) ResolveError!?Selection {
    const path = try std.fs.path.join(gpa, &.{ repo_path, ".sideshowdb", "config.toml" });
    defer gpa.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        gpa,
        .limited(16 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigReadFailed,
    };
    defer gpa.free(bytes);

    var in_storage = false;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[storage]")) {
            in_storage = true;
            continue;
        }
        if (line[0] == '[') {
            in_storage = false;
            continue;
        }
        if (!in_storage) continue;
        if (std.mem.startsWith(u8, line, "refstore")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidRefStoreConfig;
            const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (raw_value.len < 2 or raw_value[0] != '"' or raw_value[raw_value.len - 1] != '"') {
                return error.InvalidRefStoreConfig;
            }
            const value = raw_value[1 .. raw_value.len - 1];
            const backend = RefStoreBackend.parse(value) orelse return error.InvalidRefStore;
            return .{ .backend = backend, .source = .config };
        }
    }
    return null;
}

/// Resolve the active backend selection given precedence: explicit flag,
/// `SIDESHOWDB_REFSTORE`, repo-local `.sideshowdb/config.toml`, then the
/// built-in default (`subprocess`).
pub fn resolve(
    gpa: std.mem.Allocator,
    repo_path: []const u8,
    env: *const std.process.Environ.Map,
    flag_backend: ?RefStoreBackend,
) ResolveError!Selection {
    if (flag_backend) |backend| return .{ .backend = backend, .source = .flag };
    if (try fromEnvironment(env)) |selection| return selection;
    if (try fromConfig(gpa, repo_path)) |selection| return selection;
    return .{ .backend = .subprocess, .source = .default };
}
