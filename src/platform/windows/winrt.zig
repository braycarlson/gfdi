const std = @import("std");

const ble_transport = @import("ble_transport.zig");
const com = @import("com.zig");
const link = @import("../../transport/link.zig");
const lock = @import("lock.zig");
const multi_link = @import("../../protocol/multi_link.zig");
const notify = @import("notify.zig");

const reassembly = @import("../../transport/reassembly.zig");
const runner = @import("../../session/runner.zig");
const session_module = @import("../../session/session.zig");
const time = @import("time.zig");

const DiskStore = @import("../../store.zig").DiskStore;
const WinClock = @import("clock.zig").WinClock;

const assert = std.debug.assert;

const BLELink = link.LinkType(ble_transport.Backend);

const RealEnv = struct {
    pub const Transport = BLELink;
    pub const Clock = WinClock;
    pub const FileStore = DiskStore;
};

const Runner = runner.RunnerType(RealEnv, time);

const StreamingHooks = struct {
    device: *anyopaque,
    out: *std.Io.Writer,

    pub fn on_streaming(hooks: StreamingHooks) void {
        log_connection_interval(hooks.device, hooks.out, "BLE link (streaming)");
    }
};

const ObserveAttempt = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    address: u64,
    state: *lock.GFDIState,
    session: *Runner.Session,
    buffers: *const runner.Buffers,

    pub fn once(attempt: ObserveAttempt) !bool {
        return observe_once(attempt);
    }
};

const Scanner = extern struct {
    vtable: *const com.HandlerVtable,
    runtime: *com.Runtime,
    count: u32,
    addresses: [scan_devices_max]u64,
    names: [scan_devices_max][scan_name_max]u8,
    name_lengths: [scan_devices_max]u8,
    free_threaded_marshaler: ?*com.IUnknown,
    target_address: u64,
    found: bool,
};

const MultiLinkConnection = struct {
    device: *anyopaque,
    service: *anyopaque,
    connection_request: ?*anyopaque,

    fn deinit(connection: *const MultiLinkConnection) void {
        _ = com.as_unknown(connection.service).release();
        if (connection.connection_request) |request| _ = com.as_unknown(request).release();
        _ = com.as_unknown(connection.device).release();
    }
};

const Subscriptions = struct {
    characteristics: [subscriptions_max]*com.IGattCharacteristic = undefined,
    tokens: [subscriptions_max]i64 = undefined,
    count: u32 = 0,
};

const scan_devices_max = 64;
const scan_name_max = 48;

const scan_window_ms: u32 = 8000;
const advertise_wait_ms: u32 = 20000;
const watch_pump_sleep_ms: u32 = 20;
const watch_settle_ms: u32 = 200;
const close_all_settle_ms: u32 = 500;

const multi_link_service_uuid = guid_from_uuid(multi_link.service_uuid);
const multi_link_tx_uuid = guid_from_uuid(multi_link.tx_uuid);

fn guid_from_uuid(comptime value: u128) com.GUID {
    return .{
        .Data1 = @truncate(value >> 96),
        .Data2 = @truncate(value >> 80),
        .Data3 = @truncate(value >> 64),

        .Data4 = .{
            @truncate(value >> 56), @truncate(value >> 48),
            @truncate(value >> 40), @truncate(value >> 32),
            @truncate(value >> 24), @truncate(value >> 16),
            @truncate(value >> 8),  @truncate(value),
        },
    };
}

const received_vtable = com.HandlerVtable{
    .query_interface = @ptrCast(&handler_query_interface),
    .add_ref = @ptrCast(&handler_add_ref),
    .release = @ptrCast(&handler_release),
    .invoke = @ptrCast(&handler_invoke),
};

const subscriptions_max: u32 = 32;

pub fn ble_device_selector(runtime: *com.Runtime) ![]u8 {
    const factory = try runtime.activation_factory(
        "Windows.Devices.Bluetooth.BluetoothLEDevice",
        &com.IID_IBluetoothLEDeviceStatics,
    );

    const statics: *com.IBluetoothLEDeviceStatics = @ptrCast(@alignCast(factory));
    defer statics.release();

    const selector = try statics.get_device_selector();
    defer runtime.delete(selector);

    return runtime.to_utf8(selector);
}

