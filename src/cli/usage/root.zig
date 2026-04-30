const std = @import("std");

const c = @cImport({
    @cInclude("kdl/kdl.h");
});

pub const ParseError = error{
    InvalidSpec,
    InvalidArguments,
    InvalidChoice,
    MissingRequiredField,
    ParseError,
    UnsupportedNode,
    OutOfMemory,
};

pub const Flag = struct {
    short_name: ?[]const u8 = null,
    long_name: ?[]const u8 = null,
    value_name: ?[]const u8 = null,
    help: ?[]const u8 = null,
    long_help: ?[]const u8 = null,
    default_value: ?[]const u8 = null,
    env: ?[]const u8 = null,
    config: ?[]const u8 = null,
    global: bool = false,
    choices: [][]const u8 = &.{},

    pub fn deinit(self: *Flag, gpa: std.mem.Allocator) void {
        if (self.short_name) |value| gpa.free(value);
        if (self.long_name) |value| gpa.free(value);
        if (self.value_name) |value| gpa.free(value);
        if (self.help) |value| gpa.free(value);
        if (self.long_help) |value| gpa.free(value);
        if (self.default_value) |value| gpa.free(value);
        if (self.env) |value| gpa.free(value);
        if (self.config) |value| gpa.free(value);
        for (self.choices) |choice| gpa.free(choice);
        if (self.choices.len != 0) gpa.free(self.choices);
    }
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

pub const Command = struct {
    name: []const u8,
    help: ?[]const u8 = null,
    long_help: ?[]const u8 = null,
    subcommand_required: bool = false,
    aliases: [][]const u8 = &.{},
    flags: []Flag = &.{},
    subcommands: []Command = &.{},

    pub fn deinit(self: *Command, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.help) |value| gpa.free(value);
        if (self.long_help) |value| gpa.free(value);
        for (self.aliases) |alias| gpa.free(alias);
        if (self.aliases.len != 0) gpa.free(self.aliases);
        for (self.flags) |*flag| flag.deinit(gpa);
        if (self.flags.len != 0) gpa.free(self.flags);
        for (self.subcommands) |*command| command.deinit(gpa);
        if (self.subcommands.len != 0) gpa.free(self.subcommands);
    }
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

pub const Spec = struct {
    bin: []const u8,
    usage: []const u8,
    version: ?[]const u8 = null,
    source_code_link_template: ?[]const u8 = null,
    global_flags: []Flag = &.{},
    root_commands: []Command = &.{},

    pub fn deinit(self: *Spec, gpa: std.mem.Allocator) void {
        gpa.free(self.bin);
        gpa.free(self.usage);
        if (self.version) |value| gpa.free(value);
        if (self.source_code_link_template) |value| gpa.free(value);
        for (self.global_flags) |*flag| flag.deinit(gpa);
        if (self.global_flags.len != 0) gpa.free(self.global_flags);
        for (self.root_commands) |*command| command.deinit(gpa);
        if (self.root_commands.len != 0) gpa.free(self.root_commands);
    }

    pub fn view(self: *const Spec, gpa: std.mem.Allocator) ParseError!SpecView {
        const global_flags = try cloneFlagViews(gpa, self.global_flags);
        errdefer freeFlagViews(gpa, global_flags);

        const root_commands = try cloneCommandViews(gpa, self.root_commands);
        errdefer freeCommandViews(gpa, root_commands);

        return .{
            .bin = try gpa.dupe(u8, self.bin),
            .usage = try gpa.dupe(u8, self.usage),
            .version = try cloneOptionalBytes(gpa, self.version),
            .source_code_link_template = try cloneOptionalBytes(gpa, self.source_code_link_template),
            .global_flags = global_flags,
            .root_commands = root_commands,
        };
    }
};

pub const SpecView = struct {
    bin: []const u8,
    usage: []const u8,
    version: ?[]const u8 = null,
    source_code_link_template: ?[]const u8 = null,
    global_flags: []const FlagView = &.{},
    root_commands: []const CommandView = &.{},

    pub fn deinit(self: *SpecView, gpa: std.mem.Allocator) void {
        gpa.free(self.bin);
        gpa.free(self.usage);
        if (self.version) |value| gpa.free(value);
        if (self.source_code_link_template) |value| gpa.free(value);
        freeFlagViews(gpa, self.global_flags);
        freeCommandViews(gpa, self.root_commands);
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

pub const ParsedInvocation = struct {
    command_path: [][]const u8,
    flags: []ParsedFlag,

    pub fn deinit(self: *ParsedInvocation, gpa: std.mem.Allocator) void {
        for (self.command_path) |segment| gpa.free(segment);
        gpa.free(self.command_path);
        for (self.flags) |*flag| flag.deinit(gpa);
        gpa.free(self.flags);
    }

    pub fn hasFlag(self: *const ParsedInvocation, name: []const u8) bool {
        return self.flagValue(name) != null or blk: {
            for (self.flags) |flag| {
                if (std.mem.eql(u8, flag.name, name) and flag.value == null) break :blk true;
            }
            break :blk false;
        };
    }

    pub fn flagValue(self: *const ParsedInvocation, name: []const u8) ?[]const u8 {
        var result: ?[]const u8 = null;
        for (self.flags) |flag| {
            if (std.mem.eql(u8, flag.name, name)) result = flag.value;
        }
        return result;
    }
};

const RawValueKind = enum {
    string,
    number,
    boolean,
    null,
};

const RawValue = struct {
    text: []const u8,
    annotation: ?[]const u8 = null,
    kind: RawValueKind,

    fn deinit(self: *RawValue, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        if (self.annotation) |value| gpa.free(value);
    }
};

const RawProperty = struct {
    name: []const u8,
    value: RawValue,

    fn deinit(self: *RawProperty, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        self.value.deinit(gpa);
    }
};

const RawNode = struct {
    name: []const u8,
    annotation: ?[]const u8 = null,
    args: std.ArrayList(RawValue),
    props: std.ArrayList(RawProperty),
    children: std.ArrayList(*RawNode),

    fn init(name: []const u8, annotation: ?[]const u8) RawNode {
        return .{
            .name = name,
            .annotation = annotation,
            .args = .empty,
            .props = .empty,
            .children = .empty,
        };
    }

    fn deinit(self: *RawNode, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.annotation) |value| gpa.free(value);
        for (self.args.items) |*arg| arg.deinit(gpa);
        self.args.deinit(gpa);
        for (self.props.items) |*prop| prop.deinit(gpa);
        self.props.deinit(gpa);
        for (self.children.items) |child| {
            child.deinit(gpa);
            gpa.destroy(child);
        }
        self.children.deinit(gpa);
    }

    fn getFirstArg(self: *const RawNode) ?*const RawValue {
        if (self.args.items.len == 0) return null;
        return &self.args.items[0];
    }

    fn getProp(self: *const RawNode, name: []const u8) ?*const RawValue {
        for (self.props.items) |*prop| {
            if (std.mem.eql(u8, prop.name, name)) return &prop.value;
        }
        return null;
    }
};

pub fn parseSpec(gpa: std.mem.Allocator, source: []const u8) ParseError!Spec {
    var root_nodes = try parseDocument(gpa, source);
    defer {
        for (root_nodes.items) |node| {
            node.deinit(gpa);
            gpa.destroy(node);
        }
        root_nodes.deinit(gpa);
    }

    var bin: ?[]const u8 = null;
    var usage_text: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var source_code_link_template: ?[]const u8 = null;
    errdefer if (bin) |value| gpa.free(value);
    errdefer if (usage_text) |value| gpa.free(value);
    errdefer if (version) |value| gpa.free(value);
    errdefer if (source_code_link_template) |value| gpa.free(value);
    var global_flags = std.ArrayList(Flag).empty;
    errdefer {
        for (global_flags.items) |*flag| flag.deinit(gpa);
        global_flags.deinit(gpa);
    }
    var root_commands = std.ArrayList(Command).empty;
    errdefer {
        for (root_commands.items) |*command| command.deinit(gpa);
        root_commands.deinit(gpa);
    }

    for (root_nodes.items) |node| {
        if (std.mem.eql(u8, node.name, "bin")) {
            bin = try dupeFirstArg(gpa, node);
        } else if (std.mem.eql(u8, node.name, "usage")) {
            usage_text = try dupeFirstArg(gpa, node);
        } else if (std.mem.eql(u8, node.name, "version")) {
            version = try dupeFirstArg(gpa, node);
        } else if (std.mem.eql(u8, node.name, "source_code_link_template")) {
            source_code_link_template = try dupeFirstArg(gpa, node);
        } else if (std.mem.eql(u8, node.name, "flag")) {
            try global_flags.append(gpa, try parseFlag(gpa, node));
        } else if (std.mem.eql(u8, node.name, "cmd")) {
            try root_commands.append(gpa, try parseCommand(gpa, node));
        } else if (isIgnoredTopLevelNode(node.name)) {
            continue;
        } else {
            return error.UnsupportedNode;
        }
    }

    return .{
        .bin = bin orelse return error.MissingRequiredField,
        .usage = usage_text orelse return error.MissingRequiredField,
        .version = version,
        .source_code_link_template = source_code_link_template,
        .global_flags = try global_flags.toOwnedSlice(gpa),
        .root_commands = try root_commands.toOwnedSlice(gpa),
    };
}

pub fn parseArgv(
    gpa: std.mem.Allocator,
    spec_like: anytype,
    argv: []const []const u8,
) ParseError!ParsedInvocation {
    if (argv.len < 2) return error.InvalidArguments;
    const spec = try intoSpecView(gpa, spec_like);
    defer if (spec.owned) {
        var owned = spec.view;
        owned.deinit(gpa);
    };

    var command_path = std.ArrayList([]const u8).empty;
    errdefer {
        for (command_path.items) |segment| gpa.free(segment);
        command_path.deinit(gpa);
    }
    var parsed_flags = std.ArrayList(ParsedFlag).empty;
    errdefer {
        for (parsed_flags.items) |*flag| flag.deinit(gpa);
        parsed_flags.deinit(gpa);
    }

    var current_children = spec.view.root_commands;
    var current_command: ?*const CommandView = null;

    var i: usize = 1;
    while (i < argv.len) {
        const token = argv[i];
        if (std.mem.startsWith(u8, token, "-")) {
            if (findFlag(spec.view.global_flags, token)) |flag| {
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

    return .{
        .command_path = try command_path.toOwnedSlice(gpa),
        .flags = try parsed_flags.toOwnedSlice(gpa),
    };
}

fn parseDocument(gpa: std.mem.Allocator, source: []const u8) ParseError!std.ArrayList(*RawNode) {
    const parser = c.kdl_create_string_parser(
        .{ .data = source.ptr, .len = source.len },
        c.KDL_DETECT_VERSION,
    ) orelse return error.OutOfMemory;
    defer c.kdl_destroy_parser(parser);

    var root_nodes: std.ArrayList(*RawNode) = .empty;
    errdefer {
        for (root_nodes.items) |node| {
            node.deinit(gpa);
            gpa.destroy(node);
        }
        root_nodes.deinit(gpa);
    }

    var stack: std.ArrayList(*RawNode) = .empty;
    defer stack.deinit(gpa);

    while (true) {
        const event_data = c.kdl_parser_next_event(parser);
        if (event_data == null) return error.ParseError;

        const event_bits: u32 = @intCast(event_data.*.event);
        const comment_bits: u32 = @intCast(c.KDL_EVENT_COMMENT);
        if ((event_bits & comment_bits) != 0) continue;

        const base_event = event_bits & ~comment_bits;
        switch (base_event) {
            c.KDL_EVENT_EOF => break,
            c.KDL_EVENT_PARSE_ERROR => return error.ParseError,
            c.KDL_EVENT_START_NODE => {
                const name = try cloneStr(gpa, event_data.*.name);
                const annotation = try cloneOptionalStr(gpa, event_data.*.value.type_annotation);
                const node = try gpa.create(RawNode);
                node.* = RawNode.init(name, annotation);

                if (stack.items.len == 0) {
                    try root_nodes.append(gpa, node);
                } else {
                    try stack.items[stack.items.len - 1].children.append(gpa, node);
                }
                try stack.append(gpa, node);
            },
            c.KDL_EVENT_END_NODE => {
                if (stack.items.len == 0) return error.InvalidSpec;
                _ = stack.pop().?;
            },
            c.KDL_EVENT_ARGUMENT => {
                if (stack.items.len == 0) return error.InvalidSpec;
                try stack.items[stack.items.len - 1].args.append(gpa, try cloneValue(gpa, event_data.*.value));
            },
            c.KDL_EVENT_PROPERTY => {
                if (stack.items.len == 0) return error.InvalidSpec;
                try stack.items[stack.items.len - 1].props.append(gpa, .{
                    .name = try cloneStr(gpa, event_data.*.name),
                    .value = try cloneValue(gpa, event_data.*.value),
                });
            },
            else => return error.UnsupportedNode,
        }
    }

    if (stack.items.len != 0) return error.InvalidSpec;
    return root_nodes;
}

fn parseCommand(gpa: std.mem.Allocator, node: *const RawNode) ParseError!Command {
    const name = try dupeFirstArg(gpa, node);
    errdefer gpa.free(name);

    var aliases = std.ArrayList([]const u8).empty;
    errdefer {
        for (aliases.items) |alias| gpa.free(alias);
        aliases.deinit(gpa);
    }
    var flags = std.ArrayList(Flag).empty;
    errdefer {
        for (flags.items) |*flag| flag.deinit(gpa);
        flags.deinit(gpa);
    }
    var subcommands = std.ArrayList(Command).empty;
    errdefer {
        for (subcommands.items) |*command| command.deinit(gpa);
        subcommands.deinit(gpa);
    }

    const help: ?[]const u8 = try dupeOptionalProp(gpa, node, "help");
    errdefer if (help) |value| gpa.free(value);
    const long_help: ?[]const u8 = try dupeOptionalChildArg(gpa, node, "long_help");
    errdefer if (long_help) |value| gpa.free(value);

    for (node.children.items) |child| {
        if (std.mem.eql(u8, child.name, "alias")) {
            for (child.args.items) |arg| try aliases.append(gpa, try gpa.dupe(u8, arg.text));
        } else if (std.mem.eql(u8, child.name, "flag")) {
            try flags.append(gpa, try parseFlag(gpa, child));
        } else if (std.mem.eql(u8, child.name, "cmd")) {
            try subcommands.append(gpa, try parseCommand(gpa, child));
        } else if (std.mem.eql(u8, child.name, "long_help")) {
            continue;
        } else if (isIgnoredCommandChildNode(child.name)) {
            continue;
        } else {
            return error.UnsupportedNode;
        }
    }

    return .{
        .name = name,
        .help = help,
        .long_help = long_help,
        .subcommand_required = propBool(node, "subcommand_required"),
        .aliases = try aliases.toOwnedSlice(gpa),
        .flags = try flags.toOwnedSlice(gpa),
        .subcommands = try subcommands.toOwnedSlice(gpa),
    };
}

fn parseFlag(gpa: std.mem.Allocator, node: *const RawNode) ParseError!Flag {
    const syntax = node.getFirstArg() orelse return error.MissingRequiredField;
    var parsed = try parseFlagSyntax(gpa, syntax.text);
    errdefer parsed.deinit(gpa);

    parsed.global = propBool(node, "global");
    parsed.help = try dupeOptionalProp(gpa, node, "help");
    parsed.long_help = try dupeOptionalChildArg(gpa, node, "long_help");
    parsed.default_value = try dupeOptionalProp(gpa, node, "default");
    parsed.env = try dupeOptionalProp(gpa, node, "env");
    parsed.config = try dupeOptionalProp(gpa, node, "config");

    var choices = std.ArrayList([]const u8).empty;
    errdefer {
        for (choices.items) |choice| gpa.free(choice);
        choices.deinit(gpa);
    }

    for (node.children.items) |child| {
        if (std.mem.eql(u8, child.name, "choices")) {
            for (child.args.items) |arg| try choices.append(gpa, try gpa.dupe(u8, arg.text));
        } else if (std.mem.eql(u8, child.name, "long_help")) {
            continue;
        } else if (isIgnoredFlagChildNode(child.name)) {
            continue;
        } else {
            return error.UnsupportedNode;
        }
    }

    parsed.choices = try choices.toOwnedSlice(gpa);
    return parsed;
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

fn parseFlagSyntax(gpa: std.mem.Allocator, syntax: []const u8) ParseError!Flag {
    var flag: Flag = .{};
    var tokens = std.mem.tokenizeScalar(u8, syntax, ' ');
    while (tokens.next()) |token| {
        if (std.mem.startsWith(u8, token, "--")) {
            flag.long_name = try gpa.dupe(u8, token);
        } else if (std.mem.startsWith(u8, token, "-")) {
            flag.short_name = try gpa.dupe(u8, token);
        } else if ((std.mem.startsWith(u8, token, "<") and std.mem.endsWith(u8, token, ">")) or
            (std.mem.startsWith(u8, token, "[") and std.mem.endsWith(u8, token, "]")))
        {
            flag.value_name = try gpa.dupe(u8, token[1 .. token.len - 1]);
        } else {
            return error.InvalidSpec;
        }
    }

    if (flag.short_name == null and flag.long_name == null) return error.InvalidSpec;
    return flag;
}

fn cloneValue(gpa: std.mem.Allocator, value: c.kdl_value) ParseError!RawValue {
    const annotation = try cloneOptionalStr(gpa, value.type_annotation);
    errdefer if (annotation) |text| gpa.free(text);

    return switch (value.type) {
        c.KDL_TYPE_NULL => .{
            .text = try gpa.dupe(u8, "null"),
            .annotation = annotation,
            .kind = .null,
        },
        c.KDL_TYPE_BOOLEAN => .{
            .text = try gpa.dupe(u8, if (value.unnamed_0.boolean) "true" else "false"),
            .annotation = annotation,
            .kind = .boolean,
        },
        c.KDL_TYPE_NUMBER => switch (value.unnamed_0.number.type) {
            c.KDL_NUMBER_TYPE_INTEGER => .{
                .text = try std.fmt.allocPrint(gpa, "{d}", .{value.unnamed_0.number.unnamed_0.integer}),
                .annotation = annotation,
                .kind = .number,
            },
            c.KDL_NUMBER_TYPE_FLOATING_POINT => .{
                .text = try std.fmt.allocPrint(gpa, "{d}", .{value.unnamed_0.number.unnamed_0.floating_point}),
                .annotation = annotation,
                .kind = .number,
            },
            c.KDL_NUMBER_TYPE_STRING_ENCODED => .{
                .text = try cloneStr(gpa, value.unnamed_0.number.unnamed_0.string),
                .annotation = annotation,
                .kind = .number,
            },
            else => return error.InvalidSpec,
        },
        c.KDL_TYPE_STRING => .{
            .text = try cloneStr(gpa, value.unnamed_0.string),
            .annotation = annotation,
            .kind = .string,
        },
        else => return error.InvalidSpec,
    };
}

fn cloneStr(gpa: std.mem.Allocator, value: c.kdl_str) ParseError![]const u8 {
    if (value.data == null) return try gpa.dupe(u8, "");
    return try gpa.dupe(u8, value.data[0..value.len]);
}

fn cloneOptionalStr(gpa: std.mem.Allocator, value: c.kdl_str) ParseError!?[]const u8 {
    if (value.data == null or value.len == 0) return null;
    return try cloneStr(gpa, value);
}

fn dupeFirstArg(gpa: std.mem.Allocator, node: *const RawNode) ParseError![]const u8 {
    const arg = node.getFirstArg() orelse return error.MissingRequiredField;
    return try gpa.dupe(u8, arg.text);
}

fn dupeOptionalProp(gpa: std.mem.Allocator, node: *const RawNode, name: []const u8) ParseError!?[]const u8 {
    const value = node.getProp(name) orelse return null;
    return try gpa.dupe(u8, value.text);
}

fn dupeOptionalChildArg(gpa: std.mem.Allocator, node: *const RawNode, child_name: []const u8) ParseError!?[]const u8 {
    for (node.children.items) |child| {
        if (std.mem.eql(u8, child.name, child_name)) return try dupeFirstArg(gpa, child);
    }
    return null;
}

fn propBool(node: *const RawNode, name: []const u8) bool {
    const value = node.getProp(name) orelse return false;
    return value.kind == .boolean and std.mem.eql(u8, value.text, "true");
}

fn isIgnoredTopLevelNode(name: []const u8) bool {
    return std.mem.eql(u8, name, "name") or
        std.mem.eql(u8, name, "about") or
        std.mem.eql(u8, name, "author") or
        std.mem.eql(u8, name, "license") or
        std.mem.eql(u8, name, "config_file") or
        std.mem.eql(u8, name, "min_usage_version") or
        std.mem.eql(u8, name, "before_help") or
        std.mem.eql(u8, name, "after_help") or
        std.mem.eql(u8, name, "before_long_help") or
        std.mem.eql(u8, name, "long_about") or
        std.mem.eql(u8, name, "after_long_help") or
        std.mem.eql(u8, name, "example");
}

fn isIgnoredCommandChildNode(name: []const u8) bool {
    return std.mem.eql(u8, name, "before_help") or
        std.mem.eql(u8, name, "before_long_help") or
        std.mem.eql(u8, name, "after_help") or
        std.mem.eql(u8, name, "after_long_help") or
        std.mem.eql(u8, name, "example");
}

fn isIgnoredFlagChildNode(name: []const u8) bool {
    return std.mem.eql(u8, name, "complete") or
        std.mem.eql(u8, name, "arg") or
        std.mem.eql(u8, name, "alias");
}

pub fn renderGeneratedModule(gpa: std.mem.Allocator, spec: *const Spec) ParseError![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(gpa);

    try output.appendSlice(gpa,
        \\const usage = @import("sideshowdb_cli_usage_runtime");
        \\
    );
    try appendFmt(gpa, &output, "pub const usage_message = \"{f}\";\n", .{
        std.zig.fmtString(spec.usage),
    });
    try output.appendSlice(gpa, "pub const spec: usage.SpecView = .{\n");
    try appendFmt(gpa, &output, "    .bin = \"{f}\",\n", .{std.zig.fmtString(spec.bin)});
    try appendFmt(gpa, &output, "    .usage = \"{f}\",\n", .{std.zig.fmtString(spec.usage)});
    try renderOptionalStringField(gpa, &output, "version", spec.version, 1);
    try renderOptionalStringField(gpa, &output, "source_code_link_template", spec.source_code_link_template, 1);
    try renderFlags(gpa, &output, spec.global_flags, 1);
    try renderCommands(gpa, &output, spec.root_commands, 1);
    try output.appendSlice(gpa, "};\n");

    return try output.toOwnedSlice(gpa);
}

const BorrowedOrOwnedSpecView = struct {
    view: SpecView,
    owned: bool,
};

fn intoSpecView(gpa: std.mem.Allocator, spec_like: anytype) ParseError!BorrowedOrOwnedSpecView {
    const T = @TypeOf(spec_like);
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            const Child = pointer.child;
            if (Child == Spec) {
                return .{ .view = try spec_like.view(gpa), .owned = true };
            }
            if (Child == SpecView) {
                return .{ .view = spec_like.*, .owned = false };
            }
        },
        .@"struct" => {
            if (T == SpecView) return .{ .view = spec_like, .owned = false };
        },
        else => {},
    }
    @compileError("parseArgv expects *const Spec or *const SpecView");
}

fn cloneFlagViews(gpa: std.mem.Allocator, flags: []const Flag) ParseError![]FlagView {
    var out = std.ArrayList(FlagView).empty;
    errdefer {
        freeFlagViews(gpa, out.items);
    }

    for (flags) |flag| try out.append(gpa, try cloneFlagView(gpa, &flag));
    return try out.toOwnedSlice(gpa);
}

fn cloneFlagView(gpa: std.mem.Allocator, flag: *const Flag) ParseError!FlagView {
    var choices = std.ArrayList([]const u8).empty;
    errdefer {
        for (choices.items) |choice| gpa.free(choice);
        choices.deinit(gpa);
    }
    for (flag.choices) |choice| try choices.append(gpa, try gpa.dupe(u8, choice));

    return .{
        .short_name = try cloneOptionalBytes(gpa, flag.short_name),
        .long_name = try cloneOptionalBytes(gpa, flag.long_name),
        .value_name = try cloneOptionalBytes(gpa, flag.value_name),
        .help = try cloneOptionalBytes(gpa, flag.help),
        .long_help = try cloneOptionalBytes(gpa, flag.long_help),
        .default_value = try cloneOptionalBytes(gpa, flag.default_value),
        .env = try cloneOptionalBytes(gpa, flag.env),
        .config = try cloneOptionalBytes(gpa, flag.config),
        .global = flag.global,
        .choices = try choices.toOwnedSlice(gpa),
    };
}

fn cloneCommandViews(gpa: std.mem.Allocator, commands: []const Command) ParseError![]CommandView {
    var out = std.ArrayList(CommandView).empty;
    errdefer {
        freeCommandViews(gpa, out.items);
    }

    for (commands) |command| try out.append(gpa, try cloneCommandView(gpa, &command));
    return try out.toOwnedSlice(gpa);
}

fn cloneCommandView(gpa: std.mem.Allocator, command: *const Command) ParseError!CommandView {
    var aliases = std.ArrayList([]const u8).empty;
    errdefer {
        for (aliases.items) |alias| gpa.free(alias);
        aliases.deinit(gpa);
    }
    for (command.aliases) |alias| try aliases.append(gpa, try gpa.dupe(u8, alias));

    return .{
        .name = try gpa.dupe(u8, command.name),
        .help = try cloneOptionalBytes(gpa, command.help),
        .long_help = try cloneOptionalBytes(gpa, command.long_help),
        .subcommand_required = command.subcommand_required,
        .aliases = try aliases.toOwnedSlice(gpa),
        .flags = try cloneFlagViews(gpa, command.flags),
        .subcommands = try cloneCommandViews(gpa, command.subcommands),
    };
}

fn freeFlagViews(gpa: std.mem.Allocator, flags: []const FlagView) void {
    for (flags) |flag| {
        if (flag.short_name) |value| gpa.free(value);
        if (flag.long_name) |value| gpa.free(value);
        if (flag.value_name) |value| gpa.free(value);
        if (flag.help) |value| gpa.free(value);
        if (flag.long_help) |value| gpa.free(value);
        if (flag.default_value) |value| gpa.free(value);
        if (flag.env) |value| gpa.free(value);
        if (flag.config) |value| gpa.free(value);
        for (flag.choices) |choice| gpa.free(choice);
        if (flag.choices.len != 0) gpa.free(flag.choices);
    }
    if (flags.len != 0) gpa.free(flags);
}

fn freeCommandViews(gpa: std.mem.Allocator, commands: []const CommandView) void {
    for (commands) |command| {
        gpa.free(command.name);
        if (command.help) |value| gpa.free(value);
        if (command.long_help) |value| gpa.free(value);
        for (command.aliases) |alias| gpa.free(alias);
        if (command.aliases.len != 0) gpa.free(command.aliases);
        freeFlagViews(gpa, command.flags);
        freeCommandViews(gpa, command.subcommands);
    }
    if (commands.len != 0) gpa.free(commands);
}

fn cloneOptionalBytes(gpa: std.mem.Allocator, value: ?[]const u8) ParseError!?[]const u8 {
    if (value) |bytes| return try gpa.dupe(u8, bytes);
    return null;
}

fn renderFlags(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    flags: []const Flag,
    indent_level: usize,
) ParseError!void {
    try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, ".global_flags = &.{\n");
    for (flags) |flag| {
        try writeIndent(gpa, output, indent_level + 1);
        try output.appendSlice(gpa, "usage.FlagView{\n");
        try renderOptionalStringField(gpa, output, "short_name", flag.short_name, indent_level + 2);
        try renderOptionalStringField(gpa, output, "long_name", flag.long_name, indent_level + 2);
        try renderOptionalStringField(gpa, output, "value_name", flag.value_name, indent_level + 2);
        try renderOptionalStringField(gpa, output, "help", flag.help, indent_level + 2);
        try renderOptionalStringField(gpa, output, "long_help", flag.long_help, indent_level + 2);
        try renderOptionalStringField(gpa, output, "default_value", flag.default_value, indent_level + 2);
        try renderOptionalStringField(gpa, output, "env", flag.env, indent_level + 2);
        try renderOptionalStringField(gpa, output, "config", flag.config, indent_level + 2);
        try writeIndent(gpa, output, indent_level + 2);
        try appendFmt(gpa, output, ".global = {},\n", .{flag.global});
        try renderStringSliceField(gpa, output, "choices", flag.choices, indent_level + 2);
        try writeIndent(gpa, output, indent_level + 1);
        try output.appendSlice(gpa, "},\n");
    }
    try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, "},\n");
}

fn renderCommands(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    commands: []const Command,
    indent_level: usize,
) ParseError!void {
    try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, ".root_commands = &.{\n");
    for (commands) |command| {
        try renderCommand(gpa, output, &command, indent_level + 1);
    }
    try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, "},\n");
}

