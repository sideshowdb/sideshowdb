const std = @import("std");
const usage_runtime = @import("runtime.zig");

const c = @cImport({
    @cInclude("kdl/kdl.h");
});

pub const ParseError = usage_runtime.ParseError;

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

pub const FlagView = usage_runtime.FlagView;

pub const Command = struct {
    name: []const u8,
    help: ?[]const u8 = null,
    long_help: ?[]const u8 = null,
    subcommand_required: bool = false,
    aliases: [][]const u8 = &.{},
    flags: []Flag = &.{},
    args: [][]const u8 = &.{},
    subcommands: []Command = &.{},
    examples: [][]const u8 = &.{},

    pub fn deinit(self: *Command, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.help) |value| gpa.free(value);
        if (self.long_help) |value| gpa.free(value);
        for (self.aliases) |alias| gpa.free(alias);
        if (self.aliases.len != 0) gpa.free(self.aliases);
        for (self.flags) |*flag| flag.deinit(gpa);
        if (self.flags.len != 0) gpa.free(self.flags);
        for (self.args) |arg| gpa.free(arg);
        if (self.args.len != 0) gpa.free(self.args);
        for (self.subcommands) |*command| command.deinit(gpa);
        if (self.subcommands.len != 0) gpa.free(self.subcommands);
        for (self.examples) |example| gpa.free(example);
        if (self.examples.len != 0) gpa.free(self.examples);
    }
};

pub const CommandView = usage_runtime.CommandView;
pub const HelpRequest = usage_runtime.HelpRequest;

pub const ConfigProp = struct {
    key: []const u8,
    default_value: ?[]const u8 = null,
    default_note: ?[]const u8 = null,
    data_type: ?[]const u8 = null,
    env: ?[]const u8 = null,
    help: ?[]const u8 = null,
    long_help: ?[]const u8 = null,

    pub fn deinit(self: *ConfigProp, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
        if (self.default_value) |value| gpa.free(value);
        if (self.default_note) |value| gpa.free(value);
        if (self.data_type) |value| gpa.free(value);
        if (self.env) |value| gpa.free(value);
        if (self.help) |value| gpa.free(value);
        if (self.long_help) |value| gpa.free(value);
    }
};

pub const Spec = struct {
    bin: []const u8,
    usage: []const u8,
    version: ?[]const u8 = null,
    source_code_link_template: ?[]const u8 = null,
    global_flags: []Flag = &.{},
    root_commands: []Command = &.{},
    config_props: []ConfigProp = &.{},

    pub fn deinit(self: *Spec, gpa: std.mem.Allocator) void {
        gpa.free(self.bin);
        gpa.free(self.usage);
        if (self.version) |value| gpa.free(value);
        if (self.source_code_link_template) |value| gpa.free(value);
        for (self.global_flags) |*flag| flag.deinit(gpa);
        if (self.global_flags.len != 0) gpa.free(self.global_flags);
        for (self.root_commands) |*command| command.deinit(gpa);
        if (self.root_commands.len != 0) gpa.free(self.root_commands);
        for (self.config_props) |*prop| prop.deinit(gpa);
        if (self.config_props.len != 0) gpa.free(self.config_props);
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

pub const SpecView = usage_runtime.SpecView;
pub const ParsedFlag = usage_runtime.ParsedFlag;

pub const GlobalOptions = struct {
    json: bool = false,
    refstore: ?[]const u8 = null,

    pub fn deinit(self: *GlobalOptions, gpa: std.mem.Allocator) void {
        if (self.refstore) |value| gpa.free(value);
    }
};

pub const DocPutArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: ?[]const u8 = null,
    id: ?[]const u8 = null,
    data_file: ?[]const u8 = null,

    pub fn deinit(self: *DocPutArgs, gpa: std.mem.Allocator) void {
        if (self.namespace) |value| gpa.free(value);
        if (self.doc_type) |value| gpa.free(value);
        if (self.id) |value| gpa.free(value);
        if (self.data_file) |value| gpa.free(value);
    }
};

pub const DocGetArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    version: ?[]const u8 = null,

    pub fn deinit(self: *DocGetArgs, gpa: std.mem.Allocator) void {
        if (self.namespace) |value| gpa.free(value);
        gpa.free(self.doc_type);
        gpa.free(self.id);
        if (self.version) |value| gpa.free(value);
    }
};

pub const DocListArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: ?[]const u8 = null,
    limit: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    mode: ?[]const u8 = null,

    pub fn deinit(self: *DocListArgs, gpa: std.mem.Allocator) void {
        if (self.namespace) |value| gpa.free(value);
        if (self.doc_type) |value| gpa.free(value);
        if (self.limit) |value| gpa.free(value);
        if (self.cursor) |value| gpa.free(value);
        if (self.mode) |value| gpa.free(value);
    }
};

pub const DocDeleteArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,

    pub fn deinit(self: *DocDeleteArgs, gpa: std.mem.Allocator) void {
        if (self.namespace) |value| gpa.free(value);
        gpa.free(self.doc_type);
        gpa.free(self.id);
    }
};

