const std = @import("std");

pub const ParseError = error{
    InvalidSpec,
    InvalidArguments,
    InvalidChoice,
    MissingRequiredField,
    ParseError,
    UnsupportedNode,
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
};

pub const SpecView = struct {
    bin: []const u8,
    usage: []const u8,
    version: ?[]const u8 = null,
    source_code_link_template: ?[]const u8 = null,
    global_flags: []const FlagView = &.{},
    root_commands: []const CommandView = &.{},
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
