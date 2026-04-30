const std = @import("std");
const usage = @import("sideshowdb_cli_usage");

test "usage spec parser reads nested commands and flag metadata" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\version "0.1.0-alpha.1"
        \\usage "usage: sideshowdb [--json] [--refstore subprocess] <version|doc <put|get|list|delete|history>>"
        \\flag "--json" global=#true help="Emit machine-readable JSON output"
        \\flag "--refstore <backend>" global=#true default="subprocess" help="Select the native document backend" {
        \\  choices "subprocess"
        \\}
        \\cmd "version" help="Print the product banner and package version."
        \\cmd "doc" subcommand_required=#true {
        \\  cmd "put" {
        \\    flag "--type <type>"
        \\    flag "--id <id>"
        \\  }
        \\}
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    try std.testing.expectEqualStrings("sideshowdb", spec.bin);
    try std.testing.expectEqualStrings(
        "usage: sideshowdb [--json] [--refstore subprocess] <version|doc <put|get|list|delete|history>>",
        spec.usage,
    );
    try std.testing.expectEqual(@as(usize, 2), spec.global_flags.len);
    try std.testing.expectEqual(@as(usize, 2), spec.root_commands.len);
    try std.testing.expectEqualStrings("version", spec.root_commands[0].name);
    try std.testing.expectEqualStrings("doc", spec.root_commands[1].name);
    try std.testing.expect(spec.root_commands[1].subcommand_required);
    try std.testing.expectEqual(@as(usize, 1), spec.root_commands[1].subcommands.len);
    try std.testing.expectEqualStrings("put", spec.root_commands[1].subcommands[0].name);
    try std.testing.expectEqual(@as(usize, 2), spec.root_commands[1].subcommands[0].flags.len);
    try std.testing.expectEqualStrings("--refstore", spec.global_flags[1].long_name.?);
    try std.testing.expectEqualStrings("backend", spec.global_flags[1].value_name.?);
    try std.testing.expectEqualStrings("subprocess", spec.global_flags[1].default_value.?);
    try std.testing.expectEqual(@as(usize, 1), spec.global_flags[1].choices.len);
}

test "usage spec parser preserves raw and multiline strings used by usage metadata" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb <version>"
        \\source_code_link_template r#"https://github.com/sideshowdb/sideshowdb/blob/main/src/cli/{{path}}"#
        \\cmd "version" {
        \\  long_help "Print the product banner and package version.\n\nThis mirrors the generated CLI docs."
        \\}
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, spec.source_code_link_template.?, "src/cli/{{path}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec.root_commands[0].long_help.?, "generated CLI docs") != null);
}

test "usage spec parser rejects unsupported nodes with an actionable error" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb <version>"
        \\complete "task" run="echo task-1"
    ;

    try std.testing.expectError(error.UnsupportedNode, usage.parseSpec(gpa, source));
}

test "runtime parser resolves global flags and typed command payloads from the spec" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb [--json] [--refstore subprocess] <version|doc <put|get>>"
        \\flag "--json" global=#true
        \\flag "--refstore <backend>" global=#true default="subprocess" {
        \\  choices "subprocess"
        \\}
        \\cmd "version"
        \\cmd "doc" subcommand_required=#true {
        \\  cmd "put" {
        \\    flag "--type <type>"
        \\    flag "--id <id>"
        \\  }
        \\}
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    var parsed = try usage.parseArgv(gpa, &spec, &.{
        "sideshowdb",
        "--json",
        "--refstore",
        "subprocess",
        "doc",
        "put",
        "--type",
        "issue",
        "--id",
        "cli-1",
    });
    defer parsed.deinit(gpa);

    try std.testing.expect(parsed.global.json);
    try std.testing.expectEqualStrings("subprocess", parsed.global.refstore.?);
    try std.testing.expectEqualStrings("issue", parsed.command.doc_put.doc_type.?);
    try std.testing.expectEqualStrings("cli-1", parsed.command.doc_put.id.?);
}

test "runtime parser rejects invalid choices declared in the spec" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb [--refstore subprocess] <version>"
        \\flag "--refstore <backend>" global=#true {
        \\  choices "subprocess"
        \\}
        \\cmd "version"
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    try std.testing.expectError(error.InvalidChoice, usage.parseArgv(gpa, &spec, &.{
        "sideshowdb",
        "--refstore",
        "bogus",
        "version",
    }));
}

test "runtime parser resolves version into a typed invocation case" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb <version>"
        \\cmd "version"
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    var parsed = try usage.parseArgv(gpa, &spec, &.{
        "sideshowdb",
        "version",
    });
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(@as(bool, false), parsed.global.json);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.global.refstore);
    try std.testing.expect(parsed.command == .version);
}

