//! Native `RefStore` prototype backed by the vendored `ziggit` sources.

const std = @import("std");
const RefStore = @import("ref_store.zig").RefStore;
const refs = @import("ziggit_pkg/git/refs.zig");
const objects = @import("ziggit_pkg/git/objects.zig");
const objects_parser = @import("ziggit_pkg/lib/objects_parser.zig");

const Platform = struct {
    fs: FileSystem,

    const FileSystem = struct {
        exists: *const fn (path: []const u8) anyerror!bool,
        makeDir: *const fn (path: []const u8) anyerror!void,
        readFile: *const fn (allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
        writeFile: *const fn (path: []const u8, data: []const u8) anyerror!void,
        deleteFile: *const fn (path: []const u8) anyerror!void,
        getCwd: *const fn (allocator: std.mem.Allocator) anyerror![]u8,
        chdir: *const fn (path: []const u8) anyerror!void,
        readDir: *const fn (allocator: std.mem.Allocator, path: []const u8) anyerror![][]u8,
        stat: *const fn (path: []const u8) anyerror!std.Io.File.Stat,
    };
};

fn platformExists(path: []const u8) !bool {
    std.Io.Dir.accessAbsolute(std.Options.debug_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn platformMakeDir(path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(std.Options.debug_io, path, .{});
    dir.close(std.Options.debug_io);
}

fn platformReadFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(std.math.maxInt(usize)),
    );
}

fn platformWriteFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{
        .sub_path = path,
        .data = data,
    });
}

fn platformDeleteFile(path: []const u8) !void {
    try std.Io.Dir.deleteFileAbsolute(std.Options.debug_io, path);
}

fn platformGetCwd(allocator: std.mem.Allocator) ![]u8 {
    return try std.process.currentPathAlloc(std.Options.debug_io, allocator);
}

fn platformChdir(path: []const u8) !void {
    _ = path;
}

fn platformReadDir(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    var dir = try std.Io.Dir.openDirAbsolute(std.Options.debug_io, path, .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return try names.toOwnedSlice(allocator);
}

fn platformStat(path: []const u8) !std.Io.File.Stat {
    var file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{});
    defer file.close(std.Options.debug_io);
    return try file.stat(std.Options.debug_io);
}

const platform_instance: Platform = .{
    .fs = .{
        .exists = platformExists,
        .makeDir = platformMakeDir,
        .readFile = platformReadFile,
        .writeFile = platformWriteFile,
        .deleteFile = platformDeleteFile,
        .getCwd = platformGetCwd,
        .chdir = platformChdir,
        .readDir = platformReadDir,
        .stat = platformStat,
    },
};

const native_platform = &platform_instance;

