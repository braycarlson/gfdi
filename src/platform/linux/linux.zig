const std = @import("std");

const ble_transport = @import("ble_transport.zig");
const bluez = @import("bluez.zig");
const client = @import("dbus/client.zig");
const lock = @import("lock.zig");
const multi_link = @import("../../protocol/multi_link.zig");
const time = @import("time.zig");
const wire = @import("dbus/wire.zig");

const link = @import("../../transport/link.zig");
const reassembly = @import("../../transport/reassembly.zig");
const runner = @import("../../session/runner.zig");
const session_module = @import("../../session/session.zig");

const DiskStore = @import("../../store.zig").DiskStore;
const LinuxClock = @import("clock.zig").LinuxClock;

const assert = std.debug.assert;

const dbus_service = "org.freedesktop.DBus";
const dbus_path = "/org/freedesktop/DBus";

const service_name_bytes_max: u32 = 256;

const scan_window_ms: u64 = 8000;
const advertise_wait_ms: u64 = 20000;
const resolve_wait_ms: u64 = 20000;
const connect_attempts_max: u32 = 3;
const close_all_settle_ms: u32 = 500;

const BLELink = link.LinkType(ble_transport.Backend);

const RealEnv = struct {
    pub const Transport = BLELink;
    pub const Clock = LinuxClock;
    pub const FileStore = DiskStore;
};

const Runner = runner.RunnerType(RealEnv, time);

comptime {
    assert(dbus_service.len > 0);
    assert(dbus_path[0] == '/');
    assert(service_name_bytes_max > bluez.service.len);
    assert(advertise_wait_ms > scan_window_ms);
    assert(resolve_wait_ms > 0);
    assert(connect_attempts_max > 1);
    assert(close_all_settle_ms > 0);
}

const ObserveAttempt = struct {
    address: u64,
    buffers: *const runner.Buffers,
    clock: LinuxClock,
    io: std.Io,
    objects: *bluez.Objects,
    out: *std.Io.Writer,
    session: *Runner.Session,
    state: *lock.GFDIState,

    pub fn once(attempt: ObserveAttempt) !bool {
        return observe_once(attempt);
    }
};

pub fn observe(arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, address: u64) !void {
    try client.connect();
    defer client.disconnect();

    try bluez.subscribe();

    const objects = try arena.create(bluez.Objects);
    const state = try arena.create(lock.GFDIState);
    const session = try arena.create(Runner.Session);

    const buffers = runner.Buffers{
        .inflate = try arena.alloc(u8, session_module.inflate_output_max),
        .legacy = try arena.alloc(u8, session_module.legacy_buffer_max),
        .protobuf = try arena.alloc(u8, session_module.protobuf_buffer_max),
        .transfer = try arena.alloc(u8, reassembly.transfer_buffer_max),
    };

    try Runner.run_attempts(out, ObserveAttempt{
        .address = address,
        .buffers = &buffers,
        .clock = LinuxClock.init(arena, io),
        .io = io,
        .objects = objects,
        .out = out,
        .session = session,
        .state = state,
    });
}

fn observe_once(attempt: ObserveAttempt) !bool {
    const objects = attempt.objects;
    const out = attempt.out;
    const state = attempt.state;

    const adapter = try open_adapter(objects);

    var buffer: [bluez.path_bytes_max]u8 = undefined;
    const path = bluez.device_path(&buffer, adapter.slice(), attempt.address);

    if (!try open_device(objects, adapter, path, attempt.address, out)) return false;

    defer disconnect_device(path, out);

    const service_uuid = multi_link.uuid_text(multi_link.service_uuid);

    const service = objects.find_service(path, service_uuid) orelse {
        try out.print("Multi-Link service 6a4e2800 not found.\n", .{});
        try out.flush();
        return false;
    };

    state.* = .{};
    state.transfer_buffer = attempt.buffers.transfer;

    var subscriptions = ble_transport.Subscriptions{};

    try subscribe_notify_characteristics(objects, out, service.path.slice(), &subscriptions);
    defer unsubscribe_all(&subscriptions, out);

    const tx = objects.find_characteristic(
        service.path.slice(),
        multi_link.uuid_text(multi_link.tx_uuid),
    ) orelse {
        try out.print("ML write characteristic 6a4e2820 not found.\n", .{});
        try out.flush();
        return false;
    };

    var backend = ble_transport.Backend{
        .command = tx.flags.write_without_response,
        .objects = objects,
        .state = state,
        .subscriptions = &subscriptions,
        .tx = tx.path,
    };

    try multi_link_register_gfdi(&backend, out);

    var transport = BLELink{ .backend = &backend, .state = state };

    Runner.init_session(
        attempt.session,
        &transport,
        out,
        attempt.clock,
        .{ .io = attempt.io },
        attempt.buffers,
    );

    try Runner.run_pump(out, attempt.session, state, runner.NoHooks{});

    if (client.pending_drops() > 0) try out.print(
        "note: {d} D-Bus signal(s) dropped while awaiting replies\n",
        .{client.pending_drops()},
    );

    return attempt.session.archive.complete;
}

