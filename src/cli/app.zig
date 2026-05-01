const std = @import("std");
const sideshowdb = @import("sideshowdb");
const generated_usage = @import("sideshowdb_cli_generated_usage");
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
    var parsed = generated_usage.parseArgv(gpa, argv) catch |err| switch (err) {
        error.InvalidChoice => {
            if (hasInvalidRefstoreChoice(argv)) return failure(gpa, refstore_invalid_message);
            return usageFailure(gpa);
        },
        else => return usageFailure(gpa),
    };
    defer parsed.deinit(gpa);

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
        .version,
        .auth_status,
        .auth_logout,
        .gh_auth_login,
        .gh_auth_status,
        .gh_auth_logout,
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

fn usageFailure(gpa: Allocator) !RunResult {
    return failure(gpa, usage_message);
}

fn versionSuccess(gpa: Allocator) !RunResult {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try sideshowdb.writeBanner(&writer);
    return success(gpa, try gpa.dupe(u8, writer.buffered()));
}
