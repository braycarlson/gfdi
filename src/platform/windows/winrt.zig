const std = @import("std");

const ble_transport = @import("ble_transport.zig");
const com = @import("com.zig");
const fake_com = @import("fake_com.zig");
const interface = @import("../interface.zig");
const lock = @import("lock.zig");
const notify = @import("notify.zig");
const protocol = @import("../../protocol.zig");
const session_module = @import("../../session.zig");
const store_module = @import("../../store.zig");
const time = @import("time.zig");
const transport = @import("../../transport.zig");

const assert = std.debug.assert;

const DiskStore = store_module.DiskStore;
const IUnknown = com.IUnknown;
const LinkType = transport.link.LinkType;
const RunnerType = session_module.runner.RunnerType;
const Writer = std.Io.Writer;

const winrt = @This();

pub const BluetoothError = error{
    AddReceivedFailed,
    FindAllFailed,
    FromAddressFailed,
    GetCharacteristicsFailed,
    GetCharacteristicsViewFailed,
    GetServicesFailed,
    GetServicesViewFailed,
    NoDevice3,
    NoService3,
    NoWatcher,
    SizeFailed,
    StartFailed,
};

pub const Error = BluetoothError || com.Error || Writer.Error;

const BLELink = LinkType(ble_transport.Backend);

const NativeEnvironment = struct {
    pub const Clock = @import("clock.zig").Clock;
    pub const FileStore = DiskStore;
    pub const Transport = BLELink;
};

const SystemTime = session_module.runner.SystemTimeType(time);

pub const Runner = RunnerType(NativeEnvironment, SystemTime);

pub const Observation = struct {
    address: u64,
    io: std.Io,
    out: *Writer,
    session: *Runner.Session,
    state: *lock.GFDIState,
    storage: session_module.Storage,
};

const StreamingHooks = struct {
    device: *IUnknown,
    out: *Writer,

    pub fn on_streaming(hooks: *const StreamingHooks) void {
        assert(hooks.out.buffer.len > 0);

        connection_interval_log(hooks.device, hooks.out, "BLE link (streaming)");
    }
};

const ObserveAttempt = struct {
    observation: *const Observation,

    pub const Error = winrt.Error;

    pub fn once(attempt: *const ObserveAttempt) winrt.Error!bool {
        assert(attempt.observation.storage.legacy.len > 0);
        assert(attempt.observation.address >> 48 == 0);

        return observe_once(attempt.observation);
    }
};

const Scanner = extern struct {
    vtable: *const com.HandlerVtable,
    runtime: *com.Runtime,
    count: u32,
    addresses: [scan_devices_max]u64,
    names: [scan_devices_max][scan_name_max]u8,
    name_lengths: [scan_devices_max]u8,
    free_threaded_marshaler: ?*IUnknown,
    target_address: u64,
    found: bool,
};

const MultiLinkConnection = struct {
    device: *IUnknown,
    request: ?*IUnknown,
    service: *IUnknown,

    fn deinit(connection: *const MultiLinkConnection) void {
        if (connection.request) |request| assert(request != connection.device);
        assert(connection.device != connection.service);

        connection.service.release();

        if (connection.request) |request| request.release();

        connection.device.release();
    }
};

const MultiLinkOpen = union(enum) {
    connection: MultiLinkConnection,
    missing,
};

const Lookup = union(enum) {
    found: *IUnknown,
    missing,
};

const Subscriptions = struct {
    characteristics: [subscriptions_max]*com.IGattCharacteristic,
    count: u32,
    tokens: [subscriptions_max]i64,

    const empty: Subscriptions = .{ .characteristics = undefined, .count = 0, .tokens = undefined };
};

const Watch = enum {
    until_found,
    whole_window,
};

const Listing = enum {
    services,
    services_and_characteristics,
};

const scan_devices_max = 64;
const scan_name_max = 48;
const scan_window_ms: u32 = 8000;
const advertise_wait_ms: u32 = 20000;
const watch_pump_sleep_ms: u32 = 20;
const watch_settle_ms: u32 = 200;
const close_all_settle_ms: u32 = 500;
const subscriptions_max: u32 = 32;
const characteristic_notify: u32 = 0x10;
const characteristic_indicate: u32 = 0x20;
const characteristic_read: u32 = 0x02;
const characteristic_write: u32 = 0x08;
const characteristic_write_without_response: u32 = 0x04;
const address_type_public: i32 = 0;
const address_type_random: i32 = 1;
const address_type_unspecified: i32 = 2;
const scanning_mode_active: i32 = 1;
const notification_value: i32 = 1;
const device_class = "Windows.Devices.Bluetooth.BluetoothLEDevice";
const statics_iid = &com.IID_IBluetoothLEDeviceStatics;
const statics2_iid = &com.IID_IBluetoothLEDeviceStatics2;
const no_clock: NativeEnvironment.Clock = .{};
const system_time: SystemTime = .{};
const multi_link_service_uuid = guid_from_uuid(protocol.multi_link.service_uuid);
const multi_link_send_uuid = guid_from_uuid(protocol.multi_link.send_uuid);

const received_vtable = com.HandlerVtable{
    .add_reference = @ptrCast(&handler_add_reference),
    .invoke = @ptrCast(&handler_invoke),
    .query_interface = @ptrCast(&handler_query_interface),
    .release = @ptrCast(&handler_release),
};

