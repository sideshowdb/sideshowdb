const std = @import("std");
const sideshowdb = @import("sideshowdb");
const generated_usage = @import("sideshowdb_cli_generated_usage");
const usage_runtime = @import("sideshowdb_cli_usage_runtime");
const output = @import("output.zig");
const auth_handlers = @import("auth/handlers.zig");
const hosts_file = @import("auth/hosts_file.zig");
const credential_provider = @import("credential_provider");
const Environ = std.process.Environ;

const Allocator = std.mem.Allocator;
const config = sideshowdb.config;

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
        .config_get => |args| return runConfigGet(gpa, io, env, repo_path, json, parsed.global, args),
        .config_set => |args| return runConfigSet(gpa, io, env, repo_path, json, args),
        .config_unset => |args| return runConfigUnset(gpa, io, env, repo_path, json, args),
        .config_list => |args| return runConfigList(gpa, io, env, repo_path, json, parsed.global, args),
        else => {},
    }

    const cli_refstore = if (parsed.global.refstore) |value|
        config.parseRefStoreKind(value) orelse return failure(gpa, refstore_invalid_message)
    else
        null;
    const cli_credential_helper = if (parsed.global.credential_helper) |value|
        config.parseCredentialHelper(value) orelse return failure(gpa, "invalid GitHub refstore configuration\n")
    else
        null;

    var global_config = loadImplicitGlobalConfig(gpa, io, env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(gpa, "invalid refstore config: expected [refstore] kind = \"subprocess\" or \"github\"\n"),
    };
    defer global_config.deinit(gpa);
    var local_config = config.loadLocal(gpa, io, repo_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failure(gpa, "invalid refstore config: expected [refstore] kind = \"subprocess\" or \"github\"\n"),
    };
    defer local_config.deinit(gpa);

    var resolved_config = config.resolveLayers(gpa, .{
        .global = global_config.value,
        .local = local_config.value,
        .env = env,
        .cli_refstore = cli_refstore,
        .cli_repo = parsed.global.repo,
        .cli_ref_name = parsed.global.ref,
        .cli_api_base = parsed.global.api_base,
        .cli_credential_helper = cli_credential_helper,
    }) catch |err| switch (err) {
        error.InvalidConfigValue => return failure(gpa, refstore_invalid_message),
        error.UnknownConfigKey => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer resolved_config.deinit(gpa);

    switch (parsed.command) {
        .event_append => |event_args| {
            if (resolved_config.refstore.kind != .subprocess) {
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
            if (resolved_config.refstore.kind != .subprocess) {
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
            if (resolved_config.refstore.kind != .subprocess) {
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
            if (resolved_config.refstore.kind != .subprocess) {
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
            if (resolved_config.refstore.kind != .subprocess) {
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
    const ref_store: sideshowdb.RefStore = switch (resolved_config.refstore.kind) {
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
            initGithubStore(
                &github_store_state,
                gpa,
                io,
                env,
                resolved_config.refstore.repo,
                resolved_config.refstore.ref_name,
                resolved_config.refstore.api_base,
                credentialHelperName(resolved_config.refstore.credential_helper),
            ) catch |err| switch (err) {
                error.MissingRepo => return failure(gpa, refstore_github_missing_repo),
                error.MalformedRepo => return failure(gpa, "--repo must be in the form owner/name\n"),
                error.MissingCredentials => return failure(gpa, "no GitHub credentials configured; run 'sideshowdb gh auth login'\n"),
                error.InvalidConfig => return failure(gpa, "invalid GitHub refstore configuration\n"),
                error.OutOfMemory => return error.OutOfMemory,
            };
            break :blk github_store_state.refStore();
        },
    };
    defer if (resolved_config.refstore.kind == .github) github_store_state.deinit(gpa);

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
        .config_get,
        .config_set,
        .config_unset,
        .config_list,
        => unreachable,
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

const ConfigScope = enum {
    local,
    global,
};

fn runConfigGet(
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    repo_path: []const u8,
    json: bool,
    global_options: generated_usage.GlobalOptions,
    args: generated_usage.ConfigGetArgs,
) !RunResult {
    if (args.local and args.global) return failure(gpa, "choose only one of --local or --global\n");

    if (args.local or args.global) {
        const scope: ConfigScope = if (args.global) .global else .local;
        var parsed = loadScopedConfig(gpa, io, env, repo_path, scope) catch |err| return configLoadFailure(gpa, err);
        defer parsed.deinit(gpa);
        const value = config.getPath(gpa, parsed.value, args.key) catch |err| return configPathFailure(gpa, err, args.key);
        if (value == null) return missingConfigKey(gpa, args.key);
        const source = scopeName(scope);
        if (json) return success(gpa, try encodeConfigGetJson(gpa, args.key, value.?, source));
        return success(gpa, try std.fmt.allocPrint(gpa, "{s}\n", .{value.?}));
    }

    var resolved_view = loadResolvedConfig(gpa, io, env, repo_path, global_options) catch |err| return configLoadFailure(gpa, err);
    defer resolved_view.resolved.deinit(gpa);
    defer resolved_view.local.deinit(gpa);
    defer resolved_view.global.deinit(gpa);

    const typed_key = config.ConfigKey.fromString(args.key) orelse return configPathFailure(gpa, error.UnknownConfigKey, args.key);
    const value = getTypedResolvedKey(resolved_view.resolved, typed_key);
    if (value == null) return missingConfigKey(gpa, args.key);
    const source = sourceForResolvedKey(env, global_options, resolved_view.global.value, resolved_view.local.value, typed_key);
    if (json) return success(gpa, try encodeConfigGetJson(gpa, args.key, value.?, source));
    return success(gpa, try std.fmt.allocPrint(gpa, "{s}\n", .{value.?}));
}

fn runConfigSet(
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    repo_path: []const u8,
    json: bool,
    args: generated_usage.ConfigSetArgs,
) !RunResult {
    if (args.local and args.global) return failure(gpa, "choose only one of --local or --global\n");
    const scope: ConfigScope = if (args.global) .global else .local;

    var parsed = loadScopedConfig(gpa, io, env, repo_path, scope) catch |err| return configLoadFailure(gpa, err);
    defer parsed.deinit(gpa);
    config.setPath(gpa, &parsed.value, args.key, args.value) catch |err| return configPathFailure(gpa, err, args.key);
    saveScopedConfig(gpa, io, env, repo_path, scope, parsed.value) catch |err| return configSaveFailure(gpa, err);

    if (json) return success(gpa, try encodeConfigStatusJson(gpa, "set", args.key, scopeName(scope)));
    return success(gpa, try gpa.dupe(u8, ""));
}

fn runConfigUnset(
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    repo_path: []const u8,
    json: bool,
    args: generated_usage.ConfigUnsetArgs,
) !RunResult {
    if (args.local and args.global) return failure(gpa, "choose only one of --local or --global\n");
    const scope: ConfigScope = if (args.global) .global else .local;

    var parsed = loadScopedConfig(gpa, io, env, repo_path, scope) catch |err| return configLoadFailure(gpa, err);
    defer parsed.deinit(gpa);
    const current = config.getPath(gpa, parsed.value, args.key) catch |err| return configPathFailure(gpa, err, args.key);
    if (current == null) {
        if (json) return success(gpa, try encodeConfigStatusJson(gpa, "unset", args.key, scopeName(scope)));
        return success(gpa, try gpa.dupe(u8, ""));
    }
    config.unsetPath(gpa, &parsed.value, args.key) catch |err| return configPathFailure(gpa, err, args.key);
    saveScopedConfig(gpa, io, env, repo_path, scope, parsed.value) catch |err| return configSaveFailure(gpa, err);

    if (json) return success(gpa, try encodeConfigStatusJson(gpa, "unset", args.key, scopeName(scope)));
    return success(gpa, try gpa.dupe(u8, ""));
}

fn runConfigList(
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    repo_path: []const u8,
    json: bool,
    global_options: generated_usage.GlobalOptions,
    args: generated_usage.ConfigListArgs,
) !RunResult {
    if (args.local and args.global) return failure(gpa, "choose only one of --local or --global\n");

    if (args.local or args.global) {
        const scope: ConfigScope = if (args.global) .global else .local;
        var parsed = loadScopedConfig(gpa, io, env, repo_path, scope) catch |err| return configLoadFailure(gpa, err);
        defer parsed.deinit(gpa);
        const rows = try config.listFlattened(gpa, parsed.value);
        defer config.freeConfigRows(gpa, rows);
        if (json) return success(gpa, try encodeConfigRowsJson(gpa, rows, scopeName(scope)));
        return success(gpa, try encodeConfigRowsPlain(gpa, rows));
    }

    var resolved_view = loadResolvedConfig(gpa, io, env, repo_path, global_options) catch |err| return configLoadFailure(gpa, err);
    defer resolved_view.resolved.deinit(gpa);
    defer resolved_view.local.deinit(gpa);
    defer resolved_view.global.deinit(gpa);
    if (json) return success(gpa, try encodeResolvedConfigJson(gpa, env, global_options, resolved_view.global.value, resolved_view.local.value, resolved_view.resolved));
    return success(gpa, try encodeResolvedConfigPlain(gpa, resolved_view.resolved));
}

fn loadScopedConfig(
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    repo_path: []const u8,
    scope: ConfigScope,
) !config.ParsedConfig {
    return switch (scope) {
        .local => config.loadLocal(gpa, io, repo_path),
        .global => config.loadGlobal(gpa, io, env),
    };
}

fn loadImplicitGlobalConfig(gpa: Allocator, io: std.Io, env: *const Environ.Map) !config.ParsedConfig {
    return config.loadGlobal(gpa, io, env) catch |err| switch (err) {
        error.NoHomeDir => config.parseToml(gpa, ""),
        else => err,
    };
}

fn saveScopedConfig(
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    repo_path: []const u8,
    scope: ConfigScope,
    value: config.Config,
) !void {
    const path = switch (scope) {
        .local => try config.localConfigPath(gpa, repo_path),
        .global => try config.globalConfigPath(gpa, env),
    };
    defer gpa.free(path);
    try config.saveFile(gpa, io, path, value);
}

const ResolvedView = struct {
    global: config.ParsedConfig,
    local: config.ParsedConfig,
    resolved: config.ResolvedConfig,
};

fn loadResolvedConfig(
    gpa: Allocator,
    io: std.Io,
    env: *const Environ.Map,
    repo_path: []const u8,
    global_options: generated_usage.GlobalOptions,
) !ResolvedView {
    var global_cfg = try loadImplicitGlobalConfig(gpa, io, env);
    errdefer global_cfg.deinit(gpa);
    var local_cfg = try config.loadLocal(gpa, io, repo_path);
    errdefer local_cfg.deinit(gpa);

    const cli_refstore = if (global_options.refstore) |value|
        config.parseRefStoreKind(value) orelse return error.InvalidConfigValue
    else
        null;
    const cli_credential_helper = if (global_options.credential_helper) |value|
        config.parseCredentialHelper(value) orelse return error.InvalidConfigValue
    else
        null;
    const resolved = try config.resolveLayers(gpa, .{
        .global = global_cfg.value,
        .local = local_cfg.value,
        .env = env,
        .cli_refstore = cli_refstore,
        .cli_repo = global_options.repo,
        .cli_ref_name = global_options.ref,
        .cli_api_base = global_options.api_base,
        .cli_credential_helper = cli_credential_helper,
    });

    return .{
        .global = global_cfg,
        .local = local_cfg,
        .resolved = resolved,
    };
}

fn configPathFailure(gpa: Allocator, err: anyerror, key: []const u8) !RunResult {
    return switch (err) {
        error.UnknownConfigKey => unknownConfigKey(gpa, key),
        error.InvalidConfigValue => invalidConfigValue(gpa, key),
        error.OutOfMemory => error.OutOfMemory,
        else => err,
    };
}

fn configLoadFailure(gpa: Allocator, err: anyerror) !RunResult {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NoHomeDir => failure(gpa, "config path could not be resolved: set SIDESHOWDB_CONFIG_DIR or HOME\n"),
        error.StreamTooLong => failure(gpa, "config file is too large\n"),
        error.InvalidConfigValue => failure(gpa, "invalid config value\n"),
        else => failure(gpa, "invalid config file\n"),
    };
}

fn configSaveFailure(gpa: Allocator, err: anyerror) !RunResult {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NoHomeDir => failure(gpa, "config path could not be resolved: set SIDESHOWDB_CONFIG_DIR or HOME\n"),
        else => failure(gpa, "failed to write config file\n"),
    };
}

fn unknownConfigKey(gpa: Allocator, key: []const u8) !RunResult {
    const message = try std.fmt.allocPrint(gpa, "unknown config key: {s}\n", .{key});
    defer gpa.free(message);
    return failure(gpa, message);
}

fn invalidConfigValue(gpa: Allocator, key: []const u8) !RunResult {
    const message = try std.fmt.allocPrint(gpa, "invalid value for config key: {s}\n", .{key});
    defer gpa.free(message);
    return failure(gpa, message);
}

fn missingConfigKey(gpa: Allocator, key: []const u8) !RunResult {
    const message = try std.fmt.allocPrint(gpa, "config key not set: {s}\n", .{key});
    defer gpa.free(message);
    return failure(gpa, message);
}

fn scopeName(scope: ConfigScope) []const u8 {
    return switch (scope) {
        .local => "local",
        .global => "global",
    };
}

fn getResolvedPath(resolved: config.ResolvedConfig, key: []const u8) config.ConfigError!?[]const u8 {
    const typed_key = config.ConfigKey.fromString(key) orelse return error.UnknownConfigKey;
    return getTypedResolvedKey(resolved, typed_key);
}

fn getTypedResolvedKey(resolved: config.ResolvedConfig, key: config.ConfigKey) ?[]const u8 {
    return switch (key) {
        .refstore_kind => refStoreKindName(resolved.refstore.kind),
        .refstore_repo => resolved.refstore.repo,
        .refstore_ref_name => resolved.refstore.ref_name,
        .refstore_api_base => resolved.refstore.api_base,
        .refstore_credential_helper => credentialHelperName(resolved.refstore.credential_helper),
    };
}

fn sourceForResolvedKey(
    env: *const Environ.Map,
    global_options: generated_usage.GlobalOptions,
    global_cfg: config.Config,
    local_cfg: config.Config,
    key: config.ConfigKey,
) []const u8 {
    if (flagSetForKey(global_options, key)) return "flag";
    if (env.get(envNameForKey(key)) != null) return "env";
    if (config.getKey(local_cfg, key) != null) return "local";
    if (config.getKey(global_cfg, key) != null) return "global";
    return "default";
}

fn flagSetForKey(global_options: generated_usage.GlobalOptions, key: config.ConfigKey) bool {
    return switch (key) {
        .refstore_kind => global_options.refstore != null,
        .refstore_repo => global_options.repo != null,
        .refstore_ref_name => global_options.ref != null,
        .refstore_api_base => global_options.api_base != null,
        .refstore_credential_helper => global_options.credential_helper != null,
    };
}

fn envNameForKey(key: config.ConfigKey) []const u8 {
    return switch (key) {
        .refstore_kind => "SIDESHOWDB_REFSTORE",
        .refstore_repo => "SIDESHOWDB_REPO",
        .refstore_ref_name => "SIDESHOWDB_REF",
        .refstore_api_base => "SIDESHOWDB_API_BASE",
        .refstore_credential_helper => "SIDESHOWDB_CREDENTIAL_HELPER",
    };
}

fn encodeConfigGetJson(gpa: Allocator, key: []const u8, value: []const u8, source: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"key\":");
    try std.json.Stringify.value(key, .{}, &out.writer);
    try out.writer.writeAll(",\"value\":");
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeAll(",\"source\":");
    try std.json.Stringify.value(source, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn encodeConfigStatusJson(gpa: Allocator, status: []const u8, key: []const u8, scope: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"status\":");
    try std.json.Stringify.value(status, .{}, &out.writer);
    try out.writer.writeAll(",\"key\":");
    try std.json.Stringify.value(key, .{}, &out.writer);
    try out.writer.writeAll(",\"scope\":");
    try std.json.Stringify.value(scope, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn encodeConfigRowsPlain(gpa: Allocator, rows: []const config.ConfigRow) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (rows) |row| try out.writer.print("{s}={s}\n", .{ row.key, row.value });
    return out.toOwnedSlice();
}

fn encodeConfigRowsJson(gpa: Allocator, rows: []const config.ConfigRow, source: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("[");
    for (rows, 0..) |row, index| {
        if (index != 0) try out.writer.writeAll(",");
        try out.writer.writeAll("{\"key\":");
        try std.json.Stringify.value(row.key, .{}, &out.writer);
        try out.writer.writeAll(",\"value\":");
        try std.json.Stringify.value(row.value, .{}, &out.writer);
        try out.writer.writeAll(",\"source\":");
        try std.json.Stringify.value(source, .{}, &out.writer);
        try out.writer.writeAll("}");
    }
    try out.writer.writeAll("]\n");
    return out.toOwnedSlice();
}

fn encodeResolvedConfigPlain(gpa: Allocator, resolved: config.ResolvedConfig) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeResolvedRowsPlain(&out.writer, resolved);
    return out.toOwnedSlice();
}

fn encodeResolvedConfigJson(
    gpa: Allocator,
    env: *const Environ.Map,
    global_options: generated_usage.GlobalOptions,
    global_cfg: config.Config,
    local_cfg: config.Config,
    resolved: config.ResolvedConfig,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("[");
    var first = true;
    try writeResolvedJsonRow(&out.writer, &first, env, global_options, global_cfg, local_cfg, .refstore_api_base, resolved.refstore.api_base);
    try writeResolvedJsonRow(&out.writer, &first, env, global_options, global_cfg, local_cfg, .refstore_credential_helper, credentialHelperName(resolved.refstore.credential_helper));
    try writeResolvedJsonRow(&out.writer, &first, env, global_options, global_cfg, local_cfg, .refstore_kind, refStoreKindName(resolved.refstore.kind));
    try writeResolvedJsonRow(&out.writer, &first, env, global_options, global_cfg, local_cfg, .refstore_ref_name, resolved.refstore.ref_name);
    if (resolved.refstore.repo) |repo| {
        try writeResolvedJsonRow(&out.writer, &first, env, global_options, global_cfg, local_cfg, .refstore_repo, repo);
    }
    try out.writer.writeAll("]\n");
    return out.toOwnedSlice();
}

fn writeResolvedRowsPlain(writer: *std.Io.Writer, resolved: config.ResolvedConfig) !void {
    try writer.print("refstore.api_base={s}\n", .{resolved.refstore.api_base});
    try writer.print("refstore.credential_helper={s}\n", .{credentialHelperName(resolved.refstore.credential_helper)});
    try writer.print("refstore.kind={s}\n", .{refStoreKindName(resolved.refstore.kind)});
    try writer.print("refstore.ref_name={s}\n", .{resolved.refstore.ref_name});
    if (resolved.refstore.repo) |repo| try writer.print("refstore.repo={s}\n", .{repo});
}

fn writeResolvedJsonRow(
    writer: *std.Io.Writer,
    first: *bool,
    env: *const Environ.Map,
    global_options: generated_usage.GlobalOptions,
    global_cfg: config.Config,
    local_cfg: config.Config,
    key: config.ConfigKey,
    value: []const u8,
) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;
    try writer.writeAll("{\"key\":");
    try std.json.Stringify.value(key.asString(), .{}, writer);
    try writer.writeAll(",\"value\":");
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeAll(",\"source\":");
    try std.json.Stringify.value(sourceForResolvedKey(env, global_options, global_cfg, local_cfg, key), .{}, writer);
    try writer.writeAll("}");
}

fn refStoreKindName(value: config.RefStoreKind) []const u8 {
    return switch (value) {
        .subprocess => "subprocess",
        .github => "github",
    };
}

fn credentialHelperName(value: config.CredentialHelper) []const u8 {
    return switch (value) {
        .auto => "auto",
        .env => "env",
        .gh => "gh",
        .git => "git",
    };
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
    hosts_token: ?[]const u8 = null,

    pub fn refStore(self: *GitHubStoreState) sideshowdb.RefStore {
        return self.github_store.refStore();
    }

    pub fn deinit(self: *GitHubStoreState, gpa: Allocator) void {
        self.github_store.deinitCaches(gpa);
        self.cred_handle.deinit();
        self.http_client.deinit();
        if (self.hosts_token) |token| gpa.free(token);
        self.hosts_token = null;
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
    out.hosts_token = null;
    errdefer if (out.hosts_token) |token| {
        gpa.free(token);
        out.hosts_token = null;
    };

    const helper_value = credential_helper orelse "auto";
    const cred_spec: credential_provider.CredentialSpec = blk: {
        if (std.mem.eql(u8, helper_value, "auto")) {
            // Check hosts_file for a stored PAT first; fall through to .auto on failure.
            if (tryLoadHostsToken(gpa, env)) |token| {
                out.hosts_token = token;
                break :blk .{ .explicit = token };
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
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
        return config.parseRefStoreKind(argv[i + 1]) == null;
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
