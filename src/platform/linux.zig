const std = @import("std");

const ble_transport = @import("linux/ble_transport.zig");
const bluez = @import("linux/bluez.zig");
const clock_module = @import("linux/clock.zig");
const dbus = @import("linux/dbus.zig");
const interface = @import("interface.zig");
const lock = @import("linux/lock.zig");
const protocol = @import("../protocol.zig");
const session_module = @import("../session.zig");
const store_module = @import("../store.zig");
const time = @import("linux/time.zig");
const transport = @import("../transport.zig");

const assert = std.debug.assert;

const Clock = clock_module.Clock;
const DiskStore = store_module.DiskStore;
const LinkType = transport.link.LinkType;
const RunnerType = session_module.runner.RunnerType;

const Linux = @This();

client: dbus.Client,
clock: Clock,
failure: interface.Diagnostic,
io: std.Io,
objects: bluez.Objects,
session: Runner.Session,
state: lock.GFDIState,
storage: session_module.StorageType(session_module.capacity_native),
zone: clock_module.Zone,

pub const Options = struct {};

pub const capabilities: interface.Capabilities = .{ .dbus = true };

const BLELink = LinkType(ble_transport.Backend);

const NativeEnvironment = struct {
    pub const Clock = clock_module.Clock;
    pub const FileStore = DiskStore;
    pub const Transport = BLELink;
};

const AdapterError = error{
    NoAdapter,
};

const CommandError = AdapterError || bluez.Error || std.Io.Writer.Error;

const ObserveAttempt = struct {
    address: u64,
    linux: *Linux,
    out: *std.Io.Writer,

    pub const Error = CommandError;

    pub fn once(attempt: *const ObserveAttempt) Error!bool {
        assert(attempt.address >> address_bits == 0);

        return attempt.linux.observe_once(attempt.out, attempt.address);
    }
};

const SystemTime = session_module.runner.SystemTimeType(time);
const Runner = RunnerType(NativeEnvironment, SystemTime);

const address_bits: u6 = 48;
const no_hooks: session_module.runner.NoHooks = .{};
const system_time: SystemTime = .{};
const advertise_wait_ms: u64 = 20000;
const close_all_settle_ms: u32 = 500;
const connect_attempts_max: u32 = 3;
const dbus_path = "/org/freedesktop/DBus";
const dbus_service = "org.freedesktop.DBus";
const resolve_wait_ms: u64 = 20000;
const scan_window_ms: u64 = 8000;
const service_name_bytes_max: u32 = 256;

comptime {
    interface.assert_backend(Linux);

    assert(dbus_service.len > 0);
    assert(dbus_path[0] == '/');
    assert(service_name_bytes_max > bluez.service.len);
    assert(advertise_wait_ms > scan_window_ms);
    assert(resolve_wait_ms > 0);
    assert(connect_attempts_max > 1);
    assert(close_all_settle_ms > 0);
}

pub fn init(linux: *Linux, io: std.Io, options: Options) void {
    _ = options;

    linux.client = .{};
    linux.clock = Clock.init(&linux.zone, io);
    linux.failure = .none;
    linux.io = io;
    linux.objects = .{};
    linux.state = .{};
}

pub fn deinit(linux: *Linux) void {
    assert(linux.objects.devices.count <= bluez.devices_max);

    linux.client.disconnect();

    assert(!linux.client.is_connected());
}

pub fn diagnostic(linux: *const Linux) interface.Diagnostic {
    assert(linux.failure.cause.len <= std.math.maxInt(u16));

    return linux.failure;
}

pub fn observe(linux: *Linux, out: *std.Io.Writer, address: u64) interface.Error!void {
    assert(address >> address_bits == 0);
    assert(!linux.client.is_connected());

    linux.observe_attempts(out, address) catch |err| return linux.failed(err);
}

pub fn enumerate(linux: *Linux, out: *std.Io.Writer) interface.Error!void {
    assert(!linux.client.is_connected());
    assert(linux.objects.devices.count <= bluez.devices_max);

    linux.enumerate_devices(out) catch |err| return linux.failed(err);
}

