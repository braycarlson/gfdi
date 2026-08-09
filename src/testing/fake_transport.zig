const std = @import("std");

const TransferStatus = @import("../transport/transport.zig").TransferStatus;

const assert = std.debug.assert;

pub const FakeTransport = struct {
    inbound: [inbound_count_max][message_len_max]u8 = undefined,
    inbound_lengths: [inbound_count_max]u32 = undefined,
    inbound_count: u32 = 0,
    inbound_position: u32 = 0,
    sent_count: u32 = 0,
    register_count: u32 = 0,
    start_count: u32 = 0,
    status: TransferStatus = .{
        .ready = false,
        .closed = false,
        .overflow = false,
        .handle = 0,
        .len = 0,
    },
    transfer_data: []const u8 = &.{},

    pub fn queue_inbound(transport: *FakeTransport, message: []const u8) void {
        assert(transport.inbound_count < inbound_count_max);
        assert(message.len <= message_len_max);
        const slot = transport.inbound_count;
        @memcpy(transport.inbound[slot][0..message.len], message);
        transport.inbound_lengths[slot] = @intCast(message.len);
        transport.inbound_count += 1;
    }

    pub fn send(transport: *FakeTransport, message: []const u8) !void {
        _ = message;
        transport.sent_count += 1;
    }

    pub fn register_next_transfer_service(transport: *FakeTransport) !void {
        transport.register_count += 1;
    }

    pub fn start_transfer(transport: *FakeTransport, file_handle: u32) !void {
        _ = file_handle;
        transport.start_count += 1;
    }

    pub fn next_message(transport: *FakeTransport, out: []u8) ?u32 {
        if (transport.inbound_position >= transport.inbound_count) return null;
        const slot = transport.inbound_position;
        const len = transport.inbound_lengths[slot];
        @memcpy(out[0..len], transport.inbound[slot][0..len]);
        transport.inbound_position += 1;
        return len;
    }

    pub fn transfer_status(transport: *FakeTransport) TransferStatus {
        return transport.status;
    }

    pub fn transfer_reset(transport: *FakeTransport) void {
        transport.status = .{
            .ready = false,
            .closed = false,
            .overflow = false,
            .handle = 0,
            .len = 0,
        };
    }

    pub fn transfer_bytes(transport: *FakeTransport, length: u32) []const u8 {
        return transport.transfer_data[0..length];
    }

    pub fn transfer_capacity(transport: *FakeTransport) u32 {
        return @intCast(transport.transfer_data.len);
    }

    pub fn poll(transport: *FakeTransport) void {
        _ = transport;
    }
};

pub const inbound_count_max: u32 = 32;
pub const message_len_max: u32 = 256;