pub fn enumerate(arena: std.mem.Allocator, out: *std.Io.Writer) !void {
    var runtime = try com.Runtime.init(arena);
    defer runtime.deinit();

    const ble_factory = try runtime.activation_factory(
        "Windows.Devices.Bluetooth.BluetoothLEDevice",
        &com.IID_IBluetoothLEDeviceStatics,
    );

    const statics: *com.IBluetoothLEDeviceStatics = @ptrCast(@alignCast(ble_factory));
    defer statics.release();

    const selector = try statics.get_device_selector();
    defer runtime.delete(selector);

    const device_information_factory = try runtime.activation_factory(
        "Windows.Devices.Enumeration.DeviceInformation",
        &com.IID_IDeviceInformationStatics,
    );

    const device_information_statics: *com.IDeviceInformationStatics = @ptrCast(
        @alignCast(device_information_factory),
    );

    defer com.as_unknown(device_information_statics).release();

    var operation: ?*anyopaque = null;

    if (device_information_statics.vtable.find_all_async_aqs(
        device_information_statics,
        selector,
        &operation,
    ) != com.S_OK) return error.FindAllFailed;
    const collection = try com.await_operation(operation orelse return error.FindAllFailed);
    const view: *com.IVectorView = @ptrCast(@alignCast(collection));
    defer com.as_unknown(view).release();

    var size: u32 = 0;

    if (view.vtable.get_size(view, &size) != com.S_OK) return error.SizeFailed;
    try out.print("BLE devices known to Windows: {d}\n", .{size});

    var index: u32 = 0;

    while (index < size) : (index += 1) {
        var item: ?*anyopaque = null;

        if (view.vtable.get_at(view, index, &item) != com.S_OK) continue;
        const info: *com.IDeviceInformation = @ptrCast(@alignCast(item orelse continue));
        defer com.as_unknown(info).release();

        var name_handle: com.HSTRING = null;
        var id_handle: com.HSTRING = null;
        _ = info.vtable.get_name(info, &name_handle);
        _ = info.vtable.get_id(info, &id_handle);
        const name = try runtime.to_utf8(name_handle);
        const id = try runtime.to_utf8(id_handle);
        runtime.delete(name_handle);
        runtime.delete(id_handle);

        try out.print("  [{d}] {s}\n        {s}\n", .{ index, name, id });
    }
}

fn handler_query_interface(
    scanner: *Scanner,
    iid: *const com.GUID,
    out: *?*anyopaque,
) callconv(.winapi) com.HRESULT {
    return com.delegate_query_interface(scanner, scanner.free_threaded_marshaler, iid, out);
}

fn handler_add_ref(scanner: *Scanner) callconv(.winapi) u32 {
    _ = scanner;
    return 1;
}

fn handler_release(scanner: *Scanner) callconv(.winapi) u32 {
    _ = scanner;
    return 1;
}

fn handler_invoke(
    scanner: *Scanner,
    sender: ?*anyopaque,
    args: ?*anyopaque,
) callconv(.winapi) com.HRESULT {
    _ = sender;

    const event: *com.IBluetoothLEAdvertisementReceivedEventArgs = @ptrCast(
        @alignCast(args orelse return com.S_OK),
    );

    var address: u64 = 0;

    if (event.vtable.get_bluetooth_address(event, &address) != com.S_OK) return com.S_OK;
    if (address == scanner.target_address) scanner.found = true;

    var name_buffer: [scan_name_max]u8 = undefined;
    const name_length = read_local_name(scanner.runtime, event, &name_buffer);
    assert(name_length <= scan_name_max);
    assert(scanner.count <= scan_devices_max);

    var seen: u32 = 0;

    while (seen < scanner.count) : (seen += 1) {
        if (scanner.addresses[seen] != address) continue;
        if (scanner.name_lengths[seen] == 0 and name_length > 0) {
            @memcpy(scanner.names[seen][0..name_length], name_buffer[0..name_length]);
            scanner.name_lengths[seen] = name_length;
        }
        return com.S_OK;
    }

    if (scanner.count >= scan_devices_max) return com.S_OK;
    assert(scanner.count < scan_devices_max);

    scanner.addresses[scanner.count] = address;

    if (name_length > 0) {
        @memcpy(scanner.names[scanner.count][0..name_length], name_buffer[0..name_length]);
    }

    scanner.name_lengths[scanner.count] = name_length;
    scanner.count += 1;
    assert(scanner.count <= scan_devices_max);

    return com.S_OK;
}

