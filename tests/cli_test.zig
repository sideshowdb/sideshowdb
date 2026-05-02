const std = @import("std");
const cli = @import("sideshowdb_cli_app");
const cli_test_options = @import("cli_test_options");
const build_options = @import("build_options");
const Environ = std.process.Environ;

fn formatPackageVersion(gpa: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(gpa, "{f}", .{build_options.package_version});
}

fn isGitAvailable(gpa: std.mem.Allocator, io: std.Io, env: *const Environ.Map) bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "--version" },
        .environ_map = env,
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn runOk(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const Environ.Map,
    argv: []const []const u8,
) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .environ_map = env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.HelperCommandFailed;
}

fn expectConfigJsonSource(value: std.json.Value, key: []const u8, source: []const u8) !void {
    for (value.array.items) |item| {
        if (std.mem.eql(u8, item.object.get("key").?.string, key)) {
            try std.testing.expectEqualStrings(source, item.object.get("source").?.string);
            return;
        }
    }
    return error.ExpectedConfigRow;
}

test "CLI doc put/get normalize namespace and support versioned reads with --json" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);

    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const put_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "doc", "put", "--type", "issue", "--id", "cli-1" },
        "{\"title\":\"hello from cli\"}",
    );
    defer put_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), put_result.exit_code);
    try std.testing.expect(put_result.stderr.len == 0);

    var put_json = try std.json.parseFromSlice(std.json.Value, gpa, put_result.stdout, .{});
    defer put_json.deinit();
    try std.testing.expectEqualStrings("default", put_json.value.object.get("namespace").?.string);
    const written_version = put_json.value.object.get("version").?.string;

    const get_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "doc", "get", "--type", "issue", "--id", "cli-1", "--version", written_version },
        "",
    );
    defer get_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), get_result.exit_code);

    var get_json = try std.json.parseFromSlice(std.json.Value, gpa, get_result.stdout, .{});
    defer get_json.deinit();
    try std.testing.expectEqualStrings("hello from cli", get_json.value.object.get("data").?.object.get("title").?.string);
}

test "CLI usage failures return the shared usage message" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const no_args = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{"sideshow"},
        "",
    );
    defer no_args.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), no_args.exit_code);
    try std.testing.expectEqualStrings("", no_args.stderr);
    try std.testing.expect(std.mem.indexOf(u8, no_args.stdout, "usage: sideshow") != null);

    const invalid_put_args = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "doc", "put", "--type" },
        "",
    );
    defer invalid_put_args.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), invalid_put_args.exit_code);
    try std.testing.expectEqualStrings(cli.usage_message, invalid_put_args.stderr);
}

test "CLI config local set get list unset round trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo_path);

    const set_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "set", "refstore.kind", "github" },
        "",
    );
    defer set_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), set_result.exit_code);
    try std.testing.expectEqualStrings("", set_result.stderr);

    const local_config_path = try std.fs.path.join(gpa, &.{ repo_path, ".sideshowdb", "config.toml" });
    defer gpa.free(local_config_path);
    const local_config_bytes = try std.Io.Dir.cwd().readFileAlloc(io, local_config_path, gpa, .unlimited);
    defer gpa.free(local_config_bytes);
    try std.testing.expect(std.mem.indexOf(u8, local_config_bytes, "kind") != null);

    const get_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "get", "refstore.kind" },
        "",
    );
    defer get_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), get_result.exit_code);
    try std.testing.expectEqualStrings("github\n", get_result.stdout);
    try std.testing.expectEqualStrings("", get_result.stderr);

    const list_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "list", "--local" },
        "",
    );
    defer list_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), list_result.exit_code);
    try std.testing.expectEqualStrings("refstore.kind=github\n", list_result.stdout);

    const unset_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "unset", "refstore.kind" },
        "",
    );
    defer unset_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), unset_result.exit_code);

    const missing_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "get", "--local", "refstore.kind" },
        "",
    );
    defer missing_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), missing_result.exit_code);
    try std.testing.expectEqualStrings("config key not set: refstore.kind\n", missing_result.stderr);
}

test "CLI config global set get uses SIDESHOWDB_CONFIG_DIR" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "global-config" });
    defer gpa.free(config_dir);
    try env.put("SIDESHOWDB_CONFIG_DIR", config_dir);

    const set_result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "config", "set", "--global", "refstore.repo", "owner/repo" },
        "",
    );
    defer set_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), set_result.exit_code);

    const global_config_path = try std.fs.path.join(gpa, &.{ config_dir, "config.toml" });
    defer gpa.free(global_config_path);
    const global_config_bytes = try std.Io.Dir.cwd().readFileAlloc(io, global_config_path, gpa, .unlimited);
    defer gpa.free(global_config_bytes);
    try std.testing.expect(std.mem.indexOf(u8, global_config_bytes, "owner/repo") != null);

    const get_result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "config", "get", "--global", "refstore.repo" },
        "",
    );
    defer get_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), get_result.exit_code);
    try std.testing.expectEqualStrings("owner/repo\n", get_result.stdout);
}

