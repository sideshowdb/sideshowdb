# Native RefStore Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prototype a zero-subprocess native `RefStore` backend by attempting full parity with `ziggit`, preserving current version semantics, and producing a documented fallback path if `ziggit` is not viable.

**Architecture:** First lock the contract with reusable parity tests and backend EARS so the current subprocess store becomes the baseline oracle. Then add a second concrete `RefStore` implementation for `ziggit`, prove or disprove its viability against the parity suite, and document the decision. If the dependency cannot satisfy full-parity writes and ref updates, stop the `ziggit` code path cleanly and use the report to drive a separate `libgit2` implementation pass.

**Tech Stack:** Zig 0.16, `zig build test`, `RefStore`, `DocumentStore`, `zwasm`, `zig fetch`, Git-backed test repos, beads (`bd`)

---

## File Map

- Create: `docs/development/specs/native-refstore-backend-ears.md`
  Responsibility: capture backend-facing EARS for parity, fallback reporting, and WASM behavior preservation.
- Create: `docs/development/reports/2026-04-28-ziggit-viability-report.md`
  Responsibility: record viability findings, missing capabilities, and next-step recommendation.
- Create: `tests/ref_store_parity.zig`
  Responsibility: reusable parity harness shared by subprocess and native backend tests.
- Create: `tests/ziggit_ref_store_test.zig`
  Responsibility: run the parity harness against the `ziggit` candidate backend.
- Modify: `tests/git_ref_store_test.zig`
  Responsibility: switch the subprocess backend tests onto the shared parity harness so the baseline behavior is encoded once.
- Create: `src/core/storage/ziggit_ref_store.zig`
  Responsibility: second concrete `RefStore` implementation for the `ziggit` exercise.
- Modify: `src/core/storage.zig`
  Responsibility: re-export `ZiggitRefStore` on non-freestanding targets.
- Modify: `src/core/root.zig`
  Responsibility: surface `ZiggitRefStore` from the public core module.
- Modify: `build.zig.zon`
  Responsibility: add the `ziggit` package dependency.
- Modify: `build.zig`
  Responsibility: register the `ziggit`-backed test module in the standard `zig build test` step.

## Task 1: Lock The Parity Contract

**Files:**
- Create: `docs/development/specs/native-refstore-backend-ears.md`
- Create: `tests/ref_store_parity.zig`
- Modify: `tests/git_ref_store_test.zig`
- Test: `tests/git_ref_store_test.zig`

- [ ] **Step 1: Write the backend EARS document**

```md
# Native RefStore Backend EARS

## Purpose

This document captures the required observable behavior for any zero-subprocess
native `RefStore` backend evaluated for sideshowdb.

## EARS

- The native backend shall preserve `put`, `get`, `delete`, `list`, and
  `history` behavior exposed by the existing `RefStore` contract.
- When a caller reads without an explicit version, the native backend shall
  return the value reachable from the current tip of the configured ref.
- When a caller reads with an explicit version, the native backend shall return
  the value reachable from that Git commit SHA or not-found if the key is not
  present there.
- When a caller writes a value, the native backend shall create a new reachable
  Git commit and return that commit SHA as the `VersionId`.
- When a caller deletes an existing key, the native backend shall produce a new
  reachable Git commit reflecting the removal.
- If the candidate backend cannot satisfy any full-parity `RefStore`
  requirement, then sideshowdb shall record the findings in repo documentation
  before beginning the fallback exercise.
- The host-backed WASM path shall preserve current result-buffer and
  version-buffer behavior while the native backend exercise is in progress.
```

- [ ] **Step 2: Add a reusable parity harness**

