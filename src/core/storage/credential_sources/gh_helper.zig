//! `GhHelperSource` — a `CredentialProvider` source backed by the
//! `gh auth token` shell-out. Defaults to `gh` on `PATH`; tests override
//! `executable_name` and `args` to drive deterministic stubs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const credential_provider = @import("credential_provider");

/// Default executable looked up on `PATH` when `Config.executable_name`
/// is omitted.
pub const default_executable: []const u8 = "gh";
/// Default argv tail (`gh auth token`) when `Config.args` is omitted.
pub const default_args: []const []const u8 = &.{ "auth", "token" };

/// Construction parameters for `GhHelperSource`.
pub const Config = struct {
    gpa: Allocator,
    io: Io,
    /// Borrowed parent environment used for the subprocess. The map must
    /// outlive the source.
    parent_env: *const Environ.Map,
    /// Override for the executable name (test stubs, alternative install
    /// paths). Defaults to `default_executable`.
    executable_name: []const u8 = default_executable,
    /// Override for the argv tail passed after `executable_name`. Defaults
    /// to `default_args`.
    args: []const []const u8 = default_args,
};

/// Source that resolves a bearer token by invoking `gh auth token` (or a
/// configured stand-in) and trimming its stdout.
pub const GhHelperSource = struct {
    gpa: Allocator,
    io: Io,
    parent_env: *const Environ.Map,
    executable_name: []const u8,
    args: []const []const u8,

    /// Builds a `GhHelperSource` from `config`.
    pub fn init(config: Config) credential_provider.CredentialError!GhHelperSource {
        if (config.executable_name.len == 0) return error.InvalidConfig;
        return .{
            .gpa = config.gpa,
            .io = config.io,
            .parent_env = config.parent_env,
            .executable_name = config.executable_name,
            .args = config.args,
        };
    }

    /// Currently a no-op; kept symmetrical with sources that own state.
    pub fn deinit(self: *GhHelperSource) void {
        self.* = undefined;
    }

    /// Returns a `CredentialProvider` vtable backed by this source.
    pub fn provider(self: *GhHelperSource) credential_provider.CredentialProvider {
        return .{
            .ctx = @ptrCast(self),
            .get_fn = ghGet,
        };
    }

    fn ghGet(
        ctx: *anyopaque,
        gpa: Allocator,
    ) credential_provider.CredentialError!credential_provider.Credential {
        const self: *GhHelperSource = @ptrCast(@alignCast(ctx));

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const local = arena.allocator();

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(local, self.executable_name);
        for (self.args) |a| try argv.append(local, a);

        const result = std.process.run(self.gpa, self.io, .{
            .argv = argv.items,
            .environ_map = self.parent_env,
        }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => return error.HelperUnavailable,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TransportError,
        };
        defer self.gpa.free(result.stdout);
        defer self.gpa.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            return error.AuthInvalid;
        }

        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (trimmed.len == 0) return error.AuthInvalid;
        return .{ .bearer = try gpa.dupe(u8, trimmed) };
    }
};