test "CLI config conflicting scopes fail without writing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo_path);

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "set", "--local", "--global", "refstore.kind", "github" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("choose only one of --local or --global\n", result.stderr);

    const get_conflict = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "get", "--local", "--global", "refstore.kind" },
        "",
    );
    defer get_conflict.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), get_conflict.exit_code);
    try std.testing.expectEqualStrings("choose only one of --local or --global\n", get_conflict.stderr);

    const list_conflict = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "list", "--local", "--global" },
        "",
    );
    defer list_conflict.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), list_conflict.exit_code);
    try std.testing.expectEqualStrings("choose only one of --local or --global\n", list_conflict.stderr);

    const unset_conflict = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "unset", "--local", "--global", "refstore.kind" },
        "",
    );
    defer unset_conflict.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), unset_conflict.exit_code);
    try std.testing.expectEqualStrings("choose only one of --local or --global\n", unset_conflict.stderr);

    const missing = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "get", "--local", "refstore.kind" },
        "",
    );
    defer missing.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), missing.exit_code);
    try std.testing.expectEqualStrings("config key not set: refstore.kind\n", missing.stderr);
}

test "CLI config rejects unknown keys and invalid enum values" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const unknown = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "config", "set", "github.token", "secret" },
        "",
    );
    defer unknown.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), unknown.exit_code);
    try std.testing.expectEqualStrings("unknown config key: github.token\n", unknown.stderr);

    const invalid = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "config", "set", "refstore.kind", "banana" },
        "",
    );
    defer invalid.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), invalid.exit_code);
    try std.testing.expectEqualStrings("invalid value for config key: refstore.kind\n", invalid.stderr);
}

test "CLI config json get includes key value and source" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo_path);

    const set_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "set", "refstore.kind", "github" },
        "",
    );
    defer set_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), set_result.exit_code);

    const get_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "config", "get", "refstore.kind" },
        "",
    );
    defer get_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), get_result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, get_result.stdout, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("refstore.kind", parsed.value.object.get("key").?.string);
    try std.testing.expectEqualStrings("github", parsed.value.object.get("value").?.string);
    try std.testing.expectEqualStrings("local", parsed.value.object.get("source").?.string);
}

test "CLI config json reports flag env local and default sources" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo_path);

    const set_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "set", "refstore.repo", "local/repo" },
        "",
    );
    defer set_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), set_result.exit_code);

    try env.put("SIDESHOWDB_API_BASE", "https://env.example/api");

    const list_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "--refstore", "github", "config", "list" },
        "",
    );
    defer list_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), list_result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, list_result.stdout, .{});
    defer parsed.deinit();
    try expectConfigJsonSource(parsed.value, "refstore.kind", "flag");
    try expectConfigJsonSource(parsed.value, "refstore.api_base", "env");
    try expectConfigJsonSource(parsed.value, "refstore.repo", "local");
    try expectConfigJsonSource(parsed.value, "refstore.ref_name", "default");

    const get_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "--refstore", "github", "config", "get", "refstore.kind" },
        "",
    );
    defer get_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), get_result.exit_code);
    var get_json = try std.json.parseFromSlice(std.json.Value, gpa, get_result.stdout, .{});
    defer get_json.deinit();
    try std.testing.expectEqualStrings("flag", get_json.value.object.get("source").?.string);
}

test "CLI config json set and unset status include key scope and status" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo_path);

    const set_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "config", "set", "refstore.kind", "github" },
        "",
    );
    defer set_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), set_result.exit_code);
    var set_json = try std.json.parseFromSlice(std.json.Value, gpa, set_result.stdout, .{});
    defer set_json.deinit();
    try std.testing.expectEqualStrings("set", set_json.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("refstore.kind", set_json.value.object.get("key").?.string);
    try std.testing.expectEqualStrings("local", set_json.value.object.get("scope").?.string);

    const unset_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "config", "unset", "refstore.kind" },
        "",
    );
    defer unset_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), unset_result.exit_code);
    var unset_json = try std.json.parseFromSlice(std.json.Value, gpa, unset_result.stdout, .{});
    defer unset_json.deinit();
    try std.testing.expectEqualStrings("unset", unset_json.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("refstore.kind", unset_json.value.object.get("key").?.string);
    try std.testing.expectEqualStrings("local", unset_json.value.object.get("scope").?.string);
}

