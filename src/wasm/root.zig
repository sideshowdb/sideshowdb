const std = @import("std");
const sideshowdb = @import("sideshowdb");
const ImportedRefStore = @import("imported_ref_store.zig").ImportedRefStore;

var imported_ref_store = ImportedRefStore{};
var request_buf: [64 * 1024]u8 align(16) = undefined;
var result_buf: []u8 = &.{};

fn wasmStore() sideshowdb.DocumentStore {
    return sideshowdb.DocumentStore.init(imported_ref_store.refStore());
}

fn setResult(new_result: []u8) void {
    if (result_buf.len != 0) std.heap.wasm_allocator.free(result_buf);
    result_buf = new_result;
}

fn requestBytes(request_ptr: [*]const u8, request_len: usize) ?[]const u8 {
    const request_start = @intFromPtr(request_ptr);
    const request_end = request_start +| request_len;
    const buffer_start = @intFromPtr(&request_buf);
    const buffer_end = buffer_start + request_buf.len;

    if (request_start < buffer_start or request_end > buffer_end) return null;
    return request_ptr[0..request_len];
}

export fn sideshowdb_version_major() u32 {
    return @intCast(sideshowdb.version.major);
}

export fn sideshowdb_version_minor() u32 {
    return @intCast(sideshowdb.version.minor);
}

export fn sideshowdb_version_patch() u32 {
    return @intCast(sideshowdb.version.patch);
}

export fn sideshowdb_banner_ptr() [*]const u8 {
    return sideshowdb.banner.ptr;
}

export fn sideshowdb_banner_len() usize {
    return sideshowdb.banner.len;
}

export fn sideshowdb_request_ptr() [*]u8 {
    return &request_buf;
}

export fn sideshowdb_request_len() usize {
    return request_buf.len;
}

export fn sideshowdb_document_put(request_ptr: [*]const u8, request_len: usize) u32 {
    const request = requestBytes(request_ptr, request_len) orelse return 1;
    const response = sideshowdb.document_transport.handlePut(
        std.heap.wasm_allocator,
        wasmStore(),
        request,
    ) catch return 1;
    setResult(response);
    return 0;
}

export fn sideshowdb_document_get(request_ptr: [*]const u8, request_len: usize) u32 {
    const request = requestBytes(request_ptr, request_len) orelse return 1;
    const response = sideshowdb.document_transport.handleGet(
        std.heap.wasm_allocator,
        wasmStore(),
        request,
    ) catch return 1;
    if (response) |json| {
        setResult(json);
        return 0;
    }
    setResult(std.heap.wasm_allocator.dupe(u8, "") catch return 1);
    return 1;
}

export fn sideshowdb_document_list(request_ptr: [*]const u8, request_len: usize) u32 {
    const request = requestBytes(request_ptr, request_len) orelse return 1;
    const response = sideshowdb.document_transport.handleList(
        std.heap.wasm_allocator,
        wasmStore(),
        request,
    ) catch return 1;
    setResult(response);
    return 0;
}

export fn sideshowdb_document_delete(request_ptr: [*]const u8, request_len: usize) u32 {
    const request = requestBytes(request_ptr, request_len) orelse return 1;
    const response = sideshowdb.document_transport.handleDelete(
        std.heap.wasm_allocator,
        wasmStore(),
        request,
    ) catch return 1;
    setResult(response);
    return 0;
}

export fn sideshowdb_document_history(request_ptr: [*]const u8, request_len: usize) u32 {
    const request = requestBytes(request_ptr, request_len) orelse return 1;
    const response = sideshowdb.document_transport.handleHistory(
        std.heap.wasm_allocator,
        wasmStore(),
        request,
    ) catch return 1;
    setResult(response);
    return 0;
}

export fn sideshowdb_result_ptr() [*]const u8 {
    return result_buf.ptr;
}

export fn sideshowdb_result_len() usize {
    return result_buf.len;
}