comptime {
    assert(scan_devices_max > 0);
    assert(scan_name_max <= std.math.maxInt(u8));
    assert(advertise_wait_ms > scan_window_ms);
    assert(subscriptions_max > 0);
}

fn guid_from_uuid(comptime value: u128) com.GUID {
    comptime assert(@sizeOf(com.GUID) == 16);
    comptime assert(value != 0);

    return .{
        .Data1 = @truncate(value >> 96),
        .Data2 = @truncate(value >> 80),
        .Data3 = @truncate(value >> 64),
        .Data4 = .{
            @truncate(value >> 56),
            @truncate(value >> 48),
            @truncate(value >> 40),
            @truncate(value >> 32),
            @truncate(value >> 24),
            @truncate(value >> 16),
            @truncate(value >> 8),
            @truncate(value),
        },
    };
}

pub fn device_selector(runtime: *com.Runtime, buffer: []u8) com.Error![]const u8 {
    assert(runtime.initialized);
    assert(buffer.len >= com.string_bytes_max * 3);

    const factory = try runtime.activation_factory(device_class, statics_iid);
    defer factory.release();

    const statics: *com.IBluetoothLEDeviceStatics = @ptrCast(@alignCast(factory));
    const selector_handle = try statics.get_device_selector();
    const selector: com.String = .{ .handle = selector_handle, .runtime = runtime };
    defer runtime.delete(&selector);

    return runtime.to_utf8(&selector, buffer);
}

pub fn enumerate(runtime: *com.Runtime, out: *Writer) Error!void {
    assert(runtime.initialized);
    assert(out.buffer.len > 0);

    const factory = try runtime.activation_factory(device_class, statics_iid);
    defer factory.release();

    const statics: *com.IBluetoothLEDeviceStatics = @ptrCast(@alignCast(factory));
    const selector_handle = try statics.get_device_selector();
    const selector: com.String = .{ .handle = selector_handle, .runtime = runtime };
    defer runtime.delete(&selector);

    const information_factory = try runtime.activation_factory(
        "Windows.Devices.Enumeration.DeviceInformation",
        &com.IID_IDeviceInformationStatics,
    );

    defer information_factory.release();

    const information_statics: *com.IDeviceInformationStatics = @ptrCast(
        @alignCast(information_factory),
    );

    var operation: ?*IUnknown = null;

    const status = information_statics.vtable.find_all_async_aqs(
        information_statics,
        selector.handle,
        &operation,
    );

    if (status != com.S_OK) return error.FindAllFailed;

    const collection = try com.await_operation(operation orelse return error.FindAllFailed);
    defer collection.release();

    try devices_print(runtime, out, @ptrCast(@alignCast(collection)));
}

fn devices_print(runtime: *com.Runtime, out: *Writer, view: *com.IVectorView) !void {
    assert(runtime.initialized);
    assert(out.buffer.len > 0);

    var size: u32 = 0;

    if (view.vtable.get_size(view, &size) != com.S_OK) return error.SizeFailed;

    try out.print("BLE devices known to Windows: {d}\n", .{size});

    for (0..size) |index| {
        var item: ?*IUnknown = null;

        if (view.vtable.get_at(view, @intCast(index), &item) != com.S_OK) continue;

        const object = item orelse continue;
        defer object.release();

        const information: *com.IDeviceInformation = @ptrCast(@alignCast(object));

        var name: com.String = .{ .handle = null, .runtime = runtime };
        var id: com.String = .{ .handle = null, .runtime = runtime };

        _ = information.vtable.get_name(information, &name.handle);
        defer runtime.delete(&name);

        _ = information.vtable.get_id(information, &id.handle);
        defer runtime.delete(&id);

        var name_buffer: [com.string_bytes_max * 3]u8 = undefined;
        var id_buffer: [com.string_bytes_max * 3]u8 = undefined;

        const name_text = try runtime.to_utf8(&name, &name_buffer);
        const id_text = try runtime.to_utf8(&id, &id_buffer);

        try out.print("  [{d}] {s}\n        {s}\n", .{ index, name_text, id_text });
    }
}

fn handler_query_interface(
    scanner: *Scanner,
    iid: *const com.GUID,
    out: *?*IUnknown,
) callconv(.winapi) com.HRESULT {
    assert(scanner.vtable == &received_vtable);
    assert(scanner.count <= scan_devices_max);

    return com.delegate_query_interface(
        @ptrCast(scanner),
        scanner.free_threaded_marshaler,
        iid,
        out,
    );
}

fn handler_add_reference(scanner: *Scanner) callconv(.winapi) u32 {
    assert(scanner.vtable == &received_vtable);
    assert(scanner.count <= scan_devices_max);

    return 1;
}

fn handler_release(scanner: *Scanner) callconv(.winapi) u32 {
    assert(scanner.vtable == &received_vtable);
    assert(scanner.count <= scan_devices_max);

    return 1;
}