fn renderCommand(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    command: *const Command,
    indent_level: usize,
) ParseError!void {
    try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, "usage.CommandView{\n");
    try renderStringField(gpa, output, "name", command.name, indent_level + 1);
    try renderOptionalStringField(gpa, output, "help", command.help, indent_level + 1);
    try renderOptionalStringField(gpa, output, "long_help", command.long_help, indent_level + 1);
    try writeIndent(gpa, output, indent_level + 1);
    try appendFmt(gpa, output, ".subcommand_required = {},\n", .{command.subcommand_required});
    try renderStringSliceField(gpa, output, "aliases", command.aliases, indent_level + 1);
    try renderFlagsForCommand(gpa, output, command.flags, indent_level + 1);
    try renderNestedCommands(gpa, output, command.subcommands, indent_level + 1);
    try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, "},\n");
}

fn renderFlagsForCommand(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    flags: []const Flag,
    indent_level: usize,
) ParseError!void {
    try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, ".flags = &.{\n");
    for (flags) |flag| {
        try writeIndent(gpa, output, indent_level + 1);
        try output.appendSlice(gpa, "usage.FlagView{\n");
        try renderOptionalStringField(gpa, output, "short_name", flag.short_name, indent_level + 2);
        try renderOptionalStringField(gpa, output, "long_name", flag.long_name, indent_level + 2);
        try renderOptionalStringField(gpa, output, "value_name", flag.value_name, indent_level + 2);
        try renderOptionalStringField(gpa, output, "help", flag.help, indent_level + 2);
        try renderOptionalStringField(gpa, output, "long_help", flag.long_help, indent_level + 2);
        try renderOptionalStringField(gpa, output, "default_value", flag.default_value, indent_level + 2);
        try renderOptionalStringField(gpa, output, "env", flag.env, indent_level + 2);
        try renderOptionalStringField(gpa, output, "config", flag.config, indent_level + 2);
        try writeIndent(gpa, output, indent_level + 2);
        try appendFmt(gpa, output, ".global = {},\n", .{flag.global});
        try renderStringSliceField(gpa, output, "choices", flag.choices, indent_level + 2);
        try writeIndent(gpa, output, indent_level + 1);
        try output.appendSlice(gpa, "},\n");
    }
    try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, "},\n");
}

