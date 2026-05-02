const std = @import("std");
const sideshowdb = @import("sideshowdb");
const generated_usage = @import("sideshowdb_cli_generated_usage");
const usage_runtime = @import("sideshowdb_cli_usage_runtime");
const output = @import("output.zig");
const refstore_selector = @import("refstore_selector.zig");
const auth_handlers = @import("auth/handlers.zig");
const hosts_file = @import("auth/hosts_file.zig");
const credential_provider = @import("credential_provider");
const Environ = std.process.Environ;

const Allocator = std.mem.Allocator;

pub const usage_message = generated_usage.usage_message ++ "\n";

const refstore_invalid_message = "unsupported refstore: expected subprocess|github\n";
const refstore_github_missing_repo = "--refstore github requires --repo owner/name\n";

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
    if (argv.len <= 1) {
        const stdout = generated_usage.renderHelp(gpa, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return usageFailure(gpa),
        };
        return success(gpa, stdout);
    }

    var parsed = generated_usage.parseArgv(gpa, argv) catch |err| switch (err) {
        error.InvalidChoice => {
            if (hasInvalidRefstoreChoice(argv)) return failure(gpa, refstore_invalid_message);
            return usageFailure(gpa);
        },
        error.InvalidArguments => {
            if (try buildUnknownCommandMessage(gpa, argv)) |msg| return failureOwned(gpa, msg);
            return usageFailure(gpa);
        },
        else => return usageFailure(gpa),
    };
    defer parsed.deinit(gpa);

    if (parsed.command == .help) {
        const stdout = generated_usage.renderHelp(gpa, parsed.command.help.topic) catch |err| switch (err) {
            error.UnknownHelpTopic => {
                const topic = try joinHelpTopic(gpa, parsed.command.help.topic);
                defer gpa.free(topic);
                const message = try std.fmt.allocPrint(gpa, "unknown help topic: {s}\n", .{topic});
                defer gpa.free(message);
                return failure(gpa, message);
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => return usageFailure(gpa),
        };
        return success(gpa, stdout);
    }

    const json = parsed.global.json;

    switch (parsed.command) {
        .version => return versionSuccess(gpa),
        .auth_status => return auth_handlers.runAuthStatus(.{
            .gpa = gpa,
            .io = io,
            .env = env,
            .json = json,
        }),
        .auth_logout => |args| return auth_handlers.runAuthLogout(.{
            .gpa = gpa,
            .io = io,
            .env = env,
            .json = json,
            .host = args.host,
        }),
        .gh_auth_login => |args| return auth_handlers.runGhAuthLogin(.{
            .gpa = gpa,
            .io = io,
            .env = env,
            .json = json,
            .with_token = args.with_token,
            .skip_verify = args.skip_verify,
            .stdin_data = stdin_data,
        }),
        .gh_auth_status => return auth_handlers.runGhAuthStatus(.{
            .gpa = gpa,
            .io = io,
            .env = env,
            .json = json,
        }),
        .gh_auth_logout => return auth_handlers.runGhAuthLogout(.{
            .gpa = gpa,
            .io = io,
            .env = env,
            .json = json,
        }),
        .config_get,
        .config_set,
        .config_unset,
        .config_list,
        => return failure(gpa, "configuration commands are not implemented yet\n"),
        else => {},
    }

    const refstore = if (parsed.global.refstore) |value|
        refstore_selector.RefStoreBackend.parse(value) orelse return failure(gpa, refstore_invalid_message)
    else
        null;

    const selection = refstore_selector.resolve(gpa, repo_path, env, refstore) catch |err| switch (err) {
        error.InvalidRefStore => return failure(gpa, refstore_invalid_message),
        error.InvalidRefStoreConfig => return failure(gpa, "invalid refstore config: expected [storage] refstore = \"subprocess\" or \"github\"\n"),
        error.ConfigReadFailed => return failure(gpa, "failed to read .sideshowdb/config.toml\n"),
        error.OutOfMemory => return error.OutOfMemory,
    };

    switch (parsed.command) {
        .event_append => |event_args| {
            if (selection.backend != .subprocess) {
                return failure(gpa, "event and snapshot commands require --refstore subprocess\n");
            }
            var subprocess_store = sideshowdb.SubprocessGitRefStore.init(.{
                .gpa = gpa,
                .io = io,
                .parent_env = env,
                .repo_path = repo_path,
                .ref_name = "refs/sideshowdb/events",
            });
            const ref_store = subprocess_store.refStore();
            const store = sideshowdb.EventStore.init(ref_store);

            var file_payload: ?[]u8 = null;
            defer if (file_payload) |bytes| gpa.free(bytes);
            if (event_args.data_file) |path| {
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
            const format = event_args.format orelse "jsonl";
            var batch = if (std.mem.eql(u8, format, "json"))
                sideshowdb.event.parseJsonBatch(gpa, payload) catch |err| {
                    const message = try std.fmt.allocPrint(gpa, "{s}\n", .{@errorName(err)});
                    defer gpa.free(message);
                    return failure(gpa, message);
                }
            else
                sideshowdb.event.parseJsonlBatch(gpa, payload) catch |err| {
                    const message = try std.fmt.allocPrint(gpa, "{s}\n", .{@errorName(err)});
                    defer gpa.free(message);
                    return failure(gpa, message);
                };
            defer batch.deinit(gpa);

            const identity: sideshowdb.StreamIdentity = .{
                .namespace = event_args.namespace orelse return usageFailure(gpa),
                .aggregate_type = event_args.aggregate_type orelse return usageFailure(gpa),
                .aggregate_id = event_args.aggregate_id orelse return usageFailure(gpa),
            };
            const expected_revision = if (event_args.expected_revision) |value| try parseRevision(value) else null;
            const result = store.append(gpa, .{
                .identity = identity,
                .expected_revision = expected_revision,
                .events = batch.events,
            }) catch |err| {
                const message = try std.fmt.allocPrint(gpa, "{s}\n", .{@errorName(err)});
                defer gpa.free(message);
                return failure(gpa, message);
            };
            defer result.deinit(gpa);

            const stdout = if (json)
                try std.fmt.allocPrint(gpa, "{{\"revision\":{d},\"version\":\"{s}\"}}\n", .{ result.revision, result.version })
            else
                try std.fmt.allocPrint(gpa, "revision: {d}\nversion: {s}\n", .{ result.revision, result.version });
            return success(gpa, stdout);
        },
        .event_load => |event_args| {
            if (selection.backend != .subprocess) {
                return failure(gpa, "event and snapshot commands require --refstore subprocess\n");
            }
            var subprocess_store = sideshowdb.SubprocessGitRefStore.init(.{
                .gpa = gpa,
                .io = io,
                .parent_env = env,
                .repo_path = repo_path,
                .ref_name = "refs/sideshowdb/events",
            });
            const ref_store = subprocess_store.refStore();
            const store = sideshowdb.EventStore.init(ref_store);
            const identity: sideshowdb.StreamIdentity = .{
                .namespace = event_args.namespace orelse return usageFailure(gpa),
                .aggregate_type = event_args.aggregate_type orelse return usageFailure(gpa),
                .aggregate_id = event_args.aggregate_id orelse return usageFailure(gpa),
            };
            var stream = if (event_args.from_revision) |value|
                try store.loadFromRevision(gpa, identity, try parseRevision(value))
            else
                try store.load(gpa, identity);
            defer stream.deinit(gpa);

            const stdout = try encodeEventStreamJson(gpa, stream);
            return success(gpa, stdout);
        },
        .snapshot_put => |snapshot_args| {
            if (selection.backend != .subprocess) {
                return failure(gpa, "event and snapshot commands require --refstore subprocess\n");
            }
            var subprocess_store = sideshowdb.SubprocessGitRefStore.init(.{
                .gpa = gpa,
                .io = io,
                .parent_env = env,
                .repo_path = repo_path,
                .ref_name = "refs/sideshowdb/snapshots",
            });
            const ref_store = subprocess_store.refStore();
            const store = sideshowdb.SnapshotStore.init(ref_store);

            const state_bytes = if (snapshot_args.state_file) |path|
                std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
                    const message = try std.fmt.allocPrint(gpa, "failed to read --state-file {s}: {t}\n", .{ path, err });
                    defer gpa.free(message);
                    return failure(gpa, message);
                }
            else
                try gpa.dupe(u8, stdin_data);
            defer gpa.free(state_bytes);

            var metadata_bytes: ?[]u8 = null;
            defer if (metadata_bytes) |bytes| gpa.free(bytes);
            if (snapshot_args.metadata_file) |path| {
                metadata_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
                    const message = try std.fmt.allocPrint(gpa, "failed to read --metadata-file {s}: {t}\n", .{ path, err });
                    defer gpa.free(message);
                    return failure(gpa, message);
                };
            }

            const identity: sideshowdb.StreamIdentity = .{
                .namespace = snapshot_args.namespace orelse return usageFailure(gpa),
                .aggregate_type = snapshot_args.aggregate_type orelse return usageFailure(gpa),
                .aggregate_id = snapshot_args.aggregate_id orelse return usageFailure(gpa),
            };
            const revision = try parseRevision(snapshot_args.revision orelse return usageFailure(gpa));
            const up_to_event_id = snapshot_args.up_to_event_id orelse return usageFailure(gpa);
            const result = store.put(gpa, .{
                .identity = identity,
                .record = .{
                    .namespace = identity.namespace,
                    .aggregate_type = identity.aggregate_type,
                    .aggregate_id = identity.aggregate_id,
                    .revision = revision,
                    .up_to_event_id = up_to_event_id,
                    .state_json = state_bytes,
                    .metadata_json = metadata_bytes,
                },
            }) catch |err| {
                const message = try std.fmt.allocPrint(gpa, "{s}\n", .{@errorName(err)});
                defer gpa.free(message);
                return failure(gpa, message);
            };
            defer result.deinit(gpa);

            const stdout = if (json)
                try std.fmt.allocPrint(
                    gpa,
                    "{{\"revision\":{d},\"version\":\"{s}\",\"idempotent\":{s}}}\n",
                    .{ result.revision, result.version, if (result.idempotent) "true" else "false" },
                )
            else
                try std.fmt.allocPrint(gpa, "revision: {d}\nversion: {s}\nidempotent: {s}\n", .{
                    result.revision,
                    result.version,
                    if (result.idempotent) "true" else "false",
                });
            return success(gpa, stdout);
        },
        .snapshot_get => |snapshot_args| {
            if (selection.backend != .subprocess) {
                return failure(gpa, "event and snapshot commands require --refstore subprocess\n");
            }
            var subprocess_store = sideshowdb.SubprocessGitRefStore.init(.{
                .gpa = gpa,
                .io = io,
                .parent_env = env,
                .repo_path = repo_path,
                .ref_name = "refs/sideshowdb/snapshots",
            });
            const ref_store = subprocess_store.refStore();
            const store = sideshowdb.SnapshotStore.init(ref_store);
            const identity: sideshowdb.StreamIdentity = .{
                .namespace = snapshot_args.namespace orelse return usageFailure(gpa),
                .aggregate_type = snapshot_args.aggregate_type orelse return usageFailure(gpa),
                .aggregate_id = snapshot_args.aggregate_id orelse return usageFailure(gpa),
            };

            const by_revision = if (snapshot_args.at_or_before) |value| try parseRevision(value) else null;
            const want_latest = snapshot_args.latest;
            if (want_latest and by_revision != null) return usageFailure(gpa);
            const record = if (by_revision) |revision|
                try store.getAtOrBefore(gpa, identity, revision)
            else
                try store.getLatest(gpa, identity);
            if (record == null) return failure(gpa, "snapshot not found\n");
            defer record.?.deinit(gpa);

            const stdout = try encodeSnapshotRecordJson(gpa, record.?);
            return success(gpa, stdout);
        },
        .snapshot_list => |snapshot_args| {
            if (selection.backend != .subprocess) {
                return failure(gpa, "event and snapshot commands require --refstore subprocess\n");
            }
            var subprocess_store = sideshowdb.SubprocessGitRefStore.init(.{
                .gpa = gpa,
                .io = io,
                .parent_env = env,
                .repo_path = repo_path,
                .ref_name = "refs/sideshowdb/snapshots",
            });
            const ref_store = subprocess_store.refStore();
            const store = sideshowdb.SnapshotStore.init(ref_store);
            const identity: sideshowdb.StreamIdentity = .{
                .namespace = snapshot_args.namespace orelse return usageFailure(gpa),
                .aggregate_type = snapshot_args.aggregate_type orelse return usageFailure(gpa),
                .aggregate_id = snapshot_args.aggregate_id orelse return usageFailure(gpa),
            };
            const items = try store.list(gpa, identity);
            defer sideshowdb.snapshot.freeSnapshotMetadataList(gpa, items);

            const stdout = try encodeSnapshotListJson(gpa, items);
            return success(gpa, stdout);
        },
        else => {},
    }

    var subprocess_store: sideshowdb.SubprocessGitRefStore = undefined;
    var github_store_state: GitHubStoreState = undefined;
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
        .github => blk: {
            initGithubStore(&github_store_state, gpa, io, env, parsed.global.repo, parsed.global.ref, parsed.global.api_base, parsed.global.credential_helper) catch |err| switch (err) {
                error.MissingRepo => return failure(gpa, refstore_github_missing_repo),
                error.MalformedRepo => return failure(gpa, "--repo must be in the form owner/name\n"),
                error.MissingCredentials => return failure(gpa, "no GitHub credentials configured; run 'sideshowdb gh auth login'\n"),
                error.InvalidConfig => return failure(gpa, "invalid GitHub refstore configuration\n"),
                error.OutOfMemory => return error.OutOfMemory,
            };
            break :blk github_store_state.refStore();
        },
    };
    defer if (selection.backend == .github) github_store_state.deinit(gpa);

    const store = sideshowdb.DocumentStore.init(ref_store);

    switch (parsed.command) {
        .help,
        .version,
        .auth_status,
        .auth_logout,
        .gh_auth_login,
        .gh_auth_status,
        .gh_auth_logout,
        .event_append,
        .event_load,
        .snapshot_put,
        .snapshot_get,
        .snapshot_list,
        => unreachable,
        .config_get,
        .config_set,
        .config_unset,
        .config_list,
        => return failure(gpa, "configuration commands are not implemented yet\n"),
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
            const encoded = store.put(gpa, sideshowdb.document.PutRequest.fromOverrides(
                payload,
                put_args.namespace,
                put_args.doc_type,
                put_args.id,
            )) catch |err| switch (err) {
                error.HelperUnavailable, error.AuthMissing => return failure(gpa, "no GitHub credentials configured; run 'sideshowdb gh auth login'\n"),
                else => return err,
            };
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
            const encoded = store.get(gpa, .{
                .namespace = get_args.namespace,
                .doc_type = get_args.doc_type,
                .id = get_args.id,
                .version = get_args.version,
            }) catch |err| switch (err) {
                error.HelperUnavailable, error.AuthMissing => return failure(gpa, "no GitHub credentials configured; run 'sideshowdb gh auth login'\n"),
                else => return err,
            };
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
            const result = store.list(gpa, .{
                .namespace = list_args.namespace,
                .doc_type = list_args.doc_type,
                .limit = if (list_args.limit) |value| try parseLimit(value) else null,
                .cursor = list_args.cursor,
                .mode = if (list_args.mode) |value| try parseMode(value) else .summary,
            }) catch |err| switch (err) {
                error.HelperUnavailable, error.AuthMissing => return failure(gpa, "no GitHub credentials configured; run 'sideshowdb gh auth login'\n"),
                else => return err,
            };
            defer result.deinit(gpa);

            const stdout = if (json)
                try sideshowdb.document_transport.encodeListResultJson(gpa, result)
            else
                try output.renderListResult(gpa, result);
            return success(gpa, stdout);
        },
        .doc_delete => |delete_args| {
            const result = store.delete(gpa, .{
                .namespace = delete_args.namespace,
                .doc_type = delete_args.doc_type,
                .id = delete_args.id,
            }) catch |err| switch (err) {
                error.HelperUnavailable, error.AuthMissing => return failure(gpa, "no GitHub credentials configured; run 'sideshowdb gh auth login'\n"),
                else => return err,
            };
            defer result.deinit(gpa);

            const stdout = if (json)
                try sideshowdb.document_transport.encodeDeleteResultJson(gpa, result)
            else
                try output.renderDeleteResult(gpa, result);
            return success(gpa, stdout);
        },
        .doc_history => |history_args| {
            const result = store.history(gpa, .{
                .namespace = history_args.namespace,
                .doc_type = history_args.doc_type,
                .id = history_args.id,
                .limit = if (history_args.limit) |value| try parseLimit(value) else null,
                .cursor = history_args.cursor,
                .mode = if (history_args.mode) |value| try parseMode(value) else .summary,
            }) catch |err| switch (err) {
                error.HelperUnavailable, error.AuthMissing => return failure(gpa, "no GitHub credentials configured; run 'sideshowdb gh auth login'\n"),
                else => return err,
            };
            defer result.deinit(gpa);

            const stdout = if (json)
                try sideshowdb.document_transport.encodeHistoryResultJson(gpa, result)
            else
                try output.renderHistoryResult(gpa, result);
            return success(gpa, stdout);
        },
    }
}

