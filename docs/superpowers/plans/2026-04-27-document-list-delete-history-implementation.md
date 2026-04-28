# Document List/Delete/History Implementation Plan

**Status:** Implemented on `sideshowdb-psy` and verified on the merged branch. The feature work covers storage, document APIs, transport, CLI, and WASM exports, and remains green after the later `origin/main` sync plus wasm-boundary test additions.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add paginated document `list`, `delete`, and `history` across `DocumentStore`, CLI, and WASM, with summary/detailed result unions plus human-readable CLI defaults and universal `--json` output.

**Architecture:** Extend the storage abstraction with a history primitive, then build document-level request/result types and pagination in `src/core/document.zig`. Keep transport layers thin: WASM always emits JSON, while the CLI parses the same request shapes but renders human output by default through a dedicated formatter helper.

**Tech Stack:** Zig 0.16, subprocess-backed git storage, std.json, existing Zig test suite (`zig build test`)

---

## File Structure

- Modify: `src/core/storage/ref_store.zig`
  Responsibility: add the low-level history capability and memory-management helpers for returned version lists.
- Modify: `src/core/storage/git_ref_store.zig`
  Responsibility: implement git-backed key history traversal, filtering out deletion commits and returning reachable versions in newest-first order.
- Modify: `src/core/document.zig`
  Responsibility: define list/history/delete request and result types, pagination/cursor helpers, result union encoding, and document-layer behavior.
- Modify: `src/core/document_transport.zig`
  Responsibility: parse JSON request envelopes for list/history/delete and serialize store results for WASM and CLI `--json`.
- Modify: `src/wasm/root.zig`
  Responsibility: export `sideshowdb_document_list`, `sideshowdb_document_delete`, and `sideshowdb_document_history`.
- Modify: `src/cli/app.zig`
  Responsibility: parse universal `--json`, support new doc subcommands/options, call the store/transport layer, and choose JSON or human rendering.
- Create: `src/cli/output.zig`
  Responsibility: render property-style vertical output for single-object commands and friendly tables for list/history.
- Modify: `tests/git_ref_store_test.zig`
  Responsibility: cover storage-layer history traversal semantics and deletion filtering.
- Modify: `tests/document_store_test.zig`
  Responsibility: cover summary/detailed unions, filtering, pagination, delete idempotency, and history ordering.
- Modify: `tests/document_transport_test.zig`
  Responsibility: cover JSON request parsing and encoded results for list/history/delete.
- Modify: `tests/cli_test.zig`
  Responsibility: cover universal `--json`, human-readable defaults, new commands, and output shape expectations.

## Constants And Conventions

- Default page size: `50`
- Maximum page size: `200`
- `mode` request default: `summary`
- Result discriminator field: `kind`
- List cursor payload: opaque base64-url string representing the last emitted derived key
- History cursor payload: opaque base64-url string representing the last emitted version SHA

### Task 1: Add RefStore History Traversal

**Files:**
- Modify: `src/core/storage/ref_store.zig`
- Modify: `src/core/storage/git_ref_store.zig`
- Test: `tests/git_ref_store_test.zig`

- [ ] **Step 1: Write the failing git-store history test**

```zig
test "GitRefStore history returns reachable versions and skips delete commits" {
    const history_before_delete = try rs.history(gpa, "a/x.txt");
    defer sideshowdb.RefStore.freeVersions(gpa, history_before_delete);
    try std.testing.expectEqual(@as(usize, 2), history_before_delete.len);
    try std.testing.expectEqualStrings(second_version, history_before_delete[0]);
    try std.testing.expectEqualStrings(first_version, history_before_delete[1]);

    try rs.delete("a/x.txt");

    const history_after_delete = try rs.history(gpa, "a/x.txt");
    defer sideshowdb.RefStore.freeVersions(gpa, history_after_delete);
    try std.testing.expectEqual(@as(usize, 2), history_after_delete.len);
    try std.testing.expectEqualStrings(second_version, history_after_delete[0]);
    try std.testing.expectEqualStrings(first_version, history_after_delete[1]);
}
```

- [ ] **Step 2: Run the test suite to verify it fails for the missing API**

Run: `zig build test`
Expected: FAIL with a compile error mentioning missing `history` on `RefStore` or `GitRefStore`.

- [ ] **Step 3: Extend `RefStore` with a history vtable entry and free helper**

