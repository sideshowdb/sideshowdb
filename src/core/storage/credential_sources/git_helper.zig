//! `GitHelperSource` — a `CredentialProvider` source backed by `git
//! credential fill`. Defaults to `git` on `PATH`; tests override
//! `executable_name` and `args` to drive deterministic stubs.
//!
//! `git credential fill` reads a credential request from stdin (one
//! `key=value` line per attribute, terminated by a blank line) and
//! responds with the resolved attributes on stdout. We send `protocol=`
//! and `host=`; git replies with `username=` and `password=`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const credential_provider = @import("credential_provider");

/// Default executable looked up on `PATH` when `Config.executable_name`
/// is omitted.
pub const default_executable: []const u8 = "git";
/// Default argv tail (`git credential fill`) when `Config.args` is
/// omitted.
pub const default_args: []const []const u8 = &.{ "credential", "fill" };
/// Default `protocol=` value sent in the credential request when
/// `Config.protocol` is omitted.
pub const default_protocol: []const u8 = "https";
/// Default `host=` value sent in the credential request when
/// `Config.host` is omitted.
pub const default_host: []const u8 = "github.com";

/// Maximum number of bytes accepted on either stdout or stderr. Large
/// enough for any plausible credential payload; bounded so a misbehaving
/// helper cannot exhaust memory.
const max_stream_bytes: usize = 1 << 20;

/// Construction parameters for `GitHelperSource`.
pub const Config = struct {
    gpa: Allocator,
    io: Io,
    /// Borrowed parent environment used for the subprocess. The map must
    /// outlive the source.
    parent_env: *const Environ.Map,
    /// Override for the executable name (test stubs, alternative install
    /// paths). Defaults to `default_executable`.
    executable_name: []const u8 = default_executable,
    /// Override for the argv tail passed after `executable_name`.
    /// Defaults to `default_args`.
    args: []const []const u8 = default_args,
    /// Value sent in the `protocol=` line of the credential request.
    /// Defaults to `default_protocol`.
    protocol: []const u8 = default_protocol,
    /// Value sent in the `host=` line of the credential request.
    /// Defaults to `default_host`.
    host: []const u8 = default_host,
};

/// Source that resolves an HTTP basic credential by invoking
/// `git credential fill` (or a configured stand-in) and parsing its
/// stdout.
pub const GitHelperSource = struct {
    gpa: Allocator,
    io: Io,
    parent_env: *const Environ.Map,
    executable_name: []const u8,
    args: []const []const u8,
    protocol: []const u8,
    host: []const u8,

    /// Builds a `GitHelperSource` from `config`.
    pub fn init(config: Config) credential_provider.CredentialError!GitHelperSource {
        if (config.executable_name.len == 0) return error.InvalidConfig;
        if (config.protocol.len == 0) return error.InvalidConfig;
        if (config.host.len == 0) return error.InvalidConfig;
        return .{
            .gpa = config.gpa,
            .io = config.io,
            .parent_env = config.parent_env,
            .executable_name = config.executable_name,
            .args = config.args,
            .protocol = config.protocol,
            .host = config.host,
        };
    }

    /// Currently a no-op; kept symmetrical with sources that own state.
    pub fn deinit(self: *GitHelperSource) void {
        self.* = undefined;
    }

    /// Returns a `CredentialProvider` vtable backed by this source.
    pub fn provider(self: *GitHelperSource) credential_provider.CredentialProvider {
        return .{
            .ctx = @ptrCast(self),
            .get_fn = gitGet,
        };
    }

    fn gitGet(
        ctx: *anyopaque,
        gpa: Allocator,
    ) credential_provider.CredentialError!credential_provider.Credential {
        const self: *GitHelperSource = @ptrCast(@alignCast(ctx));

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const local = arena.allocator();

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(local, self.executable_name);
        for (self.args) |a| try argv.append(local, a);

        const stdin_payload = try std.fmt.allocPrint(
            local,
            "protocol={s}\nhost={s}\n\n",
            .{ self.protocol, self.host },
        );

        var child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .environ_map = self.parent_env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return error.HelperUnavailable,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TransportError,
        };
        defer child.kill(self.io);

        const child_stdin = child.stdin.?;
        Io.File.writeStreamingAll(child_stdin, self.io, stdin_payload) catch
            return error.TransportError;
        Io.File.close(child_stdin, self.io);
        child.stdin = null;

        var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: Io.File.MultiReader = undefined;
        multi_reader.init(
            self.gpa,
            self.io,
            multi_reader_buffer.toStreams(),
            &.{ child.stdout.?, child.stderr.? },
        );
        defer multi_reader.deinit();

        const stdout_reader = multi_reader.reader(0);
        const stderr_reader = multi_reader.reader(1);

        while (multi_reader.fill(64, .none)) |_| {
            if (stdout_reader.buffered().len > max_stream_bytes)
                return error.TransportError;
            if (stderr_reader.buffered().len > max_stream_bytes)
                return error.TransportError;
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return error.TransportError,
        }

        multi_reader.checkAnyError() catch return error.TransportError;

        const term = child.wait(self.io) catch return error.TransportError;

        const stdout_slice = try multi_reader.toOwnedSlice(0);
        defer self.gpa.free(stdout_slice);
        const stderr_slice = try multi_reader.toOwnedSlice(1);
        defer self.gpa.free(stderr_slice);

        if (term != .exited or term.exited != 0) {
            return error.AuthInvalid;
        }

        return parseCredential(gpa, stdout_slice);
    }
};

/// Scans `stdout` line-by-line for the first `username=` and
/// `password=` lines. Empty/missing username maps to
/// `error.HelperUnavailable` (matches `git credential fill` behaviour
/// when no helper is configured); missing password maps to
/// `error.AuthInvalid`.
fn parseCredential(
    gpa: Allocator,
    stdout: []const u8,
) credential_provider.CredentialError!credential_provider.Credential {
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (username == null) {
            if (std.mem.startsWith(u8, line, "username=")) {
                username = line["username=".len..];
                continue;
            }
        }
        if (password == null) {
            if (std.mem.startsWith(u8, line, "password=")) {
                password = line["password=".len..];
                continue;
            }
        }
    }

    const user = username orelse return error.HelperUnavailable;
    if (user.len == 0) return error.HelperUnavailable;
    const pass = password orelse return error.AuthInvalid;
    if (pass.len == 0) return error.AuthInvalid;

    const user_dup = try gpa.dupe(u8, user);
    errdefer gpa.free(user_dup);
    const pass_dup = try gpa.dupe(u8, pass);
    return .{ .basic = .{ .user = user_dup, .password = pass_dup } };
}