fn parseRevision(value: []const u8) !u64 {
    return std.fmt.parseInt(u64, value, 10);
}

fn encodeEventStreamJson(gpa: Allocator, stream: sideshowdb.event.EventStream) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"namespace\":");
    try std.json.Stringify.value(stream.identity.namespace, .{}, &out.writer);
    try out.writer.writeAll(",\"aggregate_type\":");
    try std.json.Stringify.value(stream.identity.aggregate_type, .{}, &out.writer);
    try out.writer.writeAll(",\"aggregate_id\":");
    try std.json.Stringify.value(stream.identity.aggregate_id, .{}, &out.writer);
    try out.writer.print(",\"revision\":{d},\"events\":[", .{stream.revision});
    for (stream.events, 0..) |item, index| {
        if (index > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"event_id\":");
        try std.json.Stringify.value(item.event_id, .{}, &out.writer);
        try out.writer.writeAll(",\"event_type\":");
        try std.json.Stringify.value(item.event_type, .{}, &out.writer);
        try out.writer.writeAll(",\"namespace\":");
        try std.json.Stringify.value(item.namespace, .{}, &out.writer);
        try out.writer.writeAll(",\"aggregate_type\":");
        try std.json.Stringify.value(item.aggregate_type, .{}, &out.writer);
        try out.writer.writeAll(",\"aggregate_id\":");
        try std.json.Stringify.value(item.aggregate_id, .{}, &out.writer);
        try out.writer.writeAll(",\"timestamp\":");
        try std.json.Stringify.value(item.timestamp, .{}, &out.writer);
        try out.writer.writeAll(",\"payload\":");
        try out.writer.writeAll(item.payload_json);
        if (item.metadata_json) |metadata_json| {
            try out.writer.print(",\"metadata\":{s}", .{metadata_json});
        }
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}\n");
    return out.toOwnedSlice();
}

