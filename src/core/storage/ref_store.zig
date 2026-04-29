//! `RefStore` is the abstraction over a section-scoped key/value store
//! backed by a single git ref.
//!
//! See `docs/development/specs/git-ref-storage-spec.md` for the conceptual
//! model and the rationale behind this vtable-style "interface" pattern.
//! The shape mirrors `std.mem.Allocator` and `std.Io.Writer`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Section-scoped key/value store backed by a single git ref.
///
/// `RefStore` is a type-erased "interface" struct (vtable + opaque pointer)
/// the same way `std.mem.Allocator` and `std.Io.Writer` are. Implementors
/// expose a `refStore` method that returns a `RefStore` view over their
/// concrete state; callers receive that view and never see the
/// implementation type.
pub const RefStore = struct {
    /// Opaque version identifier returned by `put` and accepted by `get`.
    /// Always allocated by the implementation; release with the
    /// implementation's freeing convention (e.g. `freeReadResult` for
    /// values returned by `get`).
    pub const VersionId = []const u8;

    ptr: *anyopaque,
    vtable: *const VTable,

    /// Result of a successful `RefStore.get` call. Both fields are owned
    /// by the caller and must be freed with `freeReadResult`.
    pub const ReadResult = struct {
        value: []u8,
        version: VersionId,
    };

    /// Function pointer table backing the `RefStore` "interface" struct.
    /// Implementations populate this once and pass `&vtable` to a
    /// `RefStore` they hand out.
    pub const VTable = struct {
        put: *const fn (
            ctx: *anyopaque,
            gpa: Allocator,
            key: []const u8,
            value: []const u8,
        ) anyerror!VersionId,

        get: *const fn (
            ctx: *anyopaque,
            gpa: Allocator,
            key: []const u8,
            version: ?VersionId,
        ) anyerror!?ReadResult,

        delete: *const fn (
            ctx: *anyopaque,
            key: []const u8,
        ) anyerror!void,

        list: *const fn (
            ctx: *anyopaque,
            gpa: Allocator,
        ) anyerror![][]u8,

        history: *const fn (
            ctx: *anyopaque,
            gpa: Allocator,
            key: []const u8,
        ) anyerror![]VersionId,
    };

    /// Overwrite-or-create the blob at `key`, returning the version identifier
    /// for the successful write. Caller owns the returned memory.
    pub fn put(self: RefStore, gpa: Allocator, key: []const u8, value: []const u8) anyerror!VersionId {
        return self.vtable.put(self.ptr, gpa, key, value);
    }

    /// Return the blob at `key`, or null if absent. When `version` is null,
    /// the implementation returns the latest reachable value; otherwise it
    /// returns the value from the requested version. Caller owns the result and
    /// must free it with `freeReadResult`.
    pub fn get(self: RefStore, gpa: Allocator, key: []const u8, version: ?VersionId) anyerror!?ReadResult {
        return self.vtable.get(self.ptr, gpa, key, version);
    }

    /// Remove the blob at `key`. Idempotent if the key is absent.
    pub fn delete(self: RefStore, key: []const u8) anyerror!void {
        return self.vtable.delete(self.ptr, key);
    }

    /// Enumerate every key currently under the section. Caller owns both the
    /// outer slice and each inner slice; use `freeKeys` to release them.
    pub fn list(self: RefStore, gpa: Allocator) anyerror![][]u8 {
        return self.vtable.list(self.ptr, gpa);
    }

    /// Return reachable readable versions for `key` in newest-first order.
    /// Caller owns the outer slice and each version string; use
    /// `freeVersions` to release them.
    pub fn history(self: RefStore, gpa: Allocator, key: []const u8) anyerror![]VersionId {
        return self.vtable.history(self.ptr, gpa, key);
    }
    /// Free a key list returned by `RefStore.list`. Frees both the outer
    /// slice and each inner key slice.
    pub fn freeKeys(gpa: Allocator, keys: [][]u8) void {
        for (keys) |k| gpa.free(k);
        gpa.free(keys);
    }

    /// Free a version list returned by `RefStore.history`. Frees both the
    /// outer slice and each inner version slice.
    pub fn freeVersions(gpa: Allocator, versions: []VersionId) void {
        for (versions) |version| gpa.free(version);
        gpa.free(versions);
    }
    /// Free a `ReadResult` returned by `RefStore.get`. Frees both the
    /// `value` and the `version` slices.
    pub fn freeReadResult(gpa: Allocator, result: ReadResult) void {
        gpa.free(result.value);
        gpa.free(result.version);
    }

    /// Canonical key-validation rules shared across every `RefStore`
    /// implementation. Concrete backends call this before doing any
    /// I/O so a malformed key is rejected with `error.InvalidKey`
    /// before backend-specific work begins. Composite implementations
    /// (e.g. `WriteThroughRefStore`) call it themselves so a bad key
    /// fails fast without contacting any underlying store.
    pub fn validateKey(key: []const u8) error{InvalidKey}!void {
        if (key.len == 0) return error.InvalidKey;
        if (key[0] == '/') return error.InvalidKey;
        if (key[key.len - 1] == '/') return error.InvalidKey;
        if (std.mem.indexOf(u8, key, "//") != null) return error.InvalidKey;
        if (std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidKey;
    }
};