fn read_local_name(
    runtime: *com.Runtime,
    event: *com.IBluetoothLEAdvertisementReceivedEventArgs,
    buffer: *[scan_name_max]u8,
) u8 {
    var advertisement_ptr: ?*anyopaque = null;

    if (event.vtable.get_advertisement(event, &advertisement_ptr) != com.S_OK) return 0;
    const pointer = advertisement_ptr orelse return 0;
    const advertisement: *com.IBluetoothLEAdvertisement = @ptrCast(@alignCast(pointer));
    defer _ = com.as_unknown(advertisement).release();

    var name_handle: com.HSTRING = null;

    if (advertisement.vtable.get_local_name(advertisement, &name_handle) != com.S_OK) return 0;
    if (name_handle == null) return 0;
    defer _ = runtime.delete_string(name_handle);

    var length: u32 = 0;
    const raw = runtime.get_string_raw_buffer(name_handle, &length);
    var name_length: u8 = 0;
    var index: u32 = 0;

    while (index < length and name_length < scan_name_max) : (index += 1) {
        assert(name_length < scan_name_max);
        const code = raw[index];

        if (code >= 0x20 and code < 0x7F) {
            buffer[name_length] = @intCast(code);
            name_length += 1;
        }
    }
    assert(name_length <= scan_name_max);
    return name_length;
}

fn print_mac(out: *std.Io.Writer, address: u64) !void {
    try out.print("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        (address >> 40) & 0xFF,
        (address >> 32) & 0xFF,
        (address >> 24) & 0xFF,
        (address >> 16) & 0xFF,
        (address >> 8) & 0xFF,
        address & 0xFF,
    });
}

fn marshaler_attach(
    runtime: *com.Runtime,
    target: *anyopaque,
    slot: *?*com.IUnknown,
) !void {
    assert(slot.* == null);

    var marshaler: ?*anyopaque = null;

    if (runtime.co_create_ftm(target, &marshaler) != com.S_OK) return error.MarshalerFailed;

    slot.* = @ptrCast(@alignCast(marshaler orelse return error.MarshalerFailed));
    assert(slot.* != null);
}

fn watch_advertisements(
    runtime: *com.Runtime,
    scanner: *Scanner,
    timeout_ms: u32,
    stop_on_found: bool,
) !void {
    const inspectable = try runtime.activate_instance(
        "Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher",
    );

    const watcher_ptr = com.as_unknown(inspectable).query(
        &com.IID_IBluetoothLEAdvertisementWatcher,
    ) orelse return error.NoWatcher;

    com.as_unknown(inspectable).release();
    const watcher: *com.IBluetoothLEAdvertisementWatcher = @ptrCast(@alignCast(watcher_ptr));
    defer _ = com.as_unknown(watcher).release();

    _ = watcher.vtable.put_scanning_mode(watcher, 1);

    try marshaler_attach(runtime, @ptrCast(scanner), &scanner.free_threaded_marshaler);
    defer if (scanner.free_threaded_marshaler) |ftm| ftm.release();

    var token: i64 = 0;

    if (watcher.vtable.add_received(
        watcher,
        @ptrCast(scanner),
        &token,
    ) != com.S_OK) return error.AddReceivedFailed;
    if (watcher.vtable.start(watcher) != com.S_OK) return error.StartFailed;

    const start_tick = time.now_ms();
    var message: com.MSG = undefined;

    while ((!stop_on_found or !scanner.found) and time.now_ms() - start_tick < timeout_ms) {
        while (com.PeekMessageW(&message, null, 0, 0, 1) != 0) {
            _ = com.TranslateMessage(&message);
            _ = com.DispatchMessageW(&message);
        }
        time.sleep_ms(watch_pump_sleep_ms);
    }

    _ = watcher.vtable.stop(watcher);
    time.sleep_ms(watch_settle_ms);
}

pub fn scan(arena: std.mem.Allocator, out: *std.Io.Writer) !void {
    var runtime = try com.Runtime.init(arena);
    defer runtime.deinit();

    var scanner = Scanner{
        .vtable = &received_vtable,
        .runtime = &runtime,
        .count = 0,
        .addresses = undefined,
        .names = undefined,
        .name_lengths = undefined,
        .free_threaded_marshaler = null,
        .target_address = 0,
        .found = false,
    };

    try out.print("Scanning BLE for 8s (active)...\n", .{});
    try out.flush();
    try watch_advertisements(&runtime, &scanner, scan_window_ms, false);

    try out.print("Advertisers seen: {d}\n", .{scanner.count});
    var index: u32 = 0;

    while (index < scanner.count) : (index += 1) {
        try out.print("  ", .{});
        try print_mac(out, scanner.addresses[index]);
        try out.print("  {s}\n", .{scanner.names[index][0..scanner.name_lengths[index]]});
    }
}

