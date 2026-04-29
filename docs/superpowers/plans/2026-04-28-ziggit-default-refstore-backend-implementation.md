# Ziggit Default RefStore Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the ziggit-backed RefStore the default native backend while keeping the subprocess backend selectable through CLI flag, environment variable, and repo-local config.

**Architecture:** Preserve `RefStore` as the product-facing abstraction. Rename the current subprocess implementation to `SubprocessGitRefStore`, introduce `ZiggitRefStore`, alias `GitRefStore` to `ZiggitRefStore` on native targets, and add a small CLI backend selector that chooses between concrete backends before constructing `DocumentStore`.

**Tech Stack:** Zig 0.16, std.Build, bd/beads, existing `RefStore` vtable pattern, ziggit source from `sideshowdb-w1i-ziggit`, existing CLI test harness.

---

## Bead Workflow

**Primary bead:** `sideshowdb-cnm` - Make ziggit the default selectable RefStore backend.

Before implementation:

- [ ] **Step 1: Confirm bead is claimed**

Run:

```bash
bd show sideshowdb-cnm --json
```

Expected: status is `in_progress` and assignee is `Damian Reeves`.

- [ ] **Step 2: Work in an isolated worktree**

Run from repo root:

```bash
git status --short --branch
git check-ignore -q .worktrees
git worktree add .worktrees/sideshowdb-cnm-ziggit-default -b sideshowdb-cnm-ziggit-default main
cd .worktrees/sideshowdb-cnm-ziggit-default
```

Expected: new worktree on branch `sideshowdb-cnm-ziggit-default`.

During implementation:

- Use `sideshowdb-cnm` for all implementation status.
- If native-Git WASM feasibility needs separate work, create a follow-up bead with `--deps discovered-from:sideshowdb-cnm`.
- If upstream ziggit cannot be consumed cleanly and a compatibility subset must be carried, record that explicitly in the PR body and docs.

Before final PR:

- [ ] **Step 3: Close or update bead only after verification**

Run:

```bash
bd close sideshowdb-cnm --reason "Implemented ziggit as the default native RefStore backend with selectable subprocess fallback and parity coverage." --json
bd dolt push
```

Expected: close succeeds and Dolt push succeeds.

---

## File Map

- Modify: `build.zig`
  - Add ziggit test/build wiring only if the production backend needs an explicit module import.
  - Add `tests/ziggit_ref_store_test.zig` to `zig build test`.
- Modify: `build.zig.zon`
  - Add a maintainable ziggit dependency if upstream can be consumed directly.
- Modify: `src/core/root.zig`
  - Re-export `ZiggitRefStore` and `SubprocessGitRefStore`.
- Modify: `src/core/storage.zig`
  - Export `GitRefStore` as the default ziggit alias on native targets.
  - Export `SubprocessGitRefStore` as the fallback.
- Move/modify: `src/core/storage/git_ref_store.zig`
  - Rename implementation type from `GitRefStore` to `SubprocessGitRefStore`.
- Create: `src/core/storage/ziggit_ref_store.zig`
  - Production-shaped version of the exploration backend.
- Optional create: `src/core/storage/ziggit_pkg/**`
  - Only if upstream ziggit cannot be used directly with Zig 0.16.
- Create: `src/cli/refstore_selector.zig`
  - Parse backend selectors from flag/env/config and instantiate document stores.
- Modify: `src/cli/app.zig`
  - Add `--refstore` global option and selector integration.
- Modify: `README.md`
  - Document default backend and selector precedence.
- Modify: `docs/development/specs/git-ref-storage-spec.md`
  - Document the new default and fallback.
- Create/modify: `tests/ref_store_parity.zig`
  - Shared backend parity harness.
- Modify: `tests/git_ref_store_test.zig`
  - Run parity against `SubprocessGitRefStore`.
- Create: `tests/ziggit_ref_store_test.zig`
  - Run parity against `ZiggitRefStore`.
