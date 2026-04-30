const std = @import("std");
const usage = @import("sideshowdb_cli_usage");

test "usage spec parser reads nested commands and flag metadata" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\version "0.1.0-alpha.1"
        \\usage "usage: sideshowdb [--json] [--refstore ziggit|subprocess] <version|doc <put|get|list|delete|history>>"
        \\flag "--json" global=#true help="Emit machine-readable JSON output"
        \\flag "--refstore <backend>" global=#true default="ziggit" help="Select the native document backend" {
        \\  choices "ziggit" "subprocess"
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
        "usage: sideshowdb [--json] [--refstore ziggit|subprocess] <version|doc <put|get|list|delete|history>>",
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
    try std.testing.expectEqualStrings("ziggit", spec.global_flags[1].default_value.?);
    try std.testing.expectEqual(@as(usize, 2), spec.global_flags[1].choices.len);
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

test "runtime parser resolves global flags, command path, and command flags from the spec" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb [--json] [--refstore ziggit|subprocess] <version|doc <put|get>>"
        \\flag "--json" global=#true
        \\flag "--refstore <backend>" global=#true default="ziggit" {
        \\  choices "ziggit" "subprocess"
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

    try std.testing.expectEqualStrings("doc", parsed.command_path[0]);
    try std.testing.expectEqualStrings("put", parsed.command_path[1]);
    try std.testing.expect(parsed.hasFlag("--json"));
    try std.testing.expectEqualStrings("subprocess", parsed.flagValue("--refstore").?);
    try std.testing.expectEqualStrings("issue", parsed.flagValue("--type").?);
    try std.testing.expectEqualStrings("cli-1", parsed.flagValue("--id").?);
}

test "runtime parser rejects invalid choices declared in the spec" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb [--refstore ziggit|subprocess] <version>"
        \\flag "--refstore <backend>" global=#true {
        \\  choices "ziggit" "subprocess"
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

test "generator emits Zig source for usage text and command metadata" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb [--json] <version|doc <put>>"
        \\flag "--json" global=#true
        \\cmd "version"
        \\cmd "doc" subcommand_required=#true {
        \\  cmd "put" {
        \\    flag "--type <type>"
        \\  }
        \\}
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    const zig_source = try usage.renderGeneratedModule(gpa, &spec);
    defer gpa.free(zig_source);

    try std.testing.expect(std.mem.indexOf(u8, zig_source, "pub const usage_message") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "\"usage: sideshowdb [--json] <version|doc <put>>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "\"--json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "\"doc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "\"put\"") != null);
}
