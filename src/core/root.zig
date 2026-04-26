//! Core sideshowdb library.
//!
//! Spec implementation lives in later work; this module currently exposes
//! version metadata, a banner helper, and placeholder event types so the
//! build graph and downstream clients (CLI, wasm) can wire up correctly.

const std = @import("std");
const Io = std.Io;

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };

pub const banner = "sideshowdb — git-backed event-sourced db";

pub const event = @import("event.zig");
pub const Event = event.Event;

pub const storage = @import("storage.zig");
pub const RefStore = storage.RefStore;
pub const GitRefStore = storage.GitRefStore;

pub fn writeBanner(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("{s} v{f}\n", .{ banner, version });
}

test {
    _ = event;
    _ = storage;
}

test "writeBanner emits banner and version" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeBanner(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "sideshowdb") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0.0.0") != null);
}
