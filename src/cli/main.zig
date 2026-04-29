const std = @import("std");
const Io = std.Io;
const sideshowdb = @import("sideshowdb");
const cli = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_it.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |arg| gpa.free(arg);
        args.deinit(gpa);
    }
    while (args_it.next()) |arg| {
        try args.append(gpa, try gpa.dupe(u8, arg));
    }

    const repo_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(repo_path);

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
    const stdin_data = try stdin_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(stdin_data);

    const result = try cli.run(
        gpa,
        io,
        init.environ_map,
        repo_path,
        args.items,
        stdin_data,
    );
    defer result.deinit(gpa);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(result.stdout);
    try stdout.flush();

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    try stderr.writeAll(result.stderr);
    try stderr.flush();

    if (result.exit_code != 0) std.process.exit(result.exit_code);
}