fn handler_invoke(
    scanner: *Scanner,
    sender: ?*IUnknown,
    arguments: ?*IUnknown,
) callconv(.winapi) com.HRESULT {
    assert(sender != null);
    assert(arguments != null);
    assert(scanner.runtime.initialized);

    const event: *com.IBluetoothLEAdvertisementReceivedEventArgs = @ptrCast(
        @alignCast(arguments orelse return com.S_OK),
    );

    var address: u64 = 0;

    if (event.vtable.get_bluetooth_address(event, &address) != com.S_OK) return com.S_OK;
    if (address == scanner.target_address) scanner.found = true;

    var name_buffer: [scan_name_max]u8 = undefined;

    const name_length = local_name_read(scanner.runtime, event, &name_buffer);

    scanner_record(scanner, address, name_buffer[0..name_length]);

    return com.S_OK;
}

fn scanner_record(scanner: *Scanner, address: u64, name: []const u8) void {
    assert(name.len <= scan_name_max);
    assert(scanner.count <= scan_devices_max);

    for (0..scanner.count) |seen| {
        assert(scanner.name_lengths[seen] <= scan_name_max);

        if (scanner.addresses[seen] != address) continue;

        if (scanner.name_lengths[seen] == 0) {
            @memcpy(scanner.names[seen][0..name.len], name);
            scanner.name_lengths[seen] = @intCast(name.len);
        }

        return;
    }

    if (scanner.count == scan_devices_max) return;

    scanner.addresses[scanner.count] = address;

    @memcpy(scanner.names[scanner.count][0..name.len], name);

    scanner.name_lengths[scanner.count] = @intCast(name.len);
    scanner.count += 1;

    assert(scanner.count <= scan_devices_max);
}

fn local_name_read(
    runtime: *com.Runtime,
    event: *com.IBluetoothLEAdvertisementReceivedEventArgs,
    buffer: *[scan_name_max]u8,
) u8 {
    assert(runtime.initialized);

    var advertisement_object: ?*IUnknown = null;

    if (event.vtable.get_advertisement(event, &advertisement_object) != com.S_OK) return 0;

    const object = advertisement_object orelse return 0;
    defer object.release();

    const advertisement: *com.IBluetoothLEAdvertisement = @ptrCast(@alignCast(object));

    var name: com.String = .{ .handle = null, .runtime = runtime };

    if (advertisement.vtable.get_local_name(advertisement, &name.handle) != com.S_OK) return 0;
    if (name.handle == null) return 0;

    defer runtime.delete(&name);

    var length: u32 = 0;

    const raw = runtime.get_string_raw_buffer(name.handle, &length);

    var name_length: u8 = 0;

    for (raw[0..length]) |code| {
        if (name_length == scan_name_max) break;

        switch (code) {
            0x20...0x7E => {
                buffer[name_length] = @intCast(code);
                name_length += 1;
            },
            else => {},
        }
    }

    assert(name_length <= scan_name_max);

    return name_length;
}

fn address_print(out: *Writer, address: u64) !void {
    assert(address >> 48 == 0);
    assert(out.buffer.len > 0);

    try out.print("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        (address >> 40) & 0xFF,
        (address >> 32) & 0xFF,
        (address >> 24) & 0xFF,
        (address >> 16) & 0xFF,
        (address >> 8) & 0xFF,
        address & 0xFF,
    });
}

fn scanner_reset(scanner: *Scanner, runtime: *com.Runtime, target_address: u64) void {
    assert(target_address >> 48 == 0);
    assert(runtime.initialized);

    scanner.* = .{
        .addresses = undefined,
        .count = 0,
        .found = false,
        .free_threaded_marshaler = null,
        .name_lengths = undefined,
        .names = undefined,
        .runtime = runtime,
        .target_address = target_address,
        .vtable = &received_vtable,
    };
}

fn advertisements_watch(
    runtime: *com.Runtime,
    scanner: *Scanner,
    timeout_ms: u32,
    watch: Watch,
) !void {
    assert(timeout_ms > 0);
    assert(scanner.free_threaded_marshaler == null);
    assert(scanner.runtime == runtime);
    assert(scanner.vtable == &received_vtable);

    const inspectable = try runtime.activate_instance(
        "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher",
    );

    defer inspectable.release();

    const watcher_object = inspectable.query(&com.IID_IBluetoothLEAdvertisementWatcher) orelse {
        return error.NoWatcher;
    };

    defer watcher_object.release();

    const watcher: *com.IBluetoothLEAdvertisementWatcher = @ptrCast(@alignCast(watcher_object));

    _ = watcher.vtable.put_scanning_mode(watcher, scanning_mode_active);

    scanner.free_threaded_marshaler = try runtime.marshaler_create(@ptrCast(scanner));
    defer if (scanner.free_threaded_marshaler) |marshaler| marshaler.release();

    var token: i64 = 0;

    if (watcher.vtable.add_received(watcher, @ptrCast(scanner), &token) != com.S_OK) {
        return error.AddReceivedFailed;
    }

    if (watcher.vtable.start(watcher) != com.S_OK) return error.StartFailed;

    const start_tick = time.now_ms();

    for (0..timeout_ms) |_| {
        const now = time.now_ms();

        assert(now >= start_tick);

        if (now - start_tick >= timeout_ms) break;

        switch (watch) {
            .until_found => if (scanner.found) break,
            .whole_window => {},
        }

        com.messages_pump();
        time.sleep_ms(watch_pump_sleep_ms);
    }

    _ = watcher.vtable.stop(watcher);

    time.sleep_ms(watch_settle_ms);
}

