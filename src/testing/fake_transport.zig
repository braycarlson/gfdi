const std = @import("std");

const bounded = @import("bounded");

const TransferStatus = @import("../transport.zig").TransferStatus;

const assert = std.debug.assert;

pub const FakeTransport = struct {
    dropped_count: u32,
    inbound: bounded.ArrayType(Message, inbound_count_max),
    inbound_position: u32,
    register_count: u32,
    sent_count: u32,
    start_count: u32,
    status: TransferStatus,
    transfer_data: []const u8,

    pub const Error = error{};
    pub const Message = bounded.BufferType(message_length_max);

    pub const empty: FakeTransport = .{
        .dropped_count = 0,
        .inbound = .empty,
        .inbound_position = 0,
        .register_count = 0,
        .sent_count = 0,
        .start_count = 0,
        .status = .idle,
        .transfer_data = &.{},
    };

    pub fn queue_inbound(transport: *FakeTransport, message: []const u8) bounded.Error!void {
        assert(message.len > 0);
        assert(transport.inbound_position <= transport.inbound.count);

        if (message.len > message_length_max) return error.Overflow;

        const slot = try transport.inbound.push_slot();

        slot.* = .empty;

        try slot.set(message);

        assert(slot.count() == message.len);
    }

    pub fn send(transport: *FakeTransport, message: []const u8) Error!void {
        assert(message.len > 0);
        assert(transport.sent_count < std.math.maxInt(u32));

        transport.sent_count += 1;
    }

    pub fn register_next_transfer_service(transport: *FakeTransport) Error!void {
        assert(transport.register_count < std.math.maxInt(u32));

        transport.register_count += 1;
    }

    pub fn start_transfer(transport: *FakeTransport, file_handle: u32) Error!void {
        assert(file_handle <= std.math.maxInt(u16));
        assert(transport.start_count < std.math.maxInt(u32));

        transport.start_count += 1;
    }

    pub fn next_message(transport: *FakeTransport, out: []u8) ?u32 {
        assert(out.len >= message_length_max);
        assert(transport.inbound_position <= transport.inbound.count);

        if (transport.inbound_position == transport.inbound.count) return null;

        const message = transport.inbound.get(transport.inbound_position).slice();

        @memcpy(out[0..message.len], message);

        transport.inbound_position += 1;

        const result: u32 = @intCast(message.len);

        assert(result <= out.len);

        return result;
    }

    pub fn transfer_status(transport: *const FakeTransport) TransferStatus {
        assert(transport.status.length <= transport.transfer_data.len);

        return transport.status;
    }

    pub fn transfer_reset(transport: *FakeTransport) void {
        assert(transport.status.length <= transport.transfer_data.len);

        transport.status = .idle;
    }

    pub fn transfer_bytes(transport: *const FakeTransport, length: u32) []const u8 {
        assert(length <= transport.transfer_data.len);

        return transport.transfer_data[0..length];
    }

    pub fn transfer_capacity(transport: *const FakeTransport) u32 {
        const result: u32 = @intCast(transport.transfer_data.len);

        assert(result == transport.transfer_data.len);

        return result;
    }

    pub fn dropped(transport: *const FakeTransport) u32 {
        assert(transport.inbound_position <= transport.inbound.count);

        return transport.dropped_count;
    }

    pub fn poll(transport: *FakeTransport) void {
        assert(transport.inbound_position <= transport.inbound.count);
    }
};

pub const inbound_count_max: u32 = 64;
pub const message_length_max: u32 = 256;

const testing = std.testing;

test FakeTransport {
    var transport: FakeTransport = .empty;
    var out: [message_length_max]u8 = undefined;

    try transport.queue_inbound("first");
    try transport.queue_inbound("second");

    try testing.expectEqualStrings("first", out[0..transport.next_message(&out).?]);
    try testing.expectEqualStrings("second", out[0..transport.next_message(&out).?]);
    try testing.expect(transport.next_message(&out) == null);

    transport.transfer_data = "abcdef";

    transport.status = .{
        .closed = false,
        .handle = 1,
        .length = 4,
        .overflow = false,
        .ready = true,
    };

    const length = transport.transfer_status().length;

    try testing.expectEqualStrings("abcd", transport.transfer_bytes(length));
    try testing.expectEqual(@as(u32, 6), transport.transfer_capacity());

    transport.transfer_reset();
    transport.dropped_count = 3;

    try testing.expectEqual(TransferStatus.idle, transport.transfer_status());
    try testing.expectEqual(@as(u32, 3), transport.dropped());
}