```zig
pub const VTable = struct {
    put: *const fn (
        ctx: *anyopaque,
        gpa: Allocator,
        key: []const u8,
        value: []const u8,
    ) anyerror!VersionId,
    get: *const fn (
        ctx: *anyopaque,
        gpa: Allocator,
        key: []const u8,
        version: ?VersionId,
    ) anyerror!?ReadResult,
    delete: *const fn (ctx: *anyopaque, key: []const u8) anyerror!void,
    list: *const fn (ctx: *anyopaque, gpa: Allocator) anyerror![][]u8,
    history: *const fn (
        ctx: *anyopaque,
        gpa: Allocator,
        key: []const u8,
    ) anyerror![]VersionId,
};

pub fn history(self: RefStore, gpa: Allocator, key: []const u8) anyerror![]VersionId {
    return self.vtable.history(self.ptr, gpa, key);
}

pub fn freeVersions(gpa: Allocator, versions: [][]const u8) void {
    for (versions) |version| gpa.free(version);
    gpa.free(versions);
}
```

- [ ] **Step 4: Implement git-backed history traversal**

```zig
const vtable: RefStore.VTable = .{
    .put = vtablePut,
    .get = vtableGet,
    .delete = vtableDelete,
    .list = vtableList,
    .history = vtableHistory,
};

fn vtableHistory(ctx: *anyopaque, gpa: Allocator, key: []const u8) anyerror![]RefStore.VersionId {
    const self: *GitRefStore = @ptrCast(@alignCast(ctx));
    return self.history(gpa, key);
}

pub fn history(self: *GitRefStore, gpa: Allocator, key: []const u8) Error![]RefStore.VersionId {
    try validateKey(key);
    if (!try self.refExists(gpa)) return try gpa.alloc([]const u8, 0);

    const result = try self.runRaw(gpa, &.{
        "log", "--format=%H", "--", self.ref_name, "--", key,
    }, null);
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    if (!isExitOk(result.term)) return error.GitInvocationFailed;

    var versions: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (versions.items) |version| gpa.free(version);
        versions.deinit(gpa);
    }

    var it = std.mem.splitScalar(u8, result.stdout, '\n');
    while (it.next()) |line| {
        const version = std.mem.trim(u8, line, "\r ");
        if (version.len == 0) continue;
        const maybe_value = try self.get(gpa, key, version);
        defer if (maybe_value) |read_result| RefStore.freeReadResult(gpa, read_result);
        if (maybe_value == null) continue;
        try versions.append(gpa, try gpa.dupe(u8, version));
    }

    return versions.toOwnedSlice(gpa);
}
```

- [ ] **Step 5: Run the test suite to verify it passes**

Run: `zig build test`
Expected: PASS, including the new git history assertions.

- [ ] **Step 6: Commit**

```bash
git add src/core/storage/ref_store.zig src/core/storage/git_ref_store.zig tests/git_ref_store_test.zig
git commit -m "feat: add ref store history traversal"
```

### Task 2: Implement DocumentStore Summary Results, Cursors, And Delete

**Files:**
- Modify: `src/core/document.zig`
- Test: `tests/document_store_test.zig`

- [ ] **Step 1: Write failing document-store tests for summary list/history/delete**

```zig
test "DocumentStore list summary paginates and filters by namespace and type" {
    const first_page = try document_store.list(gpa, .{
        .limit = 1,
        .mode = .summary,
    });
    defer first_page.deinit(gpa);

    switch (first_page) {
        .summary => |page| {
            try std.testing.expectEqualStrings("summary", page.kind);
            try std.testing.expectEqual(@as(usize, 1), page.items.len);
            try std.testing.expect(page.next_cursor != null);
        },
        else => return error.UnexpectedDetailedPage,
    }
}

test "DocumentStore delete is idempotent and reports deleted state" {
    const deleted = try document_store.delete(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
    });
    try std.testing.expect(deleted.deleted);

    const deleted_again = try document_store.delete(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
    });
    try std.testing.expect(!deleted_again.deleted);
}

test "DocumentStore history summary uses newest first and empty page for missing identity" {
    const history = try document_store.history(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
        .mode = .summary,
    });
    defer history.deinit(gpa);

    switch (history) {
        .summary => |page| {
            try std.testing.expect(page.items.len >= 2);
            try std.testing.expectEqualStrings(second_version, page.items[0].version);
        },
        else => return error.UnexpectedDetailedPage,
    }
}
```

- [ ] **Step 2: Run the test suite to verify it fails for missing document APIs**

Run: `zig build test`
Expected: FAIL with compile errors for missing `list`, `delete`, `history`, `ListResult`, or `HistoryResult`.