/// In-process `RefStore` implementation backed by the vendored `ziggit_pkg`
/// sources. Drives the on-disk Git layout directly without spawning the
/// user's `git` binary.
pub const ZiggitRefStore = struct {
    /// Configuration accepted by `ZiggitRefStore.init`. The store borrows
    /// every slice; callers must keep that memory alive for the store's
    /// lifetime.
    pub const Options = struct {
        gpa: std.mem.Allocator,
        repo_path: []const u8,
        ref_name: []const u8,
        author_name: []const u8 = "sideshowdb",
        author_email: []const u8 = "sideshowdb@local",
    };

    const OwnedTreeEntry = struct {
        mode: []u8,
        name: []u8,
        hash: []u8,

        fn deinit(self: OwnedTreeEntry, gpa: std.mem.Allocator) void {
            gpa.free(self.mode);
            gpa.free(self.name);
            gpa.free(self.hash);
        }
    };

    gpa: std.mem.Allocator,
    repo_path: []const u8,
    ref_name: []const u8,
    author_name: []const u8,
    author_email: []const u8,

    /// Build a `ZiggitRefStore` from `options`. Pure constructor: performs
    /// no I/O. The store borrows every slice in `options`; callers must keep
    /// that memory alive for the store's lifetime.
    pub fn init(options: Options) ZiggitRefStore {
        return .{
            .gpa = options.gpa,
            .repo_path = options.repo_path,
            .ref_name = options.ref_name,
            .author_name = options.author_name,
            .author_email = options.author_email,
        };
    }

    /// Return the type-erased `RefStore` view over `self`. The view holds a
    /// pointer to `self`; the underlying `ZiggitRefStore` must outlive every
    /// returned view.
    pub fn refStore(self: *ZiggitRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: RefStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .delete = vtableDelete,
        .list = vtableList,
        .history = vtableHistory,
    };

    fn vtablePut(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8, value: []const u8) anyerror!RefStore.VersionId {
        const self: *ZiggitRefStore = @ptrCast(@alignCast(ctx));
        return self.put(gpa, key, value);
    }

    fn vtableGet(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8, version: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        const self: *ZiggitRefStore = @ptrCast(@alignCast(ctx));
        return self.get(gpa, key, version);
    }

    fn vtableDelete(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *ZiggitRefStore = @ptrCast(@alignCast(ctx));
        return self.delete(key);
    }

    fn vtableList(ctx: *anyopaque, gpa: std.mem.Allocator) anyerror![][]u8 {
        const self: *ZiggitRefStore = @ptrCast(@alignCast(ctx));
        return self.list(gpa);
    }

    fn vtableHistory(ctx: *anyopaque, gpa: std.mem.Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        const self: *ZiggitRefStore = @ptrCast(@alignCast(ctx));
        return self.history(gpa, key);
    }

    /// See `RefStore.put`. Writes the blob to the on-disk Git layout under
    /// `repo_path` and advances `ref_name` to the resulting commit. The
    /// returned `VersionId` is the new commit SHA. Caller owns the slice.
    pub fn put(self: *ZiggitRefStore, gpa: std.mem.Allocator, key: []const u8, value: []const u8) !RefStore.VersionId {
        try validateKey(key);

        const git_dir = try self.ensureGitDir();
        defer self.gpa.free(git_dir);

        const blob_hash = try self.storeBlob(git_dir, value);
        defer self.gpa.free(blob_hash);

        const current_commit = try self.resolveStoreRef(git_dir);
        defer if (current_commit) |hash| self.gpa.free(hash);

        const current_tree = if (current_commit) |hash|
            try self.loadCommitTreeHash(git_dir, hash)
        else
            null;
        defer if (current_tree) |hash| self.gpa.free(hash);

        const new_tree = try self.rewriteTree(git_dir, current_tree, key, blob_hash);
        defer if (new_tree) |hash| self.gpa.free(hash);

        const tree_hash = if (new_tree) |hash|
            hash
        else
            return error.UnexpectedEmptyTree;

        const version = try self.commitTree(git_dir, current_commit, tree_hash, "put", key);
        defer self.gpa.free(version);
        try refs.updateRef(git_dir, self.ref_name, version, native_platform, self.gpa);
        return try gpa.dupe(u8, version);
    }

    /// See `RefStore.get`. Reads the blob at `key` from the latest reachable
    /// version of `ref_name`, or from `requested_version` if non-null. Caller
    /// owns the returned slices and must release them with
    /// `RefStore.freeReadResult`.
    pub fn get(self: *ZiggitRefStore, gpa: std.mem.Allocator, key: []const u8, requested_version: ?RefStore.VersionId) !?RefStore.ReadResult {
        try validateKey(key);

        const git_dir = try self.ensureGitDir();
        defer self.gpa.free(git_dir);

        const resolved_version = if (requested_version) |version|
            try self.gpa.dupe(u8, version)
        else
            (try self.resolveStoreRef(git_dir)) orelse return null;
        defer self.gpa.free(resolved_version);

        const blob_hash = try self.findBlobAtCommit(git_dir, resolved_version, key);
        defer if (blob_hash) |hash| self.gpa.free(hash);
        if (blob_hash == null) return null;

        const blob = try objects.GitObject.load(blob_hash.?, git_dir, native_platform, self.gpa);
        defer blob.deinit(self.gpa);
        if (blob.type != .blob) return error.NotABlob;

        return .{
            .value = try gpa.dupe(u8, blob.data),
            .version = try gpa.dupe(u8, resolved_version),
        };
    }

    /// See `RefStore.delete`. Removes `key` from the current tree under
    /// `ref_name` and records a new commit. Idempotent if the key is absent.
    pub fn delete(self: *ZiggitRefStore, key: []const u8) !void {
        try validateKey(key);

        const git_dir = try self.ensureGitDir();
        defer self.gpa.free(git_dir);

        const current_commit = try self.resolveStoreRef(git_dir) orelse return;
        defer self.gpa.free(current_commit);

        const existing = try self.findBlobAtCommit(git_dir, current_commit, key);
        defer if (existing) |hash| self.gpa.free(hash);
        if (existing == null) return;

        const current_tree = try self.loadCommitTreeHash(git_dir, current_commit);
        defer self.gpa.free(current_tree);

        const maybe_tree = try self.rewriteTree(git_dir, current_tree, key, null);
        defer if (maybe_tree) |hash| self.gpa.free(hash);

        const new_tree = if (maybe_tree) |hash|
            hash
        else
            try self.storeEmptyTree(git_dir);
        defer if (maybe_tree == null) self.gpa.free(new_tree);

        const version = try self.commitTree(git_dir, current_commit, new_tree, "delete", key);
        defer self.gpa.free(version);
        try refs.updateRef(git_dir, self.ref_name, version, native_platform, self.gpa);
    }

    /// See `RefStore.list`. Enumerates every key currently reachable from
    /// `ref_name`. Caller owns the outer slice and each inner key; release
    /// them with `RefStore.freeKeys`.
    pub fn list(self: *ZiggitRefStore, gpa: std.mem.Allocator) ![][]u8 {
        const git_dir = try self.ensureGitDir();
        defer self.gpa.free(git_dir);

        const current_commit = try self.resolveStoreRef(git_dir) orelse return try gpa.alloc([]u8, 0);
        defer self.gpa.free(current_commit);

        const tree_hash = try self.loadCommitTreeHash(git_dir, current_commit);
        defer self.gpa.free(tree_hash);

        var keys: std.ArrayList([]u8) = .empty;
        errdefer {
            for (keys.items) |key| gpa.free(key);
            keys.deinit(gpa);
        }

        try self.collectTreeKeys(git_dir, tree_hash, "", gpa, &keys);

        std.sort.block([]u8, keys.items, {}, struct {
            fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);

        return try keys.toOwnedSlice(gpa);
    }

    /// See `RefStore.history`. Returns reachable versions of `key` newest
    /// first. Caller owns the outer slice and each version; release them
    /// with `RefStore.freeVersions`.
    pub fn history(self: *ZiggitRefStore, gpa: std.mem.Allocator, key: []const u8) ![]RefStore.VersionId {
        try validateKey(key);

        const git_dir = try self.ensureGitDir();
        defer self.gpa.free(git_dir);

        var versions: std.ArrayList(RefStore.VersionId) = .empty;
        errdefer {
            for (versions.items) |version| gpa.free(version);
            versions.deinit(gpa);
        }

        var current = try self.resolveStoreRef(git_dir);
        while (current) |commit_hash| {
            defer self.gpa.free(commit_hash);

            const maybe_blob = try self.findBlobAtCommit(git_dir, commit_hash, key);
            defer if (maybe_blob) |hash| self.gpa.free(hash);
            const parent = try self.loadFirstParent(git_dir, commit_hash);
            defer if (parent) |hash| self.gpa.free(hash);
            const parent_blob = if (parent) |parent_hash|
                try self.findBlobAtCommit(git_dir, parent_hash, key)
            else
                null;
            defer if (parent_blob) |hash| self.gpa.free(hash);

            if (maybe_blob) |blob_hash| {
                if (parent_blob == null or !std.mem.eql(u8, blob_hash, parent_blob.?)) {
                    try versions.append(gpa, try gpa.dupe(u8, commit_hash));
                }
            }

            current = if (parent) |parent_hash|
                try self.gpa.dupe(u8, parent_hash)
            else
                null;
        }

        return try versions.toOwnedSlice(gpa);
    }

    fn ensureGitDir(self: *ZiggitRefStore) ![]u8 {
        const io = std.Options.debug_io;
        const git_dir = try std.fs.path.join(self.gpa, &.{ self.repo_path, ".git" });
        errdefer self.gpa.free(git_dir);

        const head_path = try std.fs.path.join(self.gpa, &.{ git_dir, "HEAD" });
        defer self.gpa.free(head_path);
        if (std.Io.Dir.cwd().access(io, head_path, .{})) |_| return git_dir else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        var repo_dir = try std.Io.Dir.cwd().createDirPathOpen(io, self.repo_path, .{});
        repo_dir.close(io);

        var git_root_dir = try std.Io.Dir.cwd().createDirPathOpen(io, git_dir, .{});
        git_root_dir.close(io);

        const objects_dir = try std.fs.path.join(self.gpa, &.{ git_dir, "objects" });
        defer self.gpa.free(objects_dir);
        var objects_handle = try std.Io.Dir.cwd().createDirPathOpen(io, objects_dir, .{});
        objects_handle.close(io);

        const refs_heads_dir = try std.fs.path.join(self.gpa, &.{ git_dir, "refs", "heads" });
        defer self.gpa.free(refs_heads_dir);
        var refs_heads_handle = try std.Io.Dir.cwd().createDirPathOpen(io, refs_heads_dir, .{});
        refs_heads_handle.close(io);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = head_path, .data = "ref: refs/heads/master\n" });
        return git_dir;
    }

    fn resolveStoreRef(self: *ZiggitRefStore, git_dir: []const u8) !?[]u8 {
        return refs.resolveRef(git_dir, self.ref_name, native_platform, self.gpa) catch |err| switch (err) {
            error.RefNotFound => null,
            else => err,
        };
    }

    fn storeBlob(self: *ZiggitRefStore, git_dir: []const u8, value: []const u8) ![]u8 {
        var blob = try objects.createBlobObject(value, self.gpa);
        defer blob.deinit(self.gpa);
        return try blob.store(git_dir, native_platform, self.gpa);
    }

    fn storeEmptyTree(self: *ZiggitRefStore, git_dir: []const u8) ![]u8 {
        const no_entries = [_]objects.TreeEntry{};
        var tree = try objects.createTreeObject(&no_entries, self.gpa);
        defer tree.deinit(self.gpa);
        return try tree.store(git_dir, native_platform, self.gpa);
    }

    fn commitTree(self: *ZiggitRefStore, git_dir: []const u8, parent_commit: ?[]const u8, tree_hash: []const u8, op: []const u8, key: []const u8) ![]u8 {
        const author = try self.commitIdentity();
        defer self.gpa.free(author);
        const message = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ op, key });
        defer self.gpa.free(message);

        var parents_buf: [1][]const u8 = undefined;
        const parents: []const []const u8 = if (parent_commit) |parent| blk: {
            parents_buf[0] = parent;
            break :blk parents_buf[0..1];
        } else &.{};

        var commit = try objects.createCommitObject(tree_hash, parents, author, author, message, self.gpa);
        defer commit.deinit(self.gpa);
        return try commit.store(git_dir, native_platform, self.gpa);
    }

    fn commitIdentity(self: *ZiggitRefStore) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s} <{s}> {d} +0000", .{
            self.author_name,
            self.author_email,
            0,
        });
    }

    fn loadCommitTreeHash(self: *ZiggitRefStore, git_dir: []const u8, commit_hash: []const u8) ![]u8 {
        const commit = try objects.GitObject.load(commit_hash, git_dir, native_platform, self.gpa);
        defer commit.deinit(self.gpa);
        if (commit.type != .commit) return error.NotACommit;

        var info = try objects_parser.parseCommit(self.gpa, commit.data);
        defer info.deinit();

        var tree_hash: [40]u8 = undefined;
        objects_parser.shaToHex(&info.tree_sha, &tree_hash);
        return try self.gpa.dupe(u8, &tree_hash);
    }

    fn loadFirstParent(self: *ZiggitRefStore, git_dir: []const u8, commit_hash: []const u8) !?[]u8 {
        const commit = try objects.GitObject.load(commit_hash, git_dir, native_platform, self.gpa);
        defer commit.deinit(self.gpa);
        if (commit.type != .commit) return error.NotACommit;

        var info = try objects_parser.parseCommit(self.gpa, commit.data);
        defer info.deinit();
        if (info.parent_shas.len == 0) return null;

        var parent_hash: [40]u8 = undefined;
        objects_parser.shaToHex(&info.parent_shas[0], &parent_hash);
        return try self.gpa.dupe(u8, &parent_hash);
    }

    fn findBlobAtCommit(self: *ZiggitRefStore, git_dir: []const u8, commit_hash: []const u8, key: []const u8) !?[]u8 {
        const tree_hash = try self.loadCommitTreeHash(git_dir, commit_hash);
        defer self.gpa.free(tree_hash);
        return try self.findBlobAtTree(git_dir, tree_hash, key);
    }

    fn findBlobAtTree(self: *ZiggitRefStore, git_dir: []const u8, tree_hash: []const u8, key: []const u8) !?[]u8 {
        const tree = try objects.GitObject.load(tree_hash, git_dir, native_platform, self.gpa);
        defer tree.deinit(self.gpa);
        if (tree.type != .tree) return error.NotATree;

        var parsed: std.array_list.Managed(objects_parser.TreeEntry) = .init(self.gpa);
        defer parsed.deinit();
        try objects_parser.parseTree(tree.data, &parsed);

        const slash = std.mem.indexOfScalar(u8, key, '/');
        const name = if (slash) |idx| key[0..idx] else key;
        const remainder = if (slash) |idx| key[idx + 1 ..] else null;

        for (parsed.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;

            var hash_hex: [40]u8 = undefined;
            objects_parser.shaToHex(&entry.sha1, &hash_hex);

            if (remainder) |rest| {
                if (!isTreeMode(entry.mode)) return null;
                return try self.findBlobAtTree(git_dir, &hash_hex, rest);
            }
            if (isTreeMode(entry.mode)) return null;
            return try self.gpa.dupe(u8, &hash_hex);
        }
        return null;
    }

    fn rewriteTree(self: *ZiggitRefStore, git_dir: []const u8, current_tree_hash: ?[]const u8, path: []const u8, new_blob_hash: ?[]const u8) !?[]u8 {
        var entries = try self.loadOwnedTreeEntries(git_dir, current_tree_hash);
        defer {
            for (entries.items) |entry| entry.deinit(self.gpa);
            entries.deinit(self.gpa);
        }

        const slash = std.mem.indexOfScalar(u8, path, '/');
        const name = if (slash) |idx| path[0..idx] else path;
        const remainder = if (slash) |idx| path[idx + 1 ..] else null;

        const maybe_index = findEntryIndex(entries.items, name);
        if (remainder) |rest| {
            const existing_tree = if (maybe_index) |idx|
                try self.gpa.dupe(u8, entries.items[idx].hash)
            else
                null;
            defer if (existing_tree) |hash| self.gpa.free(hash);

            const next_tree = try self.rewriteTree(git_dir, existing_tree, rest, new_blob_hash);
            defer if (next_tree) |hash| self.gpa.free(hash);

            if (next_tree) |hash| {
                const owned_name = try self.gpa.dupe(u8, name);
                errdefer self.gpa.free(owned_name);
                const replacement = OwnedTreeEntry{
                    .mode = try self.gpa.dupe(u8, "040000"),
                    .name = owned_name,
                    .hash = try self.gpa.dupe(u8, hash),
                };
                try upsertEntry(self.gpa, &entries, maybe_index, replacement);
            } else if (maybe_index) |idx| {
                removeEntry(self.gpa, &entries, idx);
            }
        } else if (new_blob_hash) |hash| {
            const owned_name = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(owned_name);
            const replacement = OwnedTreeEntry{
                .mode = try self.gpa.dupe(u8, "100644"),
                .name = owned_name,
                .hash = try self.gpa.dupe(u8, hash),
            };
            try upsertEntry(self.gpa, &entries, maybe_index, replacement);
        } else if (maybe_index) |idx| {
            removeEntry(self.gpa, &entries, idx);
        }

        if (entries.items.len == 0) return null;

        var object_entries = try self.gpa.alloc(objects.TreeEntry, entries.items.len);
        defer self.gpa.free(object_entries);
        for (entries.items, 0..) |entry, idx| {
            object_entries[idx] = objects.TreeEntry.init(entry.mode, entry.name, entry.hash);
        }

        var tree = try objects.createTreeObject(object_entries, self.gpa);
        defer tree.deinit(self.gpa);
        return try tree.store(git_dir, native_platform, self.gpa);
    }

    fn loadOwnedTreeEntries(self: *ZiggitRefStore, git_dir: []const u8, maybe_tree_hash: ?[]const u8) !std.ArrayList(OwnedTreeEntry) {
        var entries: std.ArrayList(OwnedTreeEntry) = .empty;
        if (maybe_tree_hash == null) return entries;

        const tree = try objects.GitObject.load(maybe_tree_hash.?, git_dir, native_platform, self.gpa);
        defer tree.deinit(self.gpa);
        if (tree.type != .tree) return error.NotATree;

        var parsed: std.array_list.Managed(objects_parser.TreeEntry) = .init(self.gpa);
        defer parsed.deinit();
        try objects_parser.parseTree(tree.data, &parsed);

        try entries.ensureTotalCapacity(self.gpa, parsed.items.len);
        for (parsed.items) |entry| {
            var hash_hex: [40]u8 = undefined;
            objects_parser.shaToHex(&entry.sha1, &hash_hex);
            entries.appendAssumeCapacity(.{
                .mode = try self.gpa.dupe(u8, try modeToString(entry.mode)),
                .name = try self.gpa.dupe(u8, entry.name),
                .hash = try self.gpa.dupe(u8, &hash_hex),
            });
        }
        return entries;
    }

    fn collectTreeKeys(self: *ZiggitRefStore, git_dir: []const u8, tree_hash: []const u8, prefix: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList([]u8)) !void {
        const tree = try objects.GitObject.load(tree_hash, git_dir, native_platform, self.gpa);
        defer tree.deinit(self.gpa);
        if (tree.type != .tree) return error.NotATree;

        var parsed: std.array_list.Managed(objects_parser.TreeEntry) = .init(self.gpa);
        defer parsed.deinit();
        try objects_parser.parseTree(tree.data, &parsed);

        for (parsed.items) |entry| {
            const full_path = if (prefix.len == 0)
                try std.fmt.allocPrint(self.gpa, "{s}", .{entry.name})
            else
                try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ prefix, entry.name });
            defer self.gpa.free(full_path);

            if (isTreeMode(entry.mode)) {
                var child_hash: [40]u8 = undefined;
                objects_parser.shaToHex(&entry.sha1, &child_hash);
                try self.collectTreeKeys(git_dir, &child_hash, full_path, gpa, out);
            } else {
                try out.append(gpa, try gpa.dupe(u8, full_path));
            }
        }
    }
};