pub fn scan(runtime: *com.Runtime, out: *Writer) Error!void {
    assert(runtime.initialized);
    assert(out.buffer.len > 0);

    var scanner: Scanner = undefined;

    scanner_reset(&scanner, runtime, 0);

    try out.print("Scanning BLE for 8s (active)...\n", .{});
    try out.flush();
    try advertisements_watch(runtime, &scanner, scan_window_ms, .whole_window);

    assert(scanner.count <= scan_devices_max);

    try out.print("Advertisers seen: {d}\n", .{scanner.count});

    for (0..scanner.count) |index| {
        try out.print("  ", .{});
        try address_print(out, scanner.addresses[index]);
        try out.print("  {s}\n", .{scanner.names[index][0..scanner.name_lengths[index]]});
    }
}

fn guid_print(out: *Writer, value: *const com.GUID) !void {
    assert(out.buffer.len > 0);

    try out.print(
        "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            value.Data1,
            value.Data2,
            value.Data3,
            value.Data4[0],
            value.Data4[1],
            value.Data4[2],
            value.Data4[3],
            value.Data4[4],
            value.Data4[5],
            value.Data4[6],
            value.Data4[7],
        },
    );
}

pub fn connect(runtime: *com.Runtime, out: *Writer, address: u64) Error!void {
    assert(runtime.initialized);
    assert(address >> 48 == 0);

    const factory = try runtime.activation_factory(device_class, statics2_iid);
    defer factory.release();

    const statics: *com.IBluetoothLEDeviceStatics2 = @ptrCast(@alignCast(factory));

    try out.print("connecting to ", .{});
    try address_print(out, address);
    try out.print(" ...\n", .{});
    try out.flush();

    var operation: ?*IUnknown = null;

    const status = statics.vtable.from_bluetooth_address_with_type_async(
        statics,
        address,
        address_type_random,
        &operation,
    );

    if (status != com.S_OK) return error.FromAddressFailed;

    const pending = operation orelse return error.FromAddressFailed;

    const device = com.await_operation(pending) catch |err| {
        try out.print(
            "device not found ({s}). Is the watch advertising / in range?\n",
            .{@errorName(err)},
        );

        return out.flush();
    };

    defer device.release();

    try device_services_print(out, device, .services);
}

fn device_services_print(out: *Writer, device: *IUnknown, listing: Listing) !void {
    assert(out.buffer.len > 0);

    const device3_object = device.query(&com.IID_IBluetoothLEDevice3) orelse return error.NoDevice3;
    defer device3_object.release();

    const device3: *com.IBluetoothLEDevice3 = @ptrCast(@alignCast(device3_object));

    var operation: ?*IUnknown = null;

    if (device3.vtable.get_gatt_services_async(device3, &operation) != com.S_OK) {
        return error.GetServicesFailed;
    }

    const result_object = try com.await_operation(operation orelse return error.GetServicesFailed);
    defer result_object.release();

    const result: *com.IGattDeviceServicesResult = @ptrCast(@alignCast(result_object));

    var view_object: ?*IUnknown = null;

    if (result.vtable.get_services(result, &view_object) != com.S_OK) {
        return error.GetServicesViewFailed;
    }

    const view = view_object orelse return error.GetServicesViewFailed;
    defer view.release();

    try services_print(out, @ptrCast(@alignCast(view)), listing);
}

fn services_print(out: *Writer, view: *com.IVectorView, listing: Listing) !void {
    assert(out.buffer.len > 0);

    var size: u32 = 0;

    _ = view.vtable.get_size(view, &size);

    try out.print("GATT services: {d}\n", .{size});

    for (0..size) |index| {
        var item: ?*IUnknown = null;

        if (view.vtable.get_at(view, @intCast(index), &item) != com.S_OK) continue;

        const object = item orelse continue;
        defer object.release();

        const service: *com.IGattDeviceService = @ptrCast(@alignCast(object));

        var uuid: com.GUID = undefined;

        _ = service.vtable.get_uuid(service, &uuid);

        try out.print("  ", .{});
        try guid_print(out, &uuid);
        try out.print("\n", .{});

        switch (listing) {
            .services => {},
            .services_and_characteristics => try characteristics_print(out, object),
        }
    }
}

fn characteristics_print(out: *Writer, service: *IUnknown) !void {
    assert(out.buffer.len > 0);

    const view = characteristics_view(service) catch return;
    defer view.release();

    const typed: *com.IVectorView = @ptrCast(@alignCast(view));

    var size: u32 = 0;

    _ = typed.vtable.get_size(typed, &size);

    for (0..size) |index| {
        var item: ?*IUnknown = null;

        if (typed.vtable.get_at(typed, @intCast(index), &item) != com.S_OK) continue;

        const object = item orelse continue;
        defer object.release();

        try characteristic_print(out, @ptrCast(@alignCast(object)));
    }
}