- Modify: `tests/cli_test.zig`
  - Add backend selector precedence and invalid selector tests.

---

### Task 1: Extract Shared RefStore Parity

**Files:**
- Create: `tests/ref_store_parity.zig`
- Modify: `tests/git_ref_store_test.zig`

- [ ] **Step 1: Add shared parity harness**

Create `tests/ref_store_parity.zig`:

```zig
const std = @import("std");
const sideshowdb = @import("sideshowdb");

pub const Harness = struct {
    gpa: std.mem.Allocator,
    ref_store: sideshowdb.RefStore,
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
        try std.testing.expect(v != null);
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
        var saw_a = false;
        var saw_b = false;
        for (keys) |k| {
            if (std.mem.eql(u8, k, "a/x.txt")) saw_a = true;
            if (std.mem.eql(u8, k, "b/y.txt")) saw_b = true;
        }
        try std.testing.expect(saw_a and saw_b);
    }
    {
        const versions = try rs.history(h.gpa, "missing.txt");
        defer sideshowdb.RefStore.freeVersions(h.gpa, versions);
        try std.testing.expectEqual(@as(usize, 0), versions.len);
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

    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "/leading", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "trailing/", "x"));
    try std.testing.expectError(error.InvalidKey, rs.put(h.gpa, "a//b", "x"));
    try std.testing.expectError(error.InvalidKey, rs.history(h.gpa, ""));
}
```

- [ ] **Step 2: Refactor subprocess test to use the harness**

In `tests/git_ref_store_test.zig`, add:

```zig
const parity = @import("ref_store_parity.zig");
```

Replace the long `GitRefStore: put/get/overwrite/delete/list with history`
body after store construction with:

```zig
try parity.exerciseRefStore(.{
    .gpa = gpa,
    .ref_store = store.refStore(),
});
```

Keep the existing metacharacter test.

- [ ] **Step 3: Run the refactored subprocess test**

Run:

```bash
zig build test --summary all
```

Expected: PASS. This task is a refactor, so behavior must stay green.

- [ ] **Step 4: Commit**

```bash
git add tests/ref_store_parity.zig tests/git_ref_store_test.zig
git commit -m "test(storage): share refstore parity harness"
```

---

### Task 2: Rename Subprocess Backend Without Changing Defaults

**Files:**
- Modify: `src/core/storage/git_ref_store.zig`
- Modify: `src/core/storage.zig`
- Modify: `src/core/root.zig`
- Modify: `tests/git_ref_store_test.zig`

- [ ] **Step 1: Add failing export expectations**

Add to `tests/git_ref_store_test.zig`:

```zig
test "storage exports subprocess fallback backend" {
    try std.testing.expect(@typeName(sideshowdb.SubprocessGitRefStore).len > 0);
}
```

Run:

```bash
zig build test --summary failures
```

Expected: FAIL because `SubprocessGitRefStore` is not exported yet.

- [ ] **Step 2: Rename the implementation type**

In `src/core/storage/git_ref_store.zig`, change:

```zig
pub const GitRefStore = struct {
```

to:

```zig
pub const SubprocessGitRefStore = struct {
```

Within that file, update receiver and return type names from `GitRefStore` to
`SubprocessGitRefStore`. Keep comments accurate: the file remains the
subprocess-backed implementation.

- [ ] **Step 3: Export fallback and preserve current default**

In `src/core/storage.zig`, use:

```zig
pub const SubprocessGitRefStore = switch (builtin.os.tag) {
    .freestanding => void,
    else => @import("storage/git_ref_store.zig").SubprocessGitRefStore,
};

pub const GitRefStore = SubprocessGitRefStore;
```

In `src/core/root.zig`, add:

```zig
/// Convenience re-export of `storage.SubprocessGitRefStore`.
pub const SubprocessGitRefStore = storage.SubprocessGitRefStore;
```

