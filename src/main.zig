const std = @import("std");

const lib = @import("gfdi");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try lib.cli.run(lib.platform.backend, init, out);
    try out.flush();
}
