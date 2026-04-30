//! In-memory caches for GitHub Git Database API traffic (ref tip ETag + immutable objects).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Remembers the last observed ref tip commit SHA together with its `ETag`.
pub const RefTipCache = struct {
    commit_sha: ?[]u8 = null,
    etag: ?[]u8 = null,

    pub const Entry = struct {
        commit_sha: []const u8,
        etag: []const u8,
    };

    pub fn invalidate(self: *RefTipCache, gpa: Allocator) void {
        if (self.commit_sha) |s| gpa.free(s);
        if (self.etag) |s| gpa.free(s);
        self.commit_sha = null;
        self.etag = null;
    }

    pub fn lookup(self: *const RefTipCache) ?Entry {
        const sha = self.commit_sha orelse return null;
        const et = self.etag orelse return null;
        return .{ .commit_sha = sha, .etag = et };
    }

    /// Replaces any prior entry with freshly allocated copies of `commit_sha` and `etag`.
    pub fn record(self: *RefTipCache, gpa: Allocator, commit_sha: []const u8, etag: []const u8) Allocator.Error!void {
        self.invalidate(gpa);
        self.commit_sha = try gpa.dupe(u8, commit_sha);
        self.etag = try gpa.dupe(u8, etag);
    }
};

const LruItem = struct {
    key: []u8,
    value: []u8,
};

/// LRU-ordered JSON bodies keyed by Git object SHA, bounded by total key+value bytes.
pub const ShaBodyLruCache = struct {
    max_bytes: usize,
    used: usize = 0,
    items: std.ArrayListUnmanaged(LruItem) = .empty,

    pub fn init(max_bytes: usize) ShaBodyLruCache {
        return .{ .max_bytes = max_bytes };
    }

    pub fn deinit(self: *ShaBodyLruCache, gpa: Allocator) void {
        for (self.items.items) |it| {
            gpa.free(it.key);
            gpa.free(it.value);
        }
        self.items.deinit(gpa);
    }

    fn entryCost(key: []const u8, value: []const u8) usize {
        return key.len + value.len;
    }

    fn removeIndex(self: *ShaBodyLruCache, gpa: Allocator, index: usize) void {
        const victim = self.items.orderedRemove(index);
        self.used -= entryCost(victim.key, victim.value);
        gpa.free(victim.key);
        gpa.free(victim.value);
    }

    fn removeBySha(self: *ShaBodyLruCache, gpa: Allocator, sha: []const u8) bool {
        for (self.items.items, 0..) |it, i| {
            if (std.mem.eql(u8, it.key, sha)) {
                self.removeIndex(gpa, i);
                return true;
            }
        }
        return false;
    }

    /// Returns a slice into cached memory and promotes the entry to most-recently used.
    pub fn get(self: *ShaBodyLruCache, gpa: Allocator, sha: []const u8) Allocator.Error!?[]const u8 {
        for (self.items.items, 0..) |it, i| {
            if (std.mem.eql(u8, it.key, sha)) {
                const node = self.items.orderedRemove(i);
                try self.items.append(gpa, node);
                return self.items.items[self.items.items.len - 1].value;
            }
        }
        return null;
    }

    /// Inserts or replaces `sha` → dup of `body`, evicting LRU entries until within `max_bytes`
    /// (a single entry larger than `max_bytes` is still stored alone).
    pub fn put(self: *ShaBodyLruCache, gpa: Allocator, sha: []const u8, body: []const u8) Allocator.Error!void {
        _ = self.removeBySha(gpa, sha);

        const new_cost = entryCost(sha, body);
        while (self.items.items.len > 0 and self.used + new_cost > self.max_bytes) {
            self.removeIndex(gpa, 0);
        }

        const owned_key = try gpa.dupe(u8, sha);
        errdefer gpa.free(owned_key);
        const owned_val = try gpa.dupe(u8, body);
        self.used += entryCost(owned_key, owned_val);
        try self.items.append(gpa, .{ .key = owned_key, .value = owned_val });
    }
};

/// Three independent LRU caches for commit, tree, and blob JSON bodies.
pub const ObjectBodyCache = struct {
    commits: ShaBodyLruCache,
    trees: ShaBodyLruCache,
    blobs: ShaBodyLruCache,

    pub fn init(max_bytes_per_kind: usize) ObjectBodyCache {
        return .{
            .commits = ShaBodyLruCache.init(max_bytes_per_kind),
            .trees = ShaBodyLruCache.init(max_bytes_per_kind),
            .blobs = ShaBodyLruCache.init(max_bytes_per_kind),
        };
    }

    pub fn deinit(self: *ObjectBodyCache, gpa: Allocator) void {
        self.commits.deinit(gpa);
        self.trees.deinit(gpa);
        self.blobs.deinit(gpa);
    }

    pub fn getCommit(self: *ObjectBodyCache, gpa: Allocator, sha: []const u8) Allocator.Error!?[]const u8 {
        return self.commits.get(gpa, sha);
    }

    pub fn getTree(self: *ObjectBodyCache, gpa: Allocator, sha: []const u8) Allocator.Error!?[]const u8 {
        return self.trees.get(gpa, sha);
    }

    pub fn getBlob(self: *ObjectBodyCache, gpa: Allocator, sha: []const u8) Allocator.Error!?[]const u8 {
        return self.blobs.get(gpa, sha);
    }

    pub fn putCommit(self: *ObjectBodyCache, gpa: Allocator, sha: []const u8, body: []const u8) Allocator.Error!void {
        try self.commits.put(gpa, sha, body);
    }

    pub fn putTree(self: *ObjectBodyCache, gpa: Allocator, sha: []const u8, body: []const u8) Allocator.Error!void {
        try self.trees.put(gpa, sha, body);
    }

    pub fn putBlob(self: *ObjectBodyCache, gpa: Allocator, sha: []const u8, body: []const u8) Allocator.Error!void {
        try self.blobs.put(gpa, sha, body);
    }
};

test "cache_test_blob_lru_eviction" {
    const gpa = std.testing.allocator;
    var cache = ShaBodyLruCache.init(25);
    defer cache.deinit(gpa);

    try cache.put(gpa, "sha-a", "payload-a"); // 5+9=14
    try cache.put(gpa, "sha-b", "payload-bb"); // 5+10=15 — evicts a (14+15>25 → drop a, used=15)
    try std.testing.expect(cache.get(gpa, "sha-a") catch unreachable == null);
    const vb = (try cache.get(gpa, "sha-b")).?;
    try std.testing.expectEqualStrings("payload-bb", vb);

    try cache.put(gpa, "sha-c", "payload-ccc"); // 5+11=16 — evicts b then fits c alone after evicting b
    try std.testing.expect(cache.get(gpa, "sha-b") catch unreachable == null);
    const vc = (try cache.get(gpa, "sha-c")).?;
    try std.testing.expectEqualStrings("payload-ccc", vc);
}