test "CLI config scoped get and list read only the selected file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    defer gpa.free(repo_path);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cfg" });
    defer gpa.free(config_dir);
    try env.put("SIDESHOWDB_CONFIG_DIR", config_dir);

    const global_set = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "set", "--global", "refstore.kind", "github" }, "");
    defer global_set.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), global_set.exit_code);
    const local_set = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "set", "--local", "refstore.kind", "subprocess" }, "");
    defer local_set.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), local_set.exit_code);

    const global_get = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "get", "--global", "refstore.kind" }, "");
    defer global_get.deinit(gpa);
    try std.testing.expectEqualStrings("github\n", global_get.stdout);
    const local_get = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "get", "--local", "refstore.kind" }, "");
    defer local_get.deinit(gpa);
    try std.testing.expectEqualStrings("subprocess\n", local_get.stdout);

    const global_list = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "list", "--global" }, "");
    defer global_list.deinit(gpa);
    try std.testing.expectEqualStrings("refstore.kind=github\n", global_list.stdout);
    const local_list = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "list", "--local" }, "");
    defer local_list.deinit(gpa);
    try std.testing.expectEqualStrings("refstore.kind=subprocess\n", local_list.stdout);
}

test "CLI config get and list return failure for invalid local TOML" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    defer gpa.free(repo_path);
    const config_dir = try std.fs.path.join(gpa, &.{ repo_path, ".sideshowdb" });
    defer gpa.free(config_dir);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, config_dir, .{});
    dir.close(io);
    const config_path = try std.fs.path.join(gpa, &.{ config_dir, "config.toml" });
    defer gpa.free(config_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = config_path,
        .data = "[refstore\nkind = \"github\"\n",
    });

    const get_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "get", "refstore.kind" },
        "",
    );
    defer get_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), get_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, get_result.stderr, "invalid config") != null);

    const list_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "list" },
        "",
    );
    defer list_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), list_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, list_result.stderr, "invalid config") != null);
}

test "CLI config global command fails when global path cannot be resolved" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = Environ.Map.init(gpa);
    defer env.deinit();

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "config", "set", "--global", "refstore.kind", "github" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "config path") != null);
}

test "CLI command groups print contextual help on stdout" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const doc = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "doc" },
        "",
    );
    defer doc.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), doc.exit_code);
    try std.testing.expectEqualStrings("", doc.stderr);
    try std.testing.expect(std.mem.indexOf(u8, doc.stdout, "sideshow doc") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.stdout, "Usage:\n  sideshow doc <put|get|list|delete|history>") != null);

    const gh_auth = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "--json", "gh", "auth" },
        "",
    );
    defer gh_auth.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), gh_auth.exit_code);
    try std.testing.expectEqualStrings("", gh_auth.stderr);
    try std.testing.expect(std.mem.indexOf(u8, gh_auth.stdout, "sideshow gh auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, gh_auth.stdout, "Usage:\n  sideshow gh auth <login|status|logout>") != null);
}

test "CLI unknown command emits diagnostic before usage" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const bogus = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "bogus" },
        "",
    );
    defer bogus.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), bogus.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, bogus.stderr, "unknown command: bogus\n"));
    try std.testing.expect(std.mem.indexOf(u8, bogus.stderr, "usage: sideshow") != null);
    try std.testing.expectEqualStrings("", bogus.stdout);

    const typo = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "vesion" },
        "",
    );
    defer typo.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), typo.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, typo.stderr, "did you mean: version?") != null);

    const nested = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "doc", "bogus" },
        "",
    );
    defer nested.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), nested.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, nested.stderr, "unknown command: bogus\n"));
}

test "CLI nested unknown commands show nearest command group usage" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const nested = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "doc", "nope" },
        "",
    );
    defer nested.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), nested.exit_code);
    try std.testing.expectEqualStrings("", nested.stdout);
    try std.testing.expect(std.mem.startsWith(u8, nested.stderr, "unknown command: nope\n"));
    try std.testing.expect(std.mem.indexOf(u8, nested.stderr, "Usage:\n  sideshow doc <put|get|list|delete|history>") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested.stderr, "usage: sideshow [--help]") == null);
}

test "CLI version command prints banner and version" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "version" },
        "",
    );
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sideshow") != null);
    const version_str = try formatPackageVersion(gpa);
    defer gpa.free(version_str);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, version_str) != null);
}

test "CLI version command does not wait for stdin EOF" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const exe_path: []const u8 = cli_test_options.cli_exe_path;
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe_path, "version" },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = child.stdout.?.handle,
        .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&poll_fds, 250);
    if (ready == 0) {
        child.kill(io);
        return error.CliWaitedForStdin;
    }

    var stdout_buf: [512]u8 = undefined;
    const stdout_len = try std.posix.read(child.stdout.?.handle, &stdout_buf);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf[0..stdout_len], "sideshow") != null);

    child.stdin.?.close(io);
    child.stdin = null;

    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
}

