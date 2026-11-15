const std = @import("std");

const bounded = @import("bounded");

const bluez = @import("bluez.zig");
const dbus = @import("dbus.zig");
const lock = @import("lock.zig");
const protocol = @import("../../protocol.zig");
const transport = @import("../../transport.zig");

const assert = std.debug.assert;

pub const subscriptions_max: u32 = 32;

comptime {
    assert(subscriptions_max > 0);
}

pub const Subscriptions = struct {
    paths: bounded.ArrayType(bluez.Path, subscriptions_max),

    pub const empty: Subscriptions = .{ .paths = .empty };

    pub fn add(subscriptions: *Subscriptions, path: []const u8) bool {
        assert(path.len > 0);
        assert(subscriptions.paths.count <= subscriptions_max);

        if (path.len > bluez.path_bytes_max) return false;
        if (subscriptions.paths.full()) return false;

        const slot = subscriptions.paths.push_slot_assume_capacity();

        slot.* = .empty;
        slot.array.push_slice_assume_capacity(path);

        assert(subscriptions.contains(path));

        return true;
    }

    pub fn contains(subscriptions: *const Subscriptions, path: []const u8) bool {
        assert(path.len > 0);
        assert(subscriptions.paths.count <= subscriptions_max);

        for (subscriptions.paths.slice()) |*subscribed| {
            if (std.mem.eql(u8, subscribed.slice(), path)) return true;
        }

        return false;
    }
};

const Sink = struct {
    state: *lock.GFDIState,
    subscriptions: *const Subscriptions,

    pub fn on_properties(sink: *const Sink, change: *const bluez.PropertiesChanged) void {
        assert(change.path.len > 0);
        assert(sink.subscriptions.paths.count <= subscriptions_max);

        if (!sink.subscriptions.contains(change.path)) return;

        const bytes = bluez.notification_bytes(change.body) orelse return;
        if (bytes.len == 0) return;

        transport.link.route_frame(lock.GFDIState, sink.state, bytes);
    }
};

pub const Backend = struct {
    characteristic: bluez.Path,
    client: *dbus.Client,
    objects: *bluez.Objects,
    state: *lock.GFDIState,
    subscriptions: *const Subscriptions,
    write_kind: bluez.Write.Kind,

    pub const Error = bluez.Error;
    pub const State = lock.GFDIState;

    pub fn write_raw(backend: *Backend, bytes: []const u8) Error!void {
        assert(bytes.len > 0);
        assert(bytes.len <= protocol.multi_link.mtu_write_max);

        try bluez.write_value(backend.client, &.{
            .bytes = bytes,
            .kind = backend.write_kind,
            .path = backend.characteristic.slice(),
        });
    }

    pub fn poll(backend: *Backend) void {
        assert(backend.characteristic.count() > 0);
        assert(backend.subscriptions.paths.count <= subscriptions_max);

        const sink = Sink{ .state = backend.state, .subscriptions = backend.subscriptions };

        bluez.drain(backend.client, backend.objects, Sink, &sink);
    }
};

const testing = std.testing;

test Subscriptions {
    var subscriptions: Subscriptions = .empty;

    try testing.expect(subscriptions.add("/org/bluez/hci0/dev_A/service01/char02"));
    try testing.expect(subscriptions.contains("/org/bluez/hci0/dev_A/service01/char02"));
    try testing.expect(!subscriptions.contains("/org/bluez/hci0/dev_A/service01/char03"));

    for (1..subscriptions_max) |_| {
        try testing.expect(subscriptions.add("/org/bluez/hci0/dev_A/service01/charFF"));
    }

    try testing.expectEqual(subscriptions_max, subscriptions.paths.count);
    try testing.expect(!subscriptions.add("/org/bluez/hci0/dev_A/service01/charEE"));
}
