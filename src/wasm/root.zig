const std = @import("std");
const builtin = @import("builtin");
const sideshowdb = @import("sideshowdb");
const credential_provider = @import("credential_provider");
const host_capability_source = @import("credential_source_host_capability");
const ImportedRefStore = @import("imported_ref_store.zig").ImportedRefStore;

/// Allocator used by every WASM export. `wasm_allocator` is freestanding-only
/// and trips a build error on `wasm32-wasi`; the page allocator is the WASI
/// equivalent that backs onto host-provided memory.
const wasm_gpa: std.mem.Allocator = switch (builtin.os.tag) {
    .freestanding => std.heap.wasm_allocator,
    .wasi => std.heap.page_allocator,
    else => @compileError("src/wasm/root.zig only supports wasm32-freestanding and wasm32-wasi"),
};

const BackendMode = enum { memory, imported, github };

var memory_ref_store_state: sideshowdb.MemoryRefStore = sideshowdb.MemoryRefStore.init(.{
    .gpa = wasm_gpa,
});
var imported_ref_store = ImportedRefStore{};
var active_backend: BackendMode = .memory;
var wasm_github_state: ?*WasmGitHubState = null;
var request_buf: [64 * 1024]u8 align(16) = undefined;
var result_buf: []u8 = &.{};

/// Heap-allocated state for the WASM GitHub backend. Heap allocation keeps all
/// sub-object pointers (transport vtable ctx, credential provider ctx) stable
/// across the lifetime of the store.
const WasmGitHubState = struct {
    owner: []u8,
    repo: []u8,
    ref_name: []u8,
    api_base: []u8,
    cred_handle: credential_provider.ProviderHandle,
    host_http: sideshowdb.storage.HostHttpTransport,
    store: sideshowdb.GitHubApiRefStore,

    pub fn deinit(self: *WasmGitHubState) void {
        self.store.deinitCaches(wasm_gpa);
        self.cred_handle.deinit();
        wasm_gpa.free(self.owner);
        wasm_gpa.free(self.repo);
        wasm_gpa.free(self.ref_name);
        wasm_gpa.free(self.api_base);
        wasm_gpa.destroy(self);
    }
};

const document_call_failed: u32 = 1;
const document_get_not_found: u32 = 2;

fn wasmStore() sideshowdb.DocumentStore {
    const ref = switch (active_backend) {
        .memory => memory_ref_store_state.refStore(),
        .imported => imported_ref_store.refStore(),
        .github => if (wasm_github_state) |s| s.store.refStore() else memory_ref_store_state.refStore(),
    };
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
    if (wasm_github_state) |s| {
        s.deinit();
        wasm_github_state = null;
    }
    active_backend = .imported;
}

export fn sideshowdb_use_memory_ref_store() void {
    if (wasm_github_state) |s| {
        s.deinit();
        wasm_github_state = null;
    }
    active_backend = .memory;
}

/// Initialise the WASM GitHub API backend.
///
/// Caller passes owner, repo, ref (empty = default), api_base (empty = default)
/// as UTF-8 byte slices pointing into WASM linear memory.
/// Returns 0 on success, negative on failure (OOM, invalid config, etc.).
export fn sideshowdb_use_github_ref_store(
    owner_ptr: u32,
    owner_len: u32,
    repo_ptr: u32,
    repo_len: u32,
    ref_ptr: u32,
    ref_len: u32,
    api_base_ptr: u32,
    api_base_len: u32,
) i32 {
    if (wasm_github_state) |prev| {
        prev.deinit();
        wasm_github_state = null;
    }
    active_backend = .memory;

    const owner_bytes: []const u8 = @as([*]const u8, @ptrFromInt(owner_ptr))[0..owner_len];
    const repo_bytes: []const u8 = @as([*]const u8, @ptrFromInt(repo_ptr))[0..repo_len];
    const ref_raw: []const u8 = @as([*]const u8, @ptrFromInt(ref_ptr))[0..ref_len];
    const api_base_raw: []const u8 = @as([*]const u8, @ptrFromInt(api_base_ptr))[0..api_base_len];

    const state = wasm_gpa.create(WasmGitHubState) catch return -1;

    state.owner = wasm_gpa.dupe(u8, owner_bytes) catch {
        wasm_gpa.destroy(state);
        return -1;
    };
    state.repo = wasm_gpa.dupe(u8, repo_bytes) catch {
        wasm_gpa.free(state.owner);
        wasm_gpa.destroy(state);
        return -1;
    };
    const ref_resolved = if (ref_raw.len > 0) ref_raw else sideshowdb.GitHubApiRefStore.default_ref_name;
    state.ref_name = wasm_gpa.dupe(u8, ref_resolved) catch {
        wasm_gpa.free(state.owner);
        wasm_gpa.free(state.repo);
        wasm_gpa.destroy(state);
        return -1;
    };
    const api_base_resolved = if (api_base_raw.len > 0) api_base_raw else sideshowdb.GitHubApiRefStore.default_api_base;
    state.api_base = wasm_gpa.dupe(u8, api_base_resolved) catch {
        wasm_gpa.free(state.owner);
        wasm_gpa.free(state.repo);
        wasm_gpa.free(state.ref_name);
        wasm_gpa.destroy(state);
        return -1;
    };
    state.cred_handle = credential_provider.fromSpec(.{ .host_capability = .{} }, .{
        .gpa = wasm_gpa,
    }) catch {
        wasm_gpa.free(state.owner);
        wasm_gpa.free(state.repo);
        wasm_gpa.free(state.ref_name);
        wasm_gpa.free(state.api_base);
        wasm_gpa.destroy(state);
        return -1;
    };
    state.host_http = sideshowdb.storage.HostHttpTransport.init(.{});
    state.store = sideshowdb.GitHubApiRefStore.init(.{
        .owner = state.owner,
        .repo = state.repo,
        .ref_name = state.ref_name,
        .api_base = state.api_base,
        .transport = state.host_http.transport(),
        .credentials = state.cred_handle.provider(),
        .enable_read_caching = true,
    }) catch {
        state.cred_handle.deinit();
        wasm_gpa.free(state.owner);
        wasm_gpa.free(state.repo);
        wasm_gpa.free(state.ref_name);
        wasm_gpa.free(state.api_base);
        wasm_gpa.destroy(state);
        return -1;
    };

    wasm_github_state = state;
    active_backend = .github;
    return 0;
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

/// Exercises `HostCapabilitySource` against the embedder's
/// `sideshowdb_host_get_credential` import. Returns `0` when the host
/// returns a bearer matching `"from-host"` for `provider="github"`.
export fn sideshowdb_host_credential_probe() u32 {
    var src = host_capability_source.HostCapabilitySource.init(.{
        .gpa = wasm_gpa,
    }) catch return 1;
    defer src.deinit();

    var prov = src.provider();
    var cred = prov.get(wasm_gpa) catch return 2;
    defer cred.deinit(wasm_gpa);

    if (cred != .bearer) return 3;
    if (!std.mem.eql(u8, cred.bearer, "from-host")) return 4;
    return 0;
}
