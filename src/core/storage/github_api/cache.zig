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

/// Raw JSON bodies keyed by Git object SHA (commits, trees, blobs are immutable on GitHub).
pub const ObjectBodyCache = struct {
    commits: std.StringHashMapUnmanaged([]u8) = .{},
    trees: std.StringHashMapUnmanaged([]u8) = .{},
    blobs: std.StringHashMapUnmanaged([]u8) = .{},

    fn deinitMap(gpa: Allocator, map: *std.StringHashMapUnmanaged([]u8)) void {
        var it = map.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        map.deinit(gpa);
    }

    pub fn deinit(self: *ObjectBodyCache, gpa: Allocator) void {
        deinitMap(gpa, &self.commits);
        deinitMap(gpa, &self.trees);
        deinitMap(gpa, &self.blobs);
    }

    pub fn getCommit(self: *const ObjectBodyCache, sha: []const u8) ?[]const u8 {
        return self.commits.get(sha);
    }

    pub fn getTree(self: *const ObjectBodyCache, sha: []const u8) ?[]const u8 {
        return self.trees.get(sha);
    }

    pub fn getBlob(self: *const ObjectBodyCache, sha: []const u8) ?[]const u8 {
        return self.blobs.get(sha);
    }

    fn putInMap(
        gpa: Allocator,
        map: *std.StringHashMapUnmanaged([]u8),
        sha: []const u8,
        body: []const u8,
    ) Allocator.Error!void {
        if (map.fetchRemove(sha)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
        }
        const owned_key = try gpa.dupe(u8, sha);
        errdefer gpa.free(owned_key);
        const owned_val = try gpa.dupe(u8, body);
        errdefer gpa.free(owned_val);
        try map.put(gpa, owned_key, owned_val);
    }

    pub fn putCommit(self: *ObjectBodyCache, gpa: Allocator, sha: []const u8, body: []const u8) Allocator.Error!void {
        try putInMap(gpa, &self.commits, sha, body);
    }

    pub fn putTree(self: *ObjectBodyCache, gpa: Allocator, sha: []const u8, body: []const u8) Allocator.Error!void {
        try putInMap(gpa, &self.trees, sha, body);
    }

    pub fn putBlob(self: *ObjectBodyCache, gpa: Allocator, sha: []const u8, body: []const u8) Allocator.Error!void {
        try putInMap(gpa, &self.blobs, sha, body);
    }
};
