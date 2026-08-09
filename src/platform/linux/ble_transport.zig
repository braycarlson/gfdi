const std = @import("std");

const bluez = @import("bluez.zig");
const link = @import("../../transport/link.zig");
const lock = @import("lock.zig");
const multi_link = @import("../../protocol/multi_link.zig");

const assert = std.debug.assert;

pub const subscriptions_max: u32 = 32;

comptime {
    assert(subscriptions_max > 0);
}

pub const Subscriptions = struct {
    count: u32 = 0,
    paths: [subscriptions_max]bluez.Path = undefined,

    pub fn add(subscriptions: *Subscriptions, path: []const u8) bool {
        assert(path.len > 0);

        if (subscriptions.count == subscriptions_max) return false;

        const slot = subscriptions.count;

        subscriptions.paths[slot] = .{};
        subscriptions.paths[slot].set(path);
        subscriptions.count += 1;

        assert(subscriptions.count <= subscriptions_max);

        return true;
    }

    pub fn contains(subscriptions: *const Subscriptions, path: []const u8) bool {
        var index: u32 = 0;

        while (index < subscriptions.count) : (index += 1) {
            if (subscriptions.paths[index].eql(path)) return true;
        }

        return false;
    }
};

const Sink = struct {
    state: *lock.GFDIState,
    subscriptions: *const Subscriptions,

    pub fn on_properties(sink: Sink, path: []const u8, body: []const u8) void {
        if (!sink.subscriptions.contains(path)) return;

        const bytes = bluez.notification_bytes(body) orelse return;

        if (bytes.len == 0) return;

        link.route_frame(sink.state, bytes);
    }
};

pub const Backend = struct {
    command: bool,
    objects: *bluez.Objects,
    state: *lock.GFDIState,
    subscriptions: *const Subscriptions,
    tx: bluez.Path,

    pub const State = lock.GFDIState;

    pub fn write_raw(backend: *Backend, bytes: []const u8) !void {
        assert(bytes.len > 0);
        assert(bytes.len <= multi_link.mtu_write_max);

        try bluez.write_value(backend.tx.slice(), bytes, backend.command);
    }

    pub fn poll(backend: *Backend) void {
        bluez.drain(backend.objects, Sink{
            .state = backend.state,
            .subscriptions = backend.subscriptions,
        }) catch return;
    }
};

const testing = std.testing;

test "a subscription table answers membership and refuses to overflow" {
    var subscriptions = Subscriptions{};

    try testing.expect(subscriptions.add("/org/bluez/hci0/dev_A/service01/char02"));
    try testing.expect(subscriptions.contains("/org/bluez/hci0/dev_A/service01/char02"));
    try testing.expect(!subscriptions.contains("/org/bluez/hci0/dev_A/service01/char03"));

    var index: u32 = 1;

    while (index < subscriptions_max) : (index += 1) {
        try testing.expect(subscriptions.add("/org/bluez/hci0/dev_A/service01/charFF"));
    }

    try testing.expectEqual(subscriptions_max, subscriptions.count);
    try testing.expect(!subscriptions.add("/org/bluez/hci0/dev_A/service01/charEE"));
}