- [ ] **Step 3: Add request/result types, result unions, and cursor helpers to `document.zig`**

```zig
pub const CollectionMode = enum { summary, detailed };

pub const ListRequest = struct {
    namespace: ?[]const u8 = null,
    doc_type: ?[]const u8 = null,
    limit: ?usize = null,
    cursor: ?[]const u8 = null,
    mode: CollectionMode = .summary,
};

pub const DeleteRequest = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
};

pub const HistoryRequest = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    limit: ?usize = null,
    cursor: ?[]const u8 = null,
    mode: CollectionMode = .summary,
};

pub const DocumentMetadata = struct {
    namespace: []const u8,
    doc_type: []const u8,
    id: []const u8,
    version: []const u8,
};

pub const SummaryListResult = struct {
    kind: []const u8 = "summary",
    items: []DocumentMetadata,
    next_cursor: ?[]u8,
    pub fn deinit(self: SummaryListResult, gpa: Allocator) void {
        for (self.items) |item| {
            gpa.free(item.namespace);
            gpa.free(item.doc_type);
            gpa.free(item.id);
            gpa.free(item.version);
        }
        gpa.free(self.items);
        if (self.next_cursor) |cursor| gpa.free(cursor);
    }
};

pub const DetailedListResult = struct {
    kind: []const u8 = "detailed",
    items: [][]u8,
    next_cursor: ?[]u8,
    pub fn deinit(self: DetailedListResult, gpa: Allocator) void {
        for (self.items) |item| gpa.free(item);
        gpa.free(self.items);
        if (self.next_cursor) |cursor| gpa.free(cursor);
    }
};

pub const SummaryHistoryResult = struct {
    kind: []const u8 = "summary",
    items: []DocumentMetadata,
    next_cursor: ?[]u8,
    pub fn deinit(self: SummaryHistoryResult, gpa: Allocator) void {
        for (self.items) |item| {
            gpa.free(item.namespace);
            gpa.free(item.doc_type);
            gpa.free(item.id);
            gpa.free(item.version);
        }
        gpa.free(self.items);
        if (self.next_cursor) |cursor| gpa.free(cursor);
    }
};

pub const DetailedHistoryResult = struct {
    kind: []const u8 = "detailed",
    items: [][]u8,
    next_cursor: ?[]u8,
    pub fn deinit(self: DetailedHistoryResult, gpa: Allocator) void {
        for (self.items) |item| gpa.free(item);
        gpa.free(self.items);
        if (self.next_cursor) |cursor| gpa.free(cursor);
    }
};

pub const ListResult = union(enum) {
    summary: SummaryListResult,
    detailed: DetailedListResult,
    pub fn deinit(self: ListResult, gpa: Allocator) void {
        switch (self) {
            .summary => |page| page.deinit(gpa),
            .detailed => |page| page.deinit(gpa),
        }
    }
};

pub const HistoryResult = union(enum) {
    summary: SummaryHistoryResult,
    detailed: DetailedHistoryResult,
    pub fn deinit(self: HistoryResult, gpa: Allocator) void {
        switch (self) {
            .summary => |page| page.deinit(gpa),
            .detailed => |page| page.deinit(gpa),
        }
    }
};
```

- [ ] **Step 4: Implement summary list/delete/history and pagination helpers**

