const std = @import("std");

const com = @import("com.zig");
const fake_com = @import("fake_com.zig");
const lock = @import("lock.zig");
const protocol = @import("../../protocol.zig");

const assert = std.debug.assert;

pub const Backend = struct {
    characteristic: *com.IGattCharacteristic,
    value: com.ValueBuffer,

    pub const Error = com.Error;
    pub const State = lock.GFDIState;

    pub fn init(
        backend: *Backend,
        runtime: *com.Runtime,
        characteristic: *com.IGattCharacteristic,
    ) com.Error!void {
        assert(runtime.initialized);

        backend.* = .{
            .characteristic = characteristic,
            .value = try com.ValueBuffer.init(runtime, protocol.multi_link.mtu_write_max),
        };

        assert(backend.value.bytes.len == protocol.multi_link.mtu_write_max);
    }

    pub fn deinit(backend: *Backend) void {
        assert(backend.value.bytes.len == protocol.multi_link.mtu_write_max);

        backend.value.deinit();
    }

    pub fn write_raw(backend: *Backend, bytes: []const u8) Error!void {
        assert(bytes.len >= 2);
        assert(bytes.len <= protocol.multi_link.mtu_write_max);
        assert(bytes.len <= backend.value.bytes.len);

        try backend.value.write(backend.characteristic, bytes);
    }

    pub fn poll(backend: *Backend) void {
        assert(backend.value.bytes.len == protocol.multi_link.mtu_write_max);

        com.messages_pump();
    }
};

test "a backend whose buffer factory is missing reports it and leaves the characteristic alone" {
    var runtime = fake_com.runtime();
    var characteristic: fake_com.Object = .{ .vtable = &fake_com.unknown_slots };
    var backend: Backend = undefined;

    const initialized = backend.init(&runtime, @ptrCast(&characteristic));

    try std.testing.expectError(error.ActivationFactoryMissing, initialized);
    try std.testing.expectEqual(@as(u32, 0), characteristic.acquisitions);
    try std.testing.expectEqual(@as(u32, 0), characteristic.references);
}
