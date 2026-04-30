//! `sideshowdb auth ...` command handlers.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const c = std.c;

const hosts_file = @import("hosts_file.zig");
const redact = @import("redact.zig");
const secure_prompt = @import("secure_prompt.zig");

const RunResult = @import("../app.zig").RunResult;

pub const github_host = "github.com";

pub const StatusOptions = struct {
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    json: bool,
};

pub const LogoutOptions = struct {
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    json: bool,
    host: ?[]const u8 = null,
};

pub const GhLoginOptions = struct {
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    json: bool,
    with_token: bool,
    skip_verify: bool,
    stdin_data: []const u8,
    /// Optional override for the secure prompt backend (test seam).
    prompt_backend: ?secure_prompt.Backend = null,
    /// Optional override for the verify hook (test seam). When unset and
    /// `skip_verify` is false, the handler treats verification as a
    /// best-effort no-op and persists the token without an upstream
    /// confirmation.
    verify_hook: ?VerifyHook = null,
};

pub const VerifyResult = struct {
    ok: bool,
    user: ?[]u8 = null,
    status_code: ?u16 = null,

    pub fn deinit(self: *VerifyResult, gpa: Allocator) void {
        if (self.user) |u| gpa.free(u);
        self.* = .{ .ok = false };
    }
};

pub const VerifyHook = struct {
    ctx: *anyopaque,
    fn_ptr: *const fn (ctx: *anyopaque, gpa: Allocator, token: []const u8) anyerror!VerifyResult,
};

pub fn runAuthStatus(opts: StatusOptions) !RunResult {
    const path = hosts_file.resolveHostsPath(opts.gpa, opts.env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(opts.gpa, "no $HOME or $XDG_CONFIG_HOME for hosts file lookup\n"),
    };
    defer opts.gpa.free(path);

    const perm_warning = checkPermissions(opts.gpa, path) catch null;

    var file = hosts_file.read(opts.gpa, path) catch |err| switch (err) {
        error.PermissionsTooOpen => {
            const msg = "warning: hosts.toml is world- or group-readable\n";
            return RunResult{
                .exit_code = 0,
                .stdout = try opts.gpa.dupe(u8, "No authenticated hosts.\n"),
                .stderr = try opts.gpa.dupe(u8, msg),
            };
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(opts.gpa, "failed to read hosts.toml\n"),
    };
    defer file.deinit(opts.gpa);

    if (file.entries.len == 0) {
        return successWithStderr(
            try opts.gpa.dupe(u8, "No authenticated hosts.\n"),
            if (perm_warning) |w| try opts.gpa.dupe(u8, w) else try opts.gpa.dupe(u8, ""),
        );
    }

    const stdout = if (opts.json)
        try renderStatusJson(opts.gpa, file.entries)
    else
        try renderStatusPlain(opts.gpa, file.entries);

    return successWithStderr(
        stdout,
        if (perm_warning) |w| try opts.gpa.dupe(u8, w) else try opts.gpa.dupe(u8, ""),
    );
}

pub fn runAuthLogout(opts: LogoutOptions) !RunResult {
    const config_dir = hosts_file.resolveConfigDir(opts.gpa, opts.env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(opts.gpa, "no $HOME or $XDG_CONFIG_HOME for hosts file lookup\n"),
    };
    defer opts.gpa.free(config_dir);
    const path = try std.fs.path.join(opts.gpa, &.{ config_dir, hosts_file.file_basename });
    defer opts.gpa.free(path);

    if (opts.host) |host| {
        const removed = hosts_file.removeHost(opts.gpa, config_dir, path, host) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return failure(opts.gpa, "failed to update hosts.toml\n"),
        };
        if (!removed) {
            const msg = try std.fmt.allocPrint(opts.gpa, "not logged in to {s}\n", .{host});
            defer opts.gpa.free(msg);
            return failure(opts.gpa, msg);
        }
        const ok = try std.fmt.allocPrint(opts.gpa, "Logged out of {s}.\n", .{host});
        return success(opts.gpa, ok);
    }

    var file = hosts_file.read(opts.gpa, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(opts.gpa, "failed to read hosts.toml\n"),
    };
    defer file.deinit(opts.gpa);

    if (file.entries.len == 0) {
        return failure(opts.gpa, "not logged in to any host\n");
    }

    var collected_hosts: std.ArrayList([]u8) = .empty;
    defer {
        for (collected_hosts.items) |h| opts.gpa.free(h);
        collected_hosts.deinit(opts.gpa);
    }
    for (file.entries) |entry| {
        try collected_hosts.append(opts.gpa, try opts.gpa.dupe(u8, entry.host));
    }

    var any_failure = false;
    for (collected_hosts.items) |h| {
        _ = hosts_file.removeHost(opts.gpa, config_dir, path, h) catch {
            any_failure = true;
        };
    }
    if (any_failure) return failure(opts.gpa, "failed to update hosts.toml\n");
    return success(opts.gpa, try opts.gpa.dupe(u8, "Logged out of all hosts.\n"));
}