```zig
const default_page_size: usize = 50;
const max_page_size: usize = 200;

pub fn list(self: DocumentStore, gpa: Allocator, request: ListRequest) !ListResult {
    const page_size = try resolveLimit(request.limit);
    var keys = try self.ref_store.list(gpa);
    defer RefStore.freeKeys(gpa, keys);
    std.mem.sort([]u8, keys, {}, lessThanKeys);

    const start_after = try decodeListCursor(gpa, request.cursor);
    defer if (start_after) |cursor_key| gpa.free(cursor_key);

    var items: std.ArrayList(DocumentMetadata) = .empty;
    var next_cursor: ?[]u8 = null;
    for (keys) |key| {
        const identity = try parseKey(key);
        if (!matchesListFilter(identity, request)) continue;
        if (start_after) |cursor_key| if (std.mem.order(u8, key, cursor_key) != .gt) continue;

        const read_result = (try self.ref_store.get(gpa, key, null)).?;
        defer RefStore.freeReadResult(gpa, read_result);
        try items.append(gpa, .{
            .namespace = try gpa.dupe(u8, identity.namespace),
            .doc_type = try gpa.dupe(u8, identity.doc_type),
            .id = try gpa.dupe(u8, identity.id),
            .version = try gpa.dupe(u8, read_result.version),
        });
        if (items.items.len == page_size) {
            next_cursor = try encodeListCursor(gpa, key);
            break;
        }
    }

    return .{ .summary = .{
        .items = try items.toOwnedSlice(gpa),
        .next_cursor = next_cursor,
    } };
}

pub fn delete(self: DocumentStore, gpa: Allocator, request: DeleteRequest) !DeleteResult {
    const identity: Identity = .{
        .namespace = request.namespace orelse default_namespace,
        .doc_type = request.doc_type,
        .id = request.id,
    };
    const key = try deriveKey(gpa, identity);
    defer gpa.free(key);

    const existing = try self.ref_store.get(gpa, key, null);
    defer if (existing) |read_result| RefStore.freeReadResult(gpa, read_result);
    if (existing != null) try self.ref_store.delete(key);

    return .{
        .namespace = try gpa.dupe(u8, identity.namespace),
        .doc_type = try gpa.dupe(u8, identity.doc_type),
        .id = try gpa.dupe(u8, identity.id),
        .deleted = existing != null,
    };
}

pub fn history(self: DocumentStore, gpa: Allocator, request: HistoryRequest) !HistoryResult {
    const identity = normalizeIdentity(request.namespace, request.doc_type, request.id);
    const key = try deriveKey(gpa, identity);
    defer gpa.free(key);
    const versions = try self.ref_store.history(gpa, key);
    defer RefStore.freeVersions(gpa, versions);
    return try buildSummaryHistoryPage(gpa, identity, versions, request.limit, request.cursor);
}
```

- [ ] **Step 5: Run the test suite to verify summary-mode behavior passes**

Run: `zig build test`
Expected: PASS for the new summary list/history/delete coverage.

- [ ] **Step 6: Commit**

```bash
git add src/core/document.zig tests/document_store_test.zig
git commit -m "feat: add summary document traversal results"
```

### Task 3: Add Detailed Results, JSON Transport, And WASM Exports

**Files:**
- Modify: `src/core/document.zig`
- Modify: `src/core/document_transport.zig`
- Modify: `src/wasm/root.zig`
- Test: `tests/document_store_test.zig`
- Test: `tests/document_transport_test.zig`

- [ ] **Step 1: Write failing tests for detailed results and transport handlers**

```zig
test "DocumentStore list detailed returns canonical envelopes with data" {
    const page = try document_store.list(gpa, .{
        .mode = .detailed,
        .limit = 1,
    });
    defer page.deinit(gpa);

    switch (page) {
        .detailed => |detailed| {
            try std.testing.expectEqualStrings("detailed", detailed.kind);
            var parsed = try std.json.parseFromSlice(std.json.Value, gpa, detailed.items[0], .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("issue", parsed.value.object.get("type").?.string);
            try std.testing.expect(parsed.value.object.get("data") != null);
        },
        else => return error.UnexpectedSummaryPage,
    }
}

test "document transport handles list history and delete JSON requests" {
    const list_response = try sideshowdb.document_transport.handleList(
        gpa,
        document_store,
        "{\"limit\":\"1\",\"mode\":\"summary\"}",
    );
    defer gpa.free(list_response);
    try std.testing.expect(std.mem.indexOf(u8, list_response, "\"kind\":\"summary\"") != null);

    const delete_response = try sideshowdb.document_transport.handleDelete(
        gpa,
        document_store,
        "{\"type\":\"issue\",\"id\":\"transport-1\"}",
    );
    defer gpa.free(delete_response);
    try std.testing.expect(std.mem.indexOf(u8, delete_response, "\"deleted\":true") != null);
}
```

- [ ] **Step 2: Run the test suite to verify it fails on missing detailed/transport behavior**

Run: `zig build test`
Expected: FAIL with compile errors for missing `handleList`, `handleDelete`, `handleHistory`, or failing assertions about missing `data`.

- [ ] **Step 3: Implement detailed page builders and JSON encoders**

```zig
fn buildDetailedListResult(
    self: DocumentStore,
    gpa: Allocator,
    request: ListRequest,
    keys: [][]u8,
) !ListResult {
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |item| gpa.free(item);
        items.deinit(gpa);
    }

    for (keys) |key| {
        const read_result = (try self.ref_store.get(gpa, key, null)).?;
        defer RefStore.freeReadResult(gpa, read_result);

        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, read_result.value, .{});
        defer parsed.deinit();
        const stored = try parseStoredEnvelope(parsed.value);

        const encoded = try encodeEnvelope(gpa, stored.identity, read_result.version, stored.data);
        try items.append(gpa, encoded);
    }

    return .{ .detailed = .{
        .items = try items.toOwnedSlice(gpa),
        .next_cursor = request_next_cursor,
    } };
}
```