```zig
const std = @import("std");
const sideshowdb = @import("sideshowdb");

pub const Harness = struct {
    gpa: std.mem.Allocator,
    ref_store: sideshowdb.RefStore,
    repo_path: []const u8,
    count_commits: *const fn (ctx: *const anyopaque, repo_path: []const u8) anyerror!u32,
    ctx: *const anyopaque,
};

pub fn exerciseRefStore(h: Harness) !void {
    const rs = h.ref_store;

    {
        const keys = try rs.list(h.gpa);
        defer sideshowdb.RefStore.freeKeys(h.gpa, keys);
        try std.testing.expectEqual(@as(usize, 0), keys.len);
    }
    {
        const v = try rs.get(h.gpa, "a/x.txt", null);
        try std.testing.expect(v == null);
    }
    {
        const versions = try rs.history(h.gpa, "a/x.txt");
        defer sideshowdb.RefStore.freeVersions(h.gpa, versions);
        try std.testing.expectEqual(@as(usize, 0), versions.len);
    }

    const first_version = try rs.put(h.gpa, "a/x.txt", "hello");
    defer h.gpa.free(first_version);
    {
        const v = try rs.get(h.gpa, "a/x.txt", null);
        defer if (v) |r| sideshowdb.RefStore.freeReadResult(h.gpa, r);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("hello", v.?.value);
        try std.testing.expectEqualStrings(first_version, v.?.version);
    }

    const second_version = try rs.put(h.gpa, "a/x.txt", "world");
    defer h.gpa.free(second_version);
    {
        const v = try rs.get(h.gpa, "a/x.txt", null);
        defer if (v) |r| sideshowdb.RefStore.freeReadResult(h.gpa, r);
        try std.testing.expectEqualStrings("world", v.?.value);
        try std.testing.expectEqualStrings(second_version, v.?.version);
    }
    {
        const versions = try rs.history(h.gpa, "a/x.txt");
        defer sideshowdb.RefStore.freeVersions(h.gpa, versions);
        try std.testing.expectEqual(@as(usize, 2), versions.len);
        try std.testing.expectEqualStrings(second_version, versions[0]);
        try std.testing.expectEqualStrings(first_version, versions[1]);
    }

    const third_version = try rs.put(h.gpa, "b/y.txt", "ok");
    defer h.gpa.free(third_version);
    {
        const keys = try rs.list(h.gpa);
        defer sideshowdb.RefStore.freeKeys(h.gpa, keys);
        try std.testing.expectEqual(@as(usize, 2), keys.len);
    }

    try rs.delete("a/x.txt");
    {
        const v = try rs.get(h.gpa, "a/x.txt", null);
        try std.testing.expect(v == null);
    }
    {
        const keys = try rs.list(h.gpa);
        defer sideshowdb.RefStore.freeKeys(h.gpa, keys);
        try std.testing.expectEqual(@as(usize, 1), keys.len);
        try std.testing.expectEqualStrings("b/y.txt", keys[0]);
    }
    {
        const versions = try rs.history(h.gpa, "a/x.txt");
        defer sideshowdb.RefStore.freeVersions(h.gpa, versions);
        try std.testing.expectEqual(@as(usize, 2), versions.len);
        try std.testing.expectEqualStrings(second_version, versions[0]);
        try std.testing.expectEqualStrings(first_version, versions[1]);
    }

    try rs.delete("a/x.txt");

    {
        const v = try rs.get(h.gpa, "a/x.txt", first_version);
        defer if (v) |r| sideshowdb.RefStore.freeReadResult(h.gpa, r);
        try std.testing.expect(v != null);
        try std.testing.expectEqualStrings("hello", v.?.value);
        try std.testing.expectEqualStrings(first_version, v.?.version);
    }

    const commit_count = try h.count_commits(h.ctx, h.repo_path);
    try std.testing.expect(commit_count >= 4);

    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "/leading", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "trailing/", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "a//b", "x"));
    try std.testing.expectError(error.InvalidKey, rs.history(h.gpa, ""));
}
```

- [ ] **Step 3: Refactor the subprocess test to call the parity harness**

```zig
const parity = @import("ref_store_parity.zig");

test "GitRefStore: parity harness" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo_path);

    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    var store = sideshowdb.GitRefStore.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = &env,
        .repo_path = repo_path,
        .ref_name = "refs/sideshowdb/test",
    });

    const Counter = struct {
        fn count(ctx: *const anyopaque, path: []const u8) !u32 {
            const self: *const Environ.Map = @ptrCast(@alignCast(ctx));
            const result = try std.process.run(std.testing.allocator, std.testing.io, .{
                .argv = &.{ "git", "-C", path, "rev-list", "--count", "refs/sideshowdb/test" },
                .environ_map = self,
            });
            defer std.testing.allocator.free(result.stdout);
            defer std.testing.allocator.free(result.stderr);
            const count_str = std.mem.trim(u8, result.stdout, " \n\r");
            return try std.fmt.parseInt(u32, count_str, 10);
        }
    };

    try parity.exerciseRefStore(.{
        .gpa = gpa,
        .ref_store = store.refStore(),
        .repo_path = repo_path,
        .count_commits = Counter.count,
        .ctx = &env,
    });
}
```