fn subscribe_notify_characteristics(
    objects: *bluez.Objects,
    out: *std.Io.Writer,
    owner: []const u8,
    subscriptions: *ble_transport.Subscriptions,
) !void {
    var index: u32 = 0;

    while (index < objects.characteristic_count) : (index += 1) {
        const characteristic = &objects.characteristics[index];

        if (!characteristic.service.eql(owner)) continue;
        if (!characteristic.flags.notify) continue;

        const path = characteristic.path.slice();

        bluez.start_notify(path) catch |err| {
            try out.print("StartNotify {s} failed: {s}\n", .{ path, @errorName(err) });

            continue;
        };

        if (!subscriptions.add(path)) continue;

        try out.print("subscribed {s}\n", .{characteristic.uuid.slice()});
    }

    try out.flush();
}

fn unsubscribe_all(subscriptions: *const ble_transport.Subscriptions, out: *std.Io.Writer) void {
    var index: u32 = 0;

    while (index < subscriptions.count) : (index += 1) {
        const path = subscriptions.paths[index].slice();

        bluez.stop_notify(path) catch |err| {
            out.print("StopNotify failed: {s}\n", .{@errorName(err)}) catch return;
        };
    }
}

fn disconnect_device(path: []const u8, out: *std.Io.Writer) void {
    bluez.device_disconnect(path) catch |err| {
        out.print("Disconnect failed: {s}\n", .{@errorName(err)}) catch return;
    };
}

fn multi_link_register_gfdi(backend: *ble_transport.Backend, out: *std.Io.Writer) !void {
    backend.write_raw(&multi_link.close_all_frame) catch |err| try out.print(
        "CLOSE_ALL write failed: {s}\n",
        .{@errorName(err)},
    );

    try out.print("sent CLOSE_ALL_REQ.\n", .{});
    try out.flush();
    time.sleep_ms(close_all_settle_ms);

    backend.write_raw(&multi_link.register_gfdi_frame) catch |err| try out.print(
        "REGISTER write failed: {s}\n",
        .{@errorName(err)},
    );

    try out.print("sent REGISTER_ML_REQ(GFDI).\n", .{});
    try out.flush();
}

pub fn enumerate(arena: std.mem.Allocator, out: *std.Io.Writer) !void {
    try client.connect();
    defer client.disconnect();

    const objects = try arena.create(bluez.Objects);

    try bluez.refresh(objects);
    try out.print("BLE devices known to BlueZ: {d}\n", .{objects.device_count});

    var index: u32 = 0;

    while (index < objects.device_count) : (index += 1) {
        const device = &objects.devices[index];

        try out.print("  [{d}] {s}\n        {s}\n", .{
            index,
            device.name.slice(),
            device.path.slice(),
        });
    }
}

pub fn scan(arena: std.mem.Allocator, out: *std.Io.Writer) !void {
    try client.connect();
    defer client.disconnect();

    try bluez.subscribe();

    const objects = try arena.create(bluez.Objects);
    const adapter = try open_adapter(objects);

    try out.print("Scanning BLE for {d}s (active)...\n", .{@divFloor(scan_window_ms, 1000)});
    try out.flush();

    try discover(objects, adapter, out, scan_window_ms, 0);
    try out.print("Advertisers seen: {d}\n", .{objects.device_count});

    var index: u32 = 0;

    while (index < objects.device_count) : (index += 1) {
        const device = &objects.devices[index];

        try out.print("  {s}  {s}\n", .{ device.address.slice(), device.name.slice() });
    }
}