fn print_guid(out: *std.Io.Writer, value: *const com.GUID) !void {
    try out.print(
        "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            value.Data1,    value.Data2,    value.Data3,    value.Data4[0], value.Data4[1],
            value.Data4[2], value.Data4[3], value.Data4[4], value.Data4[5], value.Data4[6],
            value.Data4[7],
        },
    );
}

pub fn connect(arena: std.mem.Allocator, out: *std.Io.Writer, address: u64) !void {
    var runtime = try com.Runtime.init(arena);
    defer runtime.deinit();

    const factory = try runtime.activation_factory(
        "Windows.Devices.Bluetooth.BluetoothLEDevice",
        &com.IID_IBluetoothLEDeviceStatics2,
    );

    const statics: *com.IBluetoothLEDeviceStatics2 = @ptrCast(@alignCast(factory));
    defer _ = com.as_unknown(statics).release();

    try out.print("connecting to ", .{});
    try print_mac(out, address);
    try out.print(" ...\n", .{});
    try out.flush();

    var device_operation: ?*anyopaque = null;

    if (statics.vtable.from_bluetooth_address_with_type_async(
        statics,
        address,
        1,
        &device_operation,
    ) != com.S_OK) return error.FromAddressFailed;

    const device = com.await_operation(
        device_operation orelse return error.FromAddressFailed,
    ) catch |err| {
        try out.print(
            "device not found ({s}). Is the watch advertising / in range?\n",
            .{@errorName(err)},
        );
        try out.flush();
        return;
    };

    defer _ = com.as_unknown(device).release();

    try print_device_services(&runtime, out, com.as_unknown(device), false);
}

fn print_device_services(
    runtime: *com.Runtime,
    out: *std.Io.Writer,
    device: *com.IUnknown,
    with_characteristics: bool,
) !void {
    const device3_ptr = device.query(&com.IID_IBluetoothLEDevice3) orelse
        return error.NoDevice3;
    const device3: *com.IBluetoothLEDevice3 = @ptrCast(@alignCast(device3_ptr));
    defer _ = com.as_unknown(device3).release();

    var services_operation: ?*anyopaque = null;

    if (device3.vtable.get_gatt_services_async(
        device3,
        &services_operation,
    ) != com.S_OK) return error.GetServicesFailed;

    const result_any = try com.await_operation(
        services_operation orelse return error.GetServicesFailed,
    );

    const result: *com.IGattDeviceServicesResult = @ptrCast(@alignCast(result_any));
    defer _ = com.as_unknown(result).release();

    var view_any: ?*anyopaque = null;

    if (result.vtable.get_services(
        result,
        &view_any,
    ) != com.S_OK) return error.GetServicesViewFailed;

    const view: *com.IVectorView = @ptrCast(
        @alignCast(view_any orelse return error.GetServicesViewFailed),
    );

    defer _ = com.as_unknown(view).release();

    try print_services(runtime, out, view, with_characteristics);
}

fn print_services(
    runtime: *com.Runtime,
    out: *std.Io.Writer,
    view: *com.IVectorView,
    with_characteristics: bool,
) !void {
    var size: u32 = 0;
    _ = view.vtable.get_size(view, &size);
    try out.print("GATT services: {d}\n", .{size});

    var index: u32 = 0;

    while (index < size) : (index += 1) {
        var item: ?*anyopaque = null;

        if (view.vtable.get_at(view, index, &item) != com.S_OK) continue;
        const service: *com.IGattDeviceService = @ptrCast(@alignCast(item orelse continue));
        defer _ = com.as_unknown(service).release();

        var uuid: com.GUID = undefined;
        _ = service.vtable.get_uuid(service, &uuid);
        try out.print("  ", .{});
        try print_guid(out, &uuid);
        try out.print("\n", .{});

        if (with_characteristics) try print_characteristics(runtime, out, com.as_unknown(service));
    }
}

