//! CLI backend selector for the document `RefStore`.
//!
//! Provides the `RefStoreBackend` enum, its parsing/precedence resolution,
//! and the `Selection` record that records which source ultimately picked
//! the backend (flag, environment, config, or built-in default).

const std = @import("std");

/// Concrete `RefStore` backends selectable from the CLI.
pub const RefStoreBackend = enum {
    /// In-process ziggit-backed refstore (native default).
    ziggit,
    /// Subprocess-driven git-backed refstore (compatibility fallback).
    subprocess,

    /// Parse a backend name. Returns `null` if `value` is not a known
    /// backend identifier.
    pub fn parse(value: []const u8) ?RefStoreBackend {
        if (std.mem.eql(u8, value, "ziggit")) return .ziggit;
        if (std.mem.eql(u8, value, "subprocess")) return .subprocess;
        return null;
    }
};

/// Records which selection layer produced the resolved backend.
pub const SelectionSource = enum {
    /// Built-in default (`ziggit`).
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
