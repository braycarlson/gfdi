const std = @import("std");

const assert = std.debug.assert;

pub const Command = enum { observe, scan, connect, pull, enumerate, smoke };

const mac_octets_max: u32 = 8;

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

pub fn run(comptime Platform: type, init: std.process.Init, out: *std.Io.Writer) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len <= 1) {
        try out.writeAll(usage);
        return;
    }

    const command = parse_command(args[1]) orelse {
        const address = parse_mac(args[1]) catch {
            try out.writeAll(usage);
            return;
        };

        try Platform.observe(arena, init.io, out, address);
        return;
    };

    switch (command) {
        .scan => return Platform.scan(arena, out),
        .enumerate => return Platform.enumerate(arena, out),
        .smoke => return Platform.smoke(arena, out),
        .observe, .connect, .pull => {},
    }

    if (args.len <= 2) {
        try out.writeAll(usage);
        return;
    }

    const address = parse_mac(args[2]) catch {
        try out.writeAll(usage);
        return;
    };

    switch (command) {
        .observe => try Platform.observe(arena, init.io, out, address),
        .connect => try Platform.connect(arena, out, address),
        .pull => try Platform.pull(arena, out, address),
        .scan, .enumerate, .smoke => unreachable,
    }
}

pub fn parse_command(text: []const u8) ?Command {
    if (std.mem.eql(u8, text, "observe")) return .observe;
    if (std.mem.eql(u8, text, "scan")) return .scan;
    if (std.mem.eql(u8, text, "connect")) return .connect;
    if (std.mem.eql(u8, text, "pull")) return .pull;
    if (std.mem.eql(u8, text, "enum") or std.mem.eql(u8, text, "enumerate")) return .enumerate;
    if (std.mem.eql(u8, text, "smoke")) return .smoke;

    return null;
}

pub fn parse_mac(text: []const u8) !u64 {
    var address: u64 = 0;
    var octets: u32 = 0;
    var iterator = std.mem.tokenizeScalar(u8, text, ':');

    while (iterator.next()) |part| {
        assert(octets <= mac_octets_max);

        if (octets >= mac_octets_max) return error.BadMac;
        address = (address << 8) | try std.fmt.parseInt(u8, part, 16);
        octets += 1;
    }

    if (octets != 6) return error.BadMac;
    return address;
}

test "parse_mac parses six colon-separated hex octets" {
    try std.testing.expectEqual(@as(u64, 0xA1B2C3D4E5F6), try parse_mac("A1:B2:C3:D4:E5:F6"));
    try std.testing.expectEqual(@as(u64, 0x000000000001), try parse_mac("00:00:00:00:00:01"));
}

test "parse_mac rejects the wrong octet count" {
    try std.testing.expectError(error.BadMac, parse_mac("A1:B2:C3"));
    try std.testing.expectError(error.BadMac, parse_mac("A1:B2:C3:D4:E5:F6:07"));
}

test "parse_command maps keywords and treats a MAC as no command" {
    try std.testing.expectEqual(Command.observe, parse_command("observe").?);
    try std.testing.expectEqual(Command.scan, parse_command("scan").?);
    try std.testing.expectEqual(Command.enumerate, parse_command("enum").?);
    try std.testing.expectEqual(Command.smoke, parse_command("smoke").?);
    try std.testing.expect(parse_command("A1:B2:C3:D4:E5:F6") == null);
}