fn print_characteristics(runtime: *com.Runtime, out: *std.Io.Writer, service: *com.IUnknown) !void {
    _ = runtime;
    const service3_ptr = service.query(&com.IID_IGattDeviceService3) orelse return;
    const service3: *com.IGattDeviceService3 = @ptrCast(@alignCast(service3_ptr));
    defer _ = com.as_unknown(service3).release();

    var operation: ?*anyopaque = null;

    if (service3.vtable.get_characteristics_async(service3, &operation) != com.S_OK) return;
    const result_any = com.await_operation(operation orelse return) catch return;
    const result: *com.IGattCharacteristicsResult = @ptrCast(@alignCast(result_any));
    defer _ = com.as_unknown(result).release();

    var view_any: ?*anyopaque = null;

    if (result.vtable.get_characteristics(result, &view_any) != com.S_OK) return;
    const view: *com.IVectorView = @ptrCast(@alignCast(view_any orelse return));
    defer _ = com.as_unknown(view).release();

    var size: u32 = 0;
    _ = view.vtable.get_size(view, &size);
    var index: u32 = 0;

    while (index < size) : (index += 1) {
        var item: ?*anyopaque = null;

        if (view.vtable.get_at(view, index, &item) != com.S_OK) continue;
        const characteristic: *com.IGattCharacteristic = @ptrCast(@alignCast(item orelse continue));
        defer _ = com.as_unknown(characteristic).release();

        var uuid: com.GUID = undefined;
        _ = characteristic.vtable.get_uuid(characteristic, &uuid);
        var properties: u32 = 0;
        _ = characteristic.vtable.get_characteristic_properties(characteristic, &properties);

        try out.print("      char ", .{});
        try print_guid(out, &uuid);
        try out.print(" [", .{});
        if (properties & 0x02 != 0) try out.print("R", .{});
        if (properties & 0x04 != 0) try out.print("w", .{});
        if (properties & 0x08 != 0) try out.print("W", .{});
        if (properties & 0x10 != 0) try out.print("N", .{});
        if (properties & 0x20 != 0) try out.print("I", .{});
        try out.print("]\n", .{});
    }
}

pub fn pull(arena: std.mem.Allocator, out: *std.Io.Writer, address: u64) !void {
    var runtime = try com.Runtime.init(arena);
    defer runtime.deinit();

    var scanner = Scanner{
        .vtable = &received_vtable,
        .runtime = &runtime,
        .count = 0,
        .addresses = undefined,
        .names = undefined,
        .name_lengths = undefined,
        .free_threaded_marshaler = null,
        .target_address = address,
        .found = false,
    };

    try out.print("waiting for watch ", .{});
    try print_mac(out, address);
    try out.print(" to advertise (up to 20s)...\n", .{});
    try out.flush();
    try watch_advertisements(&runtime, &scanner, advertise_wait_ms, true);

    if (!scanner.found) {
        try out.print(
            "watch not seen advertising. Phone Bluetooth off + watch in Pair-Phone mode?\n",
            .{},
        );

        try out.flush();
        return;
    }
    try out.print("watch advertising; connecting...\n", .{});
    try out.flush();

    const device_ptr = (try open_by_address(&runtime, address)) orelse {
        try out.print("connect failed: device object null for all address types.\n", .{});
        try out.flush();
        return;
    };

    defer _ = com.as_unknown(device_ptr).release();

    try print_device_services(&runtime, out, com.as_unknown(device_ptr), true);
}

fn wait_for_advertise(runtime: *com.Runtime, out: *std.Io.Writer, address: u64) !bool {
    var scanner = Scanner{
        .vtable = &received_vtable,
        .runtime = runtime,
        .count = 0,
        .addresses = undefined,
        .names = undefined,
        .name_lengths = undefined,
        .free_threaded_marshaler = null,
        .target_address = address,
        .found = false,
    };

    try out.print("waiting for watch ", .{});
    try print_mac(out, address);
    try out.print(" to advertise...\n", .{});
    try out.flush();
    try watch_advertisements(runtime, &scanner, advertise_wait_ms, true);

    return scanner.found;
}

fn open_by_address(runtime: *com.Runtime, address: u64) !?*anyopaque {
    const factory = try runtime.activation_factory(
        "Windows.Devices.Bluetooth.BluetoothLEDevice",
        &com.IID_IBluetoothLEDeviceStatics2,
    );

    const statics: *com.IBluetoothLEDeviceStatics2 = @ptrCast(@alignCast(factory));
    defer _ = com.as_unknown(statics).release();

    const address_types = [_]i32{ 1, 2, 0 };

    for (address_types) |address_type| {
        var operation: ?*anyopaque = null;

        if (statics.vtable.from_bluetooth_address_with_type_async(
            statics,
            address,
            address_type,
            &operation,
        ) != com.S_OK) continue;
        const opened = com.await_operation(operation orelse continue) catch null;

        if (opened) |device| return device;
    }
    return null;
}

