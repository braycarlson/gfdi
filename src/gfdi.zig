const std = @import("std");

const platform = @import("platform.zig");
const session = @import("session.zig");

const assert = std.debug.assert;

pub const AddressError = platform.interface.AddressError;
pub const Command = platform.interface.Command;
pub const Diagnostic = platform.interface.Diagnostic;
pub const Error = platform.interface.Error || AddressError;
pub const Fake = platform.Fake;
pub const Native = platform.Native;
pub const SystemError = platform.interface.SystemError;

pub const address_parse = platform.interface.address_parse;

pub fn message(err: Error) []const u8 {
    return switch (err) {
        error.AdapterMissing => "no Bluetooth adapter is present or powered",
        error.AddressInvalid => "the address is not six hexadecimal octets separated by colons",
        error.BluetoothFailed => "the operating system Bluetooth stack failed a request",
        error.RuntimeUnavailable => "the Bluetooth runtime cannot be reached",
        error.WriteFailed => "the output could not be written",
    };
}

pub const limits = struct {
    pub const archive_index_max: u32 = session.archive_index_last;
    pub const attempts_max: u32 = session.runner.attempts_max;
    pub const file_bytes_max: u32 = session.legacy_buffer_max;
    pub const transfer_bytes_max: u32 = session.capacity_native.transfer_bytes_max;
};

test message {
    const names = @typeInfo(Error).error_set.error_names.?;

    inline for (names) |name| {
        const text = message(@field(Error, name));

        try std.testing.expect(text.len > 0);
        try std.testing.expect(std.mem.findScalar(u8, text, '\n') == null);

        inline for (names) |other| {
            const same = comptime std.mem.eql(u8, name, other);

            try std.testing.expect(same == std.mem.eql(u8, text, message(@field(Error, other))));
        }
    }

    try std.testing.expectEqualStrings(
        "the output could not be written",
        message(error.WriteFailed),
    );
}

test Fake {
    var buffer: [256]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);

    const fake = try std.testing.allocator.create(Fake);
    defer std.testing.allocator.destroy(fake);

    const address = try address_parse("A1:B2:C3:D4:E5:F6");

    fake.init(std.testing.io, .{ .address = address, .files = &.{}, .name = "Forerunner" });
    defer fake.deinit();

    try fake.smoke(&out);

    try std.testing.expect(std.mem.find(u8, out.buffered(), "OK") != null);
    try std.testing.expectEqual(@as(u32, 1), fake.calls.get(.smoke));
    try std.testing.expectEqualStrings(Diagnostic.none.cause, fake.diagnostic().cause);
}

test Native {
    const options: Native.Options = .{};
    const native = try std.testing.allocator.create(Native);
    defer std.testing.allocator.destroy(native);

    native.init(std.testing.io, options);
    defer native.deinit();

    try std.testing.expectEqualStrings(Diagnostic.none.cause, native.diagnostic().cause);
}

test limits {
    try std.testing.expect(limits.file_bytes_max > limits.transfer_bytes_max);
    try std.testing.expect(limits.archive_index_max > 0);
}
