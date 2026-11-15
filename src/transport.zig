const std = @import("std");

const assert = std.debug.assert;

pub const link = @import("transport/link.zig");
pub const naming = @import("transport/naming.zig");
pub const reassembly = @import("transport/reassembly.zig");

pub const TransferStatus = struct {
    closed: bool,
    handle: u8,
    length: u32,
    overflow: bool,
    ready: bool,

    pub const idle: TransferStatus = .{
        .closed = false,
        .handle = 0,
        .length = 0,
        .overflow = false,
        .ready = false,
    };
};

const transport_methods = [_][]const u8{
    "dropped",
    "next_message",
    "poll",
    "register_next_transfer_service",
    "send",
    "start_transfer",
    "transfer_bytes",
    "transfer_capacity",
    "transfer_reset",
    "transfer_status",
};

comptime {
    assert(transport_methods.len == 10);
}

pub fn assert_transport(comptime Transport: type) void {
    comptime {
        assert(@typeInfo(Transport) == .@"struct");

        if (!@hasDecl(Transport, "Error")) {
            @compileError("gfdi: the transport " ++ @typeName(Transport) ++ " declares no 'Error'");
        }

        if (@typeInfo(Transport.Error) != .error_set) {
            @compileError("gfdi: the transport " ++ @typeName(Transport) ++
                " declares 'Error' as something other than an error set");
        }

        for (transport_methods) |name| {
            if (!@hasDecl(Transport, name)) {
                @compileError("gfdi: the transport " ++ @typeName(Transport) ++
                    " declares no '" ++ name ++ "'");
            }

            if (@typeInfo(@TypeOf(@field(Transport, name))) != .@"fn") {
                @compileError("gfdi: the transport " ++ @typeName(Transport) ++
                    " declares '" ++ name ++ "' as something other than a function");
            }
        }
    }
}

test assert_transport {
    const FakeTransport = @import("testing/fake_transport.zig").FakeTransport;

    assert_transport(FakeTransport);

    try std.testing.expect(TransferStatus.idle.length == 0);
}