fn find_service(device3: *com.IBluetoothLEDevice3, target: *const com.GUID) !?*anyopaque {
    var operation: ?*anyopaque = null;

    if (device3.vtable.get_gatt_services_async(device3, &operation) != com.S_OK) return null;
    const result_any = try com.await_operation(operation orelse return null);
    const result: *com.IGattDeviceServicesResult = @ptrCast(@alignCast(result_any));
    defer _ = com.as_unknown(result).release();

    var view_any: ?*anyopaque = null;

    if (result.vtable.get_services(result, &view_any) != com.S_OK) return null;
    const view: *com.IVectorView = @ptrCast(@alignCast(view_any orelse return null));
    defer _ = com.as_unknown(view).release();

    var size: u32 = 0;
    _ = view.vtable.get_size(view, &size);
    var index: u32 = 0;

    while (index < size) : (index += 1) {
        var item: ?*anyopaque = null;

        if (view.vtable.get_at(view, index, &item) != com.S_OK) continue;
        const service: *com.IGattDeviceService = @ptrCast(@alignCast(item orelse continue));
        var uuid: com.GUID = undefined;
        _ = service.vtable.get_uuid(service, &uuid);
        if (com.guid_eql(&uuid, target)) return service;
        _ = com.as_unknown(service).release();
    }
    return null;
}

fn find_characteristic(service: *anyopaque, target: *const com.GUID) !?*anyopaque {
    const service3_ptr = com.as_unknown(service).query(&com.IID_IGattDeviceService3) orelse
        return null;
    const service3: *com.IGattDeviceService3 = @ptrCast(@alignCast(service3_ptr));
    defer _ = com.as_unknown(service3).release();

    var operation: ?*anyopaque = null;

    if (service3.vtable.get_characteristics_async(service3, &operation) != com.S_OK) return null;
    const result_any = try com.await_operation(operation orelse return null);
    const result: *com.IGattCharacteristicsResult = @ptrCast(@alignCast(result_any));
    defer _ = com.as_unknown(result).release();

    var view_any: ?*anyopaque = null;

    if (result.vtable.get_characteristics(result, &view_any) != com.S_OK) return null;
    const view: *com.IVectorView = @ptrCast(@alignCast(view_any orelse return null));
    defer _ = com.as_unknown(view).release();

    var size: u32 = 0;
    _ = view.vtable.get_size(view, &size);
    var index: u32 = 0;

    while (index < size) : (index += 1) {
        var item: ?*anyopaque = null;

        if (view.vtable.get_at(view, index, &item) != com.S_OK) continue;
        const characteristic: *com.IGattCharacteristic = @ptrCast(@alignCast(item orelse continue));
        var uuid: com.GUID = undefined;
        _ = characteristic.vtable.get_uuid(characteristic, &uuid);
        if (com.guid_eql(&uuid, target)) return characteristic;
        _ = com.as_unknown(characteristic).release();
    }
    return null;
}

fn request_throughput_link(
    runtime: *com.Runtime,
    device: *anyopaque,
    out: *std.Io.Writer,
) ?*anyopaque {
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

    const statics: *com.IBluetoothLEPreferredConnectionParametersStatics = @ptrCast(
        @alignCast(factory),
    );

    defer _ = com.as_unknown(statics).release();

    var preset_any: ?*anyopaque = null;

    if (statics.vtable.get_throughput_optimized(statics, &preset_any) != com.S_OK) return null;
    const preset = preset_any orelse return null;
    defer _ = com.as_unknown(preset).release();

    const device6_ptr = com.as_unknown(device).query(&com.IID_IBluetoothLEDevice6) orelse {
        out.print(
            "IBluetoothLEDevice6 unavailable; using default interval.\n",
            .{},
        ) catch return null;

        return null;
    };

    const device6: *com.IBluetoothLEDevice6 = @ptrCast(@alignCast(device6_ptr));
    defer _ = com.as_unknown(device6).release();

    var request_any: ?*anyopaque = null;

    if (device6.vtable.request_preferred_connection_parameters(
        device6,
        preset,
        &request_any,
    ) != com.S_OK) return null;
    const request = request_any orelse return null;

    out.print("requested ThroughputOptimized connection parameters.\n", .{}) catch return request;

    return request;
}

fn log_connection_interval(device: *anyopaque, out: *std.Io.Writer, label: []const u8) void {
    const device6_ptr = com.as_unknown(device).query(&com.IID_IBluetoothLEDevice6) orelse return;
    const device6: *com.IBluetoothLEDevice6 = @ptrCast(@alignCast(device6_ptr));
    defer _ = com.as_unknown(device6).release();

    var params_any: ?*anyopaque = null;

    if (device6.vtable.get_connection_parameters(device6, &params_any) != com.S_OK) return;
    const params = params_any orelse return;
    defer _ = com.as_unknown(params).release();

    const typed: *com.IBluetoothLEConnectionParameters = @ptrCast(@alignCast(params));
    var interval_units: u16 = 0;

    if (typed.vtable.get_connection_interval(typed, &interval_units) != com.S_OK) return;

    const interval_ms_tenths = @divFloor(@as(u32, interval_units) * 125, 10);

    out.print("{s}: connection interval {d} units ({d}.{d} ms)\n", .{
        label,
        interval_units,
        @divFloor(interval_ms_tenths, 10),
        interval_ms_tenths % 10,
    }) catch return;
}