pub const DocHistoryArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    limit: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    mode: ?[]const u8 = null,

    pub fn deinit(self: *DocHistoryArgs, gpa: std.mem.Allocator) void {
        if (self.namespace) |value| gpa.free(value);
        gpa.free(self.doc_type);
        gpa.free(self.id);
        if (self.limit) |value| gpa.free(value);
        if (self.cursor) |value| gpa.free(value);
        if (self.mode) |value| gpa.free(value);
    }
};

pub const ConfigGetArgs = struct {
    local: bool = false,
    global: bool = false,
    key: []const u8,

    pub fn deinit(self: *ConfigGetArgs, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
    }
};

pub const ConfigSetArgs = struct {
    local: bool = false,
    global: bool = false,
    key: []const u8,
    value: []const u8,

    pub fn deinit(self: *ConfigSetArgs, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
        gpa.free(self.value);
    }
};

pub const ConfigUnsetArgs = struct {
    local: bool = false,
    global: bool = false,
    key: []const u8,

    pub fn deinit(self: *ConfigUnsetArgs, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
    }
};

pub const ConfigListArgs = struct {
    local: bool = false,
    global: bool = false,

    pub fn deinit(self: *ConfigListArgs, gpa: std.mem.Allocator) void {
        _ = self;
        _ = gpa;
    }
};

pub const Invocation = union(enum) {
    help: HelpRequest,
    version: void,
    doc_put: DocPutArgs,
    doc_get: DocGetArgs,
    doc_list: DocListArgs,
    doc_delete: DocDeleteArgs,
    doc_history: DocHistoryArgs,
    config_get: ConfigGetArgs,
    config_set: ConfigSetArgs,
    config_unset: ConfigUnsetArgs,
    config_list: ConfigListArgs,

    pub fn deinit(self: *Invocation, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .help => |*value| value.deinit(gpa),
            .version => {},
            .doc_put => |*value| value.deinit(gpa),
            .doc_get => |*value| value.deinit(gpa),
            .doc_list => |*value| value.deinit(gpa),
            .doc_delete => |*value| value.deinit(gpa),
            .doc_history => |*value| value.deinit(gpa),
            .config_get => |*value| value.deinit(gpa),
            .config_set => |*value| value.deinit(gpa),
            .config_unset => |*value| value.deinit(gpa),
            .config_list => |*value| value.deinit(gpa),
        }
    }
};