pub fn runGhAuthStatus(opts: StatusOptions) !RunResult {
    const path = hosts_file.resolveHostsPath(opts.gpa, opts.env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(opts.gpa, "no $HOME or $XDG_CONFIG_HOME for hosts file lookup\n"),
    };
    defer opts.gpa.free(path);

    var file = hosts_file.read(opts.gpa, path) catch |err| switch (err) {
        error.PermissionsTooOpen => return failure(opts.gpa, "hosts.toml has permissive mode bits; refusing to read\n"),
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(opts.gpa, "failed to read hosts.toml\n"),
    };
    defer file.deinit(opts.gpa);

    const entry = file.find(github_host) orelse {
        return failure(opts.gpa, "Not logged in to github.com.\n");
    };
    const filtered = [_]hosts_file.HostEntry{entry.*};
    const stdout = if (opts.json)
        try renderStatusJson(opts.gpa, &filtered)
    else
        try renderStatusPlain(opts.gpa, &filtered);
    return success(opts.gpa, stdout);
}

pub fn runGhAuthLogout(opts: StatusOptions) !RunResult {
    const lo: LogoutOptions = .{
        .gpa = opts.gpa,
        .io = opts.io,
        .env = opts.env,
        .json = opts.json,
        .host = github_host,
    };
    return runAuthLogout(lo);
}

pub fn runGhAuthLogin(opts: GhLoginOptions) !RunResult {
    const config_dir = hosts_file.resolveConfigDir(opts.gpa, opts.env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(opts.gpa, "no $HOME or $XDG_CONFIG_HOME for hosts file lookup\n"),
    };
    defer opts.gpa.free(config_dir);
    const path = try std.fs.path.join(opts.gpa, &.{ config_dir, hosts_file.file_basename });
    defer opts.gpa.free(path);

    const raw_token: []u8 = blk: {
        if (opts.with_token) {
            break :blk try acquireTokenFromStdin(opts.gpa, opts.stdin_data);
        }
        break :blk acquireTokenFromPrompt(opts.gpa, opts.prompt_backend) catch |err| switch (err) {
            error.NoTty => return failure(opts.gpa, "interactive login requires a TTY; pass --with-token to read from stdin\n"),
            error.EmptyInput => return failure(opts.gpa, "empty token on stdin\n"),
            error.OutOfMemory => return error.OutOfMemory,
            else => return failure(opts.gpa, "failed to read token from terminal\n"),
        };
    };
    defer zeroAndFree(opts.gpa, raw_token);

    if (raw_token.len == 0) return failure(opts.gpa, "empty token on stdin\n");
    if (containsWhitespace(raw_token)) return failure(opts.gpa, "token must not contain whitespace\n");

    var verified_user: ?[]u8 = null;
    defer if (verified_user) |u| opts.gpa.free(u);

    if (!opts.skip_verify) {
        if (opts.verify_hook) |hook| {
            var v = hook.fn_ptr(hook.ctx, opts.gpa, raw_token) catch |err| {
                const msg = try std.fmt.allocPrint(opts.gpa, "verify hook failed: {t}\n", .{err});
                defer opts.gpa.free(msg);
                return failure(opts.gpa, msg);
            };
            defer v.deinit(opts.gpa);
            if (!v.ok) {
                if (v.status_code) |code| {
                    if (code == 401) return failure(opts.gpa, "token invalid (HTTP 401)\n");
                    const msg = try std.fmt.allocPrint(opts.gpa, "token rejected (HTTP {d})\n", .{code});
                    defer opts.gpa.free(msg);
                    return failure(opts.gpa, msg);
                }
                return failure(opts.gpa, "token rejected by upstream\n");
            }
            if (v.user) |u| verified_user = try opts.gpa.dupe(u8, u);
        }
    }

    const entry: hosts_file.HostEntry = .{
        .host = github_host,
        .oauth_token = raw_token,
        .user = verified_user,
        .git_protocol = "https",
    };
    hosts_file.upsertHost(opts.gpa, config_dir, path, entry) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(opts.gpa, "failed to write hosts.toml\n"),
    };

    const preview = try redact.tokenPreview(opts.gpa, raw_token);
    defer opts.gpa.free(preview);

    const stdout = blk: {
        if (verified_user) |u| {
            break :blk try std.fmt.allocPrint(
                opts.gpa,
                "Logged in to github.com as {s} (token: {s})\n",
                .{ u, preview },
            );
        }
        break :blk try std.fmt.allocPrint(
            opts.gpa,
            "Logged in to github.com (token: {s})\n",
            .{preview},
        );
    };
    return success(opts.gpa, stdout);
}

