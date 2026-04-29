const std = @import("std");
const sideshowdb = @import("sideshowdb");
const cli = @import("sideshowdb_cli_app");
const Environ = std.process.Environ;

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
        &.{ "sideshowdb", "--json", "doc", "put", "--type", "issue", "--id", "cli-1" },
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
        &.{ "sideshowdb", "--json", "doc", "get", "--type", "issue", "--id", "cli-1", "--version", written_version },
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

    const missing_args = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{"sideshowdb"},
        "",
    );
    defer missing_args.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), missing_args.exit_code);
    try std.testing.expectEqualStrings(cli.usage_message, missing_args.stderr);

    const invalid_put_args = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshowdb", "doc", "put", "--type" },
        "",
    );
    defer invalid_put_args.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), invalid_put_args.exit_code);
    try std.testing.expectEqualStrings(cli.usage_message, invalid_put_args.stderr);
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
        &.{ "sideshowdb", "version" },
        "",
    );
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "sideshowdb") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "0.1.0-alpha.1") != null);
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
        &.{ "sideshowdb", "doc", "put", "--type", "issue", "--id", "cli-json-1" },
        "{\"title\":\"json mode\"}",
    );
    defer created.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), created.exit_code);

    const json_list = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "--json", "doc", "list", "--mode", "summary" },
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
        &.{ "sideshowdb", "doc", "get", "--type", "issue", "--id", "cli-json-1" },
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
        &.{ "sideshowdb", "doc", "list" },
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
        &.{ "sideshowdb", "doc", "put", "--type", "issue", "--id", "cli-history-1" },
        "{\"title\":\"first\"}",
    );
    defer first.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), first.exit_code);

    const second = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "doc", "put", "--type", "issue", "--id", "cli-history-1" },
        "{\"title\":\"second\"}",
    );
    defer second.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), second.exit_code);

    const history_result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "--json", "doc", "history", "--type", "issue", "--id", "cli-history-1", "--limit", "1", "--mode", "detailed" },
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
        &.{ "sideshowdb", "doc", "delete", "--type", "issue", "--id", "cli-history-1" },
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
        &.{ "sideshowdb", "--refstore", "subprocess", "--json", "doc", "put", "--type", "issue", "--id", "backend-flag" },
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
        &.{ "sideshowdb", "--refstore", "bogus", "doc", "put", "--type", "issue", "--id", "bad" },
        "{\"title\":\"nope\"}",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported refstore") != null);

    const doc_ref_path = try std.fs.path.join(gpa, &.{ repo_path, ".git", "refs", "sideshowdb", "documents" });
    defer gpa.free(doc_ref_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, doc_ref_path, .{}));
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
        &.{ "sideshowdb", "--refstore", "ziggit", "version" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
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
        &.{ "sideshowdb", "doc", "list", "--type", "issue" },
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
        .data = "[storage]\nrefstore = \"subprocess\"\n",
    });

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "--json", "doc", "put", "--type", "issue", "--id", "config-1" },
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
        .data = "[storage]\nrefstore = \"ziggit\"\n",
    });

    const result = try cli.run(
        gpa,
        io,
        &env,
        repo_path,
        &.{ "sideshowdb", "doc", "list", "--type", "issue" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unsupported refstore") != null);
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
        &.{ "sideshowdb", "--json", "doc", "list", "--mode", "verbose" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings(cli.usage_message, result.stderr);
}