- [ ] **Step 4: Update subprocess tests**

In `tests/git_ref_store_test.zig`, construct:

```zig
var store = sideshowdb.SubprocessGitRefStore.init(.{
    .gpa = gpa,
    .io = io,
    .parent_env = &env,
    .repo_path = repo_path,
    .ref_name = "refs/sideshowdb/test",
});
```

- [ ] **Step 5: Verify rename**

Run:

```bash
zig build test --summary all
```

Expected: PASS. `GitRefStore` still aliases subprocess for now.

- [ ] **Step 6: Commit**

```bash
git add src/core/storage/git_ref_store.zig src/core/storage.zig src/core/root.zig tests/git_ref_store_test.zig
git commit -m "refactor(storage): name subprocess refstore"
```

---

### Task 3: Add Ziggit Backend Under Production Names

**Files:**
- Modify: `build.zig.zon`
- Modify: `build.zig`
- Modify: `src/core/storage.zig`
- Modify: `src/core/root.zig`
- Create: `src/core/storage/ziggit_ref_store.zig`
- Optional create: `src/core/storage/ziggit_pkg/**`
- Create: `tests/ziggit_ref_store_test.zig`

- [ ] **Step 1: Add failing ziggit backend test**

Create `tests/ziggit_ref_store_test.zig`:

```zig
const std = @import("std");
const sideshowdb = @import("sideshowdb");
const parity = @import("ref_store_parity.zig");

test "ZiggitRefStore: parity harness" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const repo_path = try std.fs.path.join(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(repo_path);

    var store = sideshowdb.ZiggitRefStore.init(.{
        .gpa = std.testing.allocator,
        .repo_path = repo_path,
        .ref_name = "refs/sideshowdb/test",
    });

    try parity.exerciseRefStore(.{
        .gpa = std.testing.allocator,
        .ref_store = store.refStore(),
    });
}

test "ZiggitRefStore: history treats metacharacters in keys literally" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const repo_path = try std.fs.path.join(std.testing.allocator, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer std.testing.allocator.free(repo_path);

    var store = sideshowdb.ZiggitRefStore.init(.{
        .gpa = std.testing.allocator,
        .repo_path = repo_path,
        .ref_name = "refs/sideshowdb/test",
    });
    const rs = store.refStore();

    const literal_version = try rs.put(std.testing.allocator, "a/file[1].txt", "literal");
    defer std.testing.allocator.free(literal_version);
    const wildcard_match_version = try rs.put(std.testing.allocator, "a/file1.txt", "wildcard-match");
    defer std.testing.allocator.free(wildcard_match_version);

    const versions = try rs.history(std.testing.allocator, "a/file[1].txt");
    defer sideshowdb.RefStore.freeVersions(std.testing.allocator, versions);

    try std.testing.expectEqual(@as(usize, 1), versions.len);
    try std.testing.expectEqualStrings(literal_version, versions[0]);
    try std.testing.expect(!std.mem.eql(u8, wildcard_match_version, versions[0]));
}
```

Wire this test into `build.zig` beside the existing git ref store test, then run:

```bash
zig build test --summary failures
```

Expected: FAIL because `ZiggitRefStore` is not implemented/exported yet.

- [ ] **Step 2: Add ziggit dependency or compatibility source**

First try upstream dependency in `build.zig.zon`:

```zig
.ziggit = .{
    .url = "git+https://github.com/hdresearch/ziggit.git#f05b38e309a49ad6bb4c6c4b3ef02d806e7349c4",
    .hash = "ziggit-0.3.0-db3ls8wtWgBFiVn3iZHywznVg-k8JDUOSHCIbN5dWkeu",
    .lazy = true,
},
```

Run:

```bash
zig build test --summary failures
```

If upstream ziggit fails on Zig 0.16 incompatibilities already solved in the
exploration branch, add the scoped compatibility subset from
`.worktrees/sideshowdb-w1i-ziggit/src/core/storage/ziggit_pkg/` under
`src/core/storage/ziggit_pkg/` and document why in
`src/core/storage/ziggit_ref_store.zig`.

