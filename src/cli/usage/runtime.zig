const std = @import("std");
const build_options = @import("build_options");

pub const ParseError = error{
    InvalidSpec,
    InvalidArguments,
    InvalidChoice,
    MissingRequiredField,
    ParseError,
    UnsupportedNode,
    UnknownHelpTopic,
    WriteFailed,
    OutOfMemory,
};

pub const FlagView = struct {
    short_name: ?[]const u8 = null,
    long_name: ?[]const u8 = null,
    value_name: ?[]const u8 = null,
    help: ?[]const u8 = null,
    long_help: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    env: ?[]const u8 = null,
    config: ?[]const u8 = null,
    global: bool = false,
    choices: []const []const u8 = &.{},
};

pub const CommandView = struct {
    name: []const u8,
    help: ?[]const u8 = null,
    long_help: ?[]const u8 = null,
    subcommand_required: bool = false,
    aliases: []const []const u8 = &.{},
    flags: []const FlagView = &.{},
    subcommands: []const CommandView = &.{},
    examples: []const []const u8 = &.{},
};

pub const SpecView = struct {
    bin: []const u8,
    usage: []const u8,
    version: ?[]const u8 = null,
    source_code_link_template: ?[]const u8 = null,
    global_flags: []const FlagView = &.{},
    root_commands: []const CommandView = &.{},
};

pub const HelpRequest = struct {
    topic: []const []const u8 = &.{},

    pub fn deinit(self: *HelpRequest, gpa: std.mem.Allocator) void {
        for (self.topic) |segment| gpa.free(segment);
        if (self.topic.len != 0) gpa.free(self.topic);
    }
};

pub const ParsedFlag = struct {
    name: []const u8,
    value: ?[]const u8 = null,

    fn deinit(self: *ParsedFlag, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.value) |value| gpa.free(value);
    }
};

pub fn parseArgv(
    comptime Generated: type,
    gpa: std.mem.Allocator,
    spec: *const SpecView,
    argv: []const []const u8,
) ParseError!Generated.ParsedCli {
    if (argv.len < 2) return error.InvalidArguments;

    var command_path = std.ArrayList([]const u8).empty;
    defer {
        for (command_path.items) |segment| gpa.free(segment);
        command_path.deinit(gpa);
    }
    var parsed_flags = std.ArrayList(ParsedFlag).empty;
    defer {
        for (parsed_flags.items) |*flag| flag.deinit(gpa);
        parsed_flags.deinit(gpa);
    }

    var current_children = spec.root_commands;
    var current_command: ?*const CommandView = null;

    var i: usize = 1;
    while (i < argv.len) {
        const token = argv[i];
        if (command_path.items.len == 0 and std.mem.eql(u8, token, "help")) {
            i += 1;
            while (i < argv.len) : (i += 1) {
                if (std.mem.startsWith(u8, argv[i], "-")) return error.InvalidArguments;
                try command_path.append(gpa, try gpa.dupe(u8, argv[i]));
            }
            return Generated.buildHelp(gpa, parsed_flags.items, command_path.items);
        }

        if (std.mem.eql(u8, token, "--help")) {
            try parsed_flags.append(gpa, .{
                .name = try gpa.dupe(u8, "--help"),
                .value = null,
            });
            return Generated.buildHelp(gpa, parsed_flags.items, command_path.items);
        }

        if (std.mem.startsWith(u8, token, "-")) {
            if (findFlag(spec.global_flags, token)) |flag| {
                try appendParsedFlag(gpa, &parsed_flags, flag, argv, &i);
                continue;
            }
            const command = current_command orelse return error.InvalidArguments;
            const flag = findFlag(command.flags, token) orelse return error.InvalidArguments;
            try appendParsedFlag(gpa, &parsed_flags, flag, argv, &i);
            continue;
        }

        const matched = findCommand(current_children, token) orelse return error.InvalidArguments;
        try command_path.append(gpa, try gpa.dupe(u8, matched.name));
        current_command = matched;
        current_children = matched.subcommands;
        i += 1;
    }

    const final_command = current_command orelse return error.InvalidArguments;
    if (final_command.subcommand_required and final_command.subcommands.len > 0) return error.InvalidArguments;

    var global = try Generated.buildGlobalOptions(gpa, parsed_flags.items);
    errdefer global.deinit(gpa);
    var command = try Generated.buildInvocation(gpa, command_path.items, parsed_flags.items);
    errdefer command.deinit(gpa);

    return .{
        .global = global,
        .command = command,
    };
}

pub fn renderHelp(gpa: std.mem.Allocator, spec: *const SpecView, topic: []const []const u8) ParseError![]u8 {
    const command = if (topic.len == 0)
        null
    else
        findCommandPath(spec.root_commands, topic) orelse return error.UnknownHelpTopic;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    if (command) |cmd| {
        try out.writer.print("{s}", .{spec.bin});
        for (topic) |segment| try out.writer.print(" {s}", .{segment});
        try out.writer.writeAll("\n");
        if (cmd.help) |help| try out.writer.print("{s}\n", .{help});
        try out.writer.writeByte('\n');
        if (cmd.long_help) |long_help| {
            try out.writer.print("{s}\n\n", .{long_help});
        }
        try writeUsageForCommand(&out.writer, spec.bin, topic, cmd);
        try writeFlags(&out.writer, cmd.flags);
        try writeCommands(&out.writer, cmd.subcommands);
        try writeExamples(&out.writer, cmd.examples);
    } else {
        try out.writer.print("{s} {f}\n", .{ spec.bin, build_options.package_version });
        try out.writer.print("{s}\n\n", .{spec.usage});
        try writeFlags(&out.writer, spec.global_flags);
        try writeCommands(&out.writer, spec.root_commands);
    }

    return out.toOwnedSlice();
}

