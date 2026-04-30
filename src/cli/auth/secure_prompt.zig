//! Secure password/token prompt for the CLI.
//!
//! Reads a single line from `/dev/tty` with terminal echo disabled so the
//! token never lands in shell history, terminal scrollback, or argv.
//! On platforms without a controlling TTY the prompt returns
//! `error.NoTty` so callers can surface the `--with-token` instruction.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const c = std.c;
const posix = std.posix;

pub const max_token_bytes: usize = 8 * 1024;

pub const PromptError = error{
    NoTty,
    PromptReadFailed,
    TerminalConfigFailed,
    EmptyInput,
    OutOfMemory,
};

pub const Backend = struct {
    ctx: *anyopaque,
    open_fn: *const fn (ctx: *anyopaque) anyerror!Handle,
    write_fn: *const fn (ctx: *anyopaque, handle: Handle, bytes: []const u8) anyerror!void,
    read_byte_fn: *const fn (ctx: *anyopaque, handle: Handle) anyerror!?u8,
    set_noecho_fn: *const fn (ctx: *anyopaque, handle: Handle) anyerror!Termios,
    restore_fn: *const fn (ctx: *anyopaque, handle: Handle, prior: Termios) void,
    close_fn: *const fn (ctx: *anyopaque, handle: Handle) void,
};

pub const Handle = c_int;

pub const Termios = struct {
    raw: posix.termios = undefined,
};

pub fn prompt(
    gpa: Allocator,
    backend: Backend,
    prompt_text: []const u8,
) PromptError![]u8 {
    const handle = backend.open_fn(backend.ctx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NoTty,
    };
    defer backend.close_fn(backend.ctx, handle);

    backend.write_fn(backend.ctx, handle, prompt_text) catch return error.PromptReadFailed;

    const prior = backend.set_noecho_fn(backend.ctx, handle) catch return error.TerminalConfigFailed;
    var restored = false;
    defer if (!restored) backend.restore_fn(backend.ctx, handle, prior);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    while (true) {
        const maybe_byte = backend.read_byte_fn(backend.ctx, handle) catch return error.PromptReadFailed;
        const byte = maybe_byte orelse break;
        if (byte == '\n') break;
        if (byte == '\r') continue;
        if (buf.items.len >= max_token_bytes) return error.PromptReadFailed;
        try buf.append(gpa, byte);
    }

    backend.restore_fn(backend.ctx, handle, prior);
    restored = true;

    backend.write_fn(backend.ctx, handle, "\n") catch {};

    if (buf.items.len == 0) {
        buf.deinit(gpa);
        return error.EmptyInput;
    }
    return try buf.toOwnedSlice(gpa);
}

fn libcOpen(_: *anyopaque) anyerror!Handle {
    const path: [*:0]const u8 = "/dev/tty";
    const fd = c.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.NoTty;
    return fd;
}

fn libcWrite(_: *anyopaque, handle: Handle, bytes: []const u8) anyerror!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(handle, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return error.PromptReadFailed;
        written += @intCast(n);
    }
}

fn libcReadByte(_: *anyopaque, handle: Handle) anyerror!?u8 {
    var byte: [1]u8 = undefined;
    const n = c.read(handle, &byte, 1);
    if (n < 0) return error.PromptReadFailed;
    if (n == 0) return null;
    return byte[0];
}

fn libcSetNoecho(_: *anyopaque, handle: Handle) anyerror!Termios {
    const prior = posix.tcgetattr(handle) catch return error.TerminalConfigFailed;
    var next = prior;
    next.lflag.ECHO = false;
    posix.tcsetattr(handle, .NOW, next) catch return error.TerminalConfigFailed;
    return .{ .raw = prior };
}

fn libcRestore(_: *anyopaque, handle: Handle, prior: Termios) void {
    posix.tcsetattr(handle, .NOW, prior.raw) catch {};
}

fn libcClose(_: *anyopaque, handle: Handle) void {
    _ = c.close(handle);
}

var libc_sentinel: u8 = 0;

pub fn defaultBackend() Backend {
    if (builtin.os.tag == .windows) @compileError("secure_prompt has no Windows backend yet");
    return .{
        .ctx = @ptrCast(&libc_sentinel),
        .open_fn = libcOpen,
        .write_fn = libcWrite,
        .read_byte_fn = libcReadByte,
        .set_noecho_fn = libcSetNoecho,
        .restore_fn = libcRestore,
        .close_fn = libcClose,
    };
}