fn encodeSnapshotRecordJson(gpa: Allocator, record: sideshowdb.snapshot.SnapshotRecord) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"namespace\":");
    try std.json.Stringify.value(record.namespace, .{}, &out.writer);
    try out.writer.writeAll(",\"aggregate_type\":");
    try std.json.Stringify.value(record.aggregate_type, .{}, &out.writer);
    try out.writer.writeAll(",\"aggregate_id\":");
    try std.json.Stringify.value(record.aggregate_id, .{}, &out.writer);
    try out.writer.print(",\"revision\":{d},", .{record.revision});
    try out.writer.writeAll("\"up_to_event_id\":");
    try std.json.Stringify.value(record.up_to_event_id, .{}, &out.writer);
    try out.writer.writeAll(",\"state\":");
    try out.writer.writeAll(record.state_json);
    if (record.metadata_json) |metadata_json| {
        try out.writer.print(",\"metadata\":{s}", .{metadata_json});
    }
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn encodeSnapshotListJson(gpa: Allocator, items: []const sideshowdb.snapshot.SnapshotMetadata) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"items\":[");
    for (items, 0..) |item, index| {
        if (index > 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"namespace\":");
        try std.json.Stringify.value(item.namespace, .{}, &out.writer);
        try out.writer.writeAll(",\"aggregate_type\":");
        try std.json.Stringify.value(item.aggregate_type, .{}, &out.writer);
        try out.writer.writeAll(",\"aggregate_id\":");
        try std.json.Stringify.value(item.aggregate_id, .{}, &out.writer);
        try out.writer.print(",\"revision\":{d},", .{item.revision});
        try out.writer.writeAll("\"up_to_event_id\":");
        try std.json.Stringify.value(item.up_to_event_id, .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]}\n");
    return out.toOwnedSlice();
}

