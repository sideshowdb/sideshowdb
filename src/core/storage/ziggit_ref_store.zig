//! Candidate native `RefStore` backend built around the `ziggit` package.
//!
//! This Task 2 version is intentionally a compiling stub so the parity suite
//! can prove the backend is wired in before any real behavior is attempted.

const std = @import("std");
const RefStore = @import("ref_store.zig").RefStore;

pub const ZiggitRefStore = struct {
    pub const Options = struct {
        gpa: std.mem.Allocator,
        repo_path: []const u8,
        ref_name: []const u8,
    };

    gpa: std.mem.Allocator,
    repo_path: []const u8,
    ref_name: []const u8,

    pub fn init(options: Options) ZiggitRefStore {
        return .{
            .gpa = options.gpa,
            .repo_path = options.repo_path,
            .ref_name = options.ref_name,
        };
    }

    pub fn refStore(self: *ZiggitRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: RefStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .delete = vtableDelete,
        .list = vtableList,
        .history = vtableHistory,
    };

    fn vtablePut(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8, value: []const u8) anyerror!RefStore.VersionId {
        _ = ctx;
        _ = gpa;
        _ = key;
        _ = value;
        return error.Unimplemented;
    }

    fn vtableGet(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8, version: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        _ = ctx;
        _ = gpa;
        _ = key;
        _ = version;
        return error.Unimplemented;
    }

    fn vtableDelete(ctx: *anyopaque, key: []const u8) anyerror!void {
        _ = ctx;
        _ = key;
        return error.Unimplemented;
    }

    fn vtableList(ctx: *anyopaque, gpa: std.mem.Allocator) anyerror![][]u8 {
        _ = ctx;
        _ = gpa;
        return error.Unimplemented;
    }

    fn vtableHistory(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        _ = ctx;
        _ = gpa;
        _ = key;
        return error.Unimplemented;
    }
};