fn characteristic_print(out: *Writer, characteristic: *com.IGattCharacteristic) !void {
    assert(out.buffer.len > 0);

    var uuid: com.GUID = undefined;
    var properties: u32 = 0;

    _ = characteristic.vtable.get_uuid(characteristic, &uuid);
    _ = characteristic.vtable.get_characteristic_properties(characteristic, &properties);

    try out.print("      characteristic ", .{});
    try guid_print(out, &uuid);
    try out.print(" [", .{});

    if (properties & characteristic_read != 0) try out.print("R", .{});
    if (properties & characteristic_write_without_response != 0) try out.print("w", .{});
    if (properties & characteristic_write != 0) try out.print("W", .{});
    if (properties & characteristic_notify != 0) try out.print("N", .{});
    if (properties & characteristic_indicate != 0) try out.print("I", .{});

    try out.print("]\n", .{});
}

fn characteristics_view(service: *IUnknown) !*IUnknown {
    const service3_object = service.query(&com.IID_IGattDeviceService3) orelse {
        return error.NoService3;
    };

    defer service3_object.release();

    const service3: *com.IGattDeviceService3 = @ptrCast(@alignCast(service3_object));

    var operation: ?*IUnknown = null;

    if (service3.vtable.get_characteristics_async(service3, &operation) != com.S_OK) {
        return error.GetCharacteristicsFailed;
    }

    const result_object = try com.await_operation(
        operation orelse return error.GetCharacteristicsFailed,
    );

    defer result_object.release();

    const result: *com.IGattCharacteristicsResult = @ptrCast(@alignCast(result_object));

    var view: ?*IUnknown = null;

    if (result.vtable.get_characteristics(result, &view) != com.S_OK) {
        return error.GetCharacteristicsViewFailed;
    }

    return view orelse error.GetCharacteristicsViewFailed;
}

pub fn pull(runtime: *com.Runtime, out: *Writer, address: u64) Error!void {
    assert(runtime.initialized);
    assert(address >> 48 == 0);

    var scanner: Scanner = undefined;

    scanner_reset(&scanner, runtime, address);

    try out.print("waiting for watch ", .{});
    try address_print(out, address);
    try out.print(" to advertise (up to 20s)...\n", .{});
    try out.flush();
    try advertisements_watch(runtime, &scanner, advertise_wait_ms, .until_found);

    if (!scanner.found) {
        try out.print(
            "watch not seen advertising. Phone Bluetooth off + watch in Pair-Phone mode?\n",
            .{},
        );

        return out.flush();
    }

    try out.print("watch advertising; connecting...\n", .{});
    try out.flush();

    const device = switch (try address_open(runtime, address)) {
        .found => |device| device,
        .missing => {
            try out.print("connect failed: device object null for all address types.\n", .{});

            return out.flush();
        },
    };

    defer device.release();

    try device_services_print(out, device, .services_and_characteristics);
}

fn advertise_wait(runtime: *com.Runtime, out: *Writer, address: u64) !bool {
    assert(runtime.initialized);
    assert(address >> 48 == 0);

    var scanner: Scanner = undefined;

    scanner_reset(&scanner, runtime, address);

    try out.print("waiting for watch ", .{});
    try address_print(out, address);
    try out.print(" to advertise...\n", .{});
    try out.flush();
    try advertisements_watch(runtime, &scanner, advertise_wait_ms, .until_found);

    return scanner.found;
}

fn address_open(runtime: *com.Runtime, address: u64) !Lookup {
    assert(runtime.initialized);
    assert(address >> 48 == 0);

    const factory = try runtime.activation_factory(device_class, statics2_iid);
    defer factory.release();

    const statics: *com.IBluetoothLEDeviceStatics2 = @ptrCast(@alignCast(factory));

    const address_types = [_]i32{
        address_type_random,
        address_type_unspecified,
        address_type_public,
    };

    for (address_types) |address_type| {
        var operation: ?*IUnknown = null;

        const status = statics.vtable.from_bluetooth_address_with_type_async(
            statics,
            address,
            address_type,
            &operation,
        );

        if (status != com.S_OK) continue;

        const opened = com.await_operation(operation orelse continue) catch continue;

        return .{ .found = opened };
    }

    return .missing;
}

fn service_find(device3: *com.IBluetoothLEDevice3, target: *const com.GUID) !Lookup {
    assert(!std.meta.eql(target.*, com.GUID_NULL));

    var operation: ?*IUnknown = null;

    if (device3.vtable.get_gatt_services_async(device3, &operation) != com.S_OK) return .missing;

    const result_object = try com.await_operation(operation orelse return .missing);
    defer result_object.release();

    const result: *com.IGattDeviceServicesResult = @ptrCast(@alignCast(result_object));

    var view_object: ?*IUnknown = null;

    if (result.vtable.get_services(result, &view_object) != com.S_OK) return .missing;

    const view_handle = view_object orelse return .missing;
    defer view_handle.release();

    const view: *com.IVectorView = @ptrCast(@alignCast(view_handle));

    var size: u32 = 0;

    _ = view.vtable.get_size(view, &size);

    for (0..size) |index| {
        var item: ?*IUnknown = null;

        if (view.vtable.get_at(view, @intCast(index), &item) != com.S_OK) continue;

        const object = item orelse continue;
        const service: *com.IGattDeviceService = @ptrCast(@alignCast(object));

        var uuid: com.GUID = undefined;

        _ = service.vtable.get_uuid(service, &uuid);

        if (std.meta.eql(uuid, target.*)) return .{ .found = object };

        object.release();
    }

    return .missing;
}

