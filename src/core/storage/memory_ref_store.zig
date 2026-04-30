//! In-process, in-memory `RefStore` implementation.
//!
//! Volatile by design — all data is lost when the store is dropped. Compiles
//! against any target the standard library supports, including
//! `wasm32-freestanding`, because it depends only on `std.mem.Allocator`,
//! `std.ArrayList`, `std.StringHashMapUnmanaged`, and `std.fmt`.
//!
//! Use this backend when you want a `RefStore` without any host facilities
//! (filesystem, subprocess, network) — for example, the WASM browser client
//! or unit tests that should not touch disk.

const std = @import("std");
const Allocator = std.mem.Allocator;
const RefStore = @import("ref_store.zig").RefStore;

/// In-process, in-memory `RefStore`. Stores every put as a (version, value)
/// entry on a per-key history list and tracks tombstones so deleted keys
/// disappear from `list` while remaining reachable through version-pinned
/// `get` and `history` calls.
pub const MemoryRefStore = struct {
    /// Configuration accepted by `MemoryRefStore.init`. The store owns
    /// every byte it stores; the only borrowed resource is the allocator,
    /// which must outlive the store.
    pub const Options = struct {
        gpa: Allocator,
    };

    const Entry = struct {
        version: []u8,
        value: []u8,
    };

    const KeyState = struct {
        history: std.ArrayList(Entry),
        deleted: bool,
    };

    gpa: Allocator,
    next_version: u64,
    keys: std.StringHashMapUnmanaged(KeyState),

    /// Build an empty `MemoryRefStore`. Pure constructor — no allocations
    /// are performed until the first write.
    pub fn init(options: Options) MemoryRefStore {
        return .{
            .gpa = options.gpa,
            .next_version = 1,
            .keys = .{},
        };
    }

    /// Release every byte owned by the store. Must be called exactly once
    /// per successful `init`.
    pub fn deinit(self: *MemoryRefStore) void {
        var it = self.keys.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            for (entry.value_ptr.history.items) |hist_entry| {
                self.gpa.free(hist_entry.version);
                self.gpa.free(hist_entry.value);
            }
            entry.value_ptr.history.deinit(self.gpa);
        }
        self.keys.deinit(self.gpa);
    }

    /// Return the type-erased `RefStore` view over `self`. The view holds a
    /// pointer to `self`; the underlying `MemoryRefStore` must outlive every
    /// returned view.
    pub fn refStore(self: *MemoryRefStore) RefStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: RefStore.VTable = .{
        .put = vtablePut,
        .get = vtableGet,
        .delete = vtableDelete,
        .list = vtableList,
        .history = vtableHistory,
    };

    fn vtablePut(ctx: *anyopaque, gpa: Allocator, key: []const u8, value: []const u8) anyerror!RefStore.PutResult {
        const self: *MemoryRefStore = @ptrCast(@alignCast(ctx));
        return .{ .version = try self.put(gpa, key, value) };
    }

    fn vtableGet(ctx: *anyopaque, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) anyerror!?RefStore.ReadResult {
        const self: *MemoryRefStore = @ptrCast(@alignCast(ctx));
        return self.get(gpa, key, version);
    }

    fn vtableDelete(ctx: *anyopaque, key: []const u8) anyerror!void {
        const self: *MemoryRefStore = @ptrCast(@alignCast(ctx));
        return self.delete(key);
    }

    fn vtableList(ctx: *anyopaque, gpa: Allocator) anyerror![][]u8 {
        const self: *MemoryRefStore = @ptrCast(@alignCast(ctx));
        return self.list(gpa);
    }

    fn vtableHistory(ctx: *anyopaque, gpa: Allocator, key: []const u8) anyerror![]RefStore.VersionId {
        const self: *MemoryRefStore = @ptrCast(@alignCast(ctx));
        return self.history(gpa, key);
    }

    /// See `RefStore.put`. Appends a new versioned entry to `key`'s history,
    /// clears any prior tombstone, and returns the freshly minted version
    /// identifier. Caller owns the returned slice.
    pub fn put(self: *MemoryRefStore, gpa: Allocator, key: []const u8, value: []const u8) !RefStore.VersionId {
        try RefStore.validateKey(key);

        const version_internal = try self.mintVersion();
        errdefer self.gpa.free(version_internal);

        const value_internal = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(value_internal);

        const gop = try self.keys.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            const owned_key = self.gpa.dupe(u8, key) catch |err| {
                self.keys.removeByPtr(gop.key_ptr);
                return err;
            };
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{ .history = .empty, .deleted = false };
        }

        try gop.value_ptr.history.append(self.gpa, .{
            .version = version_internal,
            .value = value_internal,
        });
        gop.value_ptr.deleted = false;

        return try gpa.dupe(u8, version_internal);
    }

    /// See `RefStore.get`. With `version == null`, returns the latest entry
    /// for `key` unless the key is tombstoned. With an explicit version,
    /// returns the matching historical entry regardless of tombstone state.
    pub fn get(self: *MemoryRefStore, gpa: Allocator, key: []const u8, version: ?RefStore.VersionId) !?RefStore.ReadResult {
        try RefStore.validateKey(key);

        const state = self.keys.getPtr(key) orelse return null;
        if (version) |requested| {
            for (state.history.items) |entry| {
                if (std.mem.eql(u8, entry.version, requested)) {
                    return .{
                        .value = try gpa.dupe(u8, entry.value),
                        .version = try gpa.dupe(u8, entry.version),
                    };
                }
            }
            return null;
        }

        if (state.deleted) return null;
        if (state.history.items.len == 0) return null;
        const latest = state.history.items[state.history.items.len - 1];
        return .{
            .value = try gpa.dupe(u8, latest.value),
            .version = try gpa.dupe(u8, latest.version),
        };
    }

    /// See `RefStore.delete`. Marks `key` as tombstoned. History is retained
    /// so version-pinned `get` calls still resolve. Idempotent if the key is
    /// absent or already tombstoned.
    pub fn delete(self: *MemoryRefStore, key: []const u8) !void {
        try RefStore.validateKey(key);
        const state = self.keys.getPtr(key) orelse return;
        state.deleted = true;
    }

    /// See `RefStore.list`. Returns every live (non-tombstoned) key in
    /// ascending byte order. Caller owns the outer slice and each inner key.
    pub fn list(self: *MemoryRefStore, gpa: Allocator) ![][]u8 {
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |k| gpa.free(k);
            out.deinit(gpa);
        }

        var it = self.keys.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.deleted) continue;
            if (entry.value_ptr.history.items.len == 0) continue;
            try out.append(gpa, try gpa.dupe(u8, entry.key_ptr.*));
        }

        std.sort.block([]u8, out.items, {}, struct {
            fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);

        return try out.toOwnedSlice(gpa);
    }

    /// See `RefStore.history`. Returns every recorded version for `key` in
    /// newest-first order. Tombstoned keys retain their history. Caller owns
    /// the outer slice and each version string.
    pub fn history(self: *MemoryRefStore, gpa: Allocator, key: []const u8) ![]RefStore.VersionId {
        try RefStore.validateKey(key);

        const state = self.keys.getPtr(key) orelse return try gpa.alloc(RefStore.VersionId, 0);

        var versions = try gpa.alloc(RefStore.VersionId, state.history.items.len);
        errdefer {
            for (versions, 0..) |v, i| {
                if (i >= state.history.items.len) break;
                gpa.free(v);
            }
            gpa.free(versions);
        }

        var i: usize = 0;
        while (i < state.history.items.len) : (i += 1) {
            const src = state.history.items[state.history.items.len - 1 - i];
            versions[i] = try gpa.dupe(u8, src.version);
        }
        return versions;
    }

    fn mintVersion(self: *MemoryRefStore) ![]u8 {
        const id = self.next_version;
        self.next_version += 1;
        return std.fmt.allocPrint(self.gpa, "{d}", .{id});
    }
};