- [ ] **Step 3: Port production ZiggitRefStore**

Create `src/core/storage/ziggit_ref_store.zig` by porting the implementation
from `.worktrees/sideshowdb-w1i-ziggit/src/core/storage/ziggit_ref_store.zig`.
Keep these production requirements:

```zig
pub const ZiggitRefStore = struct {
    pub const Options = struct {
        gpa: std.mem.Allocator,
        repo_path: []const u8,
        ref_name: []const u8,
        author_name: []const u8 = "sideshowdb",
        author_email: []const u8 = "sideshowdb@local",
    };
};
```

The production file must provide these exact public methods:

- `pub fn init(options: Options) ZiggitRefStore`
- `pub fn refStore(self: *ZiggitRefStore) RefStore`
- `pub fn put(self: *ZiggitRefStore, gpa: std.mem.Allocator, key: []const u8, value: []const u8) !RefStore.VersionId`
- `pub fn get(self: *ZiggitRefStore, gpa: std.mem.Allocator, key: []const u8, requested_version: ?RefStore.VersionId) !?RefStore.ReadResult`
- `pub fn delete(self: *ZiggitRefStore, key: []const u8) !void`
- `pub fn list(self: *ZiggitRefStore, gpa: std.mem.Allocator) ![][]u8`
- `pub fn history(self: *ZiggitRefStore, gpa: std.mem.Allocator, key: []const u8) ![]RefStore.VersionId`

Do not expose ziggit object IDs or repository internals outside this file.

- [ ] **Step 4: Export ZiggitRefStore**

In `src/core/storage.zig`, add:

```zig
pub const ZiggitRefStore = switch (builtin.os.tag) {
    .freestanding => void,
    else => @import("storage/ziggit_ref_store.zig").ZiggitRefStore,
};
```

In `src/core/root.zig`, add:

```zig
/// Convenience re-export of `storage.ZiggitRefStore`.
pub const ZiggitRefStore = storage.ZiggitRefStore;
```

- [ ] **Step 5: Verify ziggit parity**

Run:

```bash
zig build test --summary all
```

Expected: PASS including `tests/ziggit_ref_store_test.zig`.

- [ ] **Step 6: Commit**

```bash
git add build.zig build.zig.zon src/core/root.zig src/core/storage.zig src/core/storage/ziggit_ref_store.zig src/core/storage/ziggit_pkg tests/ziggit_ref_store_test.zig
git commit -m "feat(storage): add ziggit refstore backend"
```

If `src/core/storage/ziggit_pkg` is not needed, omit it from `git add`.

---

### Task 4: Make Ziggit the Native Default

**Files:**
- Modify: `src/core/storage.zig`
- Modify: `tests/git_ref_store_test.zig`
- Modify: `tests/ziggit_ref_store_test.zig`

- [ ] **Step 1: Add default alias assertion**

Add a test in `tests/ziggit_ref_store_test.zig`:

```zig
test "GitRefStore defaults to ZiggitRefStore on native targets" {
    try std.testing.expectEqualStrings(
        @typeName(sideshowdb.ZiggitRefStore),
        @typeName(sideshowdb.GitRefStore),
    );
}
```

Run:

```bash
zig build test --summary failures
```

Expected: FAIL while `GitRefStore` still aliases `SubprocessGitRefStore`.

- [ ] **Step 2: Change default alias**

In `src/core/storage.zig`, change:

```zig
pub const GitRefStore = SubprocessGitRefStore;
```

to:

```zig
pub const GitRefStore = ZiggitRefStore;
```

Keep `SubprocessGitRefStore` exported.

- [ ] **Step 3: Verify default alias**

Run:

```bash
zig build test --summary all
```

Expected: PASS. Existing CLI/document tests now exercise ziggit by default.