fn characteristic_find(service: *IUnknown, target: *const com.GUID) !Lookup {
    assert(!std.meta.eql(target.*, com.GUID_NULL));

    const view_handle = characteristics_view(service) catch return .missing;
    defer view_handle.release();

    const view: *com.IVectorView = @ptrCast(@alignCast(view_handle));

    var size: u32 = 0;

    _ = view.vtable.get_size(view, &size);

    for (0..size) |index| {
        var item: ?*IUnknown = null;

        if (view.vtable.get_at(view, @intCast(index), &item) != com.S_OK) continue;

        const object = item orelse continue;
        const characteristic: *com.IGattCharacteristic = @ptrCast(@alignCast(object));

        var uuid: com.GUID = undefined;

        _ = characteristic.vtable.get_uuid(characteristic, &uuid);

        if (std.meta.eql(uuid, target.*)) return .{ .found = object };

        object.release();
    }

    return .missing;
}

fn multi_link_send_find(out: *Writer, service: *IUnknown) !Lookup {
    assert(out.buffer.len > 0);

    const lookup = try characteristic_find(service, &multi_link_send_uuid);

    switch (lookup) {
        .found => {},
        .missing => {
            try out.print("Multi-Link send characteristic 6a4e2820 not found.\n", .{});
            try out.flush();
        },
    }

    return lookup;
}

fn throughput_request(runtime: *com.Runtime, device: *IUnknown, out: *Writer) ?*IUnknown {
    assert(out.buffer.len > 0);

    const factory = runtime.activation_factory(
        "Windows.Devices.Bluetooth.BluetoothLEPreferredConnectionParameters",
        &com.IID_IBluetoothLEPreferredConnectionParametersStatics,
    ) catch {
        out.print(
            "connection-interval tuning unavailable (needs Windows 11); using default.\n",
            .{},
        ) catch return null;

        return null;
    };

    defer factory.release();

    const statics: *com.IBluetoothLEPreferredConnectionParametersStatics = @ptrCast(
        @alignCast(factory),
    );

    var preset_object: ?*IUnknown = null;

    if (statics.vtable.get_throughput_optimized(statics, &preset_object) != com.S_OK) return null;

    const preset = preset_object orelse return null;
    defer preset.release();

    const device6_object = device.query(&com.IID_IBluetoothLEDevice6) orelse {
        out.print("IBluetoothLEDevice6 unavailable; using default interval.\n", .{}) catch {
            return null;
        };

        return null;
    };

    defer device6_object.release();

    const device6: *com.IBluetoothLEDevice6 = @ptrCast(@alignCast(device6_object));

    var request: ?*IUnknown = null;

    const request_preferred = device6.vtable.request_preferred_connection_parameters;
    const status = request_preferred(device6, preset, &request);

    if (status != com.S_OK) return null;

    const result = request orelse return null;

    out.print("requested ThroughputOptimized connection parameters.\n", .{}) catch return result;

    return result;
}

fn connection_interval_log(device: *IUnknown, out: *Writer, label: []const u8) void {
    assert(label.len > 0);

    const device6_object = device.query(&com.IID_IBluetoothLEDevice6) orelse return;
    defer device6_object.release();

    const device6: *com.IBluetoothLEDevice6 = @ptrCast(@alignCast(device6_object));

    var parameters_object: ?*IUnknown = null;

    if (device6.vtable.get_connection_parameters(device6, &parameters_object) != com.S_OK) return;

    const parameters_handle = parameters_object orelse return;
    defer parameters_handle.release();

    const parameters: *com.IBluetoothLEConnectionParameters = @ptrCast(
        @alignCast(parameters_handle),
    );

    var interval_units: u16 = 0;

    if (parameters.vtable.get_connection_interval(parameters, &interval_units) != com.S_OK) return;

    const interval_ms_tenths = @divFloor(@as(u32, interval_units) * 125, 10);

    out.print("{s}: connection interval {d} units ({d}.{d} ms)\n", .{
        label,
        interval_units,
        @divFloor(interval_ms_tenths, 10),
        interval_ms_tenths % 10,
    }) catch return;
}

fn multi_link_connection_open(runtime: *com.Runtime, out: *Writer, address: u64) !MultiLinkOpen {
    assert(runtime.initialized);
    assert(address >> 48 == 0);

    const device = switch (try address_open(runtime, address)) {
        .found => |object| object,
        .missing => {
            try out.print("connect failed (device object null).\n", .{});
            try out.flush();

            return .missing;
        },
    };

    errdefer device.release();

    const device3_object = device.query(&com.IID_IBluetoothLEDevice3) orelse return error.NoDevice3;
    defer device3_object.release();

    const device3: *com.IBluetoothLEDevice3 = @ptrCast(@alignCast(device3_object));
    const request = throughput_request(runtime, device, out);

    errdefer if (request) |object| object.release();

    const service = switch (try service_find(device3, &multi_link_service_uuid)) {
        .found => |object| object,
        .missing => {
            try out.print("Multi-Link service 6a4e2800 not found.\n", .{});
            try out.flush();

            if (request) |object| object.release();

            device.release();

            return .missing;
        },
    };

    return .{ .connection = .{ .device = device, .request = request, .service = service } };
}

