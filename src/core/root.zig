//! Core sideshowdb library.
//!
//! Spec implementation lives in later work; this module currently exposes
//! version metadata, a banner helper, and placeholder event types so the
//! build graph and downstream clients (CLI, wasm) can wire up correctly.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

/// Sideshowdb crate version. Surfaces in the CLI banner and in the
/// `writeBanner` output below.
pub const version: std.SemanticVersion = build_options.package_version;

/// Single-line product banner shared by the CLI and embed surfaces.
pub const banner = "sideshowdb — git-backed event-sourced db";

/// Event types and helpers. See `event.zig`.
pub const event = @import("event.zig");

/// Convenience re-export of `event.Event`.
pub const Event = event.Event;

/// Document store types and helpers. See `document.zig`.
pub const document = @import("document.zig");

/// Convenience re-export of `document.DocumentStore`.
pub const DocumentStore = document.DocumentStore;

/// JSON wire-format adapters for transport surfaces (CLI, WASM bridge).
/// See `document_transport.zig`.
pub const document_transport = @import("document_transport.zig");

/// Storage abstractions and concrete implementations. See `storage.zig`.
pub const storage = @import("storage.zig");

/// Convenience re-export of `storage.RefStore`.
pub const RefStore = storage.RefStore;

/// Convenience re-export of `storage.MemoryRefStore`. Available on every
/// target including `wasm32-freestanding`.
pub const MemoryRefStore = storage.MemoryRefStore;

/// Convenience re-export of `storage.WriteThroughRefStore`. Available
/// on every target — composes existing `RefStore` views without taking
/// a host-facility dependency. See
/// `docs/development/specs/write-through-store-spec.md`.
pub const WriteThroughRefStore = storage.WriteThroughRefStore;

/// Convenience re-export of `storage.GitRefStore`. Resolves to `void` on
/// freestanding targets (e.g. the wasm32 build) where subprocesses are
/// unavailable.
pub const GitRefStore = storage.GitRefStore;

/// Convenience re-export of `storage.SubprocessGitRefStore`. Resolves to
/// `void` on freestanding targets where subprocesses are unavailable.
pub const SubprocessGitRefStore = storage.SubprocessGitRefStore;

/// Convenience re-export of `storage.ZiggitRefStore`. Resolves to `void`
/// on freestanding targets where the host filesystem facilities the
/// backend depends on are unavailable.
pub const ZiggitRefStore = storage.ZiggitRefStore;

/// Write the project banner and version to `writer` as
/// `<banner> v<major>.<minor>.<patch>\n`.
///
/// Errors:
/// - any `Io.Writer.Error` propagated from the underlying writer (typically
///   `OutOfMemory` for fixed buffers, or backend-specific I/O failures).
///
/// Example (from `test "writeBanner emits banner and version"`):
/// ```
/// var buf: [256]u8 = undefined;
/// var w: Io.Writer = .fixed(&buf);
/// try writeBanner(&w);
/// ```
pub fn writeBanner(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("{s} v{f}\n", .{ banner, version });
}

test {
    _ = event;
    _ = document;
    _ = document_transport;
    _ = storage;
}

test "writeBanner emits banner and version" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeBanner(&w);
    const out = w.buffered();
    var version_buf: [64]u8 = undefined;
    const expected_version = try std.fmt.bufPrint(&version_buf, "{f}", .{version});
    try std.testing.expect(std.mem.indexOf(u8, out, "sideshowdb") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, expected_version) != null);
}

test "version matches build manifest version" {
    try std.testing.expectEqualDeep(build_options.package_version, version);
}
