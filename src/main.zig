const std = @import("std");

const gfdi = @import("gfdi");

const assert = std.debug.assert;

const Writer = std.Io.Writer;

const Invocation = struct {
    address: u64,
    command: gfdi.Command,
};

const arguments_max: u32 = 3;
const native_options: gfdi.Native.Options = .{};
const stdout_bytes: u32 = 4096;

const usage =
    \\usage: gfdi <command> [address]
    \\
    \\  observe AA:BB:CC:DD:EE:FF   pull the watch archive, reconnecting until complete
    \\  connect AA:BB:CC:DD:EE:FF   connect by address and list GATT services
    \\  pull    AA:BB:CC:DD:EE:FF   wait for the watch to advertise, then inspect GATT
    \\  scan                        list BLE advertisers seen for 8 seconds
    \\  enumerate                   list BLE devices known to the OS
    \\  smoke                       verify the BLE runtime loads
    \\
    \\  AA:BB:CC:DD:EE:FF           shorthand for observe with this address
    \\
;

comptime {
    assert(usage.len > 0);
    assert(stdout_bytes > usage.len);
}

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));

    var stdout_buffer: [stdout_bytes]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);

    const out = &stdout_writer.interface;
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());

    const invocation = parse(arguments) orelse {
        try out.writeAll(usage);
        try out.flush();

        return error.ArgumentsInvalid;
    };

    const native = try init.gpa.create(gfdi.Native);
    defer init.gpa.destroy(native);

    native.init(init.io, native_options);
    defer native.deinit();

    assert(native.diagnostic().cause.len == 0);

    run(native, out, invocation) catch |err| {
        try out.print("gfdi: {s} ({s})\n", .{ gfdi.message(err), native.diagnostic().cause });
        try out.flush();

        return err;
    };

    try out.flush();
}

fn parse(arguments: []const [:0]const u8) ?Invocation {
    if (arguments.len < 2) return null;
    if (arguments.len > arguments_max) return null;
    if (arguments[1].len == 0) return null;

    const command = command_parse(arguments[1]) orelse {
        if (arguments.len != 2) return null;

        const address = gfdi.address_parse(arguments[1]) catch return null;

        assert(address >> 48 == 0);

        return .{ .address = address, .command = .observe };
    };

    if (!command.addressed()) {
        if (arguments.len != 2) return null;

        return .{ .address = 0, .command = command };
    }

    if (arguments.len != 3) return null;

    const address = gfdi.address_parse(arguments[2]) catch return null;

    assert(address >> 48 == 0);

    return .{ .address = address, .command = command };
}

fn command_parse(text: []const u8) ?gfdi.Command {
    assert(text.len > 0);

    if (std.mem.eql(u8, text, "enum")) return .enumerate;

    const result = std.meta.stringToEnum(gfdi.Command, text);

    if (result) |command| assert(std.mem.eql(u8, @tagName(command), text));

    return result;
}

fn run(native: *gfdi.Native, out: *Writer, invocation: Invocation) gfdi.Error!void {
    assert(invocation.address >> 48 == 0);
    assert(out.buffer.len > 0);

    switch (invocation.command) {
        .connect => try native.connect(out, invocation.address),
        .enumerate => try native.enumerate(out),
        .observe => try native.observe(out, invocation.address),
        .pull => try native.pull(out, invocation.address),
        .scan => try native.scan(out),
        .smoke => try native.smoke(out),
    }
}