pub const ParsedCli = struct {
    global: GlobalOptions,
    command: Invocation,

    pub fn deinit(self: *ParsedCli, gpa: std.mem.Allocator) void {
        self.global.deinit(gpa);
        self.command.deinit(gpa);
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
    var config_props = std.ArrayList(ConfigProp).empty;
    errdefer {
        for (config_props.items) |*prop| prop.deinit(gpa);
        config_props.deinit(gpa);
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
        } else if (std.mem.eql(u8, node.name, "config")) {
            try parseConfigBlock(gpa, node, &config_props);
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
        .config_props = try config_props.toOwnedSlice(gpa),
    };
}

fn parseConfigBlock(
    gpa: std.mem.Allocator,
    node: *const RawNode,
    props: *std.ArrayList(ConfigProp),
) ParseError!void {
    for (node.children.items) |child| {
        if (std.mem.eql(u8, child.name, "prop")) {
            try props.append(gpa, try parseConfigProp(gpa, child));
        } else {
            return error.UnsupportedNode;
        }
    }
}

fn parseConfigProp(gpa: std.mem.Allocator, node: *const RawNode) ParseError!ConfigProp {
    const key = try dupeFirstArg(gpa, node);
    var prop: ConfigProp = .{ .key = key };
    errdefer prop.deinit(gpa);

    prop.default_value = try dupeOptionalProp(gpa, node, "default");
    prop.default_note = try dupeOptionalProp(gpa, node, "default_note");
    prop.data_type = try dupeOptionalProp(gpa, node, "data_type");
    prop.env = try dupeOptionalProp(gpa, node, "env");
    prop.help = try dupeOptionalProp(gpa, node, "help");
    prop.long_help = try dupeOptionalChildArg(gpa, node, "long_help");

    for (node.children.items) |child| {
        if (std.mem.eql(u8, child.name, "long_help")) continue;
        return error.UnsupportedNode;
    }

    return prop;
}

pub fn parseArgv(
    gpa: std.mem.Allocator,
    spec_like: anytype,
    argv: []const []const u8,
) ParseError!ParsedCli {
    if (argv.len < 2) return error.InvalidArguments;
    const spec = try intoSpecView(gpa, spec_like);
    defer if (spec.owned) {
        freeSpecView(gpa, &spec.view);
    };

    return usage_runtime.parseArgv(@This(), gpa, &spec.view, argv);
}

pub fn renderHelp(gpa: std.mem.Allocator, spec: *const SpecView, topic: []const []const u8) ParseError![]u8 {
    return usage_runtime.renderHelp(gpa, spec, topic);
}

pub fn freeSpecViewForTests(gpa: std.mem.Allocator, spec: *const SpecView) void {
    freeSpecView(gpa, spec);
}

pub fn buildGlobalOptions(gpa: std.mem.Allocator, flags: []const usage_runtime.ParsedFlag) ParseError!GlobalOptions {
    return .{
        .json = usage_runtime.hasFlag(flags, "--json"),
        .refstore = try dupOptionalFlagValue(gpa, flags, "--refstore"),
    };
}

pub fn buildHelp(
    gpa: std.mem.Allocator,
    flags: []const usage_runtime.ParsedFlag,
    topic: []const []const u8,
) ParseError!ParsedCli {
    return .{
        .global = try buildGlobalOptions(gpa, flags),
        .command = .{ .help = .{ .topic = try cloneTopic(gpa, topic) } },
    };
}

pub fn buildInvocation(
    gpa: std.mem.Allocator,
    command_path: []const []const u8,
    flags: []const usage_runtime.ParsedFlag,
    args: []const []const u8,
) ParseError!Invocation {
    if (commandPathMatches(command_path, &.{"version"})) {
        try ensureArgCount(args, 0);
        return .{ .version = {} };
    }

    if (commandPathMatches(command_path, &.{ "doc", "put" })) {
        try ensureArgCount(args, 0);
        return .{ .doc_put = .{
            .namespace = try dupOptionalFlagValue(gpa, flags, "--namespace"),
            .doc_type = try dupOptionalFlagValue(gpa, flags, "--type"),
            .id = try dupOptionalFlagValue(gpa, flags, "--id"),
            .data_file = try dupOptionalFlagValue(gpa, flags, "--data-file"),
        } };
    }

    if (commandPathMatches(command_path, &.{ "doc", "get" })) {
        try ensureArgCount(args, 0);
        try ensureFlagPresent(flags, "--type");
        try ensureFlagPresent(flags, "--id");
        return .{ .doc_get = .{
            .namespace = try dupOptionalFlagValue(gpa, flags, "--namespace"),
            .doc_type = try dupRequiredFlagValue(gpa, flags, "--type"),
            .id = try dupRequiredFlagValue(gpa, flags, "--id"),
            .version = try dupOptionalFlagValue(gpa, flags, "--version"),
        } };
    }

    if (commandPathMatches(command_path, &.{ "doc", "list" })) {
        try ensureArgCount(args, 0);
        return .{ .doc_list = .{
            .namespace = try dupOptionalFlagValue(gpa, flags, "--namespace"),
            .doc_type = try dupOptionalFlagValue(gpa, flags, "--type"),
            .limit = try dupOptionalFlagValue(gpa, flags, "--limit"),
            .cursor = try dupOptionalFlagValue(gpa, flags, "--cursor"),
            .mode = try dupOptionalFlagValue(gpa, flags, "--mode"),
        } };
    }

    if (commandPathMatches(command_path, &.{ "doc", "delete" })) {
        try ensureArgCount(args, 0);
        try ensureFlagPresent(flags, "--type");
        try ensureFlagPresent(flags, "--id");
        return .{ .doc_delete = .{
            .namespace = try dupOptionalFlagValue(gpa, flags, "--namespace"),
            .doc_type = try dupRequiredFlagValue(gpa, flags, "--type"),
            .id = try dupRequiredFlagValue(gpa, flags, "--id"),
        } };
    }

    if (commandPathMatches(command_path, &.{ "doc", "history" })) {
        try ensureArgCount(args, 0);
        try ensureFlagPresent(flags, "--type");
        try ensureFlagPresent(flags, "--id");
        return .{ .doc_history = .{
            .namespace = try dupOptionalFlagValue(gpa, flags, "--namespace"),
            .doc_type = try dupRequiredFlagValue(gpa, flags, "--type"),
            .id = try dupRequiredFlagValue(gpa, flags, "--id"),
            .limit = try dupOptionalFlagValue(gpa, flags, "--limit"),
            .cursor = try dupOptionalFlagValue(gpa, flags, "--cursor"),
            .mode = try dupOptionalFlagValue(gpa, flags, "--mode"),
        } };
    }

    if (commandPathMatches(command_path, &.{ "config", "get" })) {
        try ensureArgCount(args, 1);
        return .{ .config_get = .{
            .local = usage_runtime.hasFlag(flags, "--local"),
            .global = usage_runtime.hasFlag(flags, "--global"),
            .key = try dupArgValue(gpa, args, 0),
        } };
    }

    if (commandPathMatches(command_path, &.{ "config", "set" })) {
        try ensureArgCount(args, 2);
        return .{ .config_set = .{
            .local = usage_runtime.hasFlag(flags, "--local"),
            .global = usage_runtime.hasFlag(flags, "--global"),
            .key = try dupArgValue(gpa, args, 0),
            .value = try dupArgValue(gpa, args, 1),
        } };
    }

    if (commandPathMatches(command_path, &.{ "config", "unset" })) {
        try ensureArgCount(args, 1);
        return .{ .config_unset = .{
            .local = usage_runtime.hasFlag(flags, "--local"),
            .global = usage_runtime.hasFlag(flags, "--global"),
            .key = try dupArgValue(gpa, args, 0),
        } };
    }

    if (commandPathMatches(command_path, &.{ "config", "list" })) {
        try ensureArgCount(args, 0);
        return .{ .config_list = .{
            .local = usage_runtime.hasFlag(flags, "--local"),
            .global = usage_runtime.hasFlag(flags, "--global"),
        } };
    }

    return error.InvalidArguments;
}

fn dupOptionalFlagValue(
    gpa: std.mem.Allocator,
    flags: []const usage_runtime.ParsedFlag,
    name: []const u8,
) ParseError!?[]const u8 {
    const value = usage_runtime.flagValue(flags, name) orelse return null;
    return try gpa.dupe(u8, value);
}

fn dupRequiredFlagValue(
    gpa: std.mem.Allocator,
    flags: []const usage_runtime.ParsedFlag,
    name: []const u8,
) ParseError![]const u8 {
    const value = usage_runtime.flagValue(flags, name) orelse return error.InvalidArguments;
    return try gpa.dupe(u8, value);
}

fn ensureFlagPresent(flags: []const usage_runtime.ParsedFlag, name: []const u8) ParseError!void {
    _ = usage_runtime.flagValue(flags, name) orelse return error.InvalidArguments;
}

fn ensureArgCount(args: []const []const u8, expected: usize) ParseError!void {
    if (args.len != expected) return error.InvalidArguments;
}

fn dupArgValue(gpa: std.mem.Allocator, args: []const []const u8, index: usize) ParseError![]const u8 {
    if (index >= args.len) return error.InvalidArguments;
    return try gpa.dupe(u8, args[index]);
}

fn cloneTopic(gpa: std.mem.Allocator, topic: []const []const u8) ParseError![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |segment| gpa.free(segment);
        out.deinit(gpa);
    }
    for (topic) |segment| try out.append(gpa, try gpa.dupe(u8, segment));
    return try out.toOwnedSlice(gpa);
}