pub fn connect(arena: std.mem.Allocator, out: *std.Io.Writer, address: u64) !void {
    try client.connect();
    defer client.disconnect();

    try bluez.subscribe();

    const objects = try arena.create(bluez.Objects);
    const adapter = try open_adapter(objects);

    var buffer: [bluez.path_bytes_max]u8 = undefined;
    const path = bluez.device_path(&buffer, adapter.slice(), address);

    var text: [bluez.address_bytes_max]u8 = undefined;

    try out.print("connecting to {s} ...\n", .{bluez.format_address(&text, address)});
    try out.flush();

    if (!try open_device(objects, adapter, path, address, out)) return;

    try print_services(objects, out, path, false);
}

pub fn pull(arena: std.mem.Allocator, out: *std.Io.Writer, address: u64) !void {
    try client.connect();
    defer client.disconnect();

    try bluez.subscribe();

    const objects = try arena.create(bluez.Objects);
    const adapter = try open_adapter(objects);

    var text: [bluez.address_bytes_max]u8 = undefined;

    try out.print("waiting for watch {s} to advertise (up to {d}s)...\n", .{
        bluez.format_address(&text, address),
        @divFloor(advertise_wait_ms, 1000),
    });

    try out.flush();
    try discover(objects, adapter, out, advertise_wait_ms, address);

    var buffer: [bluez.path_bytes_max]u8 = undefined;
    const path = bluez.device_path(&buffer, adapter.slice(), address);

    if (objects.find_device(path) == null) {
        try out.print(
            "watch not seen advertising. Phone Bluetooth off + watch in Pair-Phone mode?\n",
            .{},
        );

        try out.flush();
        return;
    }

    try out.print("watch advertising; connecting...\n", .{});
    try out.flush();

    if (!try open_device(objects, adapter, path, address, out)) return;

    try print_services(objects, out, path, true);
}

pub fn smoke(arena: std.mem.Allocator, out: *std.Io.Writer) !void {
    _ = arena;

    try client.connect();
    defer client.disconnect();

    try out.print("D-Bus OK (system bus connected, EXTERNAL auth ok).\n", .{});
    try out.print("unique name: {s}\n", .{client.name()});

    const owner = name_owner(bluez.service) catch |err| {
        try out.print("{s} has no owner ({s}); is bluetoothd running?\n", .{
            bluez.service,
            @errorName(err),
        });

        return;
    };

    try out.print("{s} owner: {s}\n", .{ bluez.service, owner });
}

fn name_owner(service: []const u8) ![]const u8 {
    assert(service.len > 0);

    var storage: [service_name_bytes_max]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    try writer.put_string(service);

    const reply = try client.call(.{
        .destination = dbus_service,
        .interface = dbus_service,
        .member = "GetNameOwner",
        .path = dbus_path,
        .signature = "s",
    }, writer.bytes());

    var reader = wire.Reader.init(reply.body);

    return reader.take_string();
}

fn open_adapter(objects: *bluez.Objects) !bluez.Path {
    try bluez.refresh(objects);

    if (objects.adapter.length == 0) return bluez.Error.NoAdapter;

    return objects.adapter;
}

fn discover(
    objects: *bluez.Objects,
    adapter: bluez.Path,
    out: *std.Io.Writer,
    window_ms: u64,
    target: u64,
) !void {
    bluez.set_discovery_filter(adapter.slice()) catch |err| try out.print(
        "discovery filter rejected ({s}); scanning without it.\n",
        .{@errorName(err)},
    );

    try bluez.start_discovery(adapter.slice());
    defer stop_discovery(adapter, out);

    var buffer: [bluez.path_bytes_max]u8 = undefined;

    const path = if (target == 0)
        ""
    else
        bluez.device_path(&buffer, adapter.slice(), target);

    const deadline = time.now_ms() + window_ms;

    while (time.now_ms() < deadline) {
        try pump_until(objects, deadline);

        if (path.len == 0) continue;
        if (objects.find_device(path) != null) return;
    }
}