fn open_multi_link_connection(
    runtime: *com.Runtime,
    out: *std.Io.Writer,
    address: u64,
) !?MultiLinkConnection {
    const device = (try open_by_address(runtime, address)) orelse {
        try out.print("connect failed (device object null).\n", .{});
        try out.flush();
        return null;
    };

    errdefer _ = com.as_unknown(device).release();

    const device3_ptr = com.as_unknown(device).query(&com.IID_IBluetoothLEDevice3) orelse
        return error.NoDevice3;
    const device3: *com.IBluetoothLEDevice3 = @ptrCast(@alignCast(device3_ptr));
    defer _ = com.as_unknown(device3).release();

    const connection_request = request_throughput_link(runtime, device, out);
    errdefer if (connection_request) |request| {
        _ = com.as_unknown(request).release();
    };

    const service = (try find_service(device3, &multi_link_service_uuid)) orelse {
        try out.print("Multi-Link service 6a4e2800 not found.\n", .{});
        try out.flush();
        return null;
    };

    return MultiLinkConnection{
        .device = device,
        .service = service,
        .connection_request = connection_request,
    };
}

fn unsubscribe_all(subscriptions: *const Subscriptions) void {
    assert(subscriptions.count <= subscriptions_max);

    var index: u32 = 0;

    while (index < subscriptions.count) : (index += 1) {
        assert(index < subscriptions_max);

        const characteristic = subscriptions.characteristics[index];

        _ = characteristic.vtable.remove_value_changed(
            characteristic,
            subscriptions.tokens[index],
        );

        _ = com.as_unknown(characteristic).release();
    }
}

fn subscribe_notify_characteristics(
    out: *std.Io.Writer,
    service: *anyopaque,
    notifier: *notify.Notifier,
    subscriptions: *Subscriptions,
) !void {
    const service3_ptr = com.as_unknown(service).query(&com.IID_IGattDeviceService3) orelse
        return error.NoService3;
    const service3: *com.IGattDeviceService3 = @ptrCast(@alignCast(service3_ptr));
    defer _ = com.as_unknown(service3).release();

    var characteristics_operation: ?*anyopaque = null;

    if (service3.vtable.get_characteristics_async(
        service3,
        &characteristics_operation,
    ) != com.S_OK) return error.GetCharsFailed;

    const characteristics_result_any = try com.await_operation(
        characteristics_operation orelse return error.GetCharsFailed,
    );

    const characteristics_result: *com.IGattCharacteristicsResult = @ptrCast(
        @alignCast(characteristics_result_any),
    );

    defer _ = com.as_unknown(characteristics_result).release();

    var characteristics_view_any: ?*anyopaque = null;

    if (characteristics_result.vtable.get_characteristics(
        characteristics_result,
        &characteristics_view_any,
    ) != com.S_OK) return error.GetCharsViewFailed;

    const characteristics_view: *com.IVectorView = @ptrCast(
        @alignCast(characteristics_view_any orelse return error.GetCharsViewFailed),
    );

    defer _ = com.as_unknown(characteristics_view).release();

    var size: u32 = 0;
    _ = characteristics_view.vtable.get_size(characteristics_view, &size);

    var index: u32 = 0;

    while (index < size) : (index += 1) {
        var item: ?*anyopaque = null;

        if (characteristics_view.vtable.get_at(
            characteristics_view,
            index,
            &item,
        ) != com.S_OK) continue;
        const characteristic: *com.IGattCharacteristic = @ptrCast(@alignCast(item orelse continue));

        try subscribe_characteristic(out, characteristic, notifier, subscriptions);
    }
}

