const std = @import("std");
const builtin = @import("builtin");
const sideshowdb = @import("sideshowdb");
const ImportedRefStore = @import("imported_ref_store.zig").ImportedRefStore;

/// Allocator used by every WASM export. `wasm_allocator` is freestanding-only
/// and trips a build error on `wasm32-wasi`; the page allocator is the WASI
/// equivalent that backs onto host-provided memory.
const wasm_gpa: std.mem.Allocator = switch (builtin.os.tag) {
    .freestanding => std.heap.wasm_allocator,
    .wasi => std.heap.page_allocator,
    else => @compileError("src/wasm/root.zig only supports wasm32-freestanding and wasm32-wasi"),
};

var memory_ref_store_state: sideshowdb.MemoryRefStore = sideshowdb.MemoryRefStore.init(.{
    .gpa = wasm_gpa,
});
var imported_ref_store = ImportedRefStore{};
var use_imported_backend: bool = false;
var request_buf: [64 * 1024]u8 align(16) = undefined;
var result_buf: []u8 = &.{};

const document_call_failed: u32 = 1;
const document_get_not_found: u32 = 2;

fn wasmStore() sideshowdb.DocumentStore {
    const ref = if (use_imported_backend)
        imported_ref_store.refStore()
    else
        memory_ref_store_state.refStore();
    return sideshowdb.DocumentStore.init(ref);
}

fn setResult(new_result: []u8) void {
    if (result_buf.len != 0) wasm_gpa.free(result_buf);
    result_buf = new_result;
}

fn clearResult() void {
    setResult(&.{});
}

fn failDocumentCall() u32 {
    clearResult();
    return document_call_failed;
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
    const request = requestBytes(request_ptr, request_len) orelse return failDocumentCall();
    const response = sideshowdb.document_transport.handlePut(
        wasm_gpa,
        wasmStore(),
        request,
    ) catch return failDocumentCall();
    setResult(response);
    return 0;
}

export fn sideshowdb_document_get(request_ptr: [*]const u8, request_len: usize) u32 {
    const request = requestBytes(request_ptr, request_len) orelse return failDocumentCall();
    const response = sideshowdb.document_transport.handleGet(
        wasm_gpa,
        wasmStore(),
        request,
    ) catch return failDocumentCall();
    if (response) |json| {
        setResult(json);
        return 0;
    }
    clearResult();
    return document_get_not_found;
}

export fn sideshowdb_document_list(request_ptr: [*]const u8, request_len: usize) u32 {
    const request = requestBytes(request_ptr, request_len) orelse return failDocumentCall();
    const response = sideshowdb.document_transport.handleList(
        wasm_gpa,
        wasmStore(),
        request,
    ) catch return failDocumentCall();
    setResult(response);
    return 0;
}

export fn sideshowdb_document_delete(request_ptr: [*]const u8, request_len: usize) u32 {
    const request = requestBytes(request_ptr, request_len) orelse return failDocumentCall();
    const response = sideshowdb.document_transport.handleDelete(
        wasm_gpa,
        wasmStore(),
        request,
    ) catch return failDocumentCall();
    setResult(response);
    return 0;
}

export fn sideshowdb_document_history(request_ptr: [*]const u8, request_len: usize) u32 {
    const request = requestBytes(request_ptr, request_len) orelse return failDocumentCall();
    const response = sideshowdb.document_transport.handleHistory(
        wasm_gpa,
        wasmStore(),
        request,
    ) catch return failDocumentCall();
    setResult(response);
    return 0;
}

export fn sideshowdb_result_ptr() [*]const u8 {
    return result_buf.ptr;
}

export fn sideshowdb_result_len() usize {
    return result_buf.len;
}

export fn sideshowdb_use_imported_ref_store() void {
    use_imported_backend = true;
}

export fn sideshowdb_use_memory_ref_store() void {
    use_imported_backend = false;
}

/// Exercises `HostHttpTransport` against the embedder's `sideshowdb_host_http_request` import.
/// Returns `0` when the host returns a minimal `200` response with body `ok`.
export fn sideshowdb_host_http_transport_probe() u32 {
    var bridge: sideshowdb.storage.HostHttpTransport = .init(.{});
    const ht = bridge.transport();
    var resp = ht.request(.GET, "http://example.test/probe", &.{}, null, wasm_gpa) catch return 1;
    defer resp.deinit(wasm_gpa);
    if (resp.status != 200) return 2;
    if (!std.mem.eql(u8, resp.body, "ok")) return 3;
    if (resp.etag) |e| {
        if (!std.mem.eql(u8, e, "\"probe\"")) return 4;
    } else return 5;
    return 0;
}