fn commandPathMatches(actual: []const []const u8, expected: []const []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |actual_segment, expected_segment| {
        if (!std.mem.eql(u8, actual_segment, expected_segment)) return false;
    }
    return true;
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
    var args = std.ArrayList([]const u8).empty;
    errdefer {
        for (args.items) |arg| gpa.free(arg);
        args.deinit(gpa);
    }
    var subcommands = std.ArrayList(Command).empty;
    errdefer {
        for (subcommands.items) |*command| command.deinit(gpa);
        subcommands.deinit(gpa);
    }
    var examples = std.ArrayList([]const u8).empty;
    errdefer {
        for (examples.items) |example| gpa.free(example);
        examples.deinit(gpa);
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
        } else if (std.mem.eql(u8, child.name, "arg")) {
            try args.append(gpa, try dupeFirstArg(gpa, child));
        } else if (std.mem.eql(u8, child.name, "cmd")) {
            try subcommands.append(gpa, try parseCommand(gpa, child));
        } else if (std.mem.eql(u8, child.name, "long_help")) {
            continue;
        } else if (std.mem.eql(u8, child.name, "example")) {
            try examples.append(gpa, try dupeFirstArg(gpa, child));
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
        .args = try args.toOwnedSlice(gpa),
        .subcommands = try subcommands.toOwnedSlice(gpa),
        .examples = try examples.toOwnedSlice(gpa),
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
        std.mem.eql(u8, name, "after_long_help");
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
        \\const std = @import("std");
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
    try output.appendSlice(gpa, "};\n\n");
    try renderGeneratedGlobalOptions(gpa, &output, spec);
    try renderGeneratedPayloadStructs(gpa, &output, spec.root_commands);
    try renderGeneratedInvocation(gpa, &output, spec.root_commands);
    try renderGeneratedParsedCli(gpa, &output);
    try renderGeneratedParseWrapper(gpa, &output);
    try renderGeneratedHelpWrapper(gpa, &output);
    try renderGeneratedBuildGlobalOptions(gpa, &output, spec);
    try renderGeneratedBuildHelp(gpa, &output);
    try renderGeneratedBuildInvocation(gpa, &output, spec.root_commands);
    try renderGeneratedHelpers(gpa, &output);

    return try output.toOwnedSlice(gpa);
}

fn renderGeneratedGlobalOptions(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    spec: *const Spec,
) ParseError!void {
    try output.appendSlice(gpa, "pub const GlobalOptions = struct {\n");
    for (spec.global_flags) |flag| {
        const field_name = try generatedFieldName(gpa, &flag);
        defer gpa.free(field_name);
        try writeIndent(gpa, output, 1);
        if (flag.value_name == null) {
            try appendFmt(gpa, output, "{s}: bool = false,\n", .{field_name});
        } else {
            try appendFmt(gpa, output, "{s}: ?[]const u8 = null,\n", .{field_name});
        }
    }
    try output.appendSlice(gpa,
        \\
        \\    pub fn deinit(self: *GlobalOptions, gpa: std.mem.Allocator) void {
        \\
    );
    for (spec.global_flags) |flag| {
        if (flag.value_name == null) continue;
        const field_name = try generatedFieldName(gpa, &flag);
        defer gpa.free(field_name);
        try writeIndent(gpa, output, 2);
        try appendFmt(gpa, output, "if (self.{s}) |value| gpa.free(value);\n", .{field_name});
    }
    try output.appendSlice(gpa,
        \\    }
        \\};
        \\
    );
}

fn renderGeneratedPayloadStructs(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    commands: []const Command,
) ParseError!void {
    var path = std.ArrayList([]const u8).empty;
    defer path.deinit(gpa);
    for (commands) |command| try renderGeneratedPayloadStructForCommand(gpa, output, &path, &command);
}