const GitHubStoreState = struct {
    cred_handle: credential_provider.ProviderHandle,
    http_client: std.http.Client,
    std_transport: sideshowdb.storage.StdHttpTransport,
    github_store: sideshowdb.GitHubApiRefStore,

    pub fn refStore(self: *GitHubStoreState) sideshowdb.RefStore {
        return self.github_store.refStore();
    }

    pub fn deinit(self: *GitHubStoreState, gpa: Allocator) void {
        self.github_store.deinitCaches(gpa);
        self.cred_handle.deinit();
        self.http_client.deinit();
    }
};

const InitGithubError = error{
    MissingRepo,
    MalformedRepo,
    MissingCredentials,
    InvalidConfig,
    OutOfMemory,
};

fn initGithubStore(
    out: *GitHubStoreState,
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    repo: ?[]const u8,
    ref: ?[]const u8,
    api_base: ?[]const u8,
    credential_helper: ?[]const u8,
) InitGithubError!void {
    const repo_value = repo orelse return error.MissingRepo;
    const slash = std.mem.indexOfScalar(u8, repo_value, '/') orelse return error.MalformedRepo;
    const owner = repo_value[0..slash];
    const repo_name = repo_value[slash + 1 ..];
    if (owner.len == 0 or repo_name.len == 0) return error.MalformedRepo;

    const helper_value = credential_helper orelse "auto";
    const cred_spec: credential_provider.CredentialSpec = blk: {
        if (std.mem.eql(u8, helper_value, "auto")) {
            // Check hosts_file for a stored PAT first; fall through to .auto on failure.
            if (tryLoadHostsToken(gpa, env)) |token| {
                break :blk .{ .explicit = token };
            } else |_| {}
            break :blk .auto;
        } else if (std.mem.eql(u8, helper_value, "env")) {
            break :blk .{ .env = "GITHUB_TOKEN" };
        } else if (std.mem.eql(u8, helper_value, "gh")) {
            break :blk .gh_helper;
        } else if (std.mem.eql(u8, helper_value, "git")) {
            break :blk .git_helper;
        } else {
            return error.InvalidConfig;
        }
    };

    out.cred_handle = credential_provider.fromSpec(cred_spec, .{
        .gpa = gpa,
        .io = io,
        .parent_env = env,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidConfig => return error.InvalidConfig,
        else => return error.MissingCredentials,
    };
    errdefer out.cred_handle.deinit();

    out.http_client = .{ .allocator = gpa, .io = io };
    errdefer out.http_client.deinit();

    // StdHttpTransport stores a pointer to http_client. Both live at stable
    // addresses inside *out, so the pointer remains valid for the lifetime of
    // the store.
    out.std_transport = sideshowdb.storage.StdHttpTransport{ .client = &out.http_client };

    out.github_store = sideshowdb.GitHubApiRefStore.init(.{
        .owner = owner,
        .repo = repo_name,
        .ref_name = ref,
        .api_base = api_base orelse sideshowdb.GitHubApiRefStore.default_api_base,
        .transport = out.std_transport.transport(),
        .credentials = out.cred_handle.provider(),
        .retry_io = io,
        .enable_read_caching = true,
    }) catch return error.InvalidConfig;
}

fn tryLoadHostsToken(gpa: Allocator, env: *const Environ.Map) ![]const u8 {
    const hosts_path = try hosts_file.resolveHostsPath(gpa, env);
    defer gpa.free(hosts_path);
    var hf = hosts_file.read(gpa, hosts_path) catch return error.NoToken;
    defer hf.deinit(gpa);
    const entry = hf.find("github.com") orelse return error.NoToken;
    return try gpa.dupe(u8, entry.oauth_token);
}

fn parseLimit(value: []const u8) !usize {
    return std.fmt.parseInt(usize, value, 10);
}

fn parseMode(value: []const u8) !sideshowdb.document.CollectionMode {
    if (std.mem.eql(u8, value, "summary")) return .summary;
    if (std.mem.eql(u8, value, "detailed")) return .detailed;
    return error.InvalidArguments;
}

fn joinHelpTopic(gpa: Allocator, topic: []const []const u8) ![]u8 {
    if (topic.len == 0) return try gpa.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (topic, 0..) |segment, index| {
        if (index != 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(segment);
    }
    return out.toOwnedSlice();
}

pub fn shouldReadStdin(gpa: Allocator, argv: []const []const u8) !bool {
    if (argv.len <= 1) return false;

    var parsed = generated_usage.parseArgv(gpa, argv) catch return false;
    defer parsed.deinit(gpa);

    return switch (parsed.command) {
        .doc_put => |args| args.data_file == null,
        .event_append => |args| args.data_file == null,
        .snapshot_put => |args| args.state_file == null,
        .gh_auth_login => |args| args.with_token,
        else => false,
    };
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

pub fn success(gpa: Allocator, stdout: []u8) !RunResult {
    return .{
        .exit_code = 0,
        .stdout = stdout,
        .stderr = try gpa.dupe(u8, ""),
    };
}

pub fn failure(gpa: Allocator, message: []const u8) !RunResult {
    return .{
        .exit_code = 1,
        .stdout = try gpa.dupe(u8, ""),
        .stderr = try gpa.dupe(u8, message),
    };
}

fn failureOwned(gpa: Allocator, message: []u8) !RunResult {
    return .{
        .exit_code = 1,
        .stdout = try gpa.dupe(u8, ""),
        .stderr = message,
    };
}

fn findFlagView(flags: []const usage_runtime.FlagView, token: []const u8) ?*const usage_runtime.FlagView {
    for (flags) |*flag| {
        if (flag.long_name) |name| if (std.mem.eql(u8, name, token)) return flag;
        if (flag.short_name) |name| if (std.mem.eql(u8, name, token)) return flag;
    }
    return null;
}

fn findCommandView(commands: []const usage_runtime.CommandView, token: []const u8) ?*const usage_runtime.CommandView {
    for (commands) |*cmd| {
        if (std.mem.eql(u8, cmd.name, token)) return cmd;
        for (cmd.aliases) |alias| if (std.mem.eql(u8, alias, token)) return cmd;
    }
    return null;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    var prev: [64]usize = undefined;
    var curr: [64]usize = undefined;
    if (b.len + 1 > prev.len) return @max(a.len, b.len);
    var j: usize = 0;
    while (j <= b.len) : (j += 1) prev[j] = j;
    var i: usize = 1;
    while (i <= a.len) : (i += 1) {
        curr[0] = i;
        var k: usize = 1;
        while (k <= b.len) : (k += 1) {
            const cost: usize = if (a[i - 1] == b[k - 1]) 0 else 1;
            const del = prev[k] + 1;
            const ins = curr[k - 1] + 1;
            const sub = prev[k - 1] + cost;
            curr[k] = @min(@min(del, ins), sub);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

fn suggestCommand(commands: []const usage_runtime.CommandView, token: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    for (commands) |cmd| {
        const d = editDistance(cmd.name, token);
        if (d < best_dist) {
            best_dist = d;
            best = cmd.name;
        }
    }
    const limit: usize = @max(@as(usize, 1), token.len / 2);
    if (best_dist <= limit) return best;
    return null;
}

fn buildUnknownCommandMessage(gpa: Allocator, argv: []const []const u8) !?[]u8 {
    if (argv.len < 2) return null;
    var children = generated_usage.spec.root_commands;
    var current_flags: []const usage_runtime.FlagView = &.{};
    var topic = std.ArrayList([]const u8).empty;
    defer topic.deinit(gpa);
    var i: usize = 1;
    while (i < argv.len) {
        const tok = argv[i];
        if (std.mem.eql(u8, tok, "help") or std.mem.eql(u8, tok, "--help")) return null;
        if (std.mem.startsWith(u8, tok, "-")) {
            const fv = findFlagView(generated_usage.spec.global_flags, tok) orelse
                findFlagView(current_flags, tok) orelse return null;
            if (fv.value_name != null) i += 2 else i += 1;
            continue;
        }
        if (findCommandView(children, tok)) |matched| {
            try topic.append(gpa, matched.name);
            current_flags = matched.flags;
            children = matched.subcommands;
            i += 1;
            continue;
        }
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try out.writer.print("unknown command: {s}\n", .{tok});
        if (suggestCommand(children, tok)) |hint| {
            try out.writer.print("did you mean: {s}?\n", .{hint});
        }
        try out.writer.writeAll("\n");
        if (topic.items.len == 0) {
            try out.writer.writeAll(usage_message);
        } else {
            const scoped_help = generated_usage.renderHelp(gpa, topic.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidSpec,
                error.InvalidArguments,
                error.InvalidChoice,
                error.MissingRequiredField,
                error.ParseError,
                error.UnsupportedNode,
                error.UnknownHelpTopic,
                error.WriteFailed,
                => null,
            };
            if (scoped_help) |help| {
                defer gpa.free(help);
                try out.writer.writeAll(help);
            } else {
                try out.writer.writeAll(usage_message);
            }
        }
        return try out.toOwnedSlice();
    }
    return null;
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