test "CLI doc commands emit JSON only when --json is supplied" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);

    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const created = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "doc", "put", "--type", "issue", "--id", "cli-json-1" },
        "{\"title\":\"json mode\"}",
    );
    defer created.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), created.exit_code);

    const json_list = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "doc", "list", "--mode", "summary" },
        "",
    );
    defer json_list.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), json_list.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, json_list.stdout, "\"kind\":\"summary\"") != null);

    const human_get = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "doc", "get", "--type", "issue", "--id", "cli-json-1" },
        "",
    );
    defer human_get.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), human_get.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, human_get.stdout, "\"data\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, human_get.stdout, "namespace: default") != null);

    const human_list = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "doc", "list" },
        "",
    );
    defer human_list.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), human_list.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, human_list.stdout, "NAMESPACE") != null);
    try std.testing.expect(std.mem.indexOf(u8, human_list.stdout, "\"kind\"") == null);
}

test "CLI doc delete and history accept traversal flags" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);

    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const first = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "doc", "put", "--type", "issue", "--id", "cli-history-1" },
        "{\"title\":\"first\"}",
    );
    defer first.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), first.exit_code);

    const second = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "doc", "put", "--type", "issue", "--id", "cli-history-1" },
        "{\"title\":\"second\"}",
    );
    defer second.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), second.exit_code);

    const history_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "doc", "history", "--type", "issue", "--id", "cli-history-1", "--limit", "1", "--mode", "detailed" },
        "",
    );
    defer history_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), history_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, history_result.stdout, "\"kind\":\"detailed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, history_result.stdout, "\"next_cursor\":") != null);

    const delete_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "doc", "delete", "--type", "issue", "--id", "cli-history-1" },
        "",
    );
    defer delete_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), delete_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, delete_result.stdout, "deleted: true") != null);
}

test "CLI --refstore subprocess selects fallback backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);
    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--refstore", "subprocess", "--json", "doc", "put", "--type", "issue", "--id", "backend-flag" },
        "{\"title\":\"fallback\"}",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(result.stderr.len == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"version\"") != null);
}

test "CLI invalid --refstore fails before mutation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--refstore", "bogus", "doc", "put", "--type", "issue", "--id", "bad" },
        "{\"title\":\"nope\"}",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported refstore") != null);

    const doc_ref_path = try std.fs.path.join(gpa, &.{ repo_path, ".git", "refs", "sideshowdb", "documents" });
    defer gpa.free(doc_ref_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, doc_ref_path, .{}));
}

test "CLI rejects removed ziggit refstore backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "--refstore", "ziggit", "version" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported refstore") != null);
}

test "CLI refstore flag overrides environment" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_REFSTORE", "bogus");

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "--refstore", "subprocess", "version" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "CLI refstore flag ignores invalid environment refstore for doc commands" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_REFSTORE", "banana");
    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);
    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--refstore", "subprocess", "doc", "list", "--type", "issue" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "CLI invalid environment refstore fails when no flag is present" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_REFSTORE", "bogus");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "doc", "list", "--type", "issue" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported refstore") != null);
}

test "CLI loads refstore from .sideshowdb/config.toml when flag and env absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);
    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const sideshowdb_dir = try std.fs.path.join(gpa, &.{ repo_path, ".sideshowdb" });
    defer gpa.free(sideshowdb_dir);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, sideshowdb_dir, .{});
    dir.close(io);

    const config_path = try std.fs.path.join(gpa, &.{ sideshowdb_dir, "config.toml" });
    defer gpa.free(config_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = config_path,
        .data = "[refstore]\nkind = \"subprocess\"\n",
    });

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "doc", "put", "--type", "issue", "--id", "config-1" },
        "{\"title\":\"from config\"}",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"version\"") != null);
}

test "CLI environment overrides config" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_REFSTORE", "bogus");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);

    const sideshowdb_dir = try std.fs.path.join(gpa, &.{ repo_path, ".sideshowdb" });
    defer gpa.free(sideshowdb_dir);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, sideshowdb_dir, .{});
    dir.close(io);

    const config_path = try std.fs.path.join(gpa, &.{ sideshowdb_dir, "config.toml" });
    defer gpa.free(config_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = config_path,
        .data = "[refstore]\nkind = \"subprocess\"\n",
    });

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "doc", "list", "--type", "issue" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported refstore") != null);
}