fn acquireTokenFromStdin(gpa: Allocator, stdin_data: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, stdin_data, " \t\r\n");
    return try gpa.dupe(u8, trimmed);
}

fn acquireTokenFromPrompt(gpa: Allocator, override: ?secure_prompt.Backend) ![]u8 {
    const backend = override orelse secure_prompt.defaultBackend();
    return try secure_prompt.prompt(
        gpa,
        backend,
        "Paste your GitHub Personal Access Token (will not be echoed): ",
    );
}

fn renderStatusPlain(gpa: Allocator, entries: []const hosts_file.HostEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (entries) |entry| {
        const preview = try redact.tokenPreview(gpa, entry.oauth_token);
        defer gpa.free(preview);
        const line = try std.fmt.allocPrint(
            gpa,
            "{s}  source=hosts-file  token={s}",
            .{ entry.host, preview },
        );
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
        if (entry.user) |u| {
            const ul = try std.fmt.allocPrint(gpa, "  user={s}", .{u});
            defer gpa.free(ul);
            try out.appendSlice(gpa, ul);
        }
        try out.append(gpa, '\n');
    }
    return try out.toOwnedSlice(gpa);
}

fn renderStatusJson(gpa: Allocator, entries: []const hosts_file.HostEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\"hosts\":[");
    for (entries, 0..) |entry, i| {
        if (i != 0) try out.append(gpa, ',');
        const preview = try redact.tokenPreview(gpa, entry.oauth_token);
        defer gpa.free(preview);
        const obj = if (entry.user) |u|
            try std.fmt.allocPrint(
                gpa,
                "{{\"host\":\"{s}\",\"source\":\"hosts-file\",\"token_preview\":\"{s}\",\"user\":\"{s}\"}}",
                .{ entry.host, preview, u },
            )
        else
            try std.fmt.allocPrint(
                gpa,
                "{{\"host\":\"{s}\",\"source\":\"hosts-file\",\"token_preview\":\"{s}\"}}",
                .{ entry.host, preview },
            );
        defer gpa.free(obj);
        try out.appendSlice(gpa, obj);
    }
    try out.appendSlice(gpa, "]}\n");
    return try out.toOwnedSlice(gpa);
}

fn checkPermissions(gpa: Allocator, path: []const u8) !?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    var stat_buf: c.Stat = undefined;
    const rc = c.fstatat(c.AT.FDCWD, path_z.ptr, &stat_buf, 0);
    if (rc != 0) return null;
    if ((stat_buf.mode & 0o077) != 0)
        return "warning: hosts.toml is world- or group-readable; restricting to 0600 is recommended\n";
    return null;
}

fn containsWhitespace(value: []const u8) bool {
    for (value) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0) return true;
    }
    return false;
}

fn zeroAndFree(gpa: Allocator, bytes: []u8) void {
    @memset(bytes, 0);
    gpa.free(bytes);
}

fn success(gpa: Allocator, stdout: []u8) !RunResult {
    return .{
        .exit_code = 0,
        .stdout = stdout,
        .stderr = try gpa.dupe(u8, ""),
    };
}

fn successWithStderr(stdout: []u8, stderr: []u8) RunResult {
    return .{ .exit_code = 0, .stdout = stdout, .stderr = stderr };
}

fn failure(gpa: Allocator, message: []const u8) !RunResult {
    return .{
        .exit_code = 1,
        .stdout = try gpa.dupe(u8, ""),
        .stderr = try gpa.dupe(u8, message),
    };
}
