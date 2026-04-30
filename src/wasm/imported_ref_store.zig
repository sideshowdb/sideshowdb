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
extern fn sideshowdb_host_ref_delete(
    key_ptr: [*]const u8,
    key_len: usize,
) i32;
extern fn sideshowdb_host_ref_list() i32;
extern fn sideshowdb_host_ref_history(
    key_ptr: [*]const u8,
    key_len: usize,
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

    fn putImpl(_: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.PutResult {
        const status = sideshowdb_host_ref_put(key.ptr, key.len, value.ptr, value.len);
        if (status != 0) return error.HostOperationFailed;
        return .{ .version = try copyHostVersion(gpa) };
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

    fn deleteImpl(_: *anyopaque, key: []const u8) anyerror!void {
        const status = sideshowdb_host_ref_delete(key.ptr, key.len);
        if (status != 0) return error.HostOperationFailed;
    }

    fn listImpl(_: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        if (sideshowdb_host_ref_list() != 0) return error.HostOperationFailed;
        const json = try copyHostBuffer(gpa);
        defer gpa.free(json);
        return parseStringArray(gpa, json);
    }

    fn historyImpl(_: *anyopaque, gpa: Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        if (sideshowdb_host_ref_history(key.ptr, key.len) != 0) return error.HostOperationFailed;
        const json = try copyHostBuffer(gpa);
        defer gpa.free(json);
        return parseVersionArray(gpa, json);
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

    fn parseStringArray(gpa: Allocator, json: []const u8) ![][]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return error.HostOperationFailed;

        var values: std.ArrayList([]u8) = .empty;
        errdefer {
            for (values.items) |value| gpa.free(value);
            values.deinit(gpa);
        }

        for (parsed.value.array.items) |item| {
            if (item != .string) return error.HostOperationFailed;
            try values.append(gpa, try gpa.dupe(u8, item.string));
        }
        return values.toOwnedSlice(gpa);
    }

    fn parseVersionArray(gpa: Allocator, json: []const u8) ![]RefStore.VersionId {
        const values = try parseStringArray(gpa, json);
        return @ptrCast(values);
    }
};
