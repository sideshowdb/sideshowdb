//! `RefStore` is the abstraction over a section-scoped key/value store
//! backed by a single git ref.
//!
//! See `docs/development/specs/git-ref-storage-spec.md` for the conceptual
//! model and the rationale behind this vtable-style "interface" pattern.
//! The shape mirrors `std.mem.Allocator` and `std.Io.Writer`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RefStore = struct {
    pub const VersionId = []const u8;

    ptr: *anyopaque,
    vtable: *const VTable,

    pub const ReadResult = struct {
        value: []u8,
        version: VersionId,
    };

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

    pub fn freeKeys(gpa: Allocator, keys: [][]u8) void {
        for (keys) |k| gpa.free(k);
        gpa.free(keys);
    }

    pub fn freeVersions(gpa: Allocator, versions: []VersionId) void {
        for (versions) |version| gpa.free(version);
        gpa.free(versions);
    }

    pub fn freeReadResult(gpa: Allocator, result: ReadResult) void {
        gpa.free(result.value);
        gpa.free(result.version);
    }
};