pub fn scan(linux: *Linux, out: *std.Io.Writer) interface.Error!void {
    assert(!linux.client.is_connected());
    assert(linux.objects.devices.count <= bluez.devices_max);

    linux.scan_advertisers(out) catch |err| return linux.failed(err);
}

pub fn connect(linux: *Linux, out: *std.Io.Writer, address: u64) interface.Error!void {
    assert(address >> address_bits == 0);
    assert(!linux.client.is_connected());

    linux.connect_services(out, address) catch |err| return linux.failed(err);
}

pub fn pull(linux: *Linux, out: *std.Io.Writer, address: u64) interface.Error!void {
    assert(address >> address_bits == 0);
    assert(!linux.client.is_connected());

    linux.pull_characteristics(out, address) catch |err| return linux.failed(err);
}

pub fn smoke(linux: *Linux, out: *std.Io.Writer) interface.Error!void {
    assert(!linux.client.is_connected());
    assert(linux.objects.devices.count <= bluez.devices_max);

    linux.smoke_bus(out) catch |err| return linux.failed(err);
}

fn failed(linux: *Linux, err: CommandError) interface.Error {
    linux.failure = .{ .cause = @errorName(err) };

    const result: interface.Error = switch (err) {
        error.WriteFailed => error.WriteFailed,
        error.NoAdapter => error.AdapterMissing,
        error.AddressUnsupported,
        error.AuthenticationFailed,
        error.ConnectFailed,
        error.HelloFailed,
        => error.RuntimeUnavailable,
        else => error.BluetoothFailed,
    };

    assert((result == error.WriteFailed) == (err == error.WriteFailed));
    assert((result == error.AdapterMissing) == (err == error.NoAdapter));

    return result;
}

fn observe_attempts(linux: *Linux, out: *std.Io.Writer, address: u64) !void {
    assert(address >> address_bits == 0);
    assert(!linux.client.is_connected());

    try linux.client.connect();
    defer linux.client.disconnect();

    try bluez.subscribe(&linux.client);

    const attempt = ObserveAttempt{ .address = address, .linux = linux, .out = out };

    try Runner.attempts_run(ObserveAttempt, &attempt, out, &system_time);
}

fn observe_once(linux: *Linux, out: *std.Io.Writer, address: u64) !bool {
    assert(address >> address_bits == 0);
    assert(linux.client.is_connected());

    const adapter = try linux.adapter_open();

    var buffer: [bluez.path_bytes_max]u8 = undefined;
    const path = bluez.device_path(&buffer, adapter.slice(), address);

    if (!try linux.device_open(out, path, address)) return false;
    defer linux.device_disconnect(out, path);

    const service_uuid = protocol.multi_link.uuid_text(protocol.multi_link.service_uuid);

    const service = linux.objects.find_service(.{ .device = path, .uuid = service_uuid }) orelse {
        try out.print("Multi-Link service 6a4e2800 not found.\n", .{});
        try out.flush();

        return false;
    };

    linux.state = .{};
    linux.state.transfer_buffer = &linux.storage.transfer;

    var subscriptions: ble_transport.Subscriptions = .empty;

    try linux.notifications_subscribe(out, service.path.slice(), &subscriptions);
    defer linux.notifications_unsubscribe(out, &subscriptions);

    return linux.observe_pump(out, service.path.slice(), &subscriptions);
}

fn observe_pump(
    linux: *Linux,
    out: *std.Io.Writer,
    service_path: []const u8,
    subscriptions: *const ble_transport.Subscriptions,
) !bool {
    assert(service_path.len > 0);
    assert(linux.client.is_connected());

    const send_uuid = protocol.multi_link.uuid_text(protocol.multi_link.send_uuid);

    const characteristic = linux.objects.find_characteristic(.{
        .service = service_path,
        .uuid = send_uuid,
    }) orelse {
        try out.print("Multi-Link send characteristic 6a4e2820 not found.\n", .{});
        try out.flush();

        return false;
    };

    const write_kind: bluez.Write.Kind = if (characteristic.flags.write_without_response)
        .command
    else
        .request;

    var backend = ble_transport.Backend{
        .characteristic = characteristic.path,
        .client = &linux.client,
        .objects = &linux.objects,
        .state = &linux.state,
        .subscriptions = subscriptions,
        .write_kind = write_kind,
    };

    try multi_link_register_gfdi(&backend, out);

    var link = BLELink{ .backend = &backend, .state = &linux.state, .transfer_service_index = 0 };

    const storage = linux.storage.slices();

    linux.session.init(&storage, &link, out, linux.clock, .{ .io = linux.io });

    try Runner.pump_run(session_module.runner.NoHooks, &no_hooks, &linux.session, &system_time);
    try report_drops(&linux.client, out);

    return linux.session.archive.complete;
}

