const std = @import("std");
const usage = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();

    _ = args.skip();
    const input_path = args.next() orelse return error.InvalidArguments;
    const output_path = args.next() orelse return error.InvalidArguments;
    if (args.next() != null) return error.InvalidArguments;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, input_path, gpa, .unlimited);
    defer gpa.free(source);

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    const generated = try usage.renderGeneratedModule(gpa, &spec);
    defer gpa.free(generated);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = generated,
    });
}
