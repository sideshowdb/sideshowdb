const std = @import("std");
const sideshowdb = @import("sideshowdb");
const generated_usage = @import("sideshowdb_cli_generated_usage");
const output = @import("output.zig");
const refstore_selector = @import("refstore_selector.zig");
const usage_runtime = @import("sideshowdb_cli_usage_runtime");
const Environ = std.process.Environ;

const Allocator = std.mem.Allocator;

pub const usage_message = generated_usage.usage_message ++ "\n";

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
    var parsed = usage_runtime.parseArgv(gpa, &generated_usage.spec, argv) catch |err| switch (err) {
        error.InvalidChoice => {
            if (hasInvalidRefstoreChoice(argv)) return failure(gpa, refstore_invalid_message);
            return usageFailure(gpa);
        },
        else => return usageFailure(gpa),
    };
    defer parsed.deinit(gpa);

    const refstore = if (parsed.flagValue("--refstore")) |value|
        refstore_selector.RefStoreBackend.parse(value) orelse return failure(gpa, refstore_invalid_message)
    else
        null;
    const json = parsed.hasFlag("--json");

    if (parsed.command_path.len == 1 and std.mem.eql(u8, parsed.command_path[0], "version")) {
        return versionSuccess(gpa);
    }

    if (parsed.command_path.len != 2) return usageFailure(gpa);
    if (!std.mem.eql(u8, parsed.command_path[0], "doc")) return usageFailure(gpa);

    const selection = refstore_selector.resolve(gpa, repo_path, env, refstore) catch |err| switch (err) {
        error.InvalidRefStore => return failure(gpa, refstore_invalid_message),
        error.InvalidRefStoreConfig => return failure(gpa, "invalid refstore config: expected [storage] refstore = \"ziggit\" or \"subprocess\"\n"),
        error.ConfigReadFailed => return failure(gpa, "failed to read .sideshowdb/config.toml\n"),
        error.OutOfMemory => return error.OutOfMemory,
    };
    var subprocess_store: sideshowdb.SubprocessGitRefStore = undefined;
    var ziggit_store: sideshowdb.ZiggitRefStore = undefined;
    const ref_store: sideshowdb.RefStore = switch (selection.backend) {
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

    if (std.mem.eql(u8, parsed.command_path[1], "put")) {
        const put_args = parsePutArgs(&parsed);
        var file_payload: ?[]u8 = null;
        defer if (file_payload) |bytes| gpa.free(bytes);
        if (put_args.data_file) |path| {
            file_payload = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
                const message = try std.fmt.allocPrint(
                    gpa,
                    "failed to read --data-file {s}: {t}\n",
                    .{ path, err },
                );
                defer gpa.free(message);
                return failure(gpa, message);
            };
        }
        const payload: []const u8 = if (file_payload) |bytes| bytes else stdin_data;
        const encoded = try store.put(gpa, sideshowdb.document.PutRequest.fromOverrides(
            payload,
            put_args.namespace,
            put_args.doc_type,
            put_args.id,
        ));
        errdefer gpa.free(encoded);
        const stdout = if (json)
            encoded
        else blk: {
            defer gpa.free(encoded);
            break :blk try output.renderEnvelopeJson(gpa, encoded);
        };
        return success(gpa, stdout);
    }

    if (std.mem.eql(u8, parsed.command_path[1], "get")) {
        const get_args = parseGetArgs(&parsed) catch return usageFailure(gpa);
        const encoded = try store.get(gpa, .{
            .namespace = get_args.namespace,
            .doc_type = get_args.doc_type,
            .id = get_args.id,
            .version = get_args.version,
        });
        if (encoded) |json_output| {
            errdefer gpa.free(json_output);
            const stdout = if (json)
                json_output
            else blk: {
                defer gpa.free(json_output);
                break :blk try output.renderEnvelopeJson(gpa, json_output);
            };
            return success(gpa, stdout);
        }
        return failure(gpa, "document not found\n");
    }

    if (std.mem.eql(u8, parsed.command_path[1], "list")) {
        const list_args = parseListArgs(&parsed) catch return usageFailure(gpa);
        const result = try store.list(gpa, .{
            .namespace = list_args.namespace,
            .doc_type = list_args.doc_type,
            .limit = list_args.limit,
            .cursor = list_args.cursor,
            .mode = list_args.mode,
        });
        defer result.deinit(gpa);

        const stdout = if (json)
            try sideshowdb.document_transport.encodeListResultJson(gpa, result)
        else
            try output.renderListResult(gpa, result);
        return success(gpa, stdout);
    }

    if (std.mem.eql(u8, parsed.command_path[1], "delete")) {
        const delete_args = parseDeleteArgs(&parsed) catch return usageFailure(gpa);
        const result = try store.delete(gpa, .{
            .namespace = delete_args.namespace,
            .doc_type = delete_args.doc_type,
            .id = delete_args.id,
        });
        defer result.deinit(gpa);

        const stdout = if (json)
            try sideshowdb.document_transport.encodeDeleteResultJson(gpa, result)
        else
            try output.renderDeleteResult(gpa, result);
        return success(gpa, stdout);
    }

    if (std.mem.eql(u8, parsed.command_path[1], "history")) {
        const history_args = parseHistoryArgs(&parsed) catch return usageFailure(gpa);
        const result = try store.history(gpa, .{
            .namespace = history_args.namespace,
            .doc_type = history_args.doc_type,
            .id = history_args.id,
            .limit = history_args.limit,
            .cursor = history_args.cursor,
            .mode = history_args.mode,
        });
        defer result.deinit(gpa);

        const stdout = if (json)
            try sideshowdb.document_transport.encodeHistoryResultJson(gpa, result)
        else
            try output.renderHistoryResult(gpa, result);
        return success(gpa, stdout);
    }

    return usageFailure(gpa);
}

const PutArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: ?[]const u8 = null,
    id: ?[]const u8 = null,
    data_file: ?[]const u8 = null,
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

fn parsePutArgs(parsed: *const usage_runtime.ParsedInvocation) PutArgs {
    return .{
        .namespace = parsed.flagValue("--namespace"),
        .doc_type = parsed.flagValue("--type"),
        .id = parsed.flagValue("--id"),
        .data_file = parsed.flagValue("--data-file"),
    };
}

fn parseGetArgs(parsed: *const usage_runtime.ParsedInvocation) !GetArgs {
    return .{
        .namespace = parsed.flagValue("--namespace"),
        .doc_type = parsed.flagValue("--type") orelse return error.InvalidArguments,
        .id = parsed.flagValue("--id") orelse return error.InvalidArguments,
        .version = parsed.flagValue("--version"),
    };
}

fn parseListArgs(parsed: *const usage_runtime.ParsedInvocation) !ListArgs {
    return .{
        .namespace = parsed.flagValue("--namespace"),
        .doc_type = parsed.flagValue("--type"),
        .limit = if (parsed.flagValue("--limit")) |value| try parseLimit(value) else null,
        .cursor = parsed.flagValue("--cursor"),
        .mode = if (parsed.flagValue("--mode")) |value| try parseMode(value) else .summary,
    };
}

fn parseHistoryArgs(parsed: *const usage_runtime.ParsedInvocation) !HistoryArgs {
    return .{
        .namespace = parsed.flagValue("--namespace"),
        .doc_type = parsed.flagValue("--type") orelse return error.InvalidArguments,
        .id = parsed.flagValue("--id") orelse return error.InvalidArguments,
        .limit = if (parsed.flagValue("--limit")) |value| try parseLimit(value) else null,
        .cursor = parsed.flagValue("--cursor"),
        .mode = if (parsed.flagValue("--mode")) |value| try parseMode(value) else .summary,
    };
}

fn parseDeleteArgs(parsed: *const usage_runtime.ParsedInvocation) !DeleteArgs {
    return .{
        .namespace = parsed.flagValue("--namespace"),
        .doc_type = parsed.flagValue("--type") orelse return error.InvalidArguments,
        .id = parsed.flagValue("--id") orelse return error.InvalidArguments,
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

fn hasInvalidRefstoreChoice(argv: []const []const u8) bool {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (!std.mem.eql(u8, argv[i], "--refstore")) continue;
        if (i + 1 >= argv.len) return false;
        return refstore_selector.RefStoreBackend.parse(argv[i + 1]) == null;
    }
    return false;
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
