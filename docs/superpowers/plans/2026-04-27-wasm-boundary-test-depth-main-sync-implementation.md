# WASM Boundary Test Depth And Mainline Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the latest `origin/main` into `sideshowdb-psy`, then add real WASM-boundary test coverage and the missing host-bridge traversal support behind the document WASM exports.

**Architecture:** Sync the branch first so new work lands on current mainline behavior. Then split the WASM follow-up into two focused seams: a native-testable document dispatch helper that owns result-buffer semantics, and a host API abstraction that lets `ImportedRefStore` support `list`, `delete`, and `history` while remaining testable without a freestanding runtime.

**Tech Stack:** Zig 0.16, `zig build test`, Git-backed `DocumentStore`, WASM export wrappers in `src/wasm`, beads (`bd`)

---

## File Structure

- Modify: `build.zig`
  Responsibility: register the new native WASM-focused test module in the existing test step.
- Create: `src/wasm/document_runtime.zig`
  Responsibility: centralize request dispatch + result-sink updates for `put/get/list/delete/history`, callable by both `root.zig` and native tests.
- Create: `src/wasm/host_api.zig`
  Responsibility: define the host bridge function-pointer surface and provide the default extern-backed implementation used by the real WASM build.
- Modify: `src/wasm/imported_ref_store.zig`
  Responsibility: consume `host_api.zig`, add `delete`, `list`, and `history`, and keep `put/get` behavior unchanged.
- Modify: `src/wasm/root.zig`
  Responsibility: delegate exported document operations to `document_runtime.zig` while preserving the public export names and result buffer symbols.
- Create: `tests/wasm_document_runtime_test.zig`
  Responsibility: prove WASM-boundary dispatch status codes, result-buffer replacement, and host-backed traversal behavior with native tests.
- Modify: `docs/superpowers/specs/2026-04-27-wasm-boundary-test-depth-main-sync-design.md`
  Responsibility: update status or brief implementation notes if needed after the work lands.

## Task 1: Merge `origin/main` And Stabilize The Branch

**Files:**
- Modify: merge-conflicted files as needed after `origin/main` lands
- Verify: `zig build test`

- [ ] **Step 1: Merge `origin/main` into the branch**

```bash
git fetch origin
git merge origin/main
```

- [ ] **Step 2: Inspect the merge result**

Run: `git status --short`
Expected: either a clean merge or a small set of conflicted files marked with `UU`.

- [ ] **Step 3: Resolve any merge conflicts without changing feature behavior**

Prefer keeping:

```text
- document traversal files from `sideshowdb-psy`
- newer shared build/docs changes from `origin/main`
```

For any conflict in `build.zig`, preserve the current test registrations and append new ones rather than deleting mainline steps.

- [ ] **Step 4: Run the full suite to verify the merge is stable before new work**

Run: `zig build test --summary all`
Expected: PASS on the merged branch before adding new tests.

- [ ] **Step 5: Commit the merge**

```bash
git add build.zig src tests docs
git commit -m "merge: bring origin/main into sideshowdb-psy"
```

## Task 2: Add The Failing Native WASM Boundary Tests

**Files:**
- Create: `tests/wasm_document_runtime_test.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write the failing native boundary tests**

```zig
const std = @import("std");
const sideshowdb = @import("sideshowdb");
const wasm_runtime = @import("sideshowdb_wasm_runtime");

test "document runtime list replaces the previous result payload" {
    var ctx = try TestContext.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit(std.testing.allocator);

    _ = try ctx.document_store.put(std.testing.allocator, .{ .payload = .{
        .json = "{\"title\":\"alpha\"}",
        .doc_type = "issue",
        .id = "alpha",
    } });

    var sink = wasm_runtime.TestResultSink.init(std.testing.allocator);
    defer sink.deinit();

    const first_status = try wasm_runtime.handleList(
        std.testing.allocator,
        ctx.document_store,
        "{\"mode\":\"summary\"}",
        sink.sink(),
    );
    try std.testing.expectEqual(@as(u32, 0), first_status);
    try std.testing.expect(std.mem.indexOf(u8, sink.bytes(), "\"kind\":\"summary\"") != null);

    const second_status = try wasm_runtime.handleDelete(
        std.testing.allocator,
        ctx.document_store,
        "{\"type\":\"issue\",\"id\":\"alpha\"}",
        sink.sink(),
    );
    try std.testing.expectEqual(@as(u32, 0), second_status);
    try std.testing.expect(std.mem.indexOf(u8, sink.bytes(), "\"deleted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.bytes(), "\"kind\":\"summary\"") == null);
}