fn renderGeneratedPayloadStructForCommand(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    path: *std.ArrayList([]const u8),
    command: *const Command,
) ParseError!void {
    try path.append(gpa, command.name);
    defer _ = path.pop();

    if (command.subcommands.len != 0) {
        for (command.subcommands) |child| try renderGeneratedPayloadStructForCommand(gpa, output, path, &child);
        return;
    }
    if (isGeneratedHelpCommand(path.items)) return;
    if (path.items.len == 1 and std.mem.eql(u8, path.items[0], "version")) return;

    const struct_name = try generatedStructName(gpa, path.items);
    defer gpa.free(struct_name);

    try appendFmt(gpa, output, "pub const {s} = struct {{\n", .{struct_name});
    for (command.flags) |flag| {
        const field_name = try generatedFieldName(gpa, &flag);
        defer gpa.free(field_name);
        try writeIndent(gpa, output, 1);
        if (flag.value_name == null) {
            try appendFmt(gpa, output, "{s}: bool = false,\n", .{field_name});
        } else if (isRequiredGeneratedField(path.items, field_name)) {
            try appendFmt(gpa, output, "{s}: []const u8,\n", .{field_name});
        } else {
            try appendFmt(gpa, output, "{s}: ?[]const u8 = null,\n", .{field_name});
        }
    }
    for (command.args) |arg| {
        const field_name = try generatedArgFieldName(gpa, arg);
        defer gpa.free(field_name);
        try writeIndent(gpa, output, 1);
        try appendFmt(gpa, output, "{s}: []const u8,\n", .{field_name});
    }
    try appendFmt(gpa, output, "\n    pub fn deinit(self: *{s}, gpa: std.mem.Allocator) void {{\n", .{struct_name});
    var has_owned_fields = false;
    for (command.flags) |flag| {
        if (flag.value_name == null) continue;
        has_owned_fields = true;
        const field_name = try generatedFieldName(gpa, &flag);
        defer gpa.free(field_name);
        try writeIndent(gpa, output, 2);
        if (isRequiredGeneratedField(path.items, field_name)) {
            try appendFmt(gpa, output, "gpa.free(self.{s});\n", .{field_name});
        } else {
            try appendFmt(gpa, output, "if (self.{s}) |value| gpa.free(value);\n", .{field_name});
        }
    }
    for (command.args) |arg| {
        has_owned_fields = true;
        const field_name = try generatedArgFieldName(gpa, arg);
        defer gpa.free(field_name);
        try writeIndent(gpa, output, 2);
        try appendFmt(gpa, output, "gpa.free(self.{s});\n", .{field_name});
    }
    if (!has_owned_fields) {
        try writeIndent(gpa, output, 2);
        try output.appendSlice(gpa, "_ = self;\n");
        try writeIndent(gpa, output, 2);
        try output.appendSlice(gpa, "_ = gpa;\n");
    }
    try output.appendSlice(gpa,
        \\    }
        \\};
        \\
    );
}

fn renderGeneratedInvocation(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    commands: []const Command,
) ParseError!void {
    try output.appendSlice(gpa, "pub const Invocation = union(enum) {\n");
    try output.appendSlice(gpa, "    help: usage.HelpRequest,\n");
    var path = std.ArrayList([]const u8).empty;
    defer path.deinit(gpa);
    for (commands) |command| try renderGeneratedInvocationCases(gpa, output, &path, &command);
    try output.appendSlice(gpa, "\n    pub fn deinit(self: *Invocation, gpa: std.mem.Allocator) void {\n        switch (self.*) {\n");
    try output.appendSlice(gpa, "            .help => |*value| value.deinit(gpa),\n");
    for (commands) |command| try renderGeneratedInvocationDeinitCases(gpa, output, &path, &command);
    try output.appendSlice(gpa,
        \\        }
        \\    }
        \\};
        \\
    );
}

fn renderGeneratedInvocationCases(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    path: *std.ArrayList([]const u8),
    command: *const Command,
) ParseError!void {
    try path.append(gpa, command.name);
    defer _ = path.pop();

    if (command.subcommands.len != 0) {
        for (command.subcommands) |child| try renderGeneratedInvocationCases(gpa, output, path, &child);
        return;
    }
    if (isGeneratedHelpCommand(path.items)) return;

    const case_name = try generatedCaseName(gpa, path.items);
    defer gpa.free(case_name);
    try writeIndent(gpa, output, 1);
    if (path.items.len == 1 and std.mem.eql(u8, path.items[0], "version")) {
        try appendFmt(gpa, output, "{s}: void,\n", .{case_name});
    } else {
        const struct_name = try generatedStructName(gpa, path.items);
        defer gpa.free(struct_name);
        try appendFmt(gpa, output, "{s}: {s},\n", .{ case_name, struct_name });
    }
}

fn renderGeneratedInvocationDeinitCases(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    path: *std.ArrayList([]const u8),
    command: *const Command,
) ParseError!void {
    try path.append(gpa, command.name);
    defer _ = path.pop();

    if (command.subcommands.len != 0) {
        for (command.subcommands) |child| try renderGeneratedInvocationDeinitCases(gpa, output, path, &child);
        return;
    }
    if (isGeneratedHelpCommand(path.items)) return;

    const case_name = try generatedCaseName(gpa, path.items);
    defer gpa.free(case_name);
    try writeIndent(gpa, output, 3);
    if (path.items.len == 1 and std.mem.eql(u8, path.items[0], "version")) {
        try appendFmt(gpa, output, ".{s} => {{}},\n", .{case_name});
    } else {
        try appendFmt(gpa, output, ".{s} => |*value| value.deinit(gpa),\n", .{case_name});
    }
}