fn subscribe_characteristic(
    out: *std.Io.Writer,
    characteristic: *com.IGattCharacteristic,
    notifier: *notify.Notifier,
    subscriptions: *Subscriptions,
) !void {
    var properties: u32 = 0;
    _ = characteristic.vtable.get_characteristic_properties(characteristic, &properties);

    if (properties & 0x10 == 0) {
        _ = com.as_unknown(characteristic).release();
        return;
    }

    var descriptor_operation: ?*anyopaque = null;

    if (characteristic.vtable.write_cccd_async(
        characteristic,
        1,
        &descriptor_operation,
    ) == com.S_OK) {
        if (descriptor_operation) |operation| try com.await_completion(operation);
    }

    var token: i64 = 0;
    _ = characteristic.vtable.add_value_changed(characteristic, @ptrCast(notifier), &token);

    var uuid: com.GUID = undefined;
    _ = characteristic.vtable.get_uuid(characteristic, &uuid);
    try out.print("subscribed ", .{});
    try print_guid(out, &uuid);
    try out.print("\n", .{});

    if (subscriptions.count < subscriptions_max) {
        subscriptions.characteristics[subscriptions.count] = characteristic;
        subscriptions.tokens[subscriptions.count] = token;
        subscriptions.count += 1;
        assert(subscriptions.count <= subscriptions_max);
    } else {
        _ = characteristic.vtable.remove_value_changed(characteristic, token);
        _ = com.as_unknown(characteristic).release();
    }
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

pub fn observe(arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, address: u64) !void {
    const state = try arena.create(lock.GFDIState);
    const session = try arena.create(Runner.Session);

    const buffers = runner.Buffers{
        .inflate = try arena.alloc(u8, session_module.inflate_output_max),
        .legacy = try arena.alloc(u8, session_module.legacy_buffer_max),
        .protobuf = try arena.alloc(u8, session_module.protobuf_buffer_max),
        .transfer = try arena.alloc(u8, reassembly.transfer_buffer_max),
    };

    try Runner.run_attempts(out, ObserveAttempt{
        .arena = arena,
        .io = io,
        .out = out,
        .address = address,
        .state = state,
        .session = session,
        .buffers = &buffers,
    });
}

fn observe_once(attempt: ObserveAttempt) !bool {
    const out = attempt.out;
    const state = attempt.state;

    var runtime = try com.Runtime.init(attempt.arena);
    defer runtime.deinit();

    time.begin_precise();
    defer time.end_precise();

    if (!try wait_for_advertise(&runtime, out, attempt.address)) {
        try out.print("watch not seen advertising (phone BT off + watch awake?).\n", .{});
        try out.flush();
        return false;
    }

    const connection = (try open_multi_link_connection(&runtime, out, attempt.address)) orelse
        return false;
    defer connection.deinit();

    state.* = .{};
    state.transfer_buffer = attempt.buffers.transfer;

    var notifier = notify.Notifier{
        .vtable = &notify.notifier_vtable,
        .runtime = &runtime,
        .free_threaded_marshaler = null,
        .state = state,
    };

    try marshaler_attach(&runtime, @ptrCast(&notifier), &notifier.free_threaded_marshaler);
    defer if (notifier.free_threaded_marshaler) |marshaler| marshaler.release();

    var subscriptions = Subscriptions{};

    try subscribe_notify_characteristics(out, connection.service, &notifier, &subscriptions);
    defer unsubscribe_all(&subscriptions);

    const tx_any = (try find_characteristic(connection.service, &multi_link_tx_uuid)) orelse {
        try out.print("ML write characteristic 6a4e2820 not found.\n", .{});
        try out.flush();
        return false;
    };

    const tx: *com.IGattCharacteristic = @ptrCast(@alignCast(tx_any));
    defer _ = com.as_unknown(tx).release();

    var backend = ble_transport.Backend{ .runtime = &runtime, .tx = tx };

    try multi_link_register_gfdi(&backend, out);

    var transport = BLELink{ .backend = &backend, .state = state };

    const hooks = StreamingHooks{ .device = connection.device, .out = out };

    Runner.init_session(
        attempt.session,
        &transport,
        out,
        .{},
        .{ .io = attempt.io },
        attempt.buffers,
    );

    try Runner.run_pump(out, attempt.session, state, hooks);

    return attempt.session.archive.complete;
}

pub fn smoke(arena: std.mem.Allocator, out: *std.Io.Writer) !void {
    var runtime = try com.Runtime.init(arena);
    defer runtime.deinit();

    const class = "Windows.Devices.Bluetooth.BluetoothLEDevice";
    const handle = try runtime.string(class);
    defer runtime.delete(handle);

    const round_trip = try runtime.to_utf8(handle);

    try out.print("WinRT OK (combase loaded, RoInitialize ok).\n", .{});
    try out.print("HSTRING round-trip: {s}\n", .{round_trip});

    const selector = try ble_device_selector(&runtime);

    try out.print("BLE AQS selector: {s}\n", .{selector});
}