test "imported ref store forwards traversal calls through the host api" {
    var host = FakeHostApi.init(std.testing.allocator);
    defer host.deinit();

    var imported = wasm_runtime.testingImportedRefStore(host.api());
    const rs = imported.refStore();

    const keys = try rs.list(std.testing.allocator);
    defer sideshowdb.RefStore.freeKeys(std.testing.allocator, keys);
    try std.testing.expectEqual(@as(usize, 1), keys.len);

    const versions = try rs.history(std.testing.allocator, "default/issue/a.json");
    defer sideshowdb.RefStore.freeVersions(std.testing.allocator, versions);
    try std.testing.expectEqual(@as(usize, 2), versions.len);

    try rs.delete("default/issue/a.json");
    try std.testing.expect(host.deleted_called);
}
```

- [ ] **Step 2: Register the new test module in `build.zig`**

Add a native test module with imports for the core library and the new wasm helper modules:

```zig
    const wasm_runtime_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wasm_document_runtime_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
            .{ .name = "sideshowdb_wasm_runtime", .module = b.createModule(.{
                .root_source_file = b.path("src/wasm/document_runtime.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sideshowdb", .module = core_mod },
                },
            }) },
        },
    });
    const wasm_runtime_tests = b.addTest(.{ .root_module = wasm_runtime_test_mod });
    const run_wasm_runtime_tests = b.addRunArtifact(wasm_runtime_tests);
    test_step.dependOn(&run_wasm_runtime_tests.step);
```

- [ ] **Step 3: Run the full suite to verify the new tests fail for the right reason**

Run: `zig build test --summary failures`
Expected: FAIL with missing `document_runtime.zig` symbols and/or missing traversal methods on `ImportedRefStore`.

- [ ] **Step 4: Commit the failing tests**

```bash
git add build.zig tests/wasm_document_runtime_test.zig
git commit -m "test: add wasm document boundary coverage"
```

## Task 3: Make The Host Bridge Traversal-Capable

**Files:**
- Create: `src/wasm/host_api.zig`
- Modify: `src/wasm/imported_ref_store.zig`
- Test: `tests/wasm_document_runtime_test.zig`

- [ ] **Step 1: Write the host API abstraction**

```zig
const std = @import("std");

pub const HostApi = struct {
    ref_put: *const fn ([*]const u8, usize, [*]const u8, usize) i32,
    ref_get: *const fn ([*]const u8, usize, ?[*]const u8, usize) i32,
    ref_delete: *const fn ([*]const u8, usize) i32,
    ref_list: *const fn () i32,
    ref_history: *const fn ([*]const u8, usize) i32,
    result_ptr: *const fn () [*]const u8,
    result_len: *const fn () usize,
    version_ptr: *const fn () [*]const u8,
    version_len: *const fn () usize,
};