test "runtime parser resolves remaining typed command cases from the spec" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb <doc <get|list|delete|history>>"
        \\cmd "doc" subcommand_required=#true {
        \\  cmd "get" {
        \\    flag "--type <type>"
        \\    flag "--id <id>"
        \\    flag "--version <version>"
        \\  }
        \\  cmd "list" {
        \\    flag "--type <type>"
        \\    flag "--limit <count>"
        \\    flag "--cursor <cursor>"
        \\    flag "--mode <mode>" {
        \\      choices "summary" "detailed"
        \\    }
        \\  }
        \\  cmd "delete" {
        \\    flag "--type <type>"
        \\    flag "--id <id>"
        \\  }
        \\  cmd "history" {
        \\    flag "--type <type>"
        \\    flag "--id <id>"
        \\    flag "--limit <count>"
        \\    flag "--cursor <cursor>"
        \\    flag "--mode <mode>" {
        \\      choices "summary" "detailed"
        \\    }
        \\  }
        \\}
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    var get_parsed = try usage.parseArgv(gpa, &spec, &.{
        "sideshowdb",
        "doc",
        "get",
        "--type",
        "issue",
        "--id",
        "cli-2",
        "--version",
        "v3",
    });
    defer get_parsed.deinit(gpa);
    try std.testing.expect(get_parsed.command == .doc_get);
    try std.testing.expectEqualStrings("issue", get_parsed.command.doc_get.doc_type);
    try std.testing.expectEqualStrings("cli-2", get_parsed.command.doc_get.id);
    try std.testing.expectEqualStrings("v3", get_parsed.command.doc_get.version.?);

    var list_parsed = try usage.parseArgv(gpa, &spec, &.{
        "sideshowdb",
        "doc",
        "list",
        "--type",
        "issue",
        "--limit",
        "10",
        "--cursor",
        "abc",
        "--mode",
        "detailed",
    });
    defer list_parsed.deinit(gpa);
    try std.testing.expect(list_parsed.command == .doc_list);
    try std.testing.expectEqualStrings("issue", list_parsed.command.doc_list.doc_type.?);
    try std.testing.expectEqualStrings("10", list_parsed.command.doc_list.limit.?);
    try std.testing.expectEqualStrings("abc", list_parsed.command.doc_list.cursor.?);
    try std.testing.expectEqualStrings("detailed", list_parsed.command.doc_list.mode.?);

    var delete_parsed = try usage.parseArgv(gpa, &spec, &.{
        "sideshowdb",
        "doc",
        "delete",
        "--type",
        "issue",
        "--id",
        "cli-2",
    });
    defer delete_parsed.deinit(gpa);
    try std.testing.expect(delete_parsed.command == .doc_delete);
    try std.testing.expectEqualStrings("issue", delete_parsed.command.doc_delete.doc_type);
    try std.testing.expectEqualStrings("cli-2", delete_parsed.command.doc_delete.id);

    var history_parsed = try usage.parseArgv(gpa, &spec, &.{
        "sideshowdb",
        "doc",
        "history",
        "--type",
        "issue",
        "--id",
        "cli-2",
        "--limit",
        "25",
        "--cursor",
        "v1",
        "--mode",
        "summary",
    });
    defer history_parsed.deinit(gpa);
    try std.testing.expect(history_parsed.command == .doc_history);
    try std.testing.expectEqualStrings("issue", history_parsed.command.doc_history.doc_type);
    try std.testing.expectEqualStrings("cli-2", history_parsed.command.doc_history.id);
    try std.testing.expectEqualStrings("25", history_parsed.command.doc_history.limit.?);
    try std.testing.expectEqualStrings("v1", history_parsed.command.doc_history.cursor.?);
    try std.testing.expectEqualStrings("summary", history_parsed.command.doc_history.mode.?);
}

test "runtime parser rejects missing required flags while building typed invocation payloads" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb <doc <get>>"
        \\cmd "doc" subcommand_required=#true {
        \\  cmd "get" {
        \\    flag "--type <type>"
        \\    flag "--id <id>"
        \\  }
        \\}
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    try std.testing.expectError(error.InvalidArguments, usage.parseArgv(gpa, &spec, &.{
        "sideshowdb",
        "doc",
        "get",
        "--type",
        "issue",
    }));
}

test "generator emits Zig source for usage text and command metadata" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb [--json] <version|doc <put|get|list|delete|history>>"
        \\flag "--json" global=#true
        \\cmd "version"
        \\cmd "doc" subcommand_required=#true {
        \\  cmd "put" {
        \\    flag "--type <type>"
        \\  }
        \\  cmd "get" {
        \\    flag "--type <type>"
        \\    flag "--id <id>"
        \\  }
        \\  cmd "list" {
        \\    flag "--limit <count>"
        \\  }
        \\  cmd "delete" {
        \\    flag "--type <type>"
        \\    flag "--id <id>"
        \\  }
        \\  cmd "history" {
        \\    flag "--type <type>"
        \\    flag "--id <id>"
        \\  }
        \\}
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    const zig_source = try usage.renderGeneratedModule(gpa, &spec);
    defer gpa.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub const usage_message") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub const GlobalOptions = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub const ParsedCli = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub const Invocation = union(enum)") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub const DocPutArgs = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub const DocGetArgs = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub const DocListArgs = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub const DocDeleteArgs = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub const DocHistoryArgs = struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "\"usage: sideshowdb [--json] <version|doc <put|get|list|delete|history>>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "doc_put: DocPutArgs") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "doc_get: DocGetArgs") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "doc_list: DocListArgs") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "doc_delete: DocDeleteArgs") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "doc_history: DocHistoryArgs") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "version: void") != null);
}