fn renderNestedCommands(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    commands: []const Command,
    indent_level: usize,
) ParseError!void {
    try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, ".subcommands = &.{\n");
    for (commands) |command| try renderCommand(gpa, output, &command, indent_level + 1);
    try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, "},\n");
}

fn renderStringField(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    field_name: []const u8,
    value: []const u8,
    indent_level: usize,
) ParseError!void {
    try writeIndent(gpa, output, indent_level);
    try appendFmt(gpa, output, ".{s} = \"{f}\",\n", .{ field_name, std.zig.fmtString(value) });
}

fn renderOptionalStringField(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    field_name: []const u8,
    value: ?[]const u8,
    indent_level: usize,
) ParseError!void {
    try writeIndent(gpa, output, indent_level);
    if (value) |text| {
        try appendFmt(gpa, output, ".{s} = \"{f}\",\n", .{ field_name, std.zig.fmtString(text) });
    } else {
        try appendFmt(gpa, output, ".{s} = null,\n", .{field_name});
    }
}

fn renderStringSliceField(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    field_name: []const u8,
    values: []const []const u8,
    indent_level: usize,
) ParseError!void {
    try writeIndent(gpa, output, indent_level);
    try appendFmt(gpa, output, ".{s} = &.{{", .{field_name});
    if (values.len != 0) try output.append(gpa, '\n');
    for (values) |value| {
        try writeIndent(gpa, output, indent_level + 1);
        try appendFmt(gpa, output, "\"{f}\",\n", .{std.zig.fmtString(value)});
    }
    if (values.len != 0) try writeIndent(gpa, output, indent_level);
    try output.appendSlice(gpa, "},\n");
}

fn writeIndent(gpa: std.mem.Allocator, output: *std.ArrayList(u8), indent_level: usize) ParseError!void {
    var i: usize = 0;
    while (i < indent_level) : (i += 1) try output.appendSlice(gpa, "    ");
}

fn appendFmt(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) ParseError!void {
    const rendered = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(rendered);
    try output.appendSlice(gpa, rendered);
}