- [ ] **Step 4: Commit**

```bash
git add src/core/storage.zig tests/ziggit_ref_store_test.zig
git commit -m "feat(storage): default native refstore to ziggit"
```

---

### Task 5: Add CLI Backend Selector

**Files:**
- Create: `src/cli/refstore_selector.zig`
- Modify: `src/cli/app.zig`
- Modify: `tests/cli_test.zig`

- [ ] **Step 1: Add failing CLI flag tests**

Add tests to `tests/cli_test.zig`:

```zig
test "CLI --refstore subprocess selects fallback backend" {
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

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "--refstore", "subprocess", "--json", "doc", "put", "--type", "issue", "--id", "backend-flag" },
        "{\"title\":\"fallback\"}",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(result.stderr.len == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"version\"") != null);
}

test "CLI invalid --refstore fails before mutation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo_path);

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "--refstore", "bogus", "doc", "put", "--type", "issue", "--id", "bad" },
        "{\"title\":\"nope\"}",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported refstore") != null);

    const doc_ref_path = try std.fs.path.join(gpa, &.{ repo_path, ".git", "refs", "sideshowdb", "documents" });
    defer gpa.free(doc_ref_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(doc_ref_path, .{}));
}
```

Run:

```bash
zig build test --summary failures
```

Expected: FAIL because `--refstore` is not parsed.

- [ ] **Step 2: Implement selector types**

Create `src/cli/refstore_selector.zig`:

```zig
const std = @import("std");

pub const RefStoreBackend = enum {
    ziggit,
    subprocess,

    pub fn parse(value: []const u8) ?RefStoreBackend {
        if (std.mem.eql(u8, value, "ziggit")) return .ziggit;
        if (std.mem.eql(u8, value, "subprocess")) return .subprocess;
        return null;
    }
};

pub const SelectionSource = enum {
    default,
    config,
    environment,
    flag,
};

pub const Selection = struct {
    backend: RefStoreBackend,
    source: SelectionSource,
};
```

- [ ] **Step 3: Parse global `--refstore`**

In `src/cli/app.zig`, import:

```zig
const refstore_selector = @import("refstore_selector.zig");
```

Extend `usage_message`:

```zig
pub const usage_message = "usage: sideshowdb [--json] [--refstore ziggit|subprocess] <version|doc <put|get|list|delete|history>>\n";
```

Extend `GlobalOptions`:

```zig
refstore: ?refstore_selector.RefStoreBackend = null,
```

Update `parseGlobalOptions` so `--refstore` consumes the next argument:

```zig
var refstore: ?refstore_selector.RefStoreBackend = null;
var i: usize = 0;
while (i < argv.len) : (i += 1) {
    const arg = argv[i];
    if (std.mem.eql(u8, arg, "--json")) {
        json = true;
        continue;
    }
    if (std.mem.eql(u8, arg, "--refstore")) {
        if (i + 1 >= argv.len) return error.InvalidArguments;
        i += 1;
        refstore = refstore_selector.RefStoreBackend.parse(argv[i]) orelse return error.InvalidRefStore;
        continue;
    }
    try filtered.append(gpa, arg);
}
```

Map `error.InvalidRefStore` to a clear failure, not the generic usage text:

```zig
const global = parseGlobalOptions(gpa, argv) catch |err| switch (err) {
    error.InvalidRefStore => return failure(gpa, "unsupported refstore: expected ziggit or subprocess\n"),
    else => return usageFailure(gpa),
};
```

- [ ] **Step 4: Instantiate the selected backend**

In `src/cli/app.zig`, replace direct `sideshowdb.GitRefStore.init` with a
switch. The selected backend must live long enough for `DocumentStore` use:

```zig
const selected_backend = global.refstore orelse .ziggit;
return runDocumentCommand(gpa, io, env, repo_path, global, selected_backend, stdin_data);
```

