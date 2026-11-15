const std = @import("std");

const gfdi = @import("gfdi");

const assert = std.debug.assert;

const watch_file = [_]u8{
    0x0E, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, '.', 'F', 'I', 'T', 0x00, 0x00,
};

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len > 0);
    assert(watch_file.len <= gfdi.limits.file_bytes_max);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);

    const out = &stdout_writer.interface;
    const address = try gfdi.address_parse("A1:B2:C3:D4:E5:F6");

    const fake = try init.gpa.create(gfdi.Fake);
    defer init.gpa.destroy(fake);

    fake.init(init.io, .{ .address = address, .files = &.{&watch_file}, .name = "Forerunner" });
    defer fake.deinit();

    fake.observe(out, address) catch |err| {
        std.debug.print("{s} ({s})\n", .{ gfdi.message(err), fake.diagnostic().cause });

        return err;
    };

    for (0..fake.stored_count()) |index| {
        try out.print("stored {s}\n", .{fake.stored_path(@intCast(index))});
    }

    try out.flush();
}
