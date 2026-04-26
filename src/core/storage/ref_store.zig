//! `RefStore` is the abstraction over a section-scoped key/value store
//! backed by a single git ref.
//!
//! See `docs/development/specs/git-ref-storage-spec.md` for the conceptual
//! model and the rationale behind this vtable-style "interface" pattern.
//! The shape mirrors `std.mem.Allocator` and `std.Io.Writer`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RefStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (
            ctx: *anyopaque,
            key: []const u8,
            value: []const u8,
        ) anyerror!void,

        get: *const fn (
            ctx: *anyopaque,
            gpa: Allocator,
            key: []const u8,
        ) anyerror!?[]u8,

        delete: *const fn (
            ctx: *anyopaque,
            key: []const u8,
        ) anyerror!void,

        list: *const fn (
            ctx: *anyopaque,
            gpa: Allocator,
        ) anyerror![][]u8,
    };

    /// Overwrite-or-create the blob at `key`.
    pub fn put(self: RefStore, key: []const u8, value: []const u8) anyerror!void {
        return self.vtable.put(self.ptr, key, value);
    }

    /// Return the blob at `key`, or null if absent. Caller owns the returned
    /// memory and must free it with `gpa`.
    pub fn get(self: RefStore, gpa: Allocator, key: []const u8) anyerror!?[]u8 {
        return self.vtable.get(self.ptr, gpa, key);
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

    pub fn freeKeys(gpa: Allocator, keys: [][]u8) void {
        for (keys) |k| gpa.free(k);
        gpa.free(keys);
    }
};