Implement `runDocumentCommand` with separate local variables in each switch arm:

```zig
fn runDocumentCommand(
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    repo_path: []const u8,
    global: GlobalOptions,
    backend: refstore_selector.RefStoreBackend,
    stdin_data: []const u8,
) !RunResult {
    switch (backend) {
        .ziggit => {
            var ref_store = sideshowdb.ZiggitRefStore.init(.{
                .gpa = gpa,
                .repo_path = repo_path,
                .ref_name = "refs/sideshowdb/documents",
            });
            return runDocumentCommandWithStore(gpa, global, sideshowdb.DocumentStore.init(ref_store.refStore()), stdin_data);
        },
        .subprocess => {
            var ref_store = sideshowdb.SubprocessGitRefStore.init(.{
                .gpa = gpa,
                .io = io,
                .parent_env = env,
                .repo_path = repo_path,
                .ref_name = "refs/sideshowdb/documents",
            });
            return runDocumentCommandWithStore(gpa, global, sideshowdb.DocumentStore.init(ref_store.refStore()), stdin_data);
        },
    }
}
```

Move the existing `doc put|get|list|delete|history` dispatch into
`runDocumentCommandWithStore`.

- [ ] **Step 5: Verify CLI flag selection**

Run:

```bash
zig build test --summary all
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/cli/app.zig src/cli/refstore_selector.zig tests/cli_test.zig
git commit -m "feat(cli): select refstore backend by flag"
```

---

### Task 6: Add Environment and Config Selection

**Files:**
- Modify: `src/cli/refstore_selector.zig`
- Modify: `src/cli/app.zig`
- Modify: `tests/cli_test.zig`
- Modify: `README.md`

- [ ] **Step 1: Add failing precedence tests**

Add tests to `tests/cli_test.zig`:

```zig
test "CLI refstore flag overrides environment" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_REFSTORE", "bogus");

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshowdb", "--refstore", "ziggit", "version" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "CLI invalid environment refstore fails when no flag is present" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_REFSTORE", "bogus");

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshowdb", "doc", "list" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported refstore") != null);
}
```

Add a config precedence test that writes `.sideshowdb/config.toml` inside a temp
repo and confirms env wins over config.

- [ ] **Step 2: Implement environment lookup**

In `src/cli/refstore_selector.zig`, add:

```zig
pub fn fromEnvironment(env: *const std.process.Environ.Map) !?Selection {
    const value = env.get("SIDESHOWDB_REFSTORE") orelse return null;
    const backend = RefStoreBackend.parse(value) orelse return error.InvalidRefStore;
    return .{ .backend = backend, .source = .environment };
}
```

- [ ] **Step 3: Implement minimal config parser**

In `src/cli/refstore_selector.zig`, add:

```zig
pub fn fromConfig(gpa: std.mem.Allocator, repo_path: []const u8) !?Selection {
    const path = try std.fs.path.join(gpa, &.{ repo_path, ".sideshowdb", "config.toml" });
    defer gpa.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        gpa,
        .limited(16 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(bytes);

    var in_storage = false;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[storage]")) {
            in_storage = true;
            continue;
        }
        if (line[0] == '[') {
            in_storage = false;
            continue;
        }
        if (!in_storage) continue;
        if (std.mem.startsWith(u8, line, "refstore")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidRefStoreConfig;
            const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (raw_value.len < 2 or raw_value[0] != '"' or raw_value[raw_value.len - 1] != '"') {
                return error.InvalidRefStoreConfig;
            }
            const value = raw_value[1 .. raw_value.len - 1];
            const backend = RefStoreBackend.parse(value) orelse return error.InvalidRefStore;
            return .{ .backend = backend, .source = .config };
        }
    }
    return null;
}
```

This parser intentionally supports only the documented `[storage]` table with
one quoted `refstore` value.

- [ ] **Step 4: Resolve precedence**

In `src/cli/refstore_selector.zig`, add:

