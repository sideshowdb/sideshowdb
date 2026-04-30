//! Read/write/delete the SideshowDB CLI per-host credential store.
//!
//! Storage path: `<config_dir>/sideshowdb/hosts.toml` where `config_dir`
//! comes from `XDG_CONFIG_HOME` or falls back to `<home>/.config`.
//! The file is written with mode 0600; the parent directory is created
//! with mode 0700 if missing. Existing files with permissive modes are
//! tightened on every write.
//!
//! On-disk format is a minimal subset of TOML:
//!
//!     [hosts."github.com"]
//!     oauth_token = "ghp_..."
//!     user        = "octocat"
//!     git_protocol = "https"
//!
//! Only `oauth_token` is required.
//!
//! All filesystem ops go through libc (`std.c.*`) so the module compiles
//! against the Zig 0.16 stdlib without needing the new `std.Io.Dir`
//! plumbing wired through every caller.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = std.c;

const StatError = error{ FileNotFound, OtherError };

/// OS-aware path stat. Returns the file's `mode_t` on success.
/// Linux uses `statx`; Darwin/BSD use `fstatat`.
pub fn statPathMode(path_z: [*:0]const u8) StatError!c.mode_t {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx_buf: linux.Statx = undefined;
        switch (linux.errno(linux.statx(
            linux.AT.FDCWD,
            path_z,
            0,
            .{ .MODE = true },
            &statx_buf,
        ))) {
            .SUCCESS => return @intCast(statx_buf.mode),
            .NOENT => return error.FileNotFound,
            else => return error.OtherError,
        }
    }
    var stat_buf: c.Stat = undefined;
    const rc = c.fstatat(c.AT.FDCWD, path_z, &stat_buf, 0);
    if (rc == 0) return stat_buf.mode;
    switch (c.errno(rc)) {
        .NOENT => return error.FileNotFound,
        else => return error.OtherError,
    }
}

pub const file_basename = "hosts.toml";
pub const dir_basename = "sideshowdb";
pub const file_mode: c.mode_t = 0o600;
pub const dir_mode: c.mode_t = 0o700;
pub const max_file_bytes: usize = 1 * 1024 * 1024;

pub const HostEntry = struct {
    host: []const u8,
    oauth_token: []const u8,
    user: ?[]const u8 = null,
    git_protocol: ?[]const u8 = null,
};

pub const HostsFile = struct {
    entries: []HostEntry,

    pub fn deinit(self: *HostsFile, gpa: Allocator) void {
        for (self.entries) |entry| {
            gpa.free(entry.host);
            gpa.free(entry.oauth_token);
            if (entry.user) |u| gpa.free(u);
            if (entry.git_protocol) |g| gpa.free(g);
        }
        if (self.entries.len != 0) gpa.free(self.entries);
        self.entries = &.{};
    }

    pub fn find(self: HostsFile, host: []const u8) ?*const HostEntry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.host, host)) return entry;
        }
        return null;
    }
};

pub const ReadError = error{
    PermissionsTooOpen,
    Malformed,
    OutOfMemory,
    ReadFailed,
};

pub const WriteError = error{
    OutOfMemory,
    WriteFailed,
};

pub fn resolveConfigDir(
    gpa: Allocator,
    env: *const std.process.Environ.Map,
) ![]u8 {
    if (env.get("SIDESHOWDB_CONFIG_DIR")) |override| {
        return try gpa.dupe(u8, override);
    }
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len != 0) {
            return try std.fs.path.join(gpa, &.{ xdg, dir_basename });
        }
    }
    const home = env.get("HOME") orelse return error.NoHomeDir;
    return try std.fs.path.join(gpa, &.{ home, ".config", dir_basename });
}

pub fn resolveHostsPath(
    gpa: Allocator,
    env: *const std.process.Environ.Map,
) ![]u8 {
    const config_dir = try resolveConfigDir(gpa, env);
    defer gpa.free(config_dir);
    return try std.fs.path.join(gpa, &.{ config_dir, file_basename });
}

pub fn read(gpa: Allocator, path: []const u8) ReadError!HostsFile {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    const mode = statPathMode(path_z.ptr) catch |err| switch (err) {
        error.FileNotFound => return .{ .entries = &.{} },
        error.OtherError => return error.ReadFailed,
    };
    if (builtin.os.tag != .windows) {
        const masked = mode & 0o777;
        if ((masked & 0o077) != 0) return error.PermissionsTooOpen;
    }

    const fd = c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return error.ReadFailed;
    defer _ = c.close(fd);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        const m: usize = @intCast(n);
        if (bytes.items.len + m > max_file_bytes) return error.ReadFailed;
        try bytes.appendSlice(gpa, buf[0..m]);
    }
    const owned = try bytes.toOwnedSlice(gpa);
    defer gpa.free(owned);
    return parse(gpa, owned);
}

