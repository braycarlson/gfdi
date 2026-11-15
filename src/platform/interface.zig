const std = @import("std");

const assert = std.debug.assert;

const Writer = std.Io.Writer;

pub const Command = enum {
    connect,
    enumerate,
    observe,
    pull,
    scan,
    smoke,

    pub fn addressed(command: Command) bool {
        const result = switch (command) {
            .connect, .observe, .pull => true,
            .enumerate, .scan, .smoke => false,
        };

        assert(result == (command == .connect or command == .observe or command == .pull));

        return result;
    }
};

pub const Diagnostic = struct {
    cause: []const u8,

    pub const none: Diagnostic = .{ .cause = "" };
};

pub const AddressError = error{AddressInvalid};

pub const Capabilities = struct {
    dbus: bool,
};

pub const SystemError = error{
    AdapterMissing,
    BluetoothFailed,
    RuntimeUnavailable,
};

pub const Error = SystemError || Writer.Error;

pub const address_octet_count: u32 = 6;
pub const address_text_bytes: u32 = address_octet_count * 3 - 1;

comptime {
    assert(address_text_bytes == 17);
    assert(@typeInfo(Command).@"enum".field_names.len == 6);
}

pub fn address_parse(text: []const u8) AddressError!u64 {
    if (text.len != address_text_bytes) return error.AddressInvalid;

    var result: u64 = 0;

    for (0..address_octet_count) |octet| {
        const start = octet * 3;

        if (octet > 0) {
            if (text[start - 1] != ':') return error.AddressInvalid;
        }

        const digits = text[start..][0..2];
        const value = std.fmt.parseUnsigned(u8, digits, 16) catch return error.AddressInvalid;

        result = (result << 8) | value;
    }

    assert(result >> (address_octet_count * 8) == 0);

    return result;
}

pub fn assert_backend(comptime Backend: type) void {
    comptime {
        assert(@typeInfo(Backend) == .@"struct");

        require(Backend, "Options", type);
        require(Backend, "capabilities", Capabilities);
        require(Backend, "init", fn (*Backend, std.Io, Backend.Options) void);
        require(Backend, "deinit", fn (*Backend) void);
        require(Backend, "diagnostic", fn (*const Backend) Diagnostic);

        for (std.enums.values(Command)) |command| {
            const Expected = if (command.addressed())
                fn (*Backend, *Writer, u64) Error!void
            else
                fn (*Backend, *Writer) Error!void;

            require(Backend, @tagName(command), Expected);
        }
    }
}

fn require(comptime Backend: type, comptime name: []const u8, comptime Expected: type) void {
    comptime assert(name.len > 0);

    if (!@hasDecl(Backend, name)) {
        @compileError("gfdi: the backend " ++ @typeName(Backend) ++ " declares no '" ++
            name ++ "'");
    }

    const Actual = if (Expected == type) type else @TypeOf(@field(Backend, name));

    if (Actual != Expected) {
        @compileError("gfdi: the backend " ++ @typeName(Backend) ++ " declares '" ++ name ++
            "' as " ++ @typeName(Actual) ++ " where " ++ @typeName(Expected) ++ " is required");
    }
}

const testing = std.testing;

test address_parse {
    try testing.expectEqual(@as(u64, 0xA1B2C3D4E5F6), try address_parse("A1:B2:C3:D4:E5:F6"));
    try testing.expectEqual(@as(u64, 0x000000000001), try address_parse("00:00:00:00:00:01"));
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFF), try address_parse("ff:ff:ff:ff:ff:ff"));
    try testing.expectError(error.AddressInvalid, address_parse("A1:B2:C3"));
    try testing.expectError(error.AddressInvalid, address_parse("A1:B2:C3:D4:E5:F6:07"));
    try testing.expectError(error.AddressInvalid, address_parse("A1-B2-C3-D4-E5-F6"));
    try testing.expectError(error.AddressInvalid, address_parse("A1:B2:C3:D4:E5:G6"));
    try testing.expectError(error.AddressInvalid, address_parse(""));
}

test "an address renders back to the text it was parsed from" {
    const texts = [_][]const u8{ "00:11:22:33:44:55", "AB:CD:EF:01:23:45", "FF:00:FF:00:FF:00" };

    for (texts) |text| {
        const address = try address_parse(text);

        var buffer: [address_text_bytes]u8 = undefined;

        for (0..address_octet_count) |octet| {
            const shift: u6 = @intCast((address_octet_count - 1 - octet) * 8);
            const value: u8 = @truncate(address >> shift);

            _ = try std.mem.print(buffer[octet * 3 ..][0..2], "{X:0>2}", .{value});

            if (octet + 1 < address_octet_count) buffer[octet * 3 + 2] = ':';
        }

        try testing.expectEqualStrings(text, &buffer);
    }
}

test Command {
    try testing.expect(Command.observe.addressed());
    try testing.expect(Command.connect.addressed());
    try testing.expect(Command.pull.addressed());
    try testing.expect(!Command.scan.addressed());
    try testing.expect(!Command.enumerate.addressed());
    try testing.expect(!Command.smoke.addressed());
}

test assert_backend {
    const Fake = @import("fake.zig");

    assert_backend(Fake);

    try testing.expect(@hasDecl(Fake, "observe"));
    try testing.expect(@hasDecl(Fake, "Options"));
}