fn findEntryIndex(entries: []const ZiggitRefStore.OwnedTreeEntry, name: []const u8) ?usize {
    for (entries, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.name, name)) return idx;
    }
    return null;
}

fn upsertEntry(gpa: std.mem.Allocator, entries: *std.ArrayList(ZiggitRefStore.OwnedTreeEntry), maybe_index: ?usize, replacement: ZiggitRefStore.OwnedTreeEntry) !void {
    if (maybe_index) |idx| {
        entries.items[idx].deinit(gpa);
        entries.items[idx] = replacement;
        return;
    }
    try entries.append(gpa, replacement);
}

fn removeEntry(gpa: std.mem.Allocator, entries: *std.ArrayList(ZiggitRefStore.OwnedTreeEntry), idx: usize) void {
    entries.items[idx].deinit(gpa);
    _ = entries.orderedRemove(idx);
}

fn validateKey(key: []const u8) !void {
    if (key.len == 0) return error.InvalidKey;
    if (key[0] == '/') return error.InvalidKey;
    if (key[key.len - 1] == '/') return error.InvalidKey;
    if (std.mem.indexOf(u8, key, "//") != null) return error.InvalidKey;
    if (std.mem.indexOfScalar(u8, key, 0) != null) return error.InvalidKey;
}

fn isTreeMode(mode: u32) bool {
    return mode == 0o040000;
}

fn modeToString(mode: u32) ![]const u8 {
    return switch (mode) {
        0o100644 => "100644",
        0o100755 => "100755",
        0o120000 => "120000",
        0o040000 => "040000",
        0o160000 => "160000",
        else => error.UnsupportedMode,
    };
}