fn renderGeneratedParsedCli(gpa: std.mem.Allocator, output: *std.ArrayList(u8)) ParseError!void {
    try output.appendSlice(gpa,
        \\pub const ParsedCli = struct {
        \\    global: GlobalOptions,
        \\    command: Invocation,
        \\
        \\    pub fn deinit(self: *ParsedCli, gpa: std.mem.Allocator) void {
        \\        self.global.deinit(gpa);
        \\        self.command.deinit(gpa);
        \\    }
        \\};
        \\
    );
}

fn renderGeneratedParseWrapper(gpa: std.mem.Allocator, output: *std.ArrayList(u8)) ParseError!void {
    try output.appendSlice(gpa,
        \\pub fn parseArgv(gpa: std.mem.Allocator, argv: []const []const u8) usage.ParseError!ParsedCli {
        \\    return usage.parseArgv(@This(), gpa, &spec, argv);
        \\}
        \\
    );
}

fn renderGeneratedHelpWrapper(gpa: std.mem.Allocator, output: *std.ArrayList(u8)) ParseError!void {
    try output.appendSlice(gpa,
        \\pub fn renderHelp(gpa: std.mem.Allocator, topic: []const []const u8) usage.ParseError![]u8 {
        \\    return usage.renderHelp(gpa, &spec, topic);
        \\}
        \\
    );
}

fn renderGeneratedBuildGlobalOptions(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    spec: *const Spec,
) ParseError!void {
    try output.appendSlice(gpa, "pub fn buildGlobalOptions(gpa: std.mem.Allocator, flags: []const usage.ParsedFlag) usage.ParseError!GlobalOptions {\n    return .{\n");
    for (spec.global_flags) |flag| {
        const field_name = try generatedFieldName(gpa, &flag);
        defer gpa.free(field_name);
        try writeIndent(gpa, output, 2);
        if (flag.value_name == null) {
            const flag_name = flag.long_name orelse flag.short_name orelse return error.InvalidSpec;
            try appendFmt(gpa, output, ".{s} = usage.hasFlag(flags, \"{f}\"),\n", .{
                field_name,
                std.zig.fmtString(flag_name),
            });
        } else {
            const flag_name = flag.long_name orelse flag.short_name orelse return error.InvalidSpec;
            try appendFmt(gpa, output, ".{s} = try dupOptionalFlagValue(gpa, flags, \"{f}\"),\n", .{
                field_name,
                std.zig.fmtString(flag_name),
            });
        }
    }
    try output.appendSlice(gpa,
        \\    };
        \\}
        \\
    );
}

fn renderGeneratedBuildHelp(gpa: std.mem.Allocator, output: *std.ArrayList(u8)) ParseError!void {
    try output.appendSlice(gpa,
        \\pub fn buildHelp(
        \\    gpa: std.mem.Allocator,
        \\    flags: []const usage.ParsedFlag,
        \\    topic: []const []const u8,
        \\) usage.ParseError!ParsedCli {
        \\    return .{
        \\        .global = try buildGlobalOptions(gpa, flags),
        \\        .command = .{ .help = .{ .topic = try cloneTopic(gpa, topic) } },
        \\    };
        \\}
        \\
    );
}

fn renderGeneratedBuildInvocation(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    commands: []const Command,
) ParseError!void {
    try output.appendSlice(gpa,
        \\pub fn buildInvocation(
        \\    gpa: std.mem.Allocator,
        \\    command_path: []const []const u8,
        \\    flags: []const usage.ParsedFlag,
        \\    args: []const []const u8,
        \\) usage.ParseError!Invocation {
        \\
    );
    var path = std.ArrayList([]const u8).empty;
    defer path.deinit(gpa);
    for (commands) |command| try renderGeneratedBuildInvocationCase(gpa, output, &path, &command);
    try output.appendSlice(gpa,
        \\    return error.InvalidArguments;
        \\}
        \\
    );
}

