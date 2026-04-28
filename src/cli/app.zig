const std = @import("std");
const sideshowdb = @import("sideshowdb");
const output = @import("output.zig");
const refstore_selector = @import("refstore_selector.zig");
const Environ = std.process.Environ;

const Allocator = std.mem.Allocator;

pub const usage_message = "usage: sideshowdb [--json] [--refstore ziggit|subprocess] <version|doc <put|get|list|delete|history>>\n";

const refstore_invalid_message = "unsupported refstore: expected ziggit or subprocess\n";

pub const RunResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: RunResult, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

pub fn run(
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    repo_path: []const u8,
    argv: []const []const u8,
    stdin_data: []const u8,
) !RunResult {
    const global = parseGlobalOptions(gpa, argv) catch |err| switch (err) {
        error.InvalidRefStore => return failure(gpa, refstore_invalid_message),
        else => return usageFailure(gpa),
    };
    defer gpa.free(global.argv);

    if (global.argv.len >= 2 and std.mem.eql(u8, global.argv[1], "version")) {
        return versionSuccess(gpa);
    }

    if (global.argv.len < 3) return usageFailure(gpa);
    if (!std.mem.eql(u8, global.argv[1], "doc")) return usageFailure(gpa);

    const backend = global.refstore orelse .ziggit;
    var subprocess_store: sideshowdb.SubprocessGitRefStore = undefined;
    var ziggit_store: sideshowdb.ZiggitRefStore = undefined;
    const ref_store: sideshowdb.RefStore = switch (backend) {
        .ziggit => blk: {
            ziggit_store = sideshowdb.ZiggitRefStore.init(.{
                .gpa = gpa,
                .repo_path = repo_path,
                .ref_name = "refs/sideshowdb/documents",
            });
            break :blk ziggit_store.refStore();
        },
        .subprocess => blk: {
            subprocess_store = sideshowdb.SubprocessGitRefStore.init(.{
                .gpa = gpa,
                .io = io,
                .parent_env = env,
                .repo_path = repo_path,
                .ref_name = "refs/sideshowdb/documents",
            });
            break :blk subprocess_store.refStore();
        },
    };
    const store = sideshowdb.DocumentStore.init(ref_store);

    if (std.mem.eql(u8, global.argv[2], "put")) {
        const parsed = parsePutArgs(global.argv[3..]) catch return usageFailure(gpa);
        const encoded = try store.put(gpa, sideshowdb.document.PutRequest.fromOverrides(
            stdin_data,
            parsed.namespace,
            parsed.doc_type,
            parsed.id,
        ));
        errdefer gpa.free(encoded);
        const stdout = if (global.json)
            encoded
        else blk: {
            defer gpa.free(encoded);
            break :blk try output.renderEnvelopeJson(gpa, encoded);
        };
        return success(gpa, stdout);
    }

    if (std.mem.eql(u8, global.argv[2], "get")) {
        const parsed = parseGetArgs(global.argv[3..]) catch return usageFailure(gpa);
        const encoded = try store.get(gpa, .{
            .namespace = parsed.namespace,
            .doc_type = parsed.doc_type,
            .id = parsed.id,
            .version = parsed.version,
        });
        if (encoded) |json| {
            errdefer gpa.free(json);
            const stdout = if (global.json)
                json
            else blk: {
                defer gpa.free(json);
                break :blk try output.renderEnvelopeJson(gpa, json);
            };
            return success(gpa, stdout);
        }
        return failure(gpa, "document not found\n");
    }

    if (std.mem.eql(u8, global.argv[2], "list")) {
        const parsed = parseListArgs(global.argv[3..]) catch return usageFailure(gpa);
        const result = try store.list(gpa, .{
            .namespace = parsed.namespace,
            .doc_type = parsed.doc_type,
            .limit = parsed.limit,
            .cursor = parsed.cursor,
            .mode = parsed.mode,
        });
        defer result.deinit(gpa);

        const stdout = if (global.json)
            try sideshowdb.document_transport.encodeListResultJson(gpa, result)
        else
            try output.renderListResult(gpa, result);
        return success(gpa, stdout);
    }

    if (std.mem.eql(u8, global.argv[2], "delete")) {
        const parsed = parseDeleteArgs(global.argv[3..]) catch return usageFailure(gpa);
        const result = try store.delete(gpa, .{
            .namespace = parsed.namespace,
            .doc_type = parsed.doc_type,
            .id = parsed.id,
        });
        defer result.deinit(gpa);

        const stdout = if (global.json)
            try sideshowdb.document_transport.encodeDeleteResultJson(gpa, result)
        else
            try output.renderDeleteResult(gpa, result);
        return success(gpa, stdout);
    }

    if (std.mem.eql(u8, global.argv[2], "history")) {
        const parsed = parseHistoryArgs(global.argv[3..]) catch return usageFailure(gpa);
        const result = try store.history(gpa, .{
            .namespace = parsed.namespace,
            .doc_type = parsed.doc_type,
            .id = parsed.id,
            .limit = parsed.limit,
            .cursor = parsed.cursor,
            .mode = parsed.mode,
        });
        defer result.deinit(gpa);

        const stdout = if (global.json)
            try sideshowdb.document_transport.encodeHistoryResultJson(gpa, result)
        else
            try output.renderHistoryResult(gpa, result);
        return success(gpa, stdout);
    }

    return usageFailure(gpa);
}