test "prompt returns trimmed token from backend" {
    const TestBackend = struct {
        bytes: []const u8,
        cursor: usize = 0,
        echo_disabled_calls: usize = 0,
        restored_calls: usize = 0,
        write_buffer: std.ArrayList(u8) = .empty,
        gpa: Allocator,

        fn open(ctx_raw: *anyopaque) anyerror!Handle {
            _ = ctx_raw;
            return 1;
        }
        fn write(ctx_raw: *anyopaque, handle: Handle, bytes: []const u8) anyerror!void {
            _ = handle;
            const self: *@This() = @ptrCast(@alignCast(ctx_raw));
            try self.write_buffer.appendSlice(self.gpa, bytes);
        }
        fn read_byte(ctx_raw: *anyopaque, handle: Handle) anyerror!?u8 {
            _ = handle;
            const self: *@This() = @ptrCast(@alignCast(ctx_raw));
            if (self.cursor >= self.bytes.len) return null;
            const byte = self.bytes[self.cursor];
            self.cursor += 1;
            return byte;
        }
        fn set_noecho(ctx_raw: *anyopaque, handle: Handle) anyerror!Termios {
            _ = handle;
            const self: *@This() = @ptrCast(@alignCast(ctx_raw));
            self.echo_disabled_calls += 1;
            return .{};
        }
        fn restore(ctx_raw: *anyopaque, handle: Handle, prior: Termios) void {
            _ = handle;
            _ = prior;
            const self: *@This() = @ptrCast(@alignCast(ctx_raw));
            self.restored_calls += 1;
        }
        fn close(ctx_raw: *anyopaque, handle: Handle) void {
            _ = ctx_raw;
            _ = handle;
        }
    };

    const gpa = std.testing.allocator;

    var ctx = TestBackend{ .bytes = "ghp_abc123\n", .gpa = gpa };
    defer ctx.write_buffer.deinit(gpa);

    const backend = Backend{
        .ctx = @ptrCast(&ctx),
        .open_fn = TestBackend.open,
        .write_fn = TestBackend.write,
        .read_byte_fn = TestBackend.read_byte,
        .set_noecho_fn = TestBackend.set_noecho,
        .restore_fn = TestBackend.restore,
        .close_fn = TestBackend.close,
    };

    const token = try prompt(gpa, backend, "Token: ");
    defer gpa.free(token);

    try std.testing.expectEqualStrings("ghp_abc123", token);
    try std.testing.expectEqual(@as(usize, 1), ctx.echo_disabled_calls);
    try std.testing.expectEqual(@as(usize, 1), ctx.restored_calls);
    try std.testing.expectEqualStrings("Token: \n", ctx.write_buffer.items);
}

test "prompt rejects empty input" {
    const TestBackend = struct {
        bytes: []const u8 = "\n",
        cursor: usize = 0,

        fn open(ctx_raw: *anyopaque) anyerror!Handle {
            _ = ctx_raw;
            return 1;
        }
        fn write(_: *anyopaque, _: Handle, _: []const u8) anyerror!void {}
        fn read_byte(ctx_raw: *anyopaque, handle: Handle) anyerror!?u8 {
            _ = handle;
            const self: *@This() = @ptrCast(@alignCast(ctx_raw));
            if (self.cursor >= self.bytes.len) return null;
            const byte = self.bytes[self.cursor];
            self.cursor += 1;
            return byte;
        }
        fn set_noecho(_: *anyopaque, _: Handle) anyerror!Termios {
            return .{};
        }
        fn restore(_: *anyopaque, _: Handle, _: Termios) void {}
        fn close(_: *anyopaque, _: Handle) void {}
    };

    var ctx = TestBackend{};
    const backend = Backend{
        .ctx = @ptrCast(&ctx),
        .open_fn = TestBackend.open,
        .write_fn = TestBackend.write,
        .read_byte_fn = TestBackend.read_byte,
        .set_noecho_fn = TestBackend.set_noecho,
        .restore_fn = TestBackend.restore,
        .close_fn = TestBackend.close,
    };

    try std.testing.expectError(error.EmptyInput, prompt(std.testing.allocator, backend, "Token: "));
}