pub fn parse(gpa: Allocator, bytes: []const u8) ReadError!HostsFile {
    var entries: std.ArrayList(HostEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            gpa.free(entry.host);
            gpa.free(entry.oauth_token);
            if (entry.user) |u| gpa.free(u);
            if (entry.git_protocol) |g| gpa.free(g);
        }
        entries.deinit(gpa);
    }

    var current_host: ?[]const u8 = null;
    var current_token: ?[]const u8 = null;
    var current_user: ?[]const u8 = null;
    var current_proto: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            try flushCurrent(gpa, &entries, &current_host, &current_token, &current_user, &current_proto);
            current_host = parseHostHeader(line) orelse return error.Malformed;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Malformed;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (raw_value.len < 2 or raw_value[0] != '"' or raw_value[raw_value.len - 1] != '"') return error.Malformed;
        const value = raw_value[1 .. raw_value.len - 1];

        if (current_host == null) return error.Malformed;
        if (std.mem.eql(u8, key, "oauth_token")) {
            current_token = value;
        } else if (std.mem.eql(u8, key, "user")) {
            current_user = value;
        } else if (std.mem.eql(u8, key, "git_protocol")) {
            current_proto = value;
        }
    }

    try flushCurrent(gpa, &entries, &current_host, &current_token, &current_user, &current_proto);

    return .{ .entries = try entries.toOwnedSlice(gpa) };
}

fn flushCurrent(
    gpa: Allocator,
    entries: *std.ArrayList(HostEntry),
    host: *?[]const u8,
    token: *?[]const u8,
    user: *?[]const u8,
    proto: *?[]const u8,
) ReadError!void {
    const h = host.* orelse return;
    if (token.*) |t| {
        try entries.append(gpa, .{
            .host = try gpa.dupe(u8, h),
            .oauth_token = try gpa.dupe(u8, t),
            .user = if (user.*) |u| try gpa.dupe(u8, u) else null,
            .git_protocol = if (proto.*) |p| try gpa.dupe(u8, p) else null,
        });
    }
    host.* = null;
    token.* = null;
    user.* = null;
    proto.* = null;
}

fn parseHostHeader(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[line.len - 1] != ']') return null;
    const inner = line[1 .. line.len - 1];
    const prefix = "hosts.";
    if (!std.mem.startsWith(u8, inner, prefix)) return null;
    const quoted = inner[prefix.len..];
    if (quoted.len < 2 or quoted[0] != '"' or quoted[quoted.len - 1] != '"') return null;
    const host = quoted[1 .. quoted.len - 1];
    if (host.len == 0) return null;
    return host;
}

pub fn render(gpa: Allocator, file: HostsFile) WriteError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    for (file.entries, 0..) |entry, i| {
        if (i != 0) try out.append(gpa, '\n');
        const header = std.fmt.allocPrint(gpa, "[hosts.\"{s}\"]\n", .{entry.host}) catch return error.OutOfMemory;
        defer gpa.free(header);
        try out.appendSlice(gpa, header);

        const tline = std.fmt.allocPrint(gpa, "oauth_token = \"{s}\"\n", .{entry.oauth_token}) catch return error.OutOfMemory;
        defer gpa.free(tline);
        try out.appendSlice(gpa, tline);

        if (entry.user) |u| {
            const uline = std.fmt.allocPrint(gpa, "user = \"{s}\"\n", .{u}) catch return error.OutOfMemory;
            defer gpa.free(uline);
            try out.appendSlice(gpa, uline);
        }
        if (entry.git_protocol) |p| {
            const pline = std.fmt.allocPrint(gpa, "git_protocol = \"{s}\"\n", .{p}) catch return error.OutOfMemory;
            defer gpa.free(pline);
            try out.appendSlice(gpa, pline);
        }
    }
    return try out.toOwnedSlice(gpa);
}