test "CLI refstore config precedence uses global local env and flag layers" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    defer gpa.free(repo_path);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cfg" });
    defer gpa.free(config_dir);
    try env.put("SIDESHOWDB_CONFIG_DIR", config_dir);
    _ = env.swapRemove("GITHUB_TOKEN");
    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const global_set = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "set", "--global", "refstore.kind", "github" },
        "",
    );
    defer global_set.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), global_set.exit_code);

    const helper_set = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "set", "--global", "refstore.credential_helper", "env" },
        "",
    );
    defer helper_set.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), helper_set.exit_code);

    const global_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--repo", "owner/name", "doc", "list" },
        "",
    );
    defer global_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), global_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, global_result.stderr, "no GitHub credentials configured") != null);

    const local_set = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "config", "set", "--local", "refstore.kind", "subprocess" },
        "",
    );
    defer local_set.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), local_set.exit_code);

    const local_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "doc", "list", "--type", "issue" },
        "",
    );
    defer local_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), local_result.exit_code);

    try env.put("SIDESHOWDB_REFSTORE", "github");
    const env_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--repo", "owner/name", "doc", "list" },
        "",
    );
    defer env_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), env_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, env_result.stderr, "no GitHub credentials configured") != null);

    const flag_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--refstore", "subprocess", "doc", "list", "--type", "issue" },
        "",
    );
    defer flag_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), flag_result.exit_code);
}

test "CLI rejects unsupported mode with usage failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "--json", "doc", "list", "--mode", "verbose" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings(cli.usage_message, result.stderr);
}

test "CLI event append/load supports JSONL and JSON batches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);
    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const jsonl =
        \\{"event_id":"evt-1","event_type":"IssueOpened","namespace":"default","aggregate_type":"issue","aggregate_id":"issue-1","timestamp":"2026-04-30T12:00:00Z","payload":{"title":"first"}}
        \\{"event_id":"evt-2","event_type":"IssueRenamed","namespace":"default","aggregate_type":"issue","aggregate_id":"issue-1","timestamp":"2026-04-30T12:01:00Z","payload":{"title":"second"}}
        \\
    ;
    const append_jsonl = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "event",
            "append",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
            "--expected-revision",
            "0",
            "--format",
            "jsonl",
        },
        jsonl,
    );
    defer append_jsonl.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), append_jsonl.exit_code);
    var append_jsonl_value = try std.json.parseFromSlice(std.json.Value, gpa, append_jsonl.stdout, .{});
    defer append_jsonl_value.deinit();
    try std.testing.expectEqual(@as(i64, 2), append_jsonl_value.value.object.get("revision").?.integer);

    const json_batch =
        \\{"events":[{"event_id":"evt-3","event_type":"IssueClosed","namespace":"default","aggregate_type":"issue","aggregate_id":"issue-1","timestamp":"2026-04-30T12:02:00Z","payload":{"title":"third"}}]}
    ;
    const append_json = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "event",
            "append",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
            "--expected-revision",
            "2",
            "--format",
            "json",
        },
        json_batch,
    );
    defer append_json.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), append_json.exit_code);
    var append_json_value = try std.json.parseFromSlice(std.json.Value, gpa, append_json.stdout, .{});
    defer append_json_value.deinit();
    try std.testing.expectEqual(@as(i64, 3), append_json_value.value.object.get("revision").?.integer);

    const load = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "event",
            "load",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
            "--from-revision",
            "2",
        },
        "",
    );
    defer load.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), load.exit_code);
    var load_json = try std.json.parseFromSlice(std.json.Value, gpa, load.stdout, .{});
    defer load_json.deinit();
    try std.testing.expectEqual(@as(i64, 3), load_json.value.object.get("revision").?.integer);
    const events = load_json.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("evt-2", events[0].object.get("event_id").?.string);
    try std.testing.expectEqualStrings("evt-3", events[1].object.get("event_id").?.string);
}

test "CLI event append failures do not mutate the stream" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);
    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const first =
        \\{"event_id":"evt-1","event_type":"IssueOpened","namespace":"default","aggregate_type":"issue","aggregate_id":"issue-1","timestamp":"2026-04-30T12:00:00Z","payload":{"title":"first"}}
        \\
    ;
    const ok = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "event",
            "append",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
            "--expected-revision",
            "0",
        },
        first,
    );
    defer ok.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), ok.exit_code);

    const mismatch = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "event",
            "append",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
            "--expected-revision",
            "0",
        },
        first,
    );
    defer mismatch.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), mismatch.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, mismatch.stderr, "WrongExpectedRevision") != null);

    const invalid = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "event",
            "append",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
            "--expected-revision",
            "1",
            "--format",
            "json",
        },
        "{\"events\":[{\"event_type\":\"missing-id\"}]}",
    );
    defer invalid.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), invalid.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, invalid.stderr, "InvalidEvent") != null);

    const load = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "event",
            "load",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
        },
        "",
    );
    defer load.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), load.exit_code);
    var load_json = try std.json.parseFromSlice(std.json.Value, gpa, load.stdout, .{});
    defer load_json.deinit();
    try std.testing.expectEqual(@as(i64, 1), load_json.value.object.get("revision").?.integer);
    const events = load_json.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("evt-1", events[0].object.get("event_id").?.string);
}

