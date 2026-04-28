# WASM Boundary Test Depth And Mainline Sync Implementation Plan

**Status:** Implemented on `sideshowdb-psy`. The branch now includes the `origin/main` merge, `zwasm`-backed real-wasm export coverage, traversal host-import support in `ImportedRefStore`, and a passing full verification run via `zig build test --summary all` (`19/19 steps succeeded; 29/29 tests passed`).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the latest `origin/main` into `sideshowdb-psy`, then add `zwasm`-backed tests that execute the real compiled WASM artifact and cover the missing traversal host support behind the document exports.

**Architecture:** Sync the branch first so new work lands on current mainline behavior. Then add `zwasm` as a Zig dependency, compile the real `src/wasm/root.zig` artifact for tests, and drive it through real host imports backed by a temporary `DocumentStore`. Fill in the missing traversal imports used by `ImportedRefStore` so the real module can satisfy `list`, `delete`, and `history`.

**Tech Stack:** Zig 0.16, `zig build test`, `zwasm`, Git-backed `DocumentStore`, `wasm32-freestanding` browser module, beads (`bd`)

---

## File Structure

- Modify: `build.zig`
  Responsibility: register the `zwasm`-backed runtime test module and any test-only wasm build artifacts in the existing test step.
- Modify: `build.zig.zon`
  Responsibility: declare the `zwasm` dependency for the Zig build graph.
- Modify: `src/wasm/imported_ref_store.zig`
  Responsibility: add `delete`, `list`, and `history` support via real host imports while keeping `put/get` behavior unchanged.
- Create: `tests/wasm_exports_test.zig`
  Responsibility: compile/load the real wasm module with `zwasm`, provide host imports, and assert on export status/result-buffer semantics.
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

## Task 2: Add `zwasm` And The Failing Real-WASM Tests

**Files:**
- Modify: `build.zig.zon`
- Modify: `build.zig`
- Create: `tests/wasm_exports_test.zig`

- [ ] **Step 1: Add the `zwasm` dependency to `build.zig.zon`**

```bash
zig fetch --save https://github.com/clojurewasm/zwasm/archive/refs/tags/v1.11.0.tar.gz
```

Expected: `build.zig.zon` gains a new `zwasm` entry under `.dependencies`
with the resolved Zig package hash.

- [ ] **Step 2: Register the dependency and wasm export test module in `build.zig`**

Wire the dependency into a test module that can both load the wasm artifact and
reuse the core library types:

```zig
    const zwasm_dep = b.dependency("zwasm", .{
        .target = target,
        .optimize = optimize,
    });

    const wasm_exports_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wasm_exports_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
            .{ .name = "zwasm", .module = zwasm_dep.module("zwasm") },
        },
    });
    const wasm_exports_tests = b.addTest(.{ .root_module = wasm_exports_test_mod });
    const run_wasm_exports_tests = b.addRunArtifact(wasm_exports_tests);
    test_step.dependOn(&run_wasm_exports_tests.step);
```

- [ ] **Step 3: Write the failing real-WASM export tests**

```zig
const std = @import("std");
const sideshowdb = @import("sideshowdb");
const zwasm = @import("zwasm");

test "compiled wasm list replaces previous result payload" {
    var ctx = try WasmHarness.init(std.testing.allocator, std.testing.io);
    defer ctx.deinit();

    try ctx.putDocument("issue", "alpha", "{\"title\":\"alpha\"}");

    const first_status = try ctx.callDocumentList("{\"mode\":\"summary\"}");
    try std.testing.expectEqual(@as(u32, 0), first_status);
    try std.testing.expect(std.mem.indexOf(u8, ctx.resultBytes(), "\"kind\":\"summary\"") != null);

    const second_status = try ctx.callDocumentDelete("{\"type\":\"issue\",\"id\":\"alpha\"}");
    try std.testing.expectEqual(@as(u32, 0), second_status);
    try std.testing.expect(std.mem.indexOf(u8, ctx.resultBytes(), "\"deleted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.resultBytes(), "\"kind\":\"summary\"") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, ctx.resultBytes(), "second") != null);
}
```

- [ ] **Step 4: Run the full suite to verify the new tests fail for the right reason**

Run: `zig build test --summary failures`
Expected: FAIL because the real wasm harness cannot yet satisfy the missing
traversal imports or because the new test module cannot instantiate the module
successfully.

- [ ] **Step 5: Commit the failing tests**

```bash
git add build.zig build.zig.zon tests/wasm_exports_test.zig
git commit -m "test: add zwasm export coverage"
```

## Task 3: Make The Real WASM Traversal Imports Work

**Files:**
- Modify: `src/wasm/imported_ref_store.zig`
- Test: `tests/wasm_exports_test.zig`