fn renderGeneratedBuildInvocationCase(
    gpa: std.mem.Allocator,
    output: *std.ArrayList(u8),
    path: *std.ArrayList([]const u8),
    command: *const Command,
) ParseError!void {
    try path.append(gpa, command.name);
    defer _ = path.pop();

    if (command.subcommands.len != 0) {
        for (command.subcommands) |child| try renderGeneratedBuildInvocationCase(gpa, output, path, &child);
        return;
    }
    if (isGeneratedHelpCommand(path.items)) return;

    const case_name = try generatedCaseName(gpa, path.items);
    defer gpa.free(case_name);
    const path_literal = try generatedPathLiteral(gpa, path.items);
    defer gpa.free(path_literal);

    if (path.items.len == 1 and std.mem.eql(u8, path.items[0], "version")) {
        try appendFmt(gpa, output, "    if (commandPathMatches(command_path, {s})) {{\n        try ensureArgCount(args, 0);\n        return .{{ .{s} = {{}} }};\n    }}\n\n", .{
            path_literal,
            case_name,
        });
        return;
    }

    try appendFmt(gpa, output, "    if (commandPathMatches(command_path, {s})) {{\n", .{path_literal});
    try appendFmt(gpa, output, "        try ensureArgCount(args, {d});\n", .{command.args.len});
    for (command.flags) |flag| {
        const field_name = try generatedFieldName(gpa, &flag);
        defer gpa.free(field_name);
        if (flag.value_name == null or !isRequiredGeneratedField(path.items, field_name)) continue;
        const flag_name = flag.long_name orelse flag.short_name orelse return error.InvalidSpec;
        try appendFmt(gpa, output, "        try ensureFlagPresent(flags, \"{f}\");\n", .{
            std.zig.fmtString(flag_name),
        });
    }
    try appendFmt(gpa, output, "        return .{{ .{s} = .{{\n", .{case_name});
    for (command.flags) |flag| {
        const field_name = try generatedFieldName(gpa, &flag);
        defer gpa.free(field_name);
        const flag_name = flag.long_name orelse flag.short_name orelse return error.InvalidSpec;
        try writeIndent(gpa, output, 4);
        if (flag.value_name == null) {
            try appendFmt(gpa, output, ".{s} = usage.hasFlag(flags, \"{f}\"),\n", .{
                field_name,
                std.zig.fmtString(flag_name),
            });
        } else if (isRequiredGeneratedField(path.items, field_name)) {
            try appendFmt(gpa, output, ".{s} = try dupRequiredFlagValue(gpa, flags, \"{f}\"),\n", .{
                field_name,
                std.zig.fmtString(flag_name),
            });
        } else {
            try appendFmt(gpa, output, ".{s} = try dupOptionalFlagValue(gpa, flags, \"{f}\"),\n", .{
                field_name,
                std.zig.fmtString(flag_name),
            });
        }
    }
    for (command.args, 0..) |arg, index| {
        const field_name = try generatedArgFieldName(gpa, arg);
        defer gpa.free(field_name);
        try writeIndent(gpa, output, 4);
        try appendFmt(gpa, output, ".{s} = try dupArgValue(gpa, args, {d}),\n", .{ field_name, index });
    }
    try output.appendSlice(gpa,
        \\            } };
        \\    }
        \\
        \\
    );
}

fn renderGeneratedHelpers(gpa: std.mem.Allocator, output: *std.ArrayList(u8)) ParseError!void {
    try output.appendSlice(gpa,
        \\fn dupOptionalFlagValue(
        \\    gpa: std.mem.Allocator,
        \\    flags: []const usage.ParsedFlag,
        \\    name: []const u8,
        \\) usage.ParseError!?[]const u8 {
        \\    const value = usage.flagValue(flags, name) orelse return null;
        \\    return try gpa.dupe(u8, value);
        \\}
        \\
        \\fn dupRequiredFlagValue(
        \\    gpa: std.mem.Allocator,
        \\    flags: []const usage.ParsedFlag,
        \\    name: []const u8,
        \\) usage.ParseError![]const u8 {
        \\    const value = usage.flagValue(flags, name) orelse return error.InvalidArguments;
        \\    return try gpa.dupe(u8, value);
        \\}
        \\
        \\fn ensureFlagPresent(flags: []const usage.ParsedFlag, name: []const u8) usage.ParseError!void {
        \\    _ = usage.flagValue(flags, name) orelse return error.InvalidArguments;
        \\}
        \\
        \\fn ensureArgCount(args: []const []const u8, expected: usize) usage.ParseError!void {
        \\    if (args.len != expected) return error.InvalidArguments;
        \\}
        \\
        \\fn dupArgValue(gpa: std.mem.Allocator, args: []const []const u8, index: usize) usage.ParseError![]const u8 {
        \\    if (index >= args.len) return error.InvalidArguments;
        \\    return try gpa.dupe(u8, args[index]);
        \\}
        \\
        \\fn cloneTopic(gpa: std.mem.Allocator, topic: []const []const u8) usage.ParseError![][]const u8 {
        \\    var out = std.ArrayList([]const u8).empty;
        \\    errdefer {
        \\        for (out.items) |segment| gpa.free(segment);
        \\        out.deinit(gpa);
        \\    }
        \\    for (topic) |segment| try out.append(gpa, try gpa.dupe(u8, segment));
        \\    return try out.toOwnedSlice(gpa);
        \\}
        \\
        \\fn commandPathMatches(actual: []const []const u8, expected: []const []const u8) bool {
        \\    if (actual.len != expected.len) return false;
        \\    for (actual, expected) |actual_segment, expected_segment| {
        \\        if (!std.mem.eql(u8, actual_segment, expected_segment)) return false;
        \\    }
        \\    return true;
        \\}
        \\
    );
}

fn generatedCaseName(gpa: std.mem.Allocator, path: []const []const u8) ParseError![]u8 {
    return joinIdentifier(gpa, path, .snake);
}

fn generatedStructName(gpa: std.mem.Allocator, path: []const []const u8) ParseError![]u8 {
    const base = try joinIdentifier(gpa, path, .pascal);
    defer gpa.free(base);
    return try std.fmt.allocPrint(gpa, "{s}Args", .{base});
}