test "CLI snapshot put/get/list supports latest and at-or-before lookups" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);
    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const put2 = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "snapshot",
            "put",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
            "--revision",
            "2",
            "--up-to-event-id",
            "evt-2",
        },
        "{\"status\":\"open\"}",
    );
    defer put2.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), put2.exit_code);

    const put5 = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "snapshot",
            "put",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
            "--revision",
            "5",
            "--up-to-event-id",
            "evt-5",
        },
        "{\"status\":\"closed\"}",
    );
    defer put5.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), put5.exit_code);

    const latest = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "snapshot",
            "get",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
            "--latest",
        },
        "",
    );
    defer latest.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), latest.exit_code);
    var latest_json = try std.json.parseFromSlice(std.json.Value, gpa, latest.stdout, .{});
    defer latest_json.deinit();
    try std.testing.expectEqual(@as(i64, 5), latest_json.value.object.get("revision").?.integer);
    try std.testing.expectEqualStrings("closed", latest_json.value.object.get("state").?.object.get("status").?.string);

    const at_or_before = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "snapshot",
            "get",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
            "--at-or-before",
            "4",
        },
        "",
    );
    defer at_or_before.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), at_or_before.exit_code);
    var at_or_before_json = try std.json.parseFromSlice(std.json.Value, gpa, at_or_before.stdout, .{});
    defer at_or_before_json.deinit();
    try std.testing.expectEqual(@as(i64, 2), at_or_before_json.value.object.get("revision").?.integer);
    try std.testing.expectEqualStrings("open", at_or_before_json.value.object.get("state").?.object.get("status").?.string);

    const list = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",
            "--json",
            "snapshot",
            "list",
            "--namespace",
            "default",
            "--aggregate-type",
            "issue",
            "--aggregate-id",
            "issue-1",
        },
        "",
    );
    defer list.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), list.exit_code);
    var list_json = try std.json.parseFromSlice(std.json.Value, gpa, list.stdout, .{});
    defer list_json.deinit();
    const items = list_json.value.object.get("items").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i64, 5), items[0].object.get("revision").?.integer);
    try std.testing.expectEqual(@as(i64, 2), items[1].object.get("revision").?.integer);
}

test "CLI stdout preserves inherited file position across chained invocations" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const tmp_path = try std.fs.path.join(gpa, &.{
        cwd, ".zig-cache", "tmp", &tmp.sub_path,
    });
    defer gpa.free(tmp_path);

    const log_path = try std.fs.path.join(gpa, &.{ tmp_path, "stdout.log" });
    defer gpa.free(log_path);

    var log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{ .read = false, .truncate = true });
    defer log_file.close(io);

    const exe_path: []const u8 = cli_test_options.cli_exe_path;

    var child_a = try std.process.spawn(io, .{
        .argv = &.{ exe_path, "version" },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .ignore,
    });
    const term_a = try child_a.wait(io);
    try std.testing.expect(term_a == .exited);
    try std.testing.expectEqual(@as(u8, 0), term_a.exited);

    var child_b = try std.process.spawn(io, .{
        .argv = &.{ exe_path, "version" },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .ignore,
    });
    const term_b = try child_b.wait(io);
    try std.testing.expect(term_b == .exited);
    try std.testing.expectEqual(@as(u8, 0), term_b.exited);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, log_path, gpa, .unlimited);
    defer gpa.free(data);

    const version_str = try formatPackageVersion(gpa);
    defer gpa.free(version_str);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, data, version_str),
    );
}

test "CLI doc put --data-file reads payload from file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);

    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const payload_path = try std.fs.path.join(gpa, &.{ repo_path, "payload.json" });
    defer gpa.free(payload_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = payload_path,
        .data = "{\"title\":\"from file\"}",
    });

    const put_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",    "--json",     "doc",  "put",
            "--type",      "note",       "--id", "file-demo",
            "--data-file", payload_path,
        },
        "",
    );
    defer put_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), put_result.exit_code);
    try std.testing.expect(put_result.stderr.len == 0);

    var put_json = try std.json.parseFromSlice(std.json.Value, gpa, put_result.stdout, .{});
    defer put_json.deinit();
    try std.testing.expectEqualStrings("note", put_json.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("file-demo", put_json.value.object.get("id").?.string);

    const get_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "doc", "get", "--type", "note", "--id", "file-demo" },
        "",
    );
    defer get_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), get_result.exit_code);

    var get_json = try std.json.parseFromSlice(std.json.Value, gpa, get_result.stdout, .{});
    defer get_json.deinit();
    try std.testing.expectEqualStrings(
        "from file",
        get_json.value.object.get("data").?.object.get("title").?.string,
    );
}