pub fn hasFlag(flags: []const ParsedFlag, name: []const u8) bool {
    return flagValue(flags, name) != null or blk: {
        for (flags) |flag| {
            if (std.mem.eql(u8, flag.name, name) and flag.value == null) break :blk true;
        }
        break :blk false;
    };
}

pub fn flagValue(flags: []const ParsedFlag, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (flags) |flag| {
        if (std.mem.eql(u8, flag.name, name)) result = flag.value;
    }
    return result;
}

fn appendParsedFlag(
    gpa: std.mem.Allocator,
    parsed_flags: *std.ArrayList(ParsedFlag),
    flag: *const FlagView,
    argv: []const []const u8,
    index: *usize,
) ParseError!void {
    const canonical_name = flag.long_name orelse flag.short_name orelse return error.InvalidSpec;
    var value: ?[]const u8 = null;

    if (flag.value_name != null) {
        if (index.* + 1 >= argv.len) return error.InvalidArguments;
        const candidate = argv[index.* + 1];
        if (flag.choices.len != 0 and !containsString(flag.choices, candidate)) return error.InvalidChoice;
        value = try gpa.dupe(u8, candidate);
        index.* += 2;
    } else {
        index.* += 1;
    }

    try parsed_flags.append(gpa, .{
        .name = try gpa.dupe(u8, canonical_name),
        .value = value,
    });
}

fn findCommand(commands: []const CommandView, token: []const u8) ?*const CommandView {
    for (commands) |*command| {
        if (std.mem.eql(u8, command.name, token)) return command;
        for (command.aliases) |alias| {
            if (std.mem.eql(u8, alias, token)) return command;
        }
    }
    return null;
}

fn findCommandPath(commands: []const CommandView, path: []const []const u8) ?*const CommandView {
    if (path.len == 0) return null;
    const command = findCommand(commands, path[0]) orelse return null;
    if (path.len == 1) return command;
    return findCommandPath(command.subcommands, path[1..]);
}

fn findFlag(flags: []const FlagView, token: []const u8) ?*const FlagView {
    for (flags) |*flag| {
        if (flag.long_name) |name| {
            if (std.mem.eql(u8, name, token)) return flag;
        }
        if (flag.short_name) |name| {
            if (std.mem.eql(u8, name, token)) return flag;
        }
    }
    return null;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn writeUsageForCommand(writer: *std.Io.Writer, bin: []const u8, topic: []const []const u8, command: *const CommandView) !void {
    try writer.writeAll("Usage:\n  ");
    try writer.writeAll(bin);
    for (topic) |segment| {
        try writer.writeByte(' ');
        try writer.writeAll(segment);
    }
    if (command.flags.len != 0) try writer.writeAll(" [flags]");
    if (command.subcommands.len != 0) {
        try writer.writeAll(" <");
        for (command.subcommands, 0..) |child, index| {
            if (index != 0) try writer.writeByte('|');
            try writer.writeAll(child.name);
        }
        try writer.writeByte('>');
    }
    try writer.writeAll("\n\n");
}

fn writeFlags(writer: *std.Io.Writer, flags: []const FlagView) !void {
    if (flags.len == 0) return;
    try writer.writeAll("Flags:\n");
    for (flags) |flag| {
        try writer.writeAll("  ");
        try writeFlagName(writer, flag);
        if (flag.help) |help| {
            try writer.writeAll("  ");
            try writer.writeAll(help);
        }
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
}

fn writeCommands(writer: *std.Io.Writer, commands: []const CommandView) !void {
    if (commands.len == 0) return;
    try writer.writeAll("Commands:\n");
    for (commands) |command| {
        try writer.print("  {s}", .{command.name});
        if (command.help) |help| {
            try writer.writeAll("  ");
            try writer.writeAll(help);
        }
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');
}

fn writeExamples(writer: *std.Io.Writer, examples: []const []const u8) !void {
    if (examples.len == 0) return;
    try writer.writeAll("Examples:\n");
    for (examples) |example| try writer.print("  {s}\n", .{example});
    try writer.writeByte('\n');
}

fn writeFlagName(writer: *std.Io.Writer, flag: FlagView) !void {
    var wrote = false;
    if (flag.short_name) |short_name| {
        try writer.writeAll(short_name);
        wrote = true;
    }
    if (flag.long_name) |long_name| {
        if (wrote) try writer.writeAll(", ");
        try writer.writeAll(long_name);
        wrote = true;
    }
    if (flag.value_name) |value_name| {
        if (wrote) try writer.writeByte(' ');
        try writer.writeByte('<');
        try writer.writeAll(value_name);
        try writer.writeByte('>');
    }
}