fn generatedFieldName(gpa: std.mem.Allocator, flag: *const Flag) ParseError![]u8 {
    const flag_name = flag.long_name orelse flag.short_name orelse return error.InvalidSpec;
    const bare = if (std.mem.startsWith(u8, flag_name, "--")) flag_name[2..] else flag_name[1..];
    return normalizeIdentifier(gpa, bare, .snake);
}

fn generatedArgFieldName(gpa: std.mem.Allocator, arg: []const u8) ParseError![]u8 {
    const bare = if ((std.mem.startsWith(u8, arg, "<") and std.mem.endsWith(u8, arg, ">")) or
        (std.mem.startsWith(u8, arg, "[") and std.mem.endsWith(u8, arg, "]")))
        arg[1 .. arg.len - 1]
    else
        arg;
    return normalizeIdentifier(gpa, bare, .snake);
}

const IdentifierStyle = enum {
    snake,
    pascal,
};

fn joinIdentifier(gpa: std.mem.Allocator, parts: []const []const u8, style: IdentifierStyle) ParseError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);

    for (parts, 0..) |part, index| {
        const normalized = try normalizeIdentifier(gpa, part, style);
        defer gpa.free(normalized);
        if (style == .snake and index != 0) try out.append(gpa, '_');
        try out.appendSlice(gpa, normalized);
    }

    return try out.toOwnedSlice(gpa);
}

fn normalizeIdentifier(gpa: std.mem.Allocator, value: []const u8, style: IdentifierStyle) ParseError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);

    var capitalize_next = style == .pascal;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            var next_char = char;
            if (style == .pascal) {
                if (capitalize_next) {
                    next_char = std.ascii.toUpper(char);
                    capitalize_next = false;
                }
            } else {
                next_char = std.ascii.toLower(char);
            }
            try out.append(gpa, next_char);
        } else {
            if (style == .snake) {
                if (out.items.len != 0 and out.items[out.items.len - 1] != '_') try out.append(gpa, '_');
            } else {
                capitalize_next = true;
            }
        }
    }

    if (style == .snake and std.mem.eql(u8, out.items, "type")) {
        out.clearRetainingCapacity();
        try out.appendSlice(gpa, "doc_type");
    }

    return try out.toOwnedSlice(gpa);
}

fn generatedPathLiteral(gpa: std.mem.Allocator, path: []const []const u8) ParseError![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "&.{");
    for (path, 0..) |part, index| {
        if (index != 0) try out.appendSlice(gpa, ", ");
        const rendered = try std.fmt.allocPrint(gpa, "\"{f}\"", .{std.zig.fmtString(part)});
        defer gpa.free(rendered);
        try out.appendSlice(gpa, rendered);
    }
    try out.append(gpa, '}');
    return try out.toOwnedSlice(gpa);
}

fn isRequiredGeneratedField(path: []const []const u8, field_name: []const u8) bool {
    if (!std.mem.eql(u8, field_name, "doc_type") and !std.mem.eql(u8, field_name, "id")) return false;
    return commandPathMatches(path, &.{ "doc", "get" }) or
        commandPathMatches(path, &.{ "doc", "delete" }) or
        commandPathMatches(path, &.{ "doc", "history" });
}

fn isGeneratedHelpCommand(path: []const []const u8) bool {
    return path.len == 1 and std.mem.eql(u8, path[0], "help");
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

fn freeSpecView(gpa: std.mem.Allocator, spec: *const SpecView) void {
    gpa.free(spec.bin);
    gpa.free(spec.usage);
    if (spec.version) |value| gpa.free(value);
    if (spec.source_code_link_template) |value| gpa.free(value);
    freeFlagViews(gpa, spec.global_flags);
    freeCommandViews(gpa, spec.root_commands);
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
    var examples = std.ArrayList([]const u8).empty;
    errdefer {
        for (examples.items) |example| gpa.free(example);
        examples.deinit(gpa);
    }
    for (command.examples) |example| try examples.append(gpa, try gpa.dupe(u8, example));
    var args = std.ArrayList([]const u8).empty;
    errdefer {
        for (args.items) |arg| gpa.free(arg);
        args.deinit(gpa);
    }
    for (command.args) |arg| try args.append(gpa, try gpa.dupe(u8, arg));

    return .{
        .name = try gpa.dupe(u8, command.name),
        .help = try cloneOptionalBytes(gpa, command.help),
        .long_help = try cloneOptionalBytes(gpa, command.long_help),
        .subcommand_required = command.subcommand_required,
        .aliases = try aliases.toOwnedSlice(gpa),
        .flags = try cloneFlagViews(gpa, command.flags),
        .args = try args.toOwnedSlice(gpa),
        .subcommands = try cloneCommandViews(gpa, command.subcommands),
        .examples = try examples.toOwnedSlice(gpa),
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
        for (command.args) |arg| gpa.free(arg);
        if (command.args.len != 0) gpa.free(command.args);
        freeCommandViews(gpa, command.subcommands);
        for (command.examples) |example| gpa.free(example);
        if (command.examples.len != 0) gpa.free(command.examples);
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
    try renderStringSliceField(gpa, output, "args", command.args, indent_level + 1);
    try renderNestedCommands(gpa, output, command.subcommands, indent_level + 1);
    try renderStringSliceField(gpa, output, "examples", command.examples, indent_level + 1);
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