- [ ] **Step 4: Add transport handlers and WASM exports**

```zig
pub fn handleList(
    gpa: Allocator,
    store: document.DocumentStore,
    request_json: []const u8,
) ![]u8 {
    const request = try parseListRequest(gpa, request_json);
    const result = try store.list(gpa, request);
    defer result.deinit(gpa);
    return encodeListResultJson(gpa, result);
}

pub fn handleDelete(
    gpa: Allocator,
    store: document.DocumentStore,
    request_json: []const u8,
) ![]u8 {
    const request = try parseDeleteRequest(gpa, request_json);
    const result = try store.delete(gpa, request);
    defer result.deinit(gpa);
    return encodeDeleteResultJson(gpa, result);
}

pub fn handleHistory(
    gpa: Allocator,
    store: document.DocumentStore,
    request_json: []const u8,
) ![]u8 {
    const request = try parseHistoryRequest(gpa, request_json);
    const result = try store.history(gpa, request);
    defer result.deinit(gpa);
    return encodeHistoryResultJson(gpa, result);
}

export fn sideshowdb_document_list(request_ptr: [*]const u8, request_len: usize) u32 {
    const response = sideshowdb.document_transport.handleList(
        std.heap.wasm_allocator,
        wasmStore(),
        request_ptr[0..request_len],
    ) catch return 1;
    setResult(response);
    return 0;
}
```

- [ ] **Step 5: Run the test suite to verify detailed mode and transport pass**

Run: `zig build test`
Expected: PASS, including detailed page assertions and transport JSON assertions.

- [ ] **Step 6: Commit**

```bash
git add src/core/document.zig src/core/document_transport.zig src/wasm/root.zig tests/document_store_test.zig tests/document_transport_test.zig
git commit -m "feat: add detailed document traversal transport"
```

### Task 4: Add Universal `--json` Parsing And JSON CLI Command Paths

**Files:**
- Modify: `src/cli/app.zig`
- Test: `tests/cli_test.zig`

- [ ] **Step 1: Write failing CLI tests for `--json` and new commands**

```zig
test "CLI doc commands emit JSON only when --json is supplied" {
    const json_list = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "--json", "doc", "list", "--mode", "summary" },
        "",
    );
    defer json_list.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), json_list.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, json_list.stdout, "\"kind\":\"summary\"") != null);
}

test "CLI doc delete and history accept traversal flags" {
    const history_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "--json", "doc", "history", "--type", "issue", "--id", "cli-1", "--limit", "1" },
        "",
    );
    defer history_result.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, history_result.stdout, "\"items\"") != null);
}
```

- [ ] **Step 2: Run the test suite to verify it fails on missing flags/subcommands**

Run: `zig build test`
Expected: FAIL with usage failures or compile errors for missing `list`, `history`, `delete`, or `--json` support.

- [ ] **Step 3: Add global CLI options and JSON command execution**

```zig
const GlobalOptions = struct {
    json: bool = false,
    argv: []const []const u8,
};

fn parseGlobalOptions(args: []const []const u8) !GlobalOptions {
    var json = false;
    var filtered: std.ArrayList([]const u8) = .empty;
    errdefer filtered.deinit(std.heap.page_allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            continue;
        }
        try filtered.append(std.heap.page_allocator, arg);
    }

    return .{ .json = json, .argv = try filtered.toOwnedSlice(std.heap.page_allocator) };
}

if (std.mem.eql(u8, parsed_args[2], "list")) {
    const request = try parseListArgs(gpa, parsed_args[3..]);
    const result = try store.list(gpa, request);
    defer result.deinit(gpa);
    const stdout = if (global.json)
        try sideshowdb.document_transport.encodeListResultJson(gpa, result)
    else
        try output.renderListResult(gpa, result);
    return success(gpa, stdout);
}
```

- [ ] **Step 4: Expand argument parsers for list/history/delete**

```zig
const ListArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: ?[]const u8 = null,
    limit: ?usize = null,
    cursor: ?[]const u8 = null,
    mode: sideshowdb.document.CollectionMode = .summary,
};

const HistoryArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    limit: ?usize = null,
    cursor: ?[]const u8 = null,
    mode: sideshowdb.document.CollectionMode = .summary,
};

const DeleteArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
};
```