const GlobalOptions = struct {
    json: bool = false,
    refstore: ?refstore_selector.RefStoreBackend = null,
    argv: [][]const u8,
};

const ParseGlobalError = error{
    OutOfMemory,
    InvalidArguments,
    InvalidRefStore,
};

const PutArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

const GetArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    version: ?[]const u8 = null,
};

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

fn parseGlobalOptions(gpa: Allocator, argv: []const []const u8) ParseGlobalError!GlobalOptions {
    var filtered: std.ArrayList([]const u8) = .empty;
    errdefer filtered.deinit(gpa);

    var json = false;
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

    return .{
        .json = json,
        .refstore = refstore,
        .argv = try filtered.toOwnedSlice(gpa),
    };
}

fn parsePutArgs(args: []const []const u8) !PutArgs {
    var result: PutArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--namespace")) {
            result.namespace = value;
        } else if (std.mem.eql(u8, flag, "--type")) {
            result.doc_type = value;
        } else if (std.mem.eql(u8, flag, "--id")) {
            result.id = value;
        } else {
            return error.InvalidArguments;
        }
    }
    return result;
}

fn parseGetArgs(args: []const []const u8) !GetArgs {
    var namespace: ?[]const u8 = null;
    var doc_type: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var version: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--namespace")) {
            namespace = value;
        } else if (std.mem.eql(u8, flag, "--type")) {
            doc_type = value;
        } else if (std.mem.eql(u8, flag, "--id")) {
            id = value;
        } else if (std.mem.eql(u8, flag, "--version")) {
            version = value;
        } else {
            return error.InvalidArguments;
        }
    }

    return .{
        .namespace = namespace,
        .doc_type = doc_type orelse return error.InvalidArguments,
        .id = id orelse return error.InvalidArguments,
        .version = version,
    };
}

fn parseListArgs(args: []const []const u8) !ListArgs {
    var result: ListArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--namespace")) {
            result.namespace = value;
        } else if (std.mem.eql(u8, flag, "--type")) {
            result.doc_type = value;
        } else if (std.mem.eql(u8, flag, "--limit")) {
            result.limit = parseLimit(value) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, flag, "--cursor")) {
            result.cursor = value;
        } else if (std.mem.eql(u8, flag, "--mode")) {
            result.mode = parseMode(value) catch return error.InvalidArguments;
        } else {
            return error.InvalidArguments;
        }
    }
    return result;
}

fn parseHistoryArgs(args: []const []const u8) !HistoryArgs {
    var namespace: ?[]const u8 = null;
    var doc_type: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var limit: ?usize = null;
    var cursor: ?[]const u8 = null;
    var mode: sideshowdb.document.CollectionMode = .summary;

    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--namespace")) {
            namespace = value;
        } else if (std.mem.eql(u8, flag, "--type")) {
            doc_type = value;
        } else if (std.mem.eql(u8, flag, "--id")) {
            id = value;
        } else if (std.mem.eql(u8, flag, "--limit")) {
            limit = parseLimit(value) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, flag, "--cursor")) {
            cursor = value;
        } else if (std.mem.eql(u8, flag, "--mode")) {
            mode = parseMode(value) catch return error.InvalidArguments;
        } else {
            return error.InvalidArguments;
        }
    }

    return .{
        .namespace = namespace,
        .doc_type = doc_type orelse return error.InvalidArguments,
        .id = id orelse return error.InvalidArguments,
        .limit = limit,
        .cursor = cursor,
        .mode = mode,
    };
}

fn parseDeleteArgs(args: []const []const u8) !DeleteArgs {
    var namespace: ?[]const u8 = null;
    var doc_type: ?[]const u8 = null;
    var id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--namespace")) {
            namespace = value;
        } else if (std.mem.eql(u8, flag, "--type")) {
            doc_type = value;
        } else if (std.mem.eql(u8, flag, "--id")) {
            id = value;
        } else {
            return error.InvalidArguments;
        }
    }

    return .{
        .namespace = namespace,
        .doc_type = doc_type orelse return error.InvalidArguments,
        .id = id orelse return error.InvalidArguments,
    };
}

fn parseLimit(value: []const u8) !usize {
    return std.fmt.parseInt(usize, value, 10);
}

fn parseMode(value: []const u8) !sideshowdb.document.CollectionMode {
    if (std.mem.eql(u8, value, "summary")) return .summary;
    if (std.mem.eql(u8, value, "detailed")) return .detailed;
    return error.InvalidArguments;
}

fn success(gpa: Allocator, stdout: []u8) !RunResult {
    return .{
        .exit_code = 0,
        .stdout = stdout,
        .stderr = try gpa.dupe(u8, ""),
    };
}

fn failure(gpa: Allocator, message: []const u8) !RunResult {
    return .{
        .exit_code = 1,
        .stdout = try gpa.dupe(u8, ""),
        .stderr = try gpa.dupe(u8, message),
    };
}

fn usageFailure(gpa: Allocator) !RunResult {
    return failure(gpa, usage_message);
}

fn versionSuccess(gpa: Allocator) !RunResult {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try sideshowdb.writeBanner(&writer);
    return success(gpa, try gpa.dupe(u8, writer.buffered()));
}