test "CLI doc put --data-file fails non-zero on missing file without mutating state" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);

    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const missing_path = try std.fs.path.join(gpa, &.{ repo_path, "does-not-exist.json" });
    defer gpa.free(missing_path);

    const put_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",    "--json",     "doc",  "put",
            "--type",      "note",       "--id", "file-missing",
            "--data-file", missing_path,
        },
        "",
    );
    defer put_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), put_result.exit_code);
    try std.testing.expect(put_result.stdout.len == 0);
    try std.testing.expect(std.mem.indexOf(u8, put_result.stderr, "--data-file") != null);

    const get_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "doc", "get", "--type", "note", "--id", "file-missing" },
        "",
    );
    defer get_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), get_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, get_result.stderr, "document not found") != null);
}

test "CLI doc put precedence: --data-file overrides stdin payload" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    if (!isGitAvailable(gpa, io, &env)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
    });
    defer gpa.free(repo_path);

    try runOk(gpa, io, &env, &.{ "git", "init", "--quiet", repo_path });

    const payload_path = try std.fs.path.join(gpa, &.{ repo_path, "payload.json" });
    defer gpa.free(payload_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = payload_path,
        .data = "{\"title\":\"file wins\"}",
    });

    const put_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{
            "sideshow",    "--json",     "doc",  "put",
            "--type",      "note",       "--id", "precedence",
            "--data-file", payload_path,
        },
        "{\"title\":\"stdin loses\"}",
    );
    defer put_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), put_result.exit_code);

    const get_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshow", "--json", "doc", "get", "--type", "note", "--id", "precedence" },
        "",
    );
    defer get_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), get_result.exit_code);

    var get_json = try std.json.parseFromSlice(std.json.Value, gpa, get_result.stdout, .{});
    defer get_json.deinit();
    try std.testing.expectEqualStrings(
        "file wins",
        get_json.value.object.get("data").?.object.get("title").?.string,
    );
}

fn makeAuthEnv(gpa: std.mem.Allocator, config_dir: []const u8) !Environ.Map {
    var env = try Environ.createMap(std.testing.environ, gpa);
    errdefer env.deinit();
    try env.put("SIDESHOWDB_CONFIG_DIR", config_dir);
    return env;
}

test "CLI auth status reports no hosts when hosts.toml absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cfg-empty" });
    defer gpa.free(config_dir);

    var env = try makeAuthEnv(gpa, config_dir);
    defer env.deinit();

    const result = try cli.run(gpa, io, &env, ".", &.{ "sideshow", "auth", "status" }, "");
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("No authenticated hosts.\n", result.stdout);
}

test "CLI gh auth login --with-token persists token and auth status reflects it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cfg-login" });
    defer gpa.free(config_dir);

    var env = try makeAuthEnv(gpa, config_dir);
    defer env.deinit();

    const login_result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "gh", "auth", "login", "--with-token", "--skip-verify" },
        "ghp_acceptance_token_xyz12\n",
    );
    defer login_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), login_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, login_result.stdout, "Logged in to github.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, login_result.stdout, "ghp_acceptance_token_xyz12") == null);

    const status_result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "--json", "auth", "status" },
        "",
    );
    defer status_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), status_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "github.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "hosts-file") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "ghp_acceptance_token_xyz12") == null);
}

test "CLI gh auth login --with-token rejects empty stdin" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cfg-empty-token" });
    defer gpa.free(config_dir);

    var env = try makeAuthEnv(gpa, config_dir);
    defer env.deinit();

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "gh", "auth", "login", "--with-token", "--skip-verify" },
        "\n",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "empty token") != null);
}

test "CLI gh auth login --with-token rejects whitespace-bearing tokens" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cfg-ws-token" });
    defer gpa.free(config_dir);

    var env = try makeAuthEnv(gpa, config_dir);
    defer env.deinit();

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "gh", "auth", "login", "--with-token", "--skip-verify" },
        "ghp_with space\n",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "whitespace") != null);
}