fn report_drops(client: *const dbus.Client, out: *std.Io.Writer) !void {
    assert(client.is_connected());

    const drops = client.pending_drops();
    if (drops == 0) return;

    try out.print("note: {d} D-Bus signal(s) dropped while awaiting replies\n", .{drops});
}

fn notifications_subscribe(
    linux: *Linux,
    out: *std.Io.Writer,
    owner: []const u8,
    subscriptions: *ble_transport.Subscriptions,
) !void {
    assert(owner.len > 0);
    assert(subscriptions.paths.count == 0);

    for (linux.objects.characteristics.slice()) |*characteristic| {
        if (!std.mem.eql(u8, characteristic.service.slice(), owner)) continue;
        if (!characteristic.flags.notify) continue;

        const path = characteristic.path.slice();

        bluez.start_notify(&linux.client, path) catch |err| {
            try out.print("StartNotify {s} failed: {s}\n", .{ path, @errorName(err) });

            continue;
        };

        if (!subscriptions.add(path)) continue;

        try out.print("subscribed {s}\n", .{characteristic.uuid.slice()});
    }

    try out.flush();
}

fn notifications_unsubscribe(
    linux: *Linux,
    out: *std.Io.Writer,
    subscriptions: *const ble_transport.Subscriptions,
) void {
    assert(subscriptions.paths.count <= ble_transport.subscriptions_max);
    assert(linux.client.is_connected());

    for (subscriptions.paths.slice()) |*path| {
        bluez.stop_notify(&linux.client, path.slice()) catch |err| {
            out.print("StopNotify failed: {s}\n", .{@errorName(err)}) catch return;
        };
    }
}

fn device_disconnect(linux: *Linux, out: *std.Io.Writer, path: []const u8) void {
    assert(path.len > 0);
    assert(linux.client.is_connected());

    bluez.device_disconnect(&linux.client, path) catch |err| {
        out.print("Disconnect failed: {s}\n", .{@errorName(err)}) catch return;
    };
}

fn multi_link_register_gfdi(backend: *ble_transport.Backend, out: *std.Io.Writer) !void {
    assert(backend.characteristic.slice().len > 0);

    backend.write_raw(&protocol.multi_link.close_all_frame) catch |err| {
        try out.print("CLOSE_ALL write failed: {s}\n", .{@errorName(err)});
    };

    try out.print("sent CLOSE_ALL_REQ.\n", .{});
    try out.flush();

    time.sleep_ms(close_all_settle_ms);

    backend.write_raw(&protocol.multi_link.register_gfdi_frame) catch |err| {
        try out.print("REGISTER write failed: {s}\n", .{@errorName(err)});
    };

    try out.print("sent REGISTER_ML_REQ(GFDI).\n", .{});
    try out.flush();
}

fn enumerate_devices(linux: *Linux, out: *std.Io.Writer) !void {
    assert(!linux.client.is_connected());

    try linux.client.connect();
    defer linux.client.disconnect();

    try bluez.refresh(&linux.client, &linux.objects);
    try out.print("BLE devices known to BlueZ: {d}\n", .{linux.objects.devices.count});

    for (linux.objects.devices.slice(), 0..) |*device, index| {
        try out.print("  [{d}] {s}\n        {s}\n", .{
            index,
            device.name.slice(),
            device.path.slice(),
        });
    }
}