pub fn defaultHostApi() HostApi {
    return .{
        .ref_put = sideshowdb_host_ref_put,
        .ref_get = sideshowdb_host_ref_get,
        .ref_delete = sideshowdb_host_ref_delete,
        .ref_list = sideshowdb_host_ref_list,
        .ref_history = sideshowdb_host_ref_history,
        .result_ptr = sideshowdb_host_result_ptr,
        .result_len = sideshowdb_host_result_len,
        .version_ptr = sideshowdb_host_version_ptr,
        .version_len = sideshowdb_host_version_len,
    };
}
```

- [ ] **Step 2: Refactor `ImportedRefStore` to depend on `HostApi` and add traversal methods**

```zig
pub const ImportedRefStore = struct {
    host_api: host_api.HostApi = host_api.defaultHostApi(),

    pub fn refStore(self: *ImportedRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: RefStore.VTable = .{
        .put = putImpl,
        .get = getImpl,
        .delete = deleteImpl,
        .list = listImpl,
        .history = historyImpl,
    };

    fn deleteImpl(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *ImportedRefStore = @ptrCast(@alignCast(ctx));
        const status = self.host_api.ref_delete(key.ptr, key.len);
        if (status != 0) return error.HostOperationFailed;
    }

    fn listImpl(ctx: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        const self: *ImportedRefStore = @ptrCast(@alignCast(ctx));
        if (self.host_api.ref_list() != 0) return error.HostOperationFailed;
        const json = try copyHostBuffer(self, gpa);
        defer gpa.free(json);
        return parseKeyArray(gpa, json);
    }

    fn historyImpl(ctx: *anyopaque, gpa: Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        const self: *ImportedRefStore = @ptrCast(@alignCast(ctx));
        if (self.host_api.ref_history(key.ptr, key.len) != 0) return error.HostOperationFailed;
        const json = try copyHostBuffer(self, gpa);
        defer gpa.free(json);
        return parseVersionArray(gpa, json);
    }
};
```

- [ ] **Step 3: Run the suite to verify the host-bridge test moves from compile failure to runtime coverage**

Run: `zig build test --summary failures`
Expected: FAIL only on the missing `document_runtime` helper or result-sink behavior, not on missing `ImportedRefStore` traversal support.

- [ ] **Step 4: Commit the host bridge changes**

```bash
git add src/wasm/host_api.zig src/wasm/imported_ref_store.zig tests/wasm_document_runtime_test.zig
git commit -m "feat(wasm): add traversal host bridge support"
```

## Task 4: Add The Shared WASM Document Runtime Helper

**Files:**
- Create: `src/wasm/document_runtime.zig`
- Modify: `src/wasm/root.zig`
- Test: `tests/wasm_document_runtime_test.zig`

- [ ] **Step 1: Implement the result sink and request handlers**

```zig
const std = @import("std");
const sideshowdb = @import("sideshowdb");

pub const ResultSink = struct {
    ctx: *anyopaque,
    replace: *const fn (ctx: *anyopaque, bytes: []u8) anyerror!void,
};

pub fn handleList(
    gpa: std.mem.Allocator,
    store: sideshowdb.DocumentStore,
    request_json: []const u8,
    sink: ResultSink,
) !u32 {
    const response = try sideshowdb.document_transport.handleList(gpa, store, request_json);
    try sink.replace(sink.ctx, response);
    return 0;
}

pub fn handleDelete(
    gpa: std.mem.Allocator,
    store: sideshowdb.DocumentStore,
    request_json: []const u8,
    sink: ResultSink,
) !u32 {
    const response = try sideshowdb.document_transport.handleDelete(gpa, store, request_json);
    try sink.replace(sink.ctx, response);
    return 0;
}

pub fn handleHistory(
    gpa: std.mem.Allocator,
    store: sideshowdb.DocumentStore,
    request_json: []const u8,
    sink: ResultSink,
) !u32 {
    const response = try sideshowdb.document_transport.handleHistory(gpa, store, request_json);
    try sink.replace(sink.ctx, response);
    return 0;
}
```

- [ ] **Step 2: Refactor `root.zig` to delegate to the shared helper**

```zig
const runtime = @import("document_runtime.zig");

fn resultSink() runtime.ResultSink {
    return .{
        .ctx = undefined,
        .replace = replaceResult,
    };
}

fn replaceResult(_: *anyopaque, new_result: []u8) !void {
    setResult(new_result);
}

export fn sideshowdb_document_list(request_ptr: [*]const u8, request_len: usize) u32 {
    return runtime.handleList(
        std.heap.wasm_allocator,
        wasmStore(),
        request_ptr[0..request_len],
        resultSink(),
    ) catch 1;
}
```

- [ ] **Step 3: Add the native test sink used by the new tests**

```zig
pub const TestResultSink = struct {
    gpa: std.mem.Allocator,
    bytes_storage: []u8 = &.{},

    pub fn init(gpa: std.mem.Allocator) TestResultSink {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TestResultSink) void {
        if (self.bytes_storage.len != 0) self.gpa.free(self.bytes_storage);
    }

    pub fn sink(self: *TestResultSink) ResultSink {
        return .{
            .ctx = self,
            .replace = replaceImpl,
        };
    }

    fn replaceImpl(ctx: *anyopaque, bytes: []u8) !void {
        const self: *TestResultSink = @ptrCast(@alignCast(ctx));
        if (self.bytes_storage.len != 0) self.gpa.free(self.bytes_storage);
        self.bytes_storage = bytes;
    }
};
```

- [ ] **Step 4: Run the full suite to verify the new boundary tests pass**

Run: `zig build test --summary all`
Expected: PASS, including the new native WASM-boundary test module.

- [ ] **Step 5: Commit the runtime helper**

```bash
git add src/wasm/document_runtime.zig src/wasm/root.zig tests/wasm_document_runtime_test.zig build.zig
git commit -m "test(wasm): cover document export boundary"
```

## Task 5: Final Verification And Cleanup

**Files:**
- Modify: `docs/superpowers/specs/2026-04-27-wasm-boundary-test-depth-main-sync-design.md`
- Verify: repo state only

- [ ] **Step 1: Update the design doc status if implementation notes are useful**

```markdown
Status: Implemented
```

Only do this if the team wants the spec status to reflect shipped work.

- [ ] **Step 2: Run the full suite one final time**

Run: `zig build test --summary all`
Expected: PASS with the merged branch and new WASM-boundary coverage.

- [ ] **Step 3: Inspect the worktree**

Run: `git status --short`
Expected: only intended source/test/doc changes are present; do not stage `docs/superpowers/.DS_Store`.

- [ ] **Step 4: Push branch updates and beads state**

```bash
bd dolt push
git push
```

- [ ] **Step 5: Commit any final doc touch-ups**

```bash
git add docs/superpowers/specs/2026-04-27-wasm-boundary-test-depth-main-sync-design.md
git commit -m "docs: update wasm boundary test design status"
```

Only create this commit if the doc changed in Step 1.
