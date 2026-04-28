const std = @import("std");
const sideshowdb = @import("sideshowdb");
const zwasm = @import("zwasm");

const Environ = std.process.Environ;

fn isGitAvailable(gpa: std.mem.Allocator, io: std.Io, env: *const Environ.Map) bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "--version" },
        .environ_map = env,
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn runOk(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const Environ.Map,
    argv: []const []const u8,
) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .environ_map = env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.HelperCommandFailed;
}

const HostState = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: Environ.Map,
    tmp: std.testing.TmpDir,
    repo_path: []u8,
    git_store: sideshowdb.SubprocessGitRefStore,
    host_result: []u8 = &.{},
    host_version: []u8 = &.{},
    guest_request_offset: u32 = 0,
    guest_result_offset: u32 = 0,
    guest_version_offset: u32 = 0,

    fn init(gpa: std.mem.Allocator, io: std.Io) !HostState {
        var env = try Environ.createMap(std.testing.environ, gpa);
        errdefer env.deinit();

        if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);
        const repo_path = try std.fs.path.join(gpa, &.{
            cwd,
            ".zig-cache",
            "tmp",
            &tmp.sub_path,
        });
        errdefer gpa.free(repo_path);

        try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

        return .{
            .gpa = gpa,
            .io = io,
            .env = env,
            .tmp = tmp,
            .repo_path = repo_path,
            .git_store = sideshowdb.SubprocessGitRefStore.init(.{
                .gpa = gpa,
                .io = io,
                .parent_env = &env,
                .repo_path = repo_path,
                .ref_name = "refs/sideshowdb/documents",
            }),
        };
    }

    fn deinit(self: *HostState) void {
        self.freeHostBuffers();
        self.tmp.cleanup();
        self.gpa.free(self.repo_path);
        self.env.deinit();
    }

    fn refStore(self: *HostState) sideshowdb.RefStore {
        self.git_store.parent_env = &self.env;
        return self.git_store.refStore();
    }

    fn freeHostBuffers(self: *HostState) void {
        if (self.host_result.len != 0) self.gpa.free(self.host_result);
        if (self.host_version.len != 0) self.gpa.free(self.host_version);
        self.host_result = &.{};
        self.host_version = &.{};
    }

    fn setHostBuffers(self: *HostState, result: []const u8, version: []const u8) !void {
        self.freeHostBuffers();
        self.host_result = try self.gpa.dupe(u8, result);
        errdefer self.freeHostBuffers();
        self.host_version = try self.gpa.dupe(u8, version);
    }

    fn setResultJson(self: *HostState, value: anytype) !void {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();

        var stringify: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{},
        };
        try stringify.write(value);
        try self.setHostBuffers(out.written(), "");
    }

    fn guestMemorySlice(vm: *zwasm.Vm, offset: u32, len: u32) ![]u8 {
        const mem = try vm.getMemory(0);
        const bytes = mem.memory();
        const end = @as(u64, offset) + @as(u64, len);
        if (end > bytes.len) return error.OutOfBoundsMemoryAccess;
        return bytes[offset..][0..len];
    }

    fn readGuestBytes(vm: *zwasm.Vm, offset: u32, len: u32) ![]const u8 {
        return guestMemorySlice(vm, offset, len);
    }

    fn writeGuestBytes(self: *HostState, vm: *zwasm.Vm, offset: u32, bytes: []const u8) !u32 {
        const dst = try guestMemorySlice(vm, offset, @intCast(bytes.len));
        @memcpy(dst, bytes);
        _ = self;
        return offset;
    }
};