fn scan_advertisers(linux: *Linux, out: *std.Io.Writer) !void {
    assert(!linux.client.is_connected());

    try linux.client.connect();
    defer linux.client.disconnect();

    try bluez.subscribe(&linux.client);

    const adapter = try linux.adapter_open();

    try out.print("Scanning BLE for {d}s (active)...\n", .{@divFloor(scan_window_ms, 1000)});
    try out.flush();

    try linux.discover(out, adapter, .{ .target = null, .window_ms = scan_window_ms });
    try out.print("Advertisers seen: {d}\n", .{linux.objects.devices.count});

    for (linux.objects.devices.slice()) |*device| {
        try out.print("  {s}  {s}\n", .{ device.address.slice(), device.name.slice() });
    }
}

fn connect_services(linux: *Linux, out: *std.Io.Writer, address: u64) !void {
    assert(address >> address_bits == 0);
    assert(!linux.client.is_connected());

    try linux.client.connect();
    defer linux.client.disconnect();

    try bluez.subscribe(&linux.client);

    const adapter = try linux.adapter_open();

    var buffer: [bluez.path_bytes_max]u8 = undefined;
    const path = bluez.device_path(&buffer, adapter.slice(), address);

    var text: [bluez.address_bytes_max]u8 = undefined;

    try out.print("connecting to {s} ...\n", .{bluez.format_address(&text, address)});
    try out.flush();

    if (!try linux.device_open(out, path, address)) return;

    try linux.services_print(out, .{ .characteristics = .hidden, .device = path });
}

fn pull_characteristics(linux: *Linux, out: *std.Io.Writer, address: u64) !void {
    assert(address >> address_bits == 0);
    assert(!linux.client.is_connected());

    try linux.client.connect();
    defer linux.client.disconnect();

    try bluez.subscribe(&linux.client);

    const adapter = try linux.adapter_open();

    var text: [bluez.address_bytes_max]u8 = undefined;

    try out.print("waiting for watch {s} to advertise (up to {d}s)...\n", .{
        bluez.format_address(&text, address),
        @divFloor(advertise_wait_ms, 1000),
    });

    try out.flush();
    try linux.discover(out, adapter, .{ .target = address, .window_ms = advertise_wait_ms });

    var buffer: [bluez.path_bytes_max]u8 = undefined;
    const path = bluez.device_path(&buffer, adapter.slice(), address);

    if (linux.objects.find_device(path) == null) {
        try out.print(
            "watch not seen advertising. Phone Bluetooth off + watch in Pair-Phone mode?\n",
            .{},
        );

        return out.flush();
    }

    try out.print("watch advertising; connecting...\n", .{});
    try out.flush();

    if (!try linux.device_open(out, path, address)) return;

    try linux.services_print(out, .{ .characteristics = .shown, .device = path });
}

fn smoke_bus(linux: *Linux, out: *std.Io.Writer) !void {
    assert(!linux.client.is_connected());

    try linux.client.connect();
    defer linux.client.disconnect();

    assert(linux.client.is_connected());

    try out.print("D-Bus OK (system bus connected, EXTERNAL authentication ok).\n", .{});
    try out.print("unique name: {s}\n", .{linux.client.name()});

    var storage: [service_name_bytes_max]u8 = undefined;

    const owner = name_owner(&linux.client, &storage, bluez.service) catch |err| {
        return out.print("{s} has no owner ({s}); is bluetoothd running?\n", .{
            bluez.service,
            @errorName(err),
        });
    };

    try out.print("{s} owner: {s}\n", .{ bluez.service, owner });
}

fn name_owner(client: *dbus.Client, storage: []u8, service: []const u8) ![]const u8 {
    assert(service.len > 0);
    assert(storage.len >= service_name_bytes_max);

    var writer = dbus.wire.Writer.init(storage);

    try writer.put_string(service);

    const reply = try client.call(writer.bytes(), .{
        .destination = dbus_service,
        .interface = dbus_service,
        .member = "GetNameOwner",
        .path = dbus_path,
        .signature = "s",
    });

    var reader = dbus.wire.Reader.init(reply.body);

    return reader.take_string();
}

fn adapter_open(linux: *Linux) !bluez.Path {
    assert(linux.client.is_connected());

    try bluez.refresh(&linux.client, &linux.objects);

    if (linux.objects.adapter.count() == 0) return error.NoAdapter;
    return linux.objects.adapter;
}