- [ ] **Step 1: Add the missing host extern declarations**

```zig
extern fn sideshowdb_host_ref_delete(
    key_ptr: [*]const u8,
    key_len: usize,
) i32;

extern fn sideshowdb_host_ref_list() i32;

extern fn sideshowdb_host_ref_history(
    key_ptr: [*]const u8,
    key_len: usize,
) i32;
```

- [ ] **Step 2: Implement `delete`, `list`, and `history` in `ImportedRefStore`**

```zig
    const vtable: RefStore.VTable = .{
        .put = putImpl,
        .get = getImpl,
        .delete = deleteImpl,
        .list = listImpl,
        .history = historyImpl,
    };

    fn deleteImpl(_: *anyopaque, key: []const u8) anyerror!void {
        const status = sideshowdb_host_ref_delete(key.ptr, key.len);
        if (status != 0) return error.HostOperationFailed;
    }

    fn listImpl(_: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        if (sideshowdb_host_ref_list() != 0) return error.HostOperationFailed;
        const json = try copyHostBuffer(gpa);
        defer gpa.free(json);
        return parseKeyArray(gpa, json);
    }

    fn historyImpl(_: *anyopaque, gpa: Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        if (sideshowdb_host_ref_history(key.ptr, key.len) != 0) return error.HostOperationFailed;
        const json = try copyHostBuffer(gpa);
        defer gpa.free(json);
        return parseVersionArray(gpa, json);
    }
```

- [ ] **Step 3: Add the JSON array parsers used by traversal imports**

```zig
fn parseKeyArray(gpa: Allocator, json: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.HostOperationFailed;

    var keys: std.ArrayList([]u8) = .empty;
    errdefer {
        for (keys.items) |key| gpa.free(key);
        keys.deinit(gpa);
    }
    for (parsed.value.array.items) |item| {
        if (item != .string) return error.HostOperationFailed;
        try keys.append(gpa, try gpa.dupe(u8, item.string));
    }
    return keys.toOwnedSlice(gpa);
}
```

- [ ] **Step 4: Run the suite to verify the harness reaches real runtime behavior**

Run: `zig build test --summary failures`
Expected: FAIL only on harness ABI/setup issues or missing host callbacks in the
test harness, not on unresolved traversal imports inside the compiled module.

- [ ] **Step 5: Commit the traversal import support**

```bash
git add src/wasm/imported_ref_store.zig tests/wasm_exports_test.zig
git commit -m "feat(wasm): add traversal host imports"
```

## Task 4: Finish The `zwasm` Harness And Make The Tests Pass

**Files:**
- Modify: `build.zig`
- Modify: `tests/wasm_exports_test.zig`

- [ ] **Step 1: Build or stage the real wasm artifact for the test harness**

```zig
    const wasm_test_build = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "test-wasm" } },
    });
    run_wasm_exports_tests.step.dependOn(&wasm_test_build.step);
```

- [ ] **Step 2: Implement the `zwasm` test harness helpers**

```zig
fn instantiateModule(gpa: std.mem.Allocator, wasm_path: []const u8) !zwasm.WasmModule {
    const bytes = try std.fs.cwd().readFileAlloc(gpa, wasm_path, 16 * 1024 * 1024);
    defer gpa.free(bytes);
    return zwasm.WasmModule.loadWithImports(gpa, bytes, imports);
}

fn callExport(self: *WasmHarness, name: []const u8, request_json: []const u8) !u32 {
    const ptr = try self.writeRequest(request_json);
    const results = try self.module.invoke(name, .{
        .params = &.{ .{ .i32 = @intCast(ptr) }, .{ .i32 = @intCast(request_json.len) } },
    });
    return @intCast(results[0].i32);
}
```

- [ ] **Step 3: Provide host callbacks backed by a real `DocumentStore`**

```zig
fn hostRefList(ctx: *HostContext) !i32 {
    const keys = try ctx.store.ref_store.list(ctx.gpa);
    defer sideshowdb.RefStore.freeKeys(ctx.gpa, keys);
    try ctx.setResultJsonFromKeys(keys);
    return 0;
}

fn hostRefHistory(ctx: *HostContext, key: []const u8) !i32 {
    const versions = try ctx.store.ref_store.history(ctx.gpa, key);
    defer sideshowdb.RefStore.freeVersions(ctx.gpa, versions);
    try ctx.setResultJsonFromVersions(versions);
    return 0;
}
```

- [ ] **Step 4: Run the full suite to verify the real wasm tests pass**

Run: `zig build test --summary all`
Expected: PASS, including the new `zwasm`-backed export tests.

- [ ] **Step 5: Commit the harness**

```bash
git add build.zig build.zig.zon tests/wasm_exports_test.zig
git commit -m "test(wasm): execute exports with zwasm"
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