test "CLI auth logout removes a known host and is idempotent against unknown hosts" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cfg-logout" });
    defer gpa.free(config_dir);

    var env = try makeAuthEnv(gpa, config_dir);
    defer env.deinit();

    const login = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "gh", "auth", "login", "--with-token", "--skip-verify" },
        "ghp_logout_token_abcd\n",
    );
    defer login.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), login.exit_code);

    const logout_other = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "auth", "logout", "--host", "ghe.example.com" },
        "",
    );
    defer logout_other.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), logout_other.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, logout_other.stderr, "not logged in to ghe.example.com") != null);

    const logout = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "auth", "logout", "--host", "github.com" },
        "",
    );
    defer logout.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), logout.exit_code);

    const after = try cli.run(gpa, io, &env, ".", &.{ "sideshow", "auth", "status" }, "");
    defer after.deinit(gpa);
    try std.testing.expectEqualStrings("No authenticated hosts.\n", after.stdout);
}

test "CLI --refstore github without --repo fails before HTTP" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "--refstore", "github", "doc", "list" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "--repo owner/name") != null);
}

test "CLI --refstore github with malformed --repo fails before HTTP" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    // Repo with no slash is malformed.
    const no_slash = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "--refstore", "github", "--repo", "nodash", "doc", "list" },
        "",
    );
    defer no_slash.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), no_slash.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, no_slash.stderr, "owner/name") != null);

    // Repo with empty owner is malformed.
    const empty_owner = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "--refstore", "github", "--repo", "/myrepo", "doc", "list" },
        "",
    );
    defer empty_owner.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), empty_owner.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, empty_owner.stderr, "owner/name") != null);

    // Repo with empty name is malformed.
    const empty_name = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "--refstore", "github", "--repo", "myorg/", "doc", "list" },
        "",
    );
    defer empty_name.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), empty_name.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, empty_name.stderr, "owner/name") != null);
}

test "CLI --refstore github with valid --repo but no credentials fails" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cfg-no-creds" });
    defer gpa.free(config_dir);

    // Use an isolated config dir with no hosts.toml so no stored token is found.
    // Also unset GITHUB_TOKEN so the env source finds nothing.
    var env = try makeAuthEnv(gpa, config_dir);
    defer env.deinit();
    _ = env.swapRemove("GITHUB_TOKEN");

    const result = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshow", "--refstore", "github", "--repo", "owner/repo", "--credential-helper", "env", "doc", "list" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "credentials") != null);
}

test "CLI help requests print help to stdout without stderr" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = try cli.run(gpa, io, &env, ".", &.{ "sideshow", "help", "doc", "put" }, "");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Create or replace a document version.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--data-file") != null);
}

test "CLI unknown help topic fails before backend setup" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = try cli.run(gpa, io, &env, ".", &.{ "sideshow", "help", "nope" }, "");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unknown help topic: nope") != null);
}

test "CLI auth status --json produces valid JSON even when user field contains backslash" {
    // Regression: renderStatusJson previously hand-crafted JSON with %s format strings.
    // A backslash (or double-quote) in a field value produced malformed JSON.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "cfg-json-escape" });
    defer gpa.free(config_dir);

    var env = try makeAuthEnv(gpa, config_dir);
    defer env.deinit();

    // Create the config dir and write a hosts.toml with a backslash in the user field.
    // The TOML parser stores the raw bytes between the outer quotes, so `path\user`
    // ends up in memory with literal backslash characters.
    var cfg_dir_handle = try std.Io.Dir.cwd().createDirPathOpen(io, config_dir, .{});
    cfg_dir_handle.close(io);
    const hosts_path = try std.fs.path.join(gpa, &.{ config_dir, "hosts.toml" });
    defer gpa.free(hosts_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = hosts_path,
        .data = "[hosts.\"github.com\"]\noauth_token = \"ghp_test123abc\"\nuser = \"path\\user\"\n",
    });
    // hosts_file.read refuses files with permissive mode bits (0o077). Tighten
    // to 0600 so the test exercises the JSON-render path rather than the
    // permission-warning short-circuit.
    {
        const hosts_path_z = try gpa.dupeZ(u8, hosts_path);
        defer gpa.free(hosts_path_z);
        if (std.c.chmod(hosts_path_z.ptr, @as(std.c.mode_t, 0o600)) != 0) return error.SkipZigTest;
    }

    const result = try cli.run(gpa, io, &env, ".", &.{ "sideshow", "--json", "auth", "status" }, "");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    // Must be parseable as JSON — this would fail with the old hand-crafted format.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, result.stdout, .{});
    defer parsed.deinit();
    const hosts_arr = parsed.value.object.get("hosts").?.array;
    try std.testing.expectEqual(@as(usize, 1), hosts_arr.items.len);
    try std.testing.expectEqualStrings("github.com", hosts_arr.items[0].object.get("host").?.string);
    // The user value must round-trip without mangling.
    try std.testing.expectEqualStrings("path\\user", hosts_arr.items[0].object.get("user").?.string);
    // Raw token must not appear in JSON output.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ghp_test123abc") == null);
}