```zig
pub fn resolve(
    gpa: std.mem.Allocator,
    repo_path: []const u8,
    env: *const std.process.Environ.Map,
    flag_backend: ?RefStoreBackend,
) !Selection {
    if (flag_backend) |backend| return .{ .backend = backend, .source = .flag };
    if (try fromEnvironment(env)) |selection| return selection;
    if (try fromConfig(gpa, repo_path)) |selection| return selection;
    return .{ .backend = .ziggit, .source = .default };
}
```

Use `resolve` in `app.zig` before document command dispatch.

- [ ] **Step 5: Document selector precedence**

Add to `README.md`:

```markdown
### RefStore backend selection

Native SideshowDB defaults to the ziggit-backed `GitRefStore`. The
subprocess-backed backend remains available as a fallback for compatibility and
debugging.

Selection precedence:

1. `--refstore ziggit|subprocess`
2. `SIDESHOWDB_REFSTORE=ziggit|subprocess`
3. `.sideshowdb/config.toml`
4. built-in default: `ziggit`

Config file:

```toml
[storage]
refstore = "ziggit"
```
```

- [ ] **Step 6: Verify env/config selection**

Run:

```

- [ ] **Step 6: Verify env/config selection**

Run:

```bash
zig build test --summary all
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/cli/app.zig src/cli/refstore_selector.zig tests/cli_test.zig README.md
git commit -m "feat(cli): resolve refstore from env and config"
```

---

### Task 7: Documentation, Beads, and Final Regression

**Files:**
- Modify: `docs/development/specs/git-ref-storage-spec.md`
- Modify: `docs/superpowers/specs/2026-04-28-ziggit-default-refstore-backend-design.md` only if implementation decisions changed the design.

- [ ] **Step 1: Update storage spec**

In `docs/development/specs/git-ref-storage-spec.md`, add a section explaining:

- `GitRefStore` is ziggit-backed by default on native targets.
- `SubprocessGitRefStore` is the compatibility fallback.
- Both backends implement the same `RefStore` contract.
- CLI backend selection precedence is flag, environment, config, default.

- [ ] **Step 2: Run core verification**

Run:

```bash
git ls-files -z '*.zig' | xargs -0 zig fmt --check
zig build -Doptimize=ReleaseSafe
zig build check:core-docs
zig build wasm -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
```

Expected: all commands exit 0.

- [ ] **Step 3: Run JS/site regression gates**

Run:

```bash
zig build js:build-bindings
zig build js:check
zig build js:test
bash scripts/verify-site-build-from-clean-bindings.sh
bash scripts/verify-site-reference-build.sh
```

Expected: all commands exit 0. Existing SveltePress code-block accessibility
warnings and the known large chunk warning are non-blocking and tracked by
other beads.

- [ ] **Step 4: Commit documentation**

Run:

```bash
git add docs/development/specs/git-ref-storage-spec.md docs/superpowers/specs/2026-04-28-ziggit-default-refstore-backend-design.md README.md
git commit -m "docs(storage): document refstore backend selection"
```

If all documentation changes were already committed in earlier tasks, verify
with `git status --short` and skip this commit.

- [ ] **Step 5: Close bead and push**

Run:

```bash
bd close sideshowdb-cnm --reason "Implemented ziggit as the default native RefStore backend with selectable subprocess fallback and parity coverage." --json
git status --short --branch
git pull --rebase
bd dolt push
git push -u origin sideshowdb-cnm-ziggit-default
```

Expected: bead closes, Dolt push succeeds, branch push succeeds.

- [ ] **Step 6: Open PR**

Use GitHub tooling to open a PR with:

- Summary of ziggit default backend.
- Selection precedence.
- `sideshowdb-cnm` completion.
- `sideshowdb-w1i` as source exploration.
- Follow-up callout for native-Git WASM feasibility if not implemented.
- Verification command list from Steps 2 and 3.