const Discovery = struct {
    target: ?u64,
    window_ms: u64,
};

fn discover(
    linux: *Linux,
    out: *std.Io.Writer,
    adapter: bluez.Path,
    discovery: Discovery,
) !void {
    assert(discovery.window_ms > 0);
    assert(adapter.count() > 0);

    bluez.set_discovery_filter(&linux.client, adapter.slice()) catch |err| {
        try out.print("discovery filter rejected ({s}); scanning without it.\n", .{
            @errorName(err),
        });
    };

    try bluez.start_discovery(&linux.client, adapter.slice());
    defer linux.discovery_stop(out, adapter);

    var buffer: [bluez.path_bytes_max]u8 = undefined;

    const path: ?[]const u8 = if (discovery.target) |target|
        bluez.device_path(&buffer, adapter.slice(), target)
    else
        null;

    const deadline = time.now_ms() + discovery.window_ms;

    for (0..discovery.window_ms) |_| {
        if (time.now_ms() >= deadline) break;

        linux.pump_until(deadline);

        const wanted = path orelse continue;
        if (linux.objects.find_device(wanted) != null) return;
    }
}

fn pump_until(linux: *Linux, deadline_ms: u64) void {
    assert(deadline_ms > 0);
    assert(linux.client.is_connected());

    const slice_end = @min(deadline_ms, time.now_ms() + bluez.pump_poll_ms);

    bluez.pump(&linux.client, &linux.objects, slice_end, bluez.NoNotify, &.{});
}

fn discovery_stop(linux: *Linux, out: *std.Io.Writer, adapter: bluez.Path) void {
    assert(adapter.count() > 0);
    assert(linux.client.is_connected());

    bluez.stop_discovery(&linux.client, adapter.slice()) catch |err| {
        out.print("StopDiscovery failed: {s}\n", .{@errorName(err)}) catch return;
    };
}

fn device_remove(linux: *Linux, out: *std.Io.Writer, path: []const u8) void {
    assert(path.len > 0);
    assert(linux.objects.adapter.count() > 0);

    bluez.remove_device(&linux.client, .{
        .adapter = linux.objects.adapter.slice(),
        .device = path,
    }) catch |err| {
        out.print("RemoveDevice failed: {s}\n", .{@errorName(err)}) catch return;
    };
}

fn device_open(linux: *Linux, out: *std.Io.Writer, path: []const u8, address: u64) !bool {
    assert(path.len > 0);
    assert(address >> address_bits == 0);

    for (0..connect_attempts_max) |attempt| {
        if (attempt > 0) try linux.device_recover(out, path, .{
            .address = address,
            .attempt = @intCast(attempt),
        });

        bluez.device_connect(&linux.client, path) catch |err| {
            try out.print("connect failed ({s}: {s}).\n", .{
                @errorName(err),
                linux.client.error_name_last(),
            });

            try out.flush();

            continue;
        };

        if (try linux.device_resolved(path)) return true;

        try out.print("services did not resolve; retrying.\n", .{});
        try out.flush();
    }

    try out.print("connect failed after {d} attempts.\n", .{connect_attempts_max});
    try out.flush();

    return false;
}

const Recovery = struct {
    address: u64,
    attempt: u32,
};

fn device_recover(
    linux: *Linux,
    out: *std.Io.Writer,
    path: []const u8,
    recovery: Recovery,
) !void {
    assert(path.len > 0);
    assert(recovery.attempt > 0);
    assert(recovery.attempt < connect_attempts_max);

    if (recovery.attempt > 1) linux.device_remove(out, path);

    try linux.discover(out, linux.objects.adapter, .{
        .target = recovery.address,
        .window_ms = advertise_wait_ms,
    });
}

fn device_resolved(linux: *Linux, path: []const u8) !bool {
    assert(path.len > 0);
    assert(linux.client.is_connected());

    const deadline = time.now_ms() + resolve_wait_ms;

    for (0..resolve_wait_ms) |_| {
        if (time.now_ms() >= deadline) break;

        linux.pump_until(deadline);

        const device = linux.objects.find_device(path) orelse continue;
        if (device.resolved) break;
    }

    try bluez.refresh(&linux.client, &linux.objects);

    const device = linux.objects.find_device(path) orelse return false;

    return device.resolved;
}

