const std = @import("std");
const sideshowdb = @import("sideshowdb");
const RefStore = sideshowdb.RefStore;

const Allocator = std.mem.Allocator;

extern fn sideshowdb_host_ref_put(
    key_ptr: [*]const u8,
    key_len: usize,
    value_ptr: [*]const u8,
    value_len: usize,
) i32;

extern fn sideshowdb_host_ref_get(
    key_ptr: [*]const u8,
    key_len: usize,
    version_ptr: ?[*]const u8,
    version_len: usize,
) i32;

extern fn sideshowdb_host_result_ptr() [*]const u8;
extern fn sideshowdb_host_result_len() usize;
extern fn sideshowdb_host_version_ptr() [*]const u8;
extern fn sideshowdb_host_version_len() usize;

pub const ImportedRefStore = struct {
    pub fn refStore(self: *ImportedRefStore) RefStore {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: RefStore.VTable = .{
        .put = putImpl,
        .get = getImpl,
        .delete = deleteImpl,
        .list = listImpl,
        .history = historyImpl,
    };

    fn putImpl(_: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.VersionId {
        const status = sideshowdb_host_ref_put(key.ptr, key.len, value.ptr, value.len);
        if (status != 0) return error.HostOperationFailed;
        return copyHostVersion(gpa);
    }

    fn getImpl(_: *anyopaque, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        const status = sideshowdb_host_ref_get(
            key.ptr,
            key.len,
            if (version) |v| v.ptr else null,
            if (version) |v| v.len else 0,
        );
        if (status == 1) return null;
        if (status != 0) return error.HostOperationFailed;

        const value = try copyHostBuffer(gpa);
        errdefer gpa.free(value);
        const resolved_version = if (version) |v|
            try gpa.dupe(u8, v)
        else
            try copyHostVersion(gpa);
        return .{
            .value = value,
            .version = resolved_version,
        };
    }

    fn deleteImpl(_: *anyopaque, _: []const u8) anyerror!void {
        return error.UnsupportedOperation;
    }

    fn listImpl(_: *anyopaque, _: Allocator) anyerror![][]u8 {
        return error.UnsupportedOperation;
    }

    fn historyImpl(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]RefStore.VersionId {
        return error.UnsupportedOperation;
    }

    fn copyHostBuffer(gpa: Allocator) ![]u8 {
        const ptr = sideshowdb_host_result_ptr();
        const len = sideshowdb_host_result_len();
        return gpa.dupe(u8, ptr[0..len]);
    }

    fn copyHostVersion(gpa: Allocator) ![]u8 {
        const ptr = sideshowdb_host_version_ptr();
        const len = sideshowdb_host_version_len();
        return gpa.dupe(u8, ptr[0..len]);
    }
};