- [ ] **Step 5: Run the test suite to verify JSON CLI behavior passes**

Run: `zig build test`
Expected: PASS for `--json` command routing and JSON result assertions.

- [ ] **Step 6: Commit**

```bash
git add src/cli/app.zig tests/cli_test.zig
git commit -m "feat: add json document cli traversal commands"
```

### Task 5: Add Human CLI Renderers And Switch Defaults

**Files:**
- Create: `src/cli/output.zig`
- Modify: `src/cli/app.zig`
- Test: `tests/cli_test.zig`

- [ ] **Step 1: Write failing CLI tests for property and table output**

```zig
test "CLI doc get defaults to property output" {
    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "doc", "get", "--type", "issue", "--id", "cli-1" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "namespace: default") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "title") != null);
}

test "CLI doc list defaults to table output" {
    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "doc", "list" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "NAMESPACE") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "default") != null);
}
```

- [ ] **Step 2: Run the test suite to verify it fails on current JSON defaults**

Run: `zig build test`
Expected: FAIL because stdout still contains JSON instead of property/table output.

- [ ] **Step 3: Create `src/cli/output.zig` with property and table renderers**

```zig
const std = @import("std");
const document = @import("../core/document.zig");

pub fn renderProperties(
    gpa: std.mem.Allocator,
    pairs: []const struct { key: []const u8, value: []const u8 },
) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    for (pairs) |pair| try buffer.writer(gpa).print("{s}: {s}\n", .{ pair.key, pair.value });
    return buffer.toOwnedSlice(gpa);
}

pub fn renderListResult(gpa: std.mem.Allocator, result: document.ListResult) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    try buffer.writer(gpa).writeAll("NAMESPACE\tTYPE\tID\tVERSION\n");
    switch (result) {
        .summary => |page| for (page.items) |item|
            try buffer.writer(gpa).print("{s}\t{s}\t{s}\t{s}\n", .{
                item.namespace, item.doc_type, item.id, item.version,
            }),
        .detailed => |page| for (page.items) |encoded|
            try writeDetailedRow(gpa, &buffer, encoded),
    }
    return buffer.toOwnedSlice(gpa);
}
```

- [ ] **Step 4: Switch non-JSON defaults to the new renderer**

```zig
const output = @import("output.zig");

const stdout = if (global.json)
    try sideshowdb.document_transport.encodeHistoryResultJson(gpa, result)
else
    try output.renderHistoryResult(gpa, result);

const delete_stdout = if (global.json)
    try sideshowdb.document_transport.encodeDeleteResultJson(gpa, deleted)
else
    try output.renderDeleteResult(gpa, deleted);
```

- [ ] **Step 5: Run the test suite to verify human defaults and JSON opt-in both pass**

Run: `zig build test`
Expected: PASS, including property-style `put/get/delete`, table-style `list/history`, and `--json` JSON assertions.

- [ ] **Step 6: Commit**

```bash
git add src/cli/output.zig src/cli/app.zig tests/cli_test.zig
git commit -m "feat: add human-readable cli renderers"
```

### Task 6: Full Regression Verification And Final Cleanup

**Files:**
- Modify: `tests/document_store_test.zig`
- Modify: `tests/document_transport_test.zig`
- Modify: `tests/cli_test.zig`
- Modify: `tests/git_ref_store_test.zig`

- [ ] **Step 1: Add boundary and negative tests not yet covered**

```zig
test "DocumentStore rejects oversized limits and invalid cursors" {
    try std.testing.expectError(error.InvalidLimit, document_store.list(gpa, .{
        .limit = 201,
    }));
    try std.testing.expectError(error.InvalidCursor, document_store.history(gpa, .{
        .doc_type = "issue",
        .id = "doc-1",
        .cursor = "%%%bad%%%",
    }));
}

test "CLI rejects unsupported mode with usage failure" {
    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "--json", "doc", "list", "--mode", "verbose" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}
```

- [ ] **Step 2: Run the full project test suite**

Run: `zig build test`
Expected: PASS across core, git-ref, document, transport, and CLI tests.

- [ ] **Step 3: Inspect the final diff for only intended files**

Run: `git status --short`
Expected: Only the planned source, test, and docs files are modified; no accidental `.DS_Store` additions are staged.

- [ ] **Step 4: Commit**

```bash
git add tests/git_ref_store_test.zig tests/document_store_test.zig tests/document_transport_test.zig tests/cli_test.zig
git commit -m "test: cover document traversal edge cases"
```