fn notifications_unsubscribe(subscriptions: *const Subscriptions) void {
    comptime assert(subscriptions_max > 0);
    assert(subscriptions.count <= subscriptions_max);

    for (0..subscriptions.count) |index| {
        const characteristic = subscriptions.characteristics[index];

        _ = characteristic.vtable.remove_value_changed(characteristic, subscriptions.tokens[index]);

        com.as_unknown(com.IGattCharacteristic, characteristic).release();
    }
}

fn notifications_subscribe(
    out: *Writer,
    service: *IUnknown,
    notifier: *notify.Notifier,
    subscriptions: *Subscriptions,
) !void {
    assert(subscriptions.count == 0);
    assert(out.buffer.len > 0);

    const view_handle = try characteristics_view(service);
    defer view_handle.release();

    const view: *com.IVectorView = @ptrCast(@alignCast(view_handle));

    var size: u32 = 0;

    _ = view.vtable.get_size(view, &size);

    for (0..size) |index| {
        var item: ?*IUnknown = null;

        if (view.vtable.get_at(view, @intCast(index), &item) != com.S_OK) continue;

        const object = item orelse continue;

        try characteristic_subscribe(out, @ptrCast(@alignCast(object)), notifier, subscriptions);
    }
}

fn characteristic_subscribe(
    out: *Writer,
    characteristic: *com.IGattCharacteristic,
    notifier: *notify.Notifier,
    subscriptions: *Subscriptions,
) !void {
    assert(subscriptions.count <= subscriptions_max);

    const object = com.as_unknown(com.IGattCharacteristic, characteristic);

    errdefer object.release();

    var properties: u32 = 0;

    _ = characteristic.vtable.get_characteristic_properties(characteristic, &properties);

    if (properties & characteristic_notify == 0) return object.release();

    var descriptor_operation: ?*IUnknown = null;

    const written = characteristic.vtable.write_cccd_async(
        characteristic,
        notification_value,
        &descriptor_operation,
    );

    if (written == com.S_OK) {
        if (descriptor_operation) |operation| try com.await_completion(operation);
    }

    var token: i64 = 0;

    _ = characteristic.vtable.add_value_changed(characteristic, @ptrCast(notifier), &token);
    errdefer _ = characteristic.vtable.remove_value_changed(characteristic, token);

    var uuid: com.GUID = undefined;

    _ = characteristic.vtable.get_uuid(characteristic, &uuid);

    try out.print("subscribed ", .{});
    try guid_print(out, &uuid);
    try out.print("\n", .{});

    if (subscriptions.count == subscriptions_max) {
        _ = characteristic.vtable.remove_value_changed(characteristic, token);

        return object.release();
    }

    subscriptions.characteristics[subscriptions.count] = characteristic;
    subscriptions.tokens[subscriptions.count] = token;
    subscriptions.count += 1;

    assert(subscriptions.count <= subscriptions_max);
}