const WasmHarness = struct {
    gpa: std.mem.Allocator,
    state: *HostState,
    wasm_bytes: []u8,
    wasm: *zwasm.WasmModule,
    last_result: []u8 = &.{},

    fn init(gpa: std.mem.Allocator, io: std.Io) !WasmHarness {
        const state = try gpa.create(HostState);
        errdefer gpa.destroy(state);
        state.* = try HostState.init(gpa, io);
        errdefer state.deinit();

        const wasm_bytes = try readFile(gpa, io, "zig-out/wasm/sideshowdb.wasm");

        const imports = [_]zwasm.ImportEntry{
            .{
                .module = "env",
                .source = .{ .host_fns = &.{
                    .{ .name = "sideshowdb_host_ref_put", .callback = hostRefPut, .context = @intFromPtr(state) },
                    .{ .name = "sideshowdb_host_ref_get", .callback = hostRefGet, .context = @intFromPtr(state) },
                    .{ .name = "sideshowdb_host_ref_delete", .callback = hostRefDelete, .context = @intFromPtr(state) },
                    .{ .name = "sideshowdb_host_ref_list", .callback = hostRefList, .context = @intFromPtr(state) },
                    .{ .name = "sideshowdb_host_ref_history", .callback = hostRefHistory, .context = @intFromPtr(state) },
                    .{ .name = "sideshowdb_host_result_ptr", .callback = hostResultPtr, .context = @intFromPtr(state) },
                    .{ .name = "sideshowdb_host_result_len", .callback = hostResultLen, .context = @intFromPtr(state) },
                    .{ .name = "sideshowdb_host_version_ptr", .callback = hostVersionPtr, .context = @intFromPtr(state) },
                    .{ .name = "sideshowdb_host_version_len", .callback = hostVersionLen, .context = @intFromPtr(state) },
                } },
            },
        };

        const wasm = try zwasm.WasmModule.loadWithImports(gpa, wasm_bytes, &imports);
        errdefer wasm.deinit();
        wasm.force_interpreter = true;

        const scratch_base = try computeScratchBase(wasm);
        const mem = try wasm.instance.getMemory(0);
        const mem_len = mem.memory().len;
        const min_required = @as(u64, scratch_base) + (48 * 1024);
        if (min_required > mem_len) return error.OutOfBoundsMemoryAccess;

        state.guest_request_offset = scratch_base;
        state.guest_result_offset = scratch_base + (16 * 1024);
        state.guest_version_offset = scratch_base + (32 * 1024);

        return .{
            .gpa = gpa,
            .state = state,
            .wasm_bytes = wasm_bytes,
            .wasm = wasm,
        };
    }

    fn deinit(self: *WasmHarness) void {
        if (self.last_result.len != 0) self.gpa.free(self.last_result);
        self.wasm.deinit();
        self.gpa.free(self.wasm_bytes);
        self.state.deinit();
        self.gpa.destroy(self.state);
    }

    fn putDocument(self: *WasmHarness, doc_type: []const u8, id: []const u8, json: []const u8) !void {
        const request = try allocPutRequest(self.gpa, doc_type, id, json);
        defer self.gpa.free(request);

        const status = try self.invokeStatus("sideshowdb_document_put", request);
        try std.testing.expectEqual(@as(u32, 0), status);
    }

    fn callDocumentList(self: *WasmHarness, request: []const u8) !u32 {
        return self.invokeStatus("sideshowdb_document_list", request);
    }

    fn callDocumentDelete(self: *WasmHarness, request: []const u8) !u32 {
        return self.invokeStatus("sideshowdb_document_delete", request);
    }

    fn callDocumentHistory(self: *WasmHarness, request: []const u8) !u32 {
        return self.invokeStatus("sideshowdb_document_history", request);
    }

    fn requestBufferPtr(self: *WasmHarness) !u32 {
        return self.invokeScalar("sideshowdb_request_ptr");
    }

    fn requestBufferLen(self: *WasmHarness) !u32 {
        return self.invokeScalar("sideshowdb_request_len");
    }

    fn resultBytes(self: *WasmHarness) ![]const u8 {
        if (self.last_result.len != 0) {
            self.gpa.free(self.last_result);
            self.last_result = &.{};
        }

        const ptr = try self.invokeScalar("sideshowdb_result_ptr");
        const len = try self.invokeScalar("sideshowdb_result_len");
        const wasm_result = try self.wasm.memoryRead(self.gpa, @intCast(ptr), @intCast(len));
        defer self.gpa.free(wasm_result);
        self.last_result = try self.gpa.dupe(u8, wasm_result);
        return self.last_result;
    }

    fn invokeScalar(self: *WasmHarness, name: []const u8) !u32 {
        var results = [_]u64{0};
        try self.wasm.invoke(name, &.{}, &results);
        return @truncate(results[0]);
    }

    fn invokeStatus(self: *WasmHarness, name: []const u8, request: []const u8) !u32 {
        const request_ptr = try self.requestBufferPtr();
        const request_len = try self.requestBufferLen();

        try std.testing.expect(request_len >= request.len);
        return self.invokeStatusWithPtr(name, request_ptr, request);
    }

    fn writeRequestAt(self: *WasmHarness, ptr: u32, request: []const u8) !void {
        try self.wasm.memoryWrite(ptr, request);
    }

    fn invokeStatusWithPtr(self: *WasmHarness, name: []const u8, ptr: u32, request: []const u8) !u32 {
        try self.writeRequestAt(ptr, request);
        var args = [_]u64{
            ptr,
            request.len,
        };
        return self.invokeStatusAt(name, &args);
    }

    fn invokeStatusAt(self: *WasmHarness, name: []const u8, args: *const [2]u64) !u32 {
        var results = [_]u64{0};
        try self.wasm.invoke(name, args, &results);
        return @truncate(results[0]);
    }
};

