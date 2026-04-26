const std = @import("std");
const sideshowdb = @import("sideshowdb");
const Environ = std.process.Environ;

const Allocator = std.mem.Allocator;

pub const usage_message = "usage: sideshowdb doc <put|get>\n";

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
    if (argv.len < 3) return usageFailure(gpa);
    if (!std.mem.eql(u8, argv[1], "doc")) return usageFailure(gpa);

    var git_store = sideshowdb.GitRefStore.init(.{
        .gpa = gpa,
        .io = io,
        .parent_env = env,
        .repo_path = repo_path,
        .ref_name = "refs/sideshowdb/documents",
    });
    const store = sideshowdb.DocumentStore.init(git_store.refStore());

    if (std.mem.eql(u8, argv[2], "put")) {
        const parsed = parsePutArgs(argv[3..]) catch return usageFailure(gpa);
        const put_request: sideshowdb.document.PutRequest =
            if (parsed.doc_type != null and parsed.id != null)
                .{ .payload = .{
                    .json = stdin_data,
                    .namespace = parsed.namespace,
                    .doc_type = parsed.doc_type.?,
                    .id = parsed.id.?,
                } }
            else
                .{ .envelope = .{
                    .json = stdin_data,
                    .namespace = parsed.namespace,
                    .doc_type = parsed.doc_type,
                    .id = parsed.id,
                } };
        const output = try store.put(gpa, put_request);
        return .{
            .exit_code = 0,
            .stdout = output,
            .stderr = try gpa.dupe(u8, ""),
        };
    }

    if (std.mem.eql(u8, argv[2], "get")) {
        const parsed = parseGetArgs(argv[3..]) catch return usageFailure(gpa);
        const output = try store.get(gpa, .{
            .namespace = parsed.namespace,
            .doc_type = parsed.doc_type,
            .id = parsed.id,
            .version = parsed.version,
        });
        if (output) |json| {
            return .{
                .exit_code = 0,
                .stdout = json,
                .stderr = try gpa.dupe(u8, ""),
            };
        }
        return failure(gpa, "document not found\n");
    }

    return usageFailure(gpa);
}

const PutArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

const GetArgs = struct {
    namespace: ?[]const u8 = null,
    doc_type: []const u8,
    id: []const u8,
    version: ?[]const u8 = null,
};

fn parsePutArgs(args: []const []const u8) !PutArgs {
    var result: PutArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--namespace")) {
            result.namespace = value;
        } else if (std.mem.eql(u8, flag, "--type")) {
            result.doc_type = value;
        } else if (std.mem.eql(u8, flag, "--id")) {
            result.id = value;
        } else {
            return error.InvalidArguments;
        }
    }
    return result;
}

fn parseGetArgs(args: []const []const u8) !GetArgs {
    var namespace: ?[]const u8 = null;
    var doc_type: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var version: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--namespace")) {
            namespace = value;
        } else if (std.mem.eql(u8, flag, "--type")) {
            doc_type = value;
        } else if (std.mem.eql(u8, flag, "--id")) {
            id = value;
        } else if (std.mem.eql(u8, flag, "--version")) {
            version = value;
        } else {
            return error.InvalidArguments;
        }
    }

    return .{
        .namespace = namespace,
        .doc_type = doc_type orelse return error.InvalidArguments,
        .id = id orelse return error.InvalidArguments,
        .version = version,
    };
}

fn failure(gpa: Allocator, message: []const u8) !RunResult {
    return .{
        .exit_code = 1,
        .stdout = try gpa.dupe(u8, ""),
        .stderr = try gpa.dupe(u8, message),
    };
}

fn usageFailure(gpa: Allocator) !RunResult {
    return failure(gpa, usage_message);
}