const Listing = struct {
    characteristics: Visibility,
    device: []const u8,

    const Visibility = enum {
        hidden,
        shown,
    };
};

fn services_print(linux: *const Linux, out: *std.Io.Writer, listing: Listing) !void {
    assert(listing.device.len > 0);
    assert(linux.objects.services.count <= bluez.services_max);

    var count: u32 = 0;

    for (linux.objects.services.slice()) |*service| {
        if (std.mem.eql(u8, service.device.slice(), listing.device)) count += 1;
    }

    try out.print("GATT services: {d}\n", .{count});

    for (linux.objects.services.slice()) |*service| {
        if (!std.mem.eql(u8, service.device.slice(), listing.device)) continue;

        try out.print("  {s}\n", .{service.uuid.slice()});

        switch (listing.characteristics) {
            .hidden => {},
            .shown => try linux.characteristics_print(out, service.path.slice()),
        }
    }
}

fn characteristics_print(linux: *const Linux, out: *std.Io.Writer, owner: []const u8) !void {
    assert(owner.len > 0);
    assert(linux.objects.characteristics.count <= bluez.characteristics_max);

    for (linux.objects.characteristics.slice()) |*characteristic| {
        if (!std.mem.eql(u8, characteristic.service.slice(), owner)) continue;

        try out.print("      characteristic {s} [", .{characteristic.uuid.slice()});

        if (characteristic.flags.read) try out.print("R", .{});
        if (characteristic.flags.write_without_response) try out.print("w", .{});
        if (characteristic.flags.write) try out.print("W", .{});
        if (characteristic.flags.notify) try out.print("N", .{});
        if (characteristic.flags.indicate) try out.print("I", .{});

        try out.print("]\n", .{});
    }
}

const testing = std.testing;

test {
    _ = @import("linux/ble_transport.zig");
    _ = @import("linux/bluez.zig");
    _ = @import("linux/clock.zig");
    _ = @import("linux/dbus.zig");
    _ = @import("linux/dbus/client.zig");
    _ = @import("linux/lock.zig");
    _ = @import("linux/sys.zig");
    _ = @import("linux/time.zig");
}

test "the multi-link UUIDs render in the lowercase form BlueZ reports" {
    try testing.expectEqualStrings(
        "6a4e2800-667b-11e3-949a-0800200c9a66",
        protocol.multi_link.uuid_text(protocol.multi_link.service_uuid),
    );

    try testing.expectEqualStrings(
        "6a4e2820-667b-11e3-949a-0800200c9a66",
        protocol.multi_link.uuid_text(protocol.multi_link.send_uuid),
    );
}

test "a failure maps to the error a caller can act on and keeps its cause" {
    const linux = try testing.allocator.create(Linux);
    defer testing.allocator.destroy(linux);

    linux.failure = .none;

    try testing.expectEqual(error.AdapterMissing, linux.failed(error.NoAdapter));
    try testing.expectEqualStrings("NoAdapter", linux.diagnostic().cause);
    try testing.expectEqual(error.RuntimeUnavailable, linux.failed(error.ConnectFailed));
    try testing.expectEqual(error.WriteFailed, linux.failed(error.WriteFailed));
    try testing.expectEqual(error.BluetoothFailed, linux.failed(error.ReplyTimeout));
    try testing.expectEqualStrings("ReplyTimeout", linux.diagnostic().cause);
    try testing.expectEqual(error.RuntimeUnavailable, linux.failed(error.HelloFailed));
    try testing.expectEqual(error.RuntimeUnavailable, linux.failed(error.AddressUnsupported));
    try testing.expectEqual(error.RuntimeUnavailable, linux.failed(error.AuthenticationFailed));
    try testing.expectEqualStrings("AuthenticationFailed", linux.diagnostic().cause);
    try testing.expectEqual(error.BluetoothFailed, linux.failed(error.Malformed));
    try testing.expectEqual(error.BluetoothFailed, linux.failed(error.TooLarge));
}