fn allocPutRequest(
    gpa: std.mem.Allocator,
    doc_type: []const u8,
    id: []const u8,
    json: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    var stringify: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };
    try stringify.write(.{
        .type = doc_type,
        .id = id,
        .json = json,
    });
    return out.toOwnedSlice();
}

fn computeScratchBase(wasm: *zwasm.WasmModule) !u32 {
    if (wasm.instance.getExportGlobalAddr("__heap_base")) |addr| {
        const global = try wasm.store.getGlobal(addr);
        const value: u32 = @intCast(global.value);
        return std.mem.alignForward(u32, value, 16);
    }
    return 64 * 1024;
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(std.math.maxInt(usize)));
}

fn stateFromContext(context: usize) *HostState {
    return @ptrFromInt(context);
}

fn hostRefPut(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const state = stateFromContext(context);

    const value_len = vm.popOperandU32();
    const value_ptr = vm.popOperandU32();
    const key_len = vm.popOperandU32();
    const key_ptr = vm.popOperandU32();

    const key = try HostState.readGuestBytes(vm, key_ptr, key_len);
    const value = try HostState.readGuestBytes(vm, value_ptr, value_len);
    const version = try state.refStore().put(state.gpa, key, value);
    defer state.gpa.free(version);

    try state.setHostBuffers("", version);
    try vm.pushOperand(0);
}

fn hostRefGet(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const state = stateFromContext(context);

    const version_len = vm.popOperandU32();
    const version_ptr = vm.popOperandU32();
    const key_len = vm.popOperandU32();
    const key_ptr = vm.popOperandU32();

    const key = try HostState.readGuestBytes(vm, key_ptr, key_len);
    const version = if (version_ptr == 0 or version_len == 0)
        null
    else
        try HostState.readGuestBytes(vm, version_ptr, version_len);

    const read_result = try state.refStore().get(state.gpa, key, version);
    if (read_result) |resolved| {
        defer sideshowdb.RefStore.freeReadResult(state.gpa, resolved);
        try state.setHostBuffers(resolved.value, resolved.version);
        try vm.pushOperand(0);
        return;
    }

    state.freeHostBuffers();
    try vm.pushOperand(1);
}

fn hostRefDelete(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const state = stateFromContext(context);

    const key_len = vm.popOperandU32();
    const key_ptr = vm.popOperandU32();
    const key = try HostState.readGuestBytes(vm, key_ptr, key_len);

    try state.refStore().delete(key);
    state.freeHostBuffers();
    try vm.pushOperand(0);
}

fn hostRefList(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const state = stateFromContext(context);

    const keys = try state.refStore().list(state.gpa);
    defer sideshowdb.RefStore.freeKeys(state.gpa, keys);

    try state.setResultJson(keys);
    try vm.pushOperand(0);
}

fn hostRefHistory(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const state = stateFromContext(context);

    const key_len = vm.popOperandU32();
    const key_ptr = vm.popOperandU32();
    const key = try HostState.readGuestBytes(vm, key_ptr, key_len);

    const versions = try state.refStore().history(state.gpa, key);
    defer sideshowdb.RefStore.freeVersions(state.gpa, versions);

    try state.setResultJson(versions);
    try vm.pushOperand(0);
}

fn hostResultPtr(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const state = stateFromContext(context);
    const offset = try state.writeGuestBytes(vm, state.guest_result_offset, state.host_result);
    try vm.pushOperand(offset);
}

fn hostResultLen(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const state = stateFromContext(context);
    try vm.pushOperand(state.host_result.len);
}

fn hostVersionPtr(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const state = stateFromContext(context);
    const offset = try state.writeGuestBytes(vm, state.guest_version_offset, state.host_version);
    try vm.pushOperand(offset);
}

fn hostVersionLen(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));
    const state = stateFromContext(context);
    try vm.pushOperand(state.host_version.len);
}

test "compiled wasm exposes explicit request buffer exports" {
    var harness = try WasmHarness.init(std.testing.allocator, std.testing.io);
    defer harness.deinit();

    const request_ptr = try harness.requestBufferPtr();
    const request_len = try harness.requestBufferLen();

    try std.testing.expect(request_ptr > 0);
    try std.testing.expect(request_len >= 4096);
}