fn pump_until(objects: *bluez.Objects, deadline_ms: u64) !void {
    const slice = @min(deadline_ms, time.now_ms() + bluez.pump_poll_ms);

    try bluez.pump(objects, slice, bluez.NoNotify{});
}

fn stop_discovery(adapter: bluez.Path, out: *std.Io.Writer) void {
    bluez.stop_discovery(adapter.slice()) catch |err| {
        out.print("StopDiscovery failed: {s}\n", .{@errorName(err)}) catch return;
    };
}

fn remove_device(adapter: bluez.Path, path: []const u8, out: *std.Io.Writer) void {
    bluez.remove_device(adapter.slice(), path) catch |err| {
        out.print("RemoveDevice failed: {s}\n", .{@errorName(err)}) catch return;
    };
}

fn open_device(
    objects: *bluez.Objects,
    adapter: bluez.Path,
    path: []const u8,
    address: u64,
    out: *std.Io.Writer,
) !bool {
    var attempt: u32 = 0;

    while (attempt < connect_attempts_max) : (attempt += 1) {
        assert(attempt < connect_attempts_max);

        if (attempt > 0) try recover_device(objects, adapter, path, address, attempt, out);

        bluez.device_connect(path) catch |err| {
            try out.print("connect failed ({s}: {s}).\n", .{
                @errorName(err),
                client.last_error_name(),
            });

            try out.flush();
            continue;
        };

        if (try wait_resolved(objects, path)) return true;

        try out.print("services did not resolve; retrying.\n", .{});
        try out.flush();
    }

    try out.print("connect failed after {d} attempts.\n", .{connect_attempts_max});
    try out.flush();

    return false;
}

fn recover_device(
    objects: *bluez.Objects,
    adapter: bluez.Path,
    path: []const u8,
    address: u64,
    attempt: u32,
    out: *std.Io.Writer,
) !void {
    assert(attempt > 0);

    if (attempt > 1) remove_device(adapter, path, out);

    try discover(objects, adapter, out, advertise_wait_ms, address);
}

fn wait_resolved(objects: *bluez.Objects, path: []const u8) !bool {
    const deadline = time.now_ms() + resolve_wait_ms;

    while (time.now_ms() < deadline) {
        try pump_until(objects, deadline);

        const device = objects.find_device(path) orelse continue;

        if (device.resolved) break;
    }

    try bluez.refresh(objects);

    const device = objects.find_device(path) orelse return false;

    return device.resolved;
}

fn print_services(
    objects: *bluez.Objects,
    out: *std.Io.Writer,
    path: []const u8,
    with_characteristics: bool,
) !void {
    var count: u32 = 0;
    var index: u32 = 0;

    while (index < objects.service_count) : (index += 1) {
        if (objects.services[index].device.eql(path)) count += 1;
    }

    try out.print("GATT services: {d}\n", .{count});

    index = 0;

    while (index < objects.service_count) : (index += 1) {
        const service = &objects.services[index];

        if (!service.device.eql(path)) continue;

        try out.print("  {s}\n", .{service.uuid.slice()});

        if (with_characteristics) try print_characteristics(objects, out, service.path.slice());
    }
}

fn print_characteristics(objects: *bluez.Objects, out: *std.Io.Writer, owner: []const u8) !void {
    var index: u32 = 0;

    while (index < objects.characteristic_count) : (index += 1) {
        const characteristic = &objects.characteristics[index];

        if (!characteristic.service.eql(owner)) continue;

        try out.print("      char {s} [", .{characteristic.uuid.slice()});

        if (characteristic.flags.read) try out.print("R", .{});
        if (characteristic.flags.write_without_response) try out.print("w", .{});
        if (characteristic.flags.write) try out.print("W", .{});
        if (characteristic.flags.notify) try out.print("N", .{});
        if (characteristic.flags.indicate) try out.print("I", .{});

        try out.print("]\n", .{});
    }
}

const testing = std.testing;

test "the multi-link UUIDs render in the lowercase form BlueZ reports" {
    try testing.expectEqualStrings(
        "6a4e2800-667b-11e3-949a-0800200c9a66",
        multi_link.uuid_text(multi_link.service_uuid),
    );
}
