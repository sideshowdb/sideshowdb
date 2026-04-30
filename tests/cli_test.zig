const std = @import("std");
const sideshowdb = @import("sideshowdb");
const cli = @import("sideshowdb_cli_app");
const cli_test_options = @import("cli_test_options");
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
        &.{ "sideshowdb", "--refstore", "ziggit", "version" },
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
        &.{ "sideshowdb", "--refstore", "subprocess", "version" },
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
        .data = "[storage]\nrefstore = \"subprocess\"\n",
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

    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, data, "0.1.0-alpha.1"),
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
            "sideshowdb",  "--json",     "doc",  "put",
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
        &.{ "sideshowdb", "--json", "doc", "get", "--type", "note", "--id", "file-demo" },
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
            "sideshowdb",  "--json",     "doc",  "put",
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
        &.{ "sideshowdb", "--json", "doc", "get", "--type", "note", "--id", "file-missing" },
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
            "sideshowdb",  "--json",     "doc",  "put",
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
        &.{ "sideshowdb", "--json", "doc", "get", "--type", "note", "--id", "precedence" },
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

    const result = try cli.run(gpa, io, &env, ".", &.{ "sideshowdb", "auth", "status" }, "");
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
        &.{ "sideshowdb", "gh", "auth", "login", "--with-token", "--skip-verify" },
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
        &.{ "sideshowdb", "--json", "auth", "status" },
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
        &.{ "sideshowdb", "gh", "auth", "login", "--with-token", "--skip-verify" },
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
        &.{ "sideshowdb", "gh", "auth", "login", "--with-token", "--skip-verify" },
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
        &.{ "sideshowdb", "gh", "auth", "login", "--with-token", "--skip-verify" },
        "ghp_logout_token_abcd\n",
    );
    defer login.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), login.exit_code);

    const logout_other = try cli.run(
        gpa,
        io,
        &env,
        ".",
        &.{ "sideshowdb", "auth", "logout", "--host", "ghe.example.com" },
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
        &.{ "sideshowdb", "auth", "logout", "--host", "github.com" },
        "",
    );
    defer logout.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), logout.exit_code);

    const after = try cli.run(gpa, io, &env, ".", &.{ "sideshowdb", "auth", "status" }, "");
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
        &.{ "sideshowdb", "--refstore", "github", "doc", "list" },
        "",
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "--repo owner/name") != null);
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

    const result = try cli.run(gpa, io, &env, ".", &.{ "sideshowdb", "--json", "auth", "status" }, "");
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