test "compiled wasm list accepts requests written through explicit request buffer" {
    var ctx = try WasmHarness.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try ctx.putDocument("issue", "buffered", "{\"title\":\"buffered\"}");

    const request = "{\"mode\":\"summary\"}";
    const request_ptr = try ctx.requestBufferPtr();
    const request_len = try ctx.requestBufferLen();

    try std.testing.expect(request_len >= request.len);
    const status = try ctx.invokeStatusWithPtr("sideshowdb_document_list", request_ptr, request);
    try std.testing.expectEqual(@as(u32, 0), status);
    try std.testing.expect(std.mem.indexOf(u8, try ctx.resultBytes(), "\"kind\":\"summary\"") != null);
}

test "compiled wasm rejects document requests outside explicit request buffer" {
    var ctx = try WasmHarness.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const request = "{\"mode\":\"summary\"}";
    const request_ptr = try ctx.requestBufferPtr();
    const request_len = try ctx.requestBufferLen();
    const invalid_ptr = request_ptr + request_len;

    const status = try ctx.invokeStatusWithPtr("sideshowdb_document_list", invalid_ptr, request);
    try std.testing.expectEqual(@as(u32, 1), status);
}

test "compiled wasm clears result payload after invalid request pointer failure" {
    var ctx = try WasmHarness.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try ctx.putDocument("issue", "stale-result", "{\"title\":\"stale-result\"}");

    const valid_status = try ctx.callDocumentList("{\"mode\":\"summary\"}");
    try std.testing.expectEqual(@as(u32, 0), valid_status);
    try std.testing.expect(std.mem.indexOf(u8, try ctx.resultBytes(), "\"kind\":\"summary\"") != null);

    const request = "{\"mode\":\"summary\"}";
    const request_ptr = try ctx.requestBufferPtr();
    const request_len = try ctx.requestBufferLen();
    const invalid_ptr = request_ptr + request_len;

    const invalid_status = try ctx.invokeStatusWithPtr("sideshowdb_document_list", invalid_ptr, request);
    try std.testing.expectEqual(@as(u32, 1), invalid_status);
    try std.testing.expectEqual(@as(u32, 0), try ctx.invokeScalar("sideshowdb_result_len"));
    try std.testing.expectEqualStrings("", try ctx.resultBytes());
}

test "compiled wasm list replaces previous result payload" {
    var ctx = try WasmHarness.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try ctx.putDocument("issue", "alpha", "{\"title\":\"alpha\"}");

    const first_status = try ctx.callDocumentList("{\"mode\":\"summary\"}");
    try std.testing.expectEqual(@as(u32, 0), first_status);
    try std.testing.expect(std.mem.indexOf(u8, try ctx.resultBytes(), "\"kind\":\"summary\"") != null);

    const second_status = try ctx.callDocumentDelete("{\"type\":\"issue\",\"id\":\"alpha\"}");
    try std.testing.expectEqual(@as(u32, 0), second_status);
    try std.testing.expect(std.mem.indexOf(u8, try ctx.resultBytes(), "\"deleted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, try ctx.resultBytes(), "\"kind\":\"summary\"") == null);
}

test "compiled wasm history resolves traversal host imports" {
    var ctx = try WasmHarness.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try ctx.putDocument("issue", "hist-1", "{\"title\":\"first\"}");
    try ctx.putDocument("issue", "hist-1", "{\"title\":\"second\"}");

    const status = try ctx.callDocumentHistory(
        "{\"type\":\"issue\",\"id\":\"hist-1\",\"mode\":\"detailed\"}",
    );
    try std.testing.expectEqual(@as(u32, 0), status);
    try std.testing.expect(std.mem.indexOf(u8, try ctx.resultBytes(), "second") != null);
}

test "compiled wasm get uses distinct not-found status" {
    var ctx = try WasmHarness.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const status = try ctx.invokeStatus(
        "sideshowdb_document_get",
        "{\"type\":\"issue\",\"id\":\"missing\"}",
    );
    try std.testing.expectEqual(@as(u32, 2), status);
    try std.testing.expectEqual(@as(u32, 0), try ctx.invokeScalar("sideshowdb_result_len"));
}

test "compiled wasm get uses failure status for malformed requests" {
    var ctx = try WasmHarness.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    const status = try ctx.invokeStatus(
        "sideshowdb_document_get",
        "{\"id\":\"missing\"}",
    );
    try std.testing.expectEqual(@as(u32, 1), status);
    try std.testing.expectEqualStrings("", try ctx.resultBytes());
}