- [ ] **Step 4: Run the refactored subprocess parity test**

Run: `zig test tests/git_ref_store_test.zig`
Expected: PASS with the subprocess store still satisfying the shared parity harness.

- [ ] **Step 5: Commit**

```bash
git add docs/development/specs/native-refstore-backend-ears.md tests/ref_store_parity.zig tests/git_ref_store_test.zig
git commit -m "test: add refstore parity harness"
```

## Task 2: Add The Ziggit Candidate Backend And Failing Test

**Files:**
- Modify: `build.zig.zon`
- Modify: `build.zig`
- Modify: `src/core/storage.zig`
- Modify: `src/core/root.zig`
- Create: `src/core/storage/ziggit_ref_store.zig`
- Create: `tests/ziggit_ref_store_test.zig`
- Test: `tests/ziggit_ref_store_test.zig`

- [ ] **Step 1: Add the `ziggit` dependency**

Run: `zig fetch --save https://git.psch.dev/ziggit/snapshot/ziggit-main.tar.gz`
Expected: `build.zig.zon` gains a new `.ziggit` dependency entry with a resolved hash.

- [ ] **Step 2: Re-export the candidate backend from storage**

```zig
pub const ZiggitRefStore = switch (builtin.os.tag) {
    .freestanding => void,
    else => @import("storage/ziggit_ref_store.zig").ZiggitRefStore,
};

test {
    if (builtin.os.tag != .freestanding) {
        _ = @import("storage/ziggit_ref_store.zig");
    }
}
```

```zig
pub const ZiggitRefStore = storage.ZiggitRefStore;
```

- [ ] **Step 3: Add the test target to `build.zig`**

```zig
    const ziggit_dep = b.dependency("ziggit", .{
        .target = target,
        .optimize = optimize,
    });

    const ziggit_ref_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ziggit_ref_store_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
            .{ .name = "ziggit", .module = ziggit_dep.module("ziggit") },
        },
    });
    const ziggit_ref_tests = b.addTest(.{ .root_module = ziggit_ref_test_mod });
    const run_ziggit_ref_tests = b.addRunArtifact(ziggit_ref_tests);

    test_step.dependOn(&run_ziggit_ref_tests.step);
```

- [ ] **Step 4: Add a compiling stub backend and a failing parity test**

```zig
const std = @import("std");
const sideshowdb = @import("sideshowdb");

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

    pub fn refStore(self: *ZiggitRefStore) sideshowdb.RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: sideshowdb.RefStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .delete = vtableDelete,
        .list = vtableList,
        .history = vtableHistory,
    };

    fn vtablePut(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8, value: []const u8) anyerror!sideshowdb.RefStore.VersionId {
        _ = ctx;
        _ = gpa;
        _ = key;
        _ = value;
        return error.Unimplemented;
    }
    fn vtableGet(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8, version: ?sideshowdb.RefStore.VersionId) anyerror!?sideshowdb.RefStore.ReadResult {
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
    fn vtableHistory(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8) anyerror![]sideshowdb.RefStore.VersionId {
        _ = ctx;
        _ = gpa;
        _ = key;
        return error.Unimplemented;
    }
};
```

```zig
const std = @import("std");
const sideshowdb = @import("sideshowdb");
const parity = @import("ref_store_parity.zig");

test "ZiggitRefStore: parity harness" {
    _ = @import("ziggit");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const repo_path = try std.fs.path.join(std.testing.allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(repo_path);

    var store = sideshowdb.ZiggitRefStore.init(.{
        .gpa = std.testing.allocator,
        .repo_path = repo_path,
        .ref_name = "refs/sideshowdb/test",
    });

    const Counter = struct {
        fn count(_: *const anyopaque, _: []const u8) !u32 {
            return 0;
        }
    };

    try parity.exerciseRefStore(.{
        .gpa = std.testing.allocator,
        .ref_store = store.refStore(),
        .repo_path = repo_path,
        .count_commits = Counter.count,
        .ctx = undefined,
    });
}
```