fn multi_link_register_gfdi(backend: *ble_transport.Backend, out: *Writer) !void {
    assert(out.buffer.len > 0);

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

pub fn observe(observation: *const Observation) Error!void {
    assert(observation.address >> 48 == 0);
    assert(observation.storage.transfer.len > 0);

    const attempt = ObserveAttempt{ .observation = observation };

    try Runner.attempts_run(ObserveAttempt, &attempt, observation.out, &system_time);
}

fn observe_once(observation: *const Observation) !bool {
    assert(observation.storage.transfer.len > 0);
    assert(observation.address >> 48 == 0);

    const out = observation.out;

    var runtime = try com.Runtime.init();
    defer runtime.deinit();

    time.begin_precise();
    defer time.end_precise();

    if (!try advertise_wait(&runtime, out, observation.address)) {
        try out.print("watch not seen advertising (phone Bluetooth off + watch awake?).\n", .{});
        try out.flush();

        return false;
    }

    const connection = switch (try multi_link_connection_open(&runtime, out, observation.address)) {
        .connection => |opened| opened,
        .missing => return false,
    };

    defer connection.deinit();

    observation.state.* = .{};
    observation.state.transfer_buffer = observation.storage.transfer;

    var notifier = notify.Notifier{
        .free_threaded_marshaler = null,
        .runtime = &runtime,
        .state = observation.state,
        .vtable = &notify.notifier_vtable,
    };

    notifier.free_threaded_marshaler = try runtime.marshaler_create(@ptrCast(&notifier));
    defer if (notifier.free_threaded_marshaler) |marshaler| marshaler.release();

    var subscriptions: Subscriptions = .empty;
    defer notifications_unsubscribe(&subscriptions);

    try notifications_subscribe(out, connection.service, &notifier, &subscriptions);

    return observe_once_pump(observation, &runtime, &connection);
}

fn observe_once_pump(
    observation: *const Observation,
    runtime: *com.Runtime,
    connection: *const MultiLinkConnection,
) !bool {
    assert(observation.storage.legacy.len > 0);
    assert(observation.address >> 48 == 0);

    const out = observation.out;

    const characteristic_object = switch (try multi_link_send_find(out, connection.service)) {
        .found => |characteristic| characteristic,
        .missing => return false,
    };

    defer characteristic_object.release();

    var backend: ble_transport.Backend = undefined;

    try backend.init(runtime, @ptrCast(@alignCast(characteristic_object)));
    defer backend.deinit();

    try multi_link_register_gfdi(&backend, out);

    var link = BLELink{
        .backend = &backend,
        .state = observation.state,
        .transfer_service_index = 0,
    };

    const hooks = StreamingHooks{ .device = connection.device, .out = out };
    const store: DiskStore = .{ .io = observation.io };

    observation.session.init(&observation.storage, &link, out, no_clock, store);

    try Runner.pump_run(StreamingHooks, &hooks, observation.session, &system_time);

    return observation.session.archive.complete;
}

pub fn smoke(runtime: *com.Runtime, out: *Writer) Error!void {
    assert(runtime.initialized);
    assert(out.buffer.len > 0);

    const handle = try runtime.string(device_class);
    defer runtime.delete(&handle);

    var round_trip_buffer: [com.string_bytes_max * 3]u8 = undefined;
    var selector_buffer: [com.string_bytes_max * 3]u8 = undefined;

    const round_trip = try runtime.to_utf8(&handle, &round_trip_buffer);

    try out.print("WinRT OK (combase loaded, RoInitialize ok).\n", .{});
    try out.print("HSTRING round-trip: {s}\n", .{round_trip});

    const selector = try device_selector(runtime, &selector_buffer);

    try out.print("BLE AQS selector: {s}\n", .{selector});
}

test "multi_link_connection_open releases every reference when the service is missing" {
    var request: fake_com.Object = .{ .vtable = &fake_com.unknown_slots };
    var view: fake_com.Object = .{ .vtable = &fake_com.vector_view_slots };
    var device6: fake_com.Object = .{ .vtable = &fake_com.device6_slots, .product = &request };

    var services: fake_com.Object = .{
        .product = &view,
        .vtable = &fake_com.services_result_slots,
    };

    var services_operation: fake_com.Object = .{
        .product = &services,
        .vtable = &fake_com.async_operation_slots,
    };

    var device3: fake_com.Object = .{
        .product = &services_operation,
        .vtable = &fake_com.device3_slots,
    };

    var device: fake_com.Object = .{
        .interfaces = .{
            .{ .iid = &com.IID_IBluetoothLEDevice3, .object = &device3 },
            .{ .iid = &com.IID_IBluetoothLEDevice6, .object = &device6 },
        },
        .vtable = &fake_com.unknown_slots,
    };

    var device_operation: fake_com.Object = .{
        .product = &device,
        .vtable = &fake_com.async_operation_slots,
    };

    var runtime = fake_com.runtime();
    var buffer: [256]u8 = undefined;
    var out = Writer.fixed(&buffer);

    const address = fake_com.address_of(&device_operation);
    const opened = try multi_link_connection_open(&runtime, &out, address);

    try std.testing.expect(opened == .missing);
    try std.testing.expect(std.mem.find(u8, out.buffered(), "6a4e2800 not found") != null);

    const objects = [_]*const fake_com.Object{
        &device,
        &device3,
        &device6,
        &device_operation,
        &request,
        &services,
        &services_operation,
        &view,
    };

    for (objects) |object| {
        try std.testing.expect(object.acquisitions > 0);
        try std.testing.expectEqual(@as(u32, 0), object.references);
    }
}

test scanner_record {
    var runtime = fake_com.runtime();
    var scanner: Scanner = undefined;

    scanner_reset(&scanner, &runtime, 0xA1B2C3D4E5F6);
    scanner_record(&scanner, 0x000000000001, "");
    scanner_record(&scanner, 0x000000000001, "Forerunner");
    scanner_record(&scanner, 0x000000000002, "Edge");
    scanner_record(&scanner, 0x000000000002, "Renamed");

    try std.testing.expectEqual(@as(u32, 2), scanner.count);
    try std.testing.expectEqualStrings("Forerunner", scanner.names[0][0..scanner.name_lengths[0]]);
    try std.testing.expectEqualStrings("Edge", scanner.names[1][0..scanner.name_lengths[1]]);
    try std.testing.expect(!scanner.found);

    for (0..scan_devices_max + 1) |index| scanner_record(&scanner, 0x100 + index, "");

    try std.testing.expectEqual(@as(u32, scan_devices_max), scanner.count);
}

test "a GUID and an address print in the form BlueZ and the watch use" {
    var buffer: [64]u8 = undefined;
    var out = Writer.fixed(&buffer);

    try guid_print(&out, &multi_link_service_uuid);

    const service = protocol.multi_link.uuid_text(protocol.multi_link.service_uuid);

    try std.testing.expectEqualStrings(service, out.buffered());

    out.end = 0;

    try guid_print(&out, &multi_link_send_uuid);

    const send = protocol.multi_link.uuid_text(protocol.multi_link.send_uuid);

    try std.testing.expectEqualStrings(send, out.buffered());
    try std.testing.expect(!std.meta.eql(multi_link_service_uuid, multi_link_send_uuid));

    out.end = 0;

    try address_print(&out, 0xA1B2C3D4E5F6);

    const parsed = try interface.address_parse(out.buffered());

    try std.testing.expectEqualStrings("a1:b2:c3:d4:e5:f6", out.buffered());
    try std.testing.expectEqual(@as(u64, 0xA1B2C3D4E5F6), parsed);
}