pub fn writeAtomic(
    gpa: Allocator,
    config_dir: []const u8,
    path: []const u8,
    bytes: []const u8,
) WriteError!void {
    const dir_z = gpa.dupeZ(u8, config_dir) catch return error.OutOfMemory;
    defer gpa.free(dir_z);
    const path_z = gpa.dupeZ(u8, path) catch return error.OutOfMemory;
    defer gpa.free(path_z);

    const mkdir_rc = c.mkdir(dir_z.ptr, dir_mode);
    if (mkdir_rc != 0) {
        switch (c.errno(mkdir_rc)) {
            .EXIST => {},
            else => return error.WriteFailed,
        }
    }
    if (builtin.os.tag != .windows) {
        _ = c.chmod(dir_z.ptr, dir_mode);
    }

    const tmp_path = std.fmt.allocPrint(gpa, "{s}.tmp", .{path}) catch return error.OutOfMemory;
    defer gpa.free(tmp_path);
    const tmp_path_z = gpa.dupeZ(u8, tmp_path) catch return error.OutOfMemory;
    defer gpa.free(tmp_path_z);

    const fd = c.open(tmp_path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, file_mode);
    if (fd < 0) return error.WriteFailed;
    var close_done = false;
    defer if (!close_done) {
        _ = c.close(fd);
    };

    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(fd, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
    if (c.fsync(fd) != 0) return error.WriteFailed;
    _ = c.close(fd);
    close_done = true;

    if (builtin.os.tag != .windows) {
        if (c.chmod(tmp_path_z.ptr, file_mode) != 0) return error.WriteFailed;
    }
    if (c.rename(tmp_path_z.ptr, path_z.ptr) != 0) return error.WriteFailed;
    if (builtin.os.tag != .windows) {
        _ = c.chmod(path_z.ptr, file_mode);
    }
}

pub fn removeHost(
    gpa: Allocator,
    config_dir: []const u8,
    path: []const u8,
    host: []const u8,
) !bool {
    var file = try read(gpa, path);
    defer file.deinit(gpa);

    var kept: std.ArrayList(HostEntry) = .empty;
    defer kept.deinit(gpa);

    var found = false;
    for (file.entries) |entry| {
        if (std.mem.eql(u8, entry.host, host)) {
            found = true;
            continue;
        }
        try kept.append(gpa, entry);
    }
    if (!found) return false;

    if (kept.items.len == 0) {
        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);
        const unlink_rc = c.unlink(path_z.ptr);
        if (unlink_rc != 0) {
            switch (c.errno(unlink_rc)) {
                .NOENT => {},
                else => return error.WriteFailed,
            }
        }
        return true;
    }

    const next_file: HostsFile = .{ .entries = kept.items };
    const rendered = try render(gpa, next_file);
    defer gpa.free(rendered);
    try writeAtomic(gpa, config_dir, path, rendered);
    return true;
}

pub fn upsertHost(
    gpa: Allocator,
    config_dir: []const u8,
    path: []const u8,
    entry: HostEntry,
) !void {
    var file = try read(gpa, path);
    defer file.deinit(gpa);

    var merged: std.ArrayList(HostEntry) = .empty;
    defer merged.deinit(gpa);

    var inserted = false;
    for (file.entries) |existing| {
        if (std.mem.eql(u8, existing.host, entry.host)) {
            try merged.append(gpa, entry);
            inserted = true;
            continue;
        }
        try merged.append(gpa, existing);
    }
    if (!inserted) try merged.append(gpa, entry);

    const next_file: HostsFile = .{ .entries = merged.items };
    const rendered = try render(gpa, next_file);
    defer gpa.free(rendered);
    try writeAtomic(gpa, config_dir, path, rendered);
}

test "parse returns empty on empty bytes" {
    var file = try parse(std.testing.allocator, "");
    defer file.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), file.entries.len);
}

test "parse extracts oauth_token and user" {
    const sample =
        \\[hosts."github.com"]
        \\oauth_token = "ghp_abc"
        \\user = "octocat"
        \\git_protocol = "https"
        \\
    ;
    var file = try parse(std.testing.allocator, sample);
    defer file.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), file.entries.len);
    try std.testing.expectEqualStrings("github.com", file.entries[0].host);
    try std.testing.expectEqualStrings("ghp_abc", file.entries[0].oauth_token);
    try std.testing.expectEqualStrings("octocat", file.entries[0].user.?);
    try std.testing.expectEqualStrings("https", file.entries[0].git_protocol.?);
}

test "parse rejects malformed body" {
    const broken = "[hosts.\"github.com\"]\noauth_token unquoted\n";
    try std.testing.expectError(error.Malformed, parse(std.testing.allocator, broken));
}

test "render round-trips through parse" {
    const gpa = std.testing.allocator;
    const original: HostsFile = .{ .entries = @constCast(&[_]HostEntry{
        .{ .host = "github.com", .oauth_token = "ghp_abc", .user = "octocat", .git_protocol = "https" },
        .{ .host = "ghe.example.com", .oauth_token = "ghe_xyz" },
    }) };
    const rendered = try render(gpa, original);
    defer gpa.free(rendered);

    var parsed = try parse(gpa, rendered);
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), parsed.entries.len);
    try std.testing.expectEqualStrings("ghp_abc", parsed.entries[0].oauth_token);
    try std.testing.expectEqualStrings("ghe_xyz", parsed.entries[1].oauth_token);
}