- [ ] **Step 5: Run the failing backend test**

Run: `zig test tests/ziggit_ref_store_test.zig`
Expected: FAIL with `error.Unimplemented`, proving the candidate backend is wired into the suite but not yet viable.

- [ ] **Step 6: Commit**

```bash
git add build.zig build.zig.zon src/core/storage.zig src/core/root.zig src/core/storage/ziggit_ref_store.zig tests/ziggit_ref_store_test.zig
git commit -m "test: add ziggit refstore candidate"
```

## Task 3: Implement Backend-Neutral RefStore Semantics In The Candidate Store

**Files:**
- Modify: `src/core/storage/ziggit_ref_store.zig`
- Test: `tests/ziggit_ref_store_test.zig`

- [ ] **Step 1: Keep dependency-specific I/O behind small helper methods**

```zig
fn resolveHeadVersion(self: *ZiggitRefStore, gpa: std.mem.Allocator) !?[]u8 {
    const version = try self.readRefTipSha(gpa);
    return version;
}

fn resolveRequestedVersion(self: *ZiggitRefStore, gpa: std.mem.Allocator, requested: ?sideshowdb.RefStore.VersionId) !?[]u8 {
    if (requested) |version| return try gpa.dupe(u8, version);
    return try self.resolveHeadVersion(gpa);
}

fn makeReadResult(gpa: std.mem.Allocator, value: []const u8, version: []const u8) !sideshowdb.RefStore.ReadResult {
    return .{
        .value = try gpa.dupe(u8, value),
        .version = version,
    };
}
```

- [ ] **Step 2: Implement `get`, `list`, and `history` in terms of helper methods**

```zig
fn vtableGet(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8, version: ?sideshowdb.RefStore.VersionId) anyerror!?sideshowdb.RefStore.ReadResult {
    const self: *ZiggitRefStore = @ptrCast(@alignCast(ctx));
    try validateKey(key);

    const resolved_version = try self.resolveRequestedVersion(gpa, version) orelse return null;
    errdefer gpa.free(resolved_version);

    const value = try self.readValueAtVersion(gpa, resolved_version, key) orelse {
        gpa.free(resolved_version);
        return null;
    };
    defer gpa.free(value);

    return try makeReadResult(gpa, value, resolved_version);
}

fn vtableList(ctx: *anyopaque, gpa: std.mem.Allocator) anyerror![][]u8 {
    const self: *ZiggitRefStore = @ptrCast(@alignCast(ctx));
    return self.listKeysAtHead(gpa);
}

fn vtableHistory(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8) anyerror![]sideshowdb.RefStore.VersionId {
    const self: *ZiggitRefStore = @ptrCast(@alignCast(ctx));
    try validateKey(key);
    return self.historyForKey(gpa, key);
}
```

- [ ] **Step 3: Implement `put` and `delete` in terms of write-graph helpers**

```zig
fn vtablePut(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8, value: []const u8) anyerror!sideshowdb.RefStore.VersionId {
    const self: *ZiggitRefStore = @ptrCast(@alignCast(ctx));
    try validateKey(key);
    return self.writeValueCommit(gpa, key, value);
}

fn vtableDelete(ctx: *anyopaque, key: []const u8) anyerror!void {
    const self: *ZiggitRefStore = @ptrCast(@alignCast(ctx));
    try validateKey(key);
    try self.deleteValueCommit(key);
}
```

- [ ] **Step 4: Re-run the candidate backend test**

Run: `zig test tests/ziggit_ref_store_test.zig`
Expected: Still FAIL, but now only at the dependency-specific helper layer rather than at every top-level method.

- [ ] **Step 5: Commit**

```bash
git add src/core/storage/ziggit_ref_store.zig
git commit -m "refactor: isolate native refstore semantics"
```

## Task 4: Decide Ziggit Viability

**Files:**
- Modify: `src/core/storage/ziggit_ref_store.zig`
- Create: `docs/development/reports/2026-04-28-ziggit-viability-report.md`
- Test: `tests/ziggit_ref_store_test.zig`
- Test: `zig build test`

- [ ] **Step 1: Inspect the fetched dependency for the required APIs**

Run: `rg -n "pub const Repo|pub fn|write|commit|tree|ref|object" .zig-cache | head -n 200`
Expected: a concrete list of `ziggit` entry points for repo open, object reads, and any write or ref-update support.

