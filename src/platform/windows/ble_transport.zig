const std = @import("std");

const com = @import("com.zig");
const lock = @import("lock.zig");
const multi_link = @import("../../protocol/multi_link.zig");

const assert = std.debug.assert;

pub const Backend = struct {
    runtime: *com.Runtime,
    tx: *com.IGattCharacteristic,

    pub const State = lock.GFDIState;

    pub fn write_raw(backend: *Backend, bytes: []const u8) !void {
        assert(bytes.len > 0);
        assert(bytes.len <= multi_link.mtu_write_max);

        const buffer = try com.make_buffer(backend.runtime, bytes);
        defer _ = com.as_unknown(buffer).release();

        try com.write_characteristic(backend.tx, buffer);
    }

    pub fn poll(backend: *Backend) void {
        _ = backend;

        var message: com.MSG = undefined;

        while (com.PeekMessageW(&message, null, 0, 0, 1) != 0) {
            _ = com.TranslateMessage(&message);
            _ = com.DispatchMessageW(&message);
        }
    }
};
