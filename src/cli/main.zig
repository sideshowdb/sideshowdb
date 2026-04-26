const std = @import("std");
const Io = std.Io;
const sideshowdb = @import("sideshowdb");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try sideshowdb.writeBanner(stdout);
    try stdout.flush();
}
