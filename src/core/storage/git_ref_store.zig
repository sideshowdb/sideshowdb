//! Subprocess-driven `RefStore` implementation backed by the user's `git`
//! binary. See `docs/development/specs/git-ref-storage-spec.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;
const RefStore = @import("ref_store.zig").RefStore;

pub const GitRefStore = struct {
    gpa: Allocator,
    io: Io,
    parent_env: *const Environ.Map,
    repo_path: []const u8,
    ref_name: []const u8,
    git_executable: []const u8,
    author_name: []const u8,
    author_email: []const u8,

    pub const Options = struct {
        gpa: Allocator,
        io: Io,
        parent_env: *const Environ.Map,
        repo_path: []const u8,
        ref_name: []const u8,
        git_executable: []const u8 = "git",
        author_name: []const u8 = "sideshowdb",
        author_email: []const u8 = "sideshowdb@local",
    };

    pub const Error = error{
        GitNotFound,
        GitInvocationFailed,
        InvalidKey,
    } || Allocator.Error || std.process.RunError || std.Io.File.OpenError ||
        std.Io.Writer.Error;

    pub fn init(options: Options) GitRefStore {
        return .{
            .gpa = options.gpa,
            .io = options.io,
            .parent_env = options.parent_env,
            .repo_path = options.repo_path,
            .ref_name = options.ref_name,
            .git_executable = options.git_executable,
            .author_name = options.author_name,
            .author_email = options.author_email,
        };
    }

    pub fn refStore(self: *GitRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: RefStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .delete = vtableDelete,
        .list = vtableList,
    };

    fn vtablePut(ctx: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.VersionId {
        const self: *GitRefStore = @ptrCast(@alignCast(ctx));
        return self.put(gpa, key, value);
    }
    fn vtableGet(ctx: *anyopaque, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        const self: *GitRefStore = @ptrCast(@alignCast(ctx));
        return self.get(gpa, key, version);
    }
    fn vtableDelete(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *GitRefStore = @ptrCast(@alignCast(ctx));
        return self.delete(key);
    }
    fn vtableList(ctx: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        const self: *GitRefStore = @ptrCast(@alignCast(ctx));
        return self.list(gpa);
    }

    pub fn put(self: *GitRefStore, gpa: Allocator, key: []const u8, value: []const u8) Error!RefStore.VersionId {
        try validateKey(key);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const blob_sha = try self.writeBlob(arena, value);
        const tmp_index = try self.tempPath(arena, "index", "idx");
        defer self.deleteIfExists(tmp_index);

        if (try self.currentTreeSha(arena)) |tree| {
            try self.runOk(arena, &.{ "read-tree", tree }, tmp_index);
        }

        const cacheinfo = try std.fmt.allocPrint(arena, "100644,{s},{s}", .{ blob_sha, key });
        try self.runOk(arena, &.{ "update-index", "--add", "--cacheinfo", cacheinfo }, tmp_index);

        const new_tree_raw = try self.runCapture(arena, &.{"write-tree"}, tmp_index);
        const new_tree = std.mem.trim(u8, new_tree_raw, "\n\r");

        const version = try self.commitAndUpdate(arena, new_tree, "put", key);
        return try gpa.dupe(u8, version);
    }

    pub fn get(self: *GitRefStore, gpa: Allocator, key: []const u8, requested_version: ?RefStore.VersionId) Error!?RefStore.ReadResult {
        try validateKey(key);
        const resolved_version = if (requested_version) |version|
            try gpa.dupe(u8, version)
        else blk: {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const current = try self.currentCommitSha(arena_state.allocator()) orelse return null;
            break :blk try gpa.dupe(u8, current);
        };
        errdefer gpa.free(resolved_version);

        const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ resolved_version, key });
        defer gpa.free(spec);

        const result = try self.runRaw(gpa, &.{ "cat-file", "-p", spec }, null);
        gpa.free(result.stderr);
        if (!isExitOk(result.term)) {
            gpa.free(result.stdout);
            gpa.free(resolved_version);
            return null;
        }
        return .{
            .value = result.stdout,
            .version = resolved_version,
        };
    }

    pub fn delete(self: *GitRefStore, key: []const u8) Error!void {
        try validateKey(key);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const current_tree = try self.currentTreeSha(arena) orelse return;
        if (!try self.keyExists(arena, key)) return;

        const tmp_index = try self.tempPath(arena, "index", "idx");
        defer self.deleteIfExists(tmp_index);

        try self.runOk(arena, &.{ "read-tree", current_tree }, tmp_index);
        try self.runOk(arena, &.{ "update-index", "--remove", "--", key }, tmp_index);

        const new_tree_raw = try self.runCapture(arena, &.{"write-tree"}, tmp_index);
        const new_tree = std.mem.trim(u8, new_tree_raw, "\n\r");

        _ = try self.commitAndUpdate(arena, new_tree, "delete", key);
    }

    pub fn list(self: *GitRefStore, gpa: Allocator) Error![][]u8 {
        if (!try self.refExists(gpa)) return try gpa.alloc([]u8, 0);

        const result = try self.runRaw(gpa, &.{ "ls-tree", "--name-only", "-r", "-z", self.ref_name }, null);
        defer gpa.free(result.stderr);
        defer gpa.free(result.stdout);
        if (!isExitOk(result.term)) return error.GitInvocationFailed;

        var keys: std.ArrayList([]u8) = .empty;
        errdefer {
            for (keys.items) |k| gpa.free(k);
            keys.deinit(gpa);
        }
        var it = std.mem.splitScalar(u8, result.stdout, 0);
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            const dup = try gpa.dupe(u8, entry);
            errdefer gpa.free(dup);
            try keys.append(gpa, dup);
        }
        return keys.toOwnedSlice(gpa);
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// Validates that the given key is a valid git tree entry name.
    /// This is a bit more restrictive than git's actual rules
    /// (e.g. we disallow leading/trailing slashes and
    /// consecutive slashes for simplicity), but it should be sufficient for our use case.
    /// See https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-aiddefpathspecapathspec for more details on what git allows.
    /// Note that we also disallow the null byte, since that's a common string terminator
    /// and could cause issues in our code.
    fn validateKey(key: []const u8) Error!void {
        if (key.len == 0) return error.InvalidKey;
        if (key[0] == '/') return error.InvalidKey;
        if (key[key.len - 1] == '/') return error.InvalidKey;
        if (std.mem.indexOf(u8, key, "//") != null) return error.InvalidKey;
        if (std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidKey;
    }

    fn writeBlob(self: *GitRefStore, arena: Allocator, value: []const u8) Error![]const u8 {
        const tmp = try self.tempPath(arena, "blob", "tmp");
        defer self.deleteIfExists(tmp);

        {
            var file = try Io.Dir.createFileAbsolute(self.io, tmp, .{ .truncate = true });
            defer file.close(self.io);
            var buf: [4096]u8 = undefined;
            var w = file.writer(self.io, &buf);
            try w.interface.writeAll(value);
            try w.interface.flush();
        }

        const sha_raw = try self.runCapture(arena, &.{ "hash-object", "-w", "--", tmp }, null);
        return std.mem.trim(u8, sha_raw, "\n\r");
    }

    fn currentTreeSha(self: *GitRefStore, arena: Allocator) Error!?[]const u8 {
        const spec = try std.fmt.allocPrint(arena, "{s}^{{tree}}", .{self.ref_name});
        const result = try self.runRaw(arena, &.{ "rev-parse", "--verify", "--quiet", spec }, null);
        if (!isExitOk(result.term)) return null;
        return std.mem.trim(u8, result.stdout, "\n\r");
    }

    fn currentCommitSha(self: *GitRefStore, arena: Allocator) Error!?[]const u8 {
        const result = try self.runRaw(arena, &.{ "rev-parse", "--verify", "--quiet", self.ref_name }, null);
        if (!isExitOk(result.term)) return null;
        return std.mem.trim(u8, result.stdout, "\n\r");
    }

    fn refExists(self: *GitRefStore, gpa: Allocator) Error!bool {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        return (try self.currentCommitSha(arena_state.allocator())) != null;
    }

    fn keyExists(self: *GitRefStore, arena: Allocator, key: []const u8) Error!bool {
        const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ self.ref_name, key });
        const result = try self.runRaw(arena, &.{ "cat-file", "-e", spec }, null);
        return isExitOk(result.term);
    }

    fn tempPath(self: *GitRefStore, arena: Allocator, kind: []const u8, ext: []const u8) Error![]const u8 {
        var bytes: [8]u8 = undefined;
        self.io.random(&bytes);
        const r = std.mem.readInt(u64, &bytes, .little);
        return std.fmt.allocPrint(arena, "{s}/.git/sideshowdb-{s}-{x}.{s}", .{ self.repo_path, kind, r, ext });
    }

    fn deleteIfExists(self: *GitRefStore, abs_path: []const u8) void {
        Io.Dir.deleteFileAbsolute(self.io, abs_path) catch {};
    }

    fn commitAndUpdate(
        self: *GitRefStore,
        arena: Allocator,
        tree_sha: []const u8,
        op_label: []const u8,
        key: []const u8,
    ) Error![]const u8 {
        const parent = try self.currentCommitSha(arena);
        const message = try std.fmt.allocPrint(arena, "sideshowdb: {s} {s}", .{ op_label, key });

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "commit-tree", tree_sha });
        if (parent) |p| try argv.appendSlice(arena, &.{ "-p", p });
        try argv.appendSlice(arena, &.{ "-m", message });

        const new_commit_raw = try self.runCapture(arena, argv.items, null);
        const new_commit = std.mem.trim(u8, new_commit_raw, "\n\r");

        if (parent) |p| {
            try self.runOk(arena, &.{ "update-ref", self.ref_name, new_commit, p }, null);
        } else {
            try self.runOk(arena, &.{ "update-ref", self.ref_name, new_commit }, null);
        }
        return new_commit;
    }

    // ── process plumbing ─────────────────────────────────────────────────

    const RawResult = struct {
        term: std.process.Child.Term,
        stdout: []u8,
        stderr: []u8,
    };

    fn runRaw(
        self: *GitRefStore,
        gpa: Allocator,
        args: []const []const u8,
        index_file: ?[]const u8,
    ) Error!RawResult {
        var local_arena_state = std.heap.ArenaAllocator.init(gpa);
        defer local_arena_state.deinit();
        const local = local_arena_state.allocator();

        const user_name = try std.fmt.allocPrint(local, "user.name={s}", .{self.author_name});
        const user_email = try std.fmt.allocPrint(local, "user.email={s}", .{self.author_email});

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(local, &.{
            self.git_executable,
            "-c",
            user_name,
            "-c",
            user_email,
            "-C",
            self.repo_path,
        });
        for (args) |a| try argv.append(local, a);

        var env = try self.parent_env.clone(local);
        if (index_file) |idx| try env.put("GIT_INDEX_FILE", idx);

        const result = std.process.run(gpa, self.io, .{
            .argv = argv.items,
            .environ_map = &env,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            else => |e| return e,
        };

        return .{
            .term = result.term,
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }

    fn runOk(
        self: *GitRefStore,
        gpa: Allocator,
        args: []const []const u8,
        index_file: ?[]const u8,
    ) Error!void {
        const result = try self.runRaw(gpa, args, index_file);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (!isExitOk(result.term)) {
            std.log.warn("git {s} failed: {s}", .{ args[0], result.stderr });
            return error.GitInvocationFailed;
        }
    }

    fn runCapture(
        self: *GitRefStore,
        gpa: Allocator,
        args: []const []const u8,
        index_file: ?[]const u8,
    ) Error![]u8 {
        const result = try self.runRaw(gpa, args, index_file);
        defer gpa.free(result.stderr);
        if (!isExitOk(result.term)) {
            std.log.warn("git {s} failed: {s}", .{ args[0], result.stderr });
            gpa.free(result.stdout);
            return error.GitInvocationFailed;
        }
        return result.stdout;
    }
};

fn isExitOk(term: std.process.Child.Term) bool {
    return term == .exited and term.exited == 0;
}