- [ ] **Step 2: If `ziggit` exposes full write primitives, implement the helper layer**

```zig
fn readRefTipSha(self: *ZiggitRefStore, gpa: std.mem.Allocator) !?[]u8 {
    const repo = try self.openRepo();
    defer repo.close();

    const tip = try self.backendReadRef(repo, self.ref_name) orelse return null;
    return try formatSha(gpa, tip);
}

fn writeValueCommit(self: *ZiggitRefStore, gpa: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    const repo = try self.openRepo();
    defer repo.close();

    const parent = try self.backendReadRef(repo, self.ref_name);
    const blob_id = try self.backendWriteBlob(repo, value);
    const tree_id = try self.backendWriteUpdatedTree(repo, parent, key, blob_id);
    const commit_id = try self.backendWriteCommit(repo, .{
        .tree = tree_id,
        .parent = parent,
        .message = try std.fmt.allocPrint(gpa, "put {s}", .{key}),
    });
    try self.backendUpdateRef(repo, self.ref_name, commit_id, parent);
    return try formatSha(gpa, commit_id);
}
```

- [ ] **Step 3: If `ziggit` does not expose full write primitives, stop the code path and write the report**

Write `docs/development/reports/2026-04-28-ziggit-viability-report.md` with these exact sections, using concrete prose from the inspection and failing test output:

- `# Ziggit Viability Report`
- `Date: 2026-04-28`
- `Decision: Not viable for full RefStore parity`
- `## Required capabilities checked`
- `## Confirmed capabilities`
- `## Missing or blocked capabilities`
- `## Why this blocks zero-subprocess parity`
- `## Recommendation`

The report must name the specific missing write or ref-update capability and explain why that prevents `put` and `delete` from preserving commit-SHA `VersionId` behavior.

- [ ] **Step 4: Run the right verification path for the outcome**

Run: `zig test tests/ziggit_ref_store_test.zig`
Expected if viable: PASS.

Run: `zig build test`
Expected if viable: PASS across the full suite.

Run: `git diff -- docs/development/reports/2026-04-28-ziggit-viability-report.md`
Expected if not viable: the report clearly lists missing write or ref-update support and recommends fallback.

- [ ] **Step 5: Commit**

```bash
git add src/core/storage/ziggit_ref_store.zig tests/ziggit_ref_store_test.zig docs/development/reports/2026-04-28-ziggit-viability-report.md
git commit -m "feat: evaluate ziggit refstore viability"
```

## Task 5: Confirm Downstream Behavior Or Hand Off To Fallback Planning

**Files:**
- Test: `tests/document_store_test.zig`
- Test: `tests/document_transport_test.zig`
- Test: `tests/wasm_exports_test.zig`
- Modify if needed: `docs/development/reports/2026-04-28-ziggit-viability-report.md`

- [ ] **Step 1: If `ziggit` is viable, run the downstream regression suites**

Run: `zig test tests/document_store_test.zig`
Expected: PASS with document version semantics unchanged.

Run: `zig test tests/document_transport_test.zig`
Expected: PASS with transport JSON semantics unchanged.

Run: `zig test tests/wasm_exports_test.zig`
Expected: PASS with host-backed result/version buffers unchanged.

- [ ] **Step 2: If `ziggit` is not viable, record the exact fallback entry criteria**

```md
## Fallback Entry Criteria

- full-parity writes unavailable
- safe ref movement unavailable
- commit-SHA `VersionId` semantics cannot be preserved
- zero-subprocess requirement therefore unmet
```

- [ ] **Step 3: Commit**

```bash
git add docs/development/reports/2026-04-28-ziggit-viability-report.md
git commit -m "docs: record ziggit fallback criteria"
```

## Self-Review Checklist

- [ ] Every EARS statement from `docs/development/specs/native-refstore-backend-ears.md` maps to a parity test or a documented fallback decision.
- [ ] `tests/ref_store_parity.zig` is the single source of truth for baseline `RefStore` behavior.
- [ ] `ZiggitRefStore` hides backend-specific types behind helper methods rather than leaking them through `RefStore`.
- [ ] The plan either ends with a passing parity suite or a written report that clearly justifies the move to `libgit2`.
