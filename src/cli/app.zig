const std = @import("std");
const sideshowdb = @import("sideshowdb");
const generated_usage = @import("sideshowdb_cli_generated_usage");
const output = @import("output.zig");
const refstore_selector = @import("refstore_selector.zig");
const Environ = std.process.Environ;

const Allocator = std.mem.Allocator;

pub const usage_message = generated_usage.usage_message ++ "\n";

const refstore_invalid_message = "unsupported refstore: expected subprocess\n";

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
    var parsed = generated_usage.parseArgv(gpa, argv) catch |err| switch (err) {
        error.InvalidChoice => {
            if (hasInvalidRefstoreChoice(argv)) return failure(gpa, refstore_invalid_message);
            return usageFailure(gpa);
        },
        else => return usageFailure(gpa),
    };
    defer parsed.deinit(gpa);

    const refstore = if (parsed.global.refstore) |value|
        refstore_selector.RefStoreBackend.parse(value) orelse return failure(gpa, refstore_invalid_message)
    else
        null;
    const json = parsed.global.json;

    switch (parsed.command) {
        .version => return versionSuccess(gpa),
        else => {},
    }

    const selection = refstore_selector.resolve(gpa, repo_path, env, refstore) catch |err| switch (err) {
        error.InvalidRefStore => return failure(gpa, refstore_invalid_message),
        error.InvalidRefStoreConfig => return failure(gpa, "invalid refstore config: expected [storage] refstore = \"subprocess\"\n"),
        error.ConfigReadFailed => return failure(gpa, "failed to read .sideshowdb/config.toml\n"),
        error.OutOfMemory => return error.OutOfMemory,
    };
    var subprocess_store: sideshowdb.SubprocessGitRefStore = undefined;
    const ref_store: sideshowdb.RefStore = switch (selection.backend) {
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

    switch (parsed.command) {
        .version => unreachable,
        .doc_put => |put_args| {
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
        },
        .doc_get => |get_args| {
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
        },
        .doc_list => |list_args| {
            const result = try store.list(gpa, .{
                .namespace = list_args.namespace,
                .doc_type = list_args.doc_type,
                .limit = if (list_args.limit) |value| try parseLimit(value) else null,
                .cursor = list_args.cursor,
                .mode = if (list_args.mode) |value| try parseMode(value) else .summary,
            });
            defer result.deinit(gpa);

            const stdout = if (json)
                try sideshowdb.document_transport.encodeListResultJson(gpa, result)
            else
                try output.renderListResult(gpa, result);
            return success(gpa, stdout);
        },
        .doc_delete => |delete_args| {
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
        },
        .doc_history => |history_args| {
            const result = try store.history(gpa, .{
                .namespace = history_args.namespace,
                .doc_type = history_args.doc_type,
                .id = history_args.id,
                .limit = if (history_args.limit) |value| try parseLimit(value) else null,
                .cursor = history_args.cursor,
                .mode = if (history_args.mode) |value| try parseMode(value) else .summary,
            });
            defer result.deinit(gpa);

            const stdout = if (json)
                try sideshowdb.document_transport.encodeHistoryResultJson(gpa, result)
            else
                try output.renderHistoryResult(gpa, result);
            return success(gpa, stdout);
        },
    }
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
