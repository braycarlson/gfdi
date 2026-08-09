const std = @import("std");

const client = @import("dbus/client.zig");
const time = @import("time.zig");
const variant = @import("dbus/variant.zig");
const wire = @import("dbus/wire.zig");

const assert = std.debug.assert;

pub const service = "org.bluez";
pub const root_path = "/";

pub const adapter_interface = "org.bluez.Adapter1";
pub const device_interface = "org.bluez.Device1";
pub const gatt_service_interface = "org.bluez.GattService1";
pub const gatt_characteristic_interface = "org.bluez.GattCharacteristic1";

pub const object_manager_interface = "org.freedesktop.DBus.ObjectManager";
pub const properties_interface = "org.freedesktop.DBus.Properties";

pub const devices_max: u32 = 64;
pub const services_max: u32 = 64;
pub const characteristics_max: u32 = 256;

pub const path_bytes_max: u32 = 128;
pub const address_bytes_max: u32 = 17;
pub const name_bytes_max: u32 = 48;
pub const uuid_bytes_max: u32 = 48;

pub const body_bytes_max: u32 = 4096;
pub const objects_scan_max: u32 = 4096;
pub const interfaces_scan_max: u32 = 64;
pub const properties_scan_max: u32 = 128;
pub const pump_messages_max: u32 = 4096;
pub const pump_poll_ms: u32 = 20;

const match_prefix = "type='signal',sender='" ++ service ++ "',interface='";

pub const Error = error{
    Malformed,
    NoAdapter,
};

pub const Flags = struct {
    indicate: bool = false,
    notify: bool = false,
    read: bool = false,
    write: bool = false,
    write_without_response: bool = false,
};

comptime {
    assert(devices_max > 0);
    assert(services_max > 0);
    assert(characteristics_max >= services_max);
    assert(path_bytes_max > address_bytes_max);
    assert(address_bytes_max == 17);
    assert(uuid_bytes_max > 36);
    assert(body_bytes_max > 0);
    assert(objects_scan_max > 0);
    assert(interfaces_scan_max > 0);
    assert(properties_scan_max > 0);
    assert(pump_messages_max > 0);
    assert(pump_poll_ms > 0);
    assert(service.len > 0);
    assert(root_path[0] == '/');
}

pub fn TextType(comptime capacity: u32) type {
    return struct {
        const Instance = @This();

        bytes: [capacity]u8 = undefined,
        length: u32 = 0,

        pub fn set(instance: *Instance, value: []const u8) void {
            const length = @min(value.len, capacity);

            @memcpy(instance.bytes[0..length], value[0..length]);

            instance.length = @intCast(length);

            assert(instance.length <= capacity);
        }

        pub fn slice(instance: *const Instance) []const u8 {
            assert(instance.length <= capacity);

            return instance.bytes[0..instance.length];
        }

        pub fn eql(instance: *const Instance, value: []const u8) bool {
            return std.mem.eql(u8, instance.slice(), value);
        }
    };
}

pub const Path = TextType(path_bytes_max);
pub const Address = TextType(address_bytes_max);
pub const Name = TextType(name_bytes_max);
pub const Uuid = TextType(uuid_bytes_max);

pub const Device = struct {
    address: Address = .{},
    connected: bool = false,
    name: Name = .{},
    path: Path = .{},
    resolved: bool = false,
    rssi: i16 = 0,
};

pub const Service = struct {
    device: Path = .{},
    path: Path = .{},
    uuid: Uuid = .{},
};

pub const Characteristic = struct {
    flags: Flags = .{},
    path: Path = .{},
    service: Path = .{},
    uuid: Uuid = .{},
};

const Slot = union(enum) {
    adapter: void,
    characteristic: u32,
    device: u32,
    ignored: void,
    service: u32,
};

pub const Objects = struct {
    adapter: Path = .{},
    characteristic_count: u32 = 0,
    characteristics: [characteristics_max]Characteristic = undefined,
    device_count: u32 = 0,
    devices: [devices_max]Device = undefined,
    service_count: u32 = 0,
    services: [services_max]Service = undefined,

    pub fn reset(objects: *Objects) void {
        objects.adapter = .{};
        objects.characteristic_count = 0;
        objects.device_count = 0;
        objects.service_count = 0;
    }

    pub fn find_device(objects: *const Objects, path: []const u8) ?*const Device {
        var index: u32 = 0;

        while (index < objects.device_count) : (index += 1) {
            if (objects.devices[index].path.eql(path)) return &objects.devices[index];
        }

        return null;
    }

    pub fn find_service(
        objects: *const Objects,
        device: []const u8,
        uuid: []const u8,
    ) ?*const Service {
        var index: u32 = 0;

        while (index < objects.service_count) : (index += 1) {
            const candidate = &objects.services[index];

            if (!candidate.device.eql(device)) continue;
            if (candidate.uuid.eql(uuid)) return candidate;
        }

        return null;
    }

    pub fn find_characteristic(
        objects: *const Objects,
        owner: []const u8,
        uuid: []const u8,
    ) ?*const Characteristic {
        var index: u32 = 0;

        while (index < objects.characteristic_count) : (index += 1) {
            const candidate = &objects.characteristics[index];

            if (!candidate.service.eql(owner)) continue;
            if (candidate.uuid.eql(uuid)) return candidate;
        }

        return null;
    }

    fn open(objects: *Objects, interface: []const u8, path: []const u8) Slot {
        if (std.mem.eql(u8, interface, adapter_interface)) {
            if (objects.adapter.length == 0) objects.adapter.set(path);

            return .adapter;
        }

        if (std.mem.eql(u8, interface, device_interface)) return objects.open_device(path);
        if (std.mem.eql(u8, interface, gatt_service_interface)) return objects.open_service(path);

        if (std.mem.eql(u8, interface, gatt_characteristic_interface)) {
            return objects.open_characteristic(path);
        }

        return .ignored;
    }

    fn open_device(objects: *Objects, path: []const u8) Slot {
        var index: u32 = 0;

        while (index < objects.device_count) : (index += 1) {
            if (objects.devices[index].path.eql(path)) return .{ .device = index };
        }

        if (objects.device_count == devices_max) return .ignored;

        const slot = objects.device_count;

        objects.devices[slot] = .{};
        objects.devices[slot].path.set(path);
        objects.device_count += 1;

        assert(objects.device_count <= devices_max);

        return .{ .device = slot };
    }

    fn open_service(objects: *Objects, path: []const u8) Slot {
        var index: u32 = 0;

        while (index < objects.service_count) : (index += 1) {
            if (objects.services[index].path.eql(path)) return .{ .service = index };
        }

        if (objects.service_count == services_max) return .ignored;

        const slot = objects.service_count;

        objects.services[slot] = .{};
        objects.services[slot].path.set(path);
        objects.service_count += 1;

        assert(objects.service_count <= services_max);

        return .{ .service = slot };
    }

    fn open_characteristic(objects: *Objects, path: []const u8) Slot {
        var index: u32 = 0;

        while (index < objects.characteristic_count) : (index += 1) {
            if (objects.characteristics[index].path.eql(path)) return .{ .characteristic = index };
        }

        if (objects.characteristic_count == characteristics_max) return .ignored;

        const slot = objects.characteristic_count;

        objects.characteristics[slot] = .{};
        objects.characteristics[slot].path.set(path);
        objects.characteristic_count += 1;

        assert(objects.characteristic_count <= characteristics_max);

        return .{ .characteristic = slot };
    }

    fn apply(objects: *Objects, slot: Slot, key: []const u8, value: variant.Value) void {
        switch (slot) {
            .adapter, .ignored => {},
            .characteristic => |index| apply_characteristic(
                &objects.characteristics[index],
                key,
                value,
            ),
            .device => |index| apply_device(&objects.devices[index], key, value),
            .service => |index| apply_service(&objects.services[index], key, value),
        }
    }
};

fn apply_device(device: *Device, key: []const u8, value: variant.Value) void {
    if (std.mem.eql(u8, key, "Address")) {
        if (value == .text) device.address.set(value.text);

        return;
    }

    if (std.mem.eql(u8, key, "Name")) {
        if (value == .text) device.name.set(value.text);

        return;
    }

    if (std.mem.eql(u8, key, "Alias")) {
        if (value == .text and device.name.length == 0) device.name.set(value.text);

        return;
    }

    if (std.mem.eql(u8, key, "Connected")) {
        if (value == .boolean) device.connected = value.boolean;

        return;
    }

    if (std.mem.eql(u8, key, "ServicesResolved")) {
        if (value == .boolean) device.resolved = value.boolean;

        return;
    }

    if (std.mem.eql(u8, key, "RSSI")) {
        if (value == .integer) device.rssi = @truncate(value.integer);
    }
}

fn apply_service(instance: *Service, key: []const u8, value: variant.Value) void {
    if (std.mem.eql(u8, key, "UUID")) {
        if (value == .text) instance.uuid.set(value.text);

        return;
    }

    if (std.mem.eql(u8, key, "Device")) {
        if (value == .text) instance.device.set(value.text);
    }
}

fn apply_characteristic(
    characteristic: *Characteristic,
    key: []const u8,
    value: variant.Value,
) void {
    if (std.mem.eql(u8, key, "UUID")) {
        if (value == .text) characteristic.uuid.set(value.text);

        return;
    }

    if (std.mem.eql(u8, key, "Service")) {
        if (value == .text) characteristic.service.set(value.text);

        return;
    }

    if (std.mem.eql(u8, key, "Flags")) {
        if (value == .strings) characteristic.flags = read_flags(value.strings);
    }
}

fn read_flags(list: variant.StringList) Flags {
    return .{
        .indicate = list.contains("indicate"),
        .notify = list.contains("notify"),
        .read = list.contains("read"),
        .write = list.contains("write"),
        .write_without_response = list.contains("write-without-response"),
    };
}

pub fn refresh(objects: *Objects) !void {
    objects.reset();

    const reply = try client.call(.{
        .destination = service,
        .interface = object_manager_interface,
        .member = "GetManagedObjects",
        .path = root_path,
    }, &.{});

    try parse_managed_objects(objects, reply.body);
}

fn parse_managed_objects(objects: *Objects, body: []const u8) !void {
    var reader = wire.Reader.init(body);

    const length = try reader.take_u32();

    try reader.skip_to(8);

    if (reader.remaining() < length) {
        return Error.Malformed;
    }

    const end = reader.offset + length;

    var scanned: u32 = 0;

    while (reader.offset < end) {
        scanned += 1;

        if (scanned > objects_scan_max) {
            return Error.Malformed;
        }

        try parse_object(objects, &reader, end);
    }
}

fn parse_object(objects: *Objects, reader: *wire.Reader, end: u32) !void {
    try reader.skip_to(8);

    if (reader.offset >= end) return;

    const path = try reader.take_string();
    const length = try reader.take_u32();

    try reader.skip_to(8);

    if (reader.remaining() < length) {
        return Error.Malformed;
    }

    const interfaces_end = reader.offset + length;

    var scanned: u32 = 0;

    while (reader.offset < interfaces_end) {
        scanned += 1;

        if (scanned > interfaces_scan_max) {
            return Error.Malformed;
        }

        try parse_interface(objects, reader, path, interfaces_end);
    }
}

fn parse_interface(objects: *Objects, reader: *wire.Reader, path: []const u8, end: u32) !void {
    try reader.skip_to(8);

    if (reader.offset >= end) return;

    const interface = try reader.take_string();
    const slot = objects.open(interface, path);

    try parse_properties(objects, reader, slot);
}

fn parse_properties(objects: *Objects, reader: *wire.Reader, slot: Slot) !void {
    const length = try reader.take_u32();

    try reader.skip_to(8);

    if (reader.remaining() < length) {
        return Error.Malformed;
    }

    const end = reader.offset + length;

    var scanned: u32 = 0;

    while (reader.offset < end) {
        scanned += 1;

        if (scanned > properties_scan_max) {
            return Error.Malformed;
        }

        try reader.skip_to(8);

        if (reader.offset >= end) break;

        const key = try reader.take_string();
        const value = try variant.take_variant(reader);

        objects.apply(slot, key, value);
    }
}

fn parse_properties_changed(objects: *Objects, path: []const u8, body: []const u8) !void {
    var reader = wire.Reader.init(body);

    const interface = try reader.take_string();
    const slot = objects.open(interface, path);

    try parse_properties(objects, &reader, slot);
}

pub fn subscribe() !void {
    try client.add_match(match_prefix ++ object_manager_interface ++ "'");
    try client.add_match(match_prefix ++ properties_interface ++ "'");
}

pub fn pump(objects: *Objects, deadline_ms: u64, notify: anytype) !void {
    var drained: u32 = 0;

    while (time.now_ms() < deadline_ms) {
        drained += 1;

        if (drained > pump_messages_max) return;

        const message = client.take_message() catch return;

        if (message) |received| {
            try dispatch(objects, received, notify);

            continue;
        }

        const ready = client.fill(false) catch return;

        if (!ready) time.sleep_ms(pump_poll_ms);
    }
}

pub fn drain(objects: *Objects, notify: anytype) !void {
    var drained: u32 = 0;

    while (drained < pump_messages_max) : (drained += 1) {
        const message = client.take_message() catch return;

        const received = message orelse {
            const ready = client.fill(false) catch return;

            if (!ready) return;

            continue;
        };

        try dispatch(objects, received, notify);
    }
}

fn dispatch(objects: *Objects, message: client.Message, notify: anytype) !void {
    if (message.header.kind != .signal) return;

    const member = message.header.member;

    if (std.mem.eql(u8, member, "InterfacesAdded")) {
        var reader = wire.Reader.init(message.body);

        parse_object(objects, &reader, @intCast(message.body.len)) catch return;

        return;
    }

    if (!std.mem.eql(u8, member, "PropertiesChanged")) return;

    parse_properties_changed(objects, message.header.path, message.body) catch return;

    notify.on_properties(message.header.path, message.body);
}

pub fn notification_bytes(body: []const u8) ?[]const u8 {
    var reader = wire.Reader.init(body);

    const interface = reader.take_string() catch return null;

    if (!std.mem.eql(u8, interface, gatt_characteristic_interface)) return null;

    const length = reader.take_u32() catch return null;

    reader.skip_to(8) catch return null;

    if (reader.remaining() < length) return null;

    const end = reader.offset + length;

    var scanned: u32 = 0;

    while (reader.offset < end) {
        scanned += 1;

        if (scanned > properties_scan_max) return null;

        reader.skip_to(8) catch return null;

        if (reader.offset >= end) break;

        const key = reader.take_string() catch return null;
        const value = variant.take_variant(&reader) catch return null;

        if (!std.mem.eql(u8, key, "Value")) continue;
        if (value != .bytes) continue;

        return value.bytes;
    }

    return null;
}

pub const NoNotify = struct {
    pub fn on_properties(sink: NoNotify, path: []const u8, body: []const u8) void {
        _ = sink;
        _ = path;
        _ = body;
    }
};

pub fn device_path(buffer: []u8, adapter: []const u8, address: u64) []const u8 {
    assert(adapter.len > 0);
    assert(buffer.len >= path_bytes_max);

    return std.fmt.bufPrint(
        buffer,
        "{s}/dev_{X:0>2}_{X:0>2}_{X:0>2}_{X:0>2}_{X:0>2}_{X:0>2}",
        .{
            adapter,
            (address >> 40) & 0xFF,
            (address >> 32) & 0xFF,
            (address >> 24) & 0xFF,
            (address >> 16) & 0xFF,
            (address >> 8) & 0xFF,
            address & 0xFF,
        },
    ) catch buffer[0..0];
}

pub fn format_address(buffer: []u8, address: u64) []const u8 {
    assert(buffer.len >= address_bytes_max);

    return std.fmt.bufPrint(
        buffer,
        "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}",
        .{
            (address >> 40) & 0xFF,
            (address >> 32) & 0xFF,
            (address >> 24) & 0xFF,
            (address >> 16) & 0xFF,
            (address >> 8) & 0xFF,
            address & 0xFF,
        },
    ) catch buffer[0..0];
}

pub fn set_discovery_filter(adapter: []const u8) !void {
    var storage: [body_bytes_max]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    const marker = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try variant.put_dict_entry_string(&writer, "Transport", "le");
    try writer.close_array(marker);

    _ = try client.call(.{
        .destination = service,
        .interface = adapter_interface,
        .member = "SetDiscoveryFilter",
        .path = adapter,
        .signature = "a{sv}",
    }, writer.bytes());
}

pub fn start_discovery(adapter: []const u8) !void {
    _ = try client.call(.{
        .destination = service,
        .interface = adapter_interface,
        .member = "StartDiscovery",
        .path = adapter,
    }, &.{});
}

pub fn stop_discovery(adapter: []const u8) !void {
    _ = try client.call(.{
        .destination = service,
        .interface = adapter_interface,
        .member = "StopDiscovery",
        .path = adapter,
    }, &.{});
}

pub fn remove_device(adapter: []const u8, path: []const u8) !void {
    var storage: [body_bytes_max]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    try writer.put_string(path);

    _ = try client.call(.{
        .destination = service,
        .interface = adapter_interface,
        .member = "RemoveDevice",
        .path = adapter,
        .signature = "o",
    }, writer.bytes());
}

pub fn device_connect(path: []const u8) !void {
    _ = try client.call(.{
        .destination = service,
        .interface = device_interface,
        .member = "Connect",
        .path = path,
    }, &.{});
}

pub fn device_disconnect(path: []const u8) !void {
    _ = try client.call(.{
        .destination = service,
        .interface = device_interface,
        .member = "Disconnect",
        .path = path,
    }, &.{});
}

pub fn start_notify(path: []const u8) !void {
    _ = try client.call(.{
        .destination = service,
        .interface = gatt_characteristic_interface,
        .member = "StartNotify",
        .path = path,
    }, &.{});
}

pub fn stop_notify(path: []const u8) !void {
    _ = try client.call(.{
        .destination = service,
        .interface = gatt_characteristic_interface,
        .member = "StopNotify",
        .path = path,
    }, &.{});
}

pub fn write_value(path: []const u8, bytes: []const u8, command: bool) !void {
    assert(bytes.len > 0);

    var storage: [body_bytes_max]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    const payload = try writer.open_array(wire.align_of(wire.code_byte));

    try writer.put_slice(bytes);
    try writer.close_array(payload);

    const options = try writer.open_array(wire.align_of(wire.code_dict_entry));

    if (command) try variant.put_dict_entry_string(&writer, "type", "command");

    try writer.close_array(options);

    _ = try client.call(.{
        .destination = service,
        .interface = gatt_characteristic_interface,
        .member = "WriteValue",
        .path = path,
        .signature = "aya{sv}",
    }, writer.bytes());
}

const testing = std.testing;

test "device_path renders the BlueZ object path for a MAC" {
    var buffer: [path_bytes_max]u8 = undefined;

    try testing.expectEqualStrings(
        "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6",
        device_path(&buffer, "/org/bluez/hci0", 0xF1E2D3C4B5A6),
    );
}

test "format_address renders the colon separated MAC" {
    var buffer: [address_bytes_max]u8 = undefined;

    try testing.expectEqualStrings("00:11:22:33:44:55", format_address(&buffer, 0x001122334455));
}

test "a text field truncates rather than overflowing" {
    var name: Name = .{};

    name.set("x" ** (name_bytes_max + 8));

    try testing.expectEqual(@as(u32, name_bytes_max), name.length);
    try testing.expect(name.eql("x" ** name_bytes_max));
}

fn stage_managed_objects(storage: []u8) ![]const u8 {
    var writer = wire.Writer.init(storage);

    const outer = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try writer.pad_to(8);
    try writer.put_string("/org/bluez/hci0");

    const interfaces = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try writer.pad_to(8);
    try writer.put_string(adapter_interface);

    const adapter_properties = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try variant.put_dict_entry_string(&writer, "Address", "AA:BB:CC:DD:EE:FF");
    try writer.close_array(adapter_properties);
    try writer.close_array(interfaces);

    try writer.pad_to(8);
    try writer.put_string("/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6");

    const device_interfaces = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try writer.pad_to(8);
    try writer.put_string(device_interface);

    const device_properties = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try variant.put_dict_entry_string(&writer, "Address", "F1:E2:D3:C4:B5:A6");
    try variant.put_dict_entry_string(&writer, "Alias", "fenix");
    try variant.put_dict_entry_bool(&writer, "Connected", true);
    try writer.close_array(device_properties);
    try writer.close_array(device_interfaces);
    try writer.close_array(outer);

    return writer.bytes();
}

test "parse_managed_objects records the adapter and its devices" {
    var storage: [1024]u8 = undefined;
    const body = try stage_managed_objects(&storage);

    const objects = try testing.allocator.create(Objects);
    defer testing.allocator.destroy(objects);

    objects.reset();

    try parse_managed_objects(objects, body);

    try testing.expectEqualStrings("/org/bluez/hci0", objects.adapter.slice());
    try testing.expectEqual(@as(u32, 1), objects.device_count);

    const device = objects.find_device("/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6").?;

    try testing.expectEqualStrings("F1:E2:D3:C4:B5:A6", device.address.slice());
    try testing.expectEqualStrings("fenix", device.name.slice());
    try testing.expect(device.connected);
    try testing.expect(!device.resolved);
}

fn stage_gatt_objects(storage: []u8) ![]const u8 {
    var writer = wire.Writer.init(storage);

    const outer = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try writer.pad_to(8);
    try writer.put_string("/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6/service001f");

    const service_interfaces = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try writer.pad_to(8);
    try writer.put_string(gatt_service_interface);

    const service_properties = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try variant.put_dict_entry_string(&writer, "UUID", "6a4e2800-667b-11e3-949a-0800200c9a66");

    try writer.pad_to(8);
    try writer.put_string("Device");
    try variant.put_object_variant(&writer, "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6");
    try writer.close_array(service_properties);
    try writer.close_array(service_interfaces);

    try writer.pad_to(8);
    try writer.put_string("/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6/service001f/char0020");

    const char_interfaces = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try writer.pad_to(8);
    try writer.put_string(gatt_characteristic_interface);

    const char_properties = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try variant.put_dict_entry_string(&writer, "UUID", "6a4e2820-667b-11e3-949a-0800200c9a66");

    try writer.pad_to(8);
    try writer.put_string("Service");
    try variant.put_object_variant(&writer, "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6/service001f");

    try writer.pad_to(8);
    try writer.put_string("Flags");
    try writer.put_signature("as");

    const flags = try writer.open_array(4);

    try writer.put_string("write-without-response");
    try writer.put_string("notify");
    try writer.close_array(flags);
    try writer.close_array(char_properties);
    try writer.close_array(char_interfaces);
    try writer.close_array(outer);

    return writer.bytes();
}

test "parse_managed_objects records GATT services and their characteristics" {
    var storage: [2048]u8 = undefined;
    const body = try stage_gatt_objects(&storage);

    const objects = try testing.allocator.create(Objects);
    defer testing.allocator.destroy(objects);

    objects.reset();

    try parse_managed_objects(objects, body);

    try testing.expectEqual(@as(u32, 1), objects.service_count);
    try testing.expectEqual(@as(u32, 1), objects.characteristic_count);

    const device = "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6";
    const found = objects.find_service(device, "6a4e2800-667b-11e3-949a-0800200c9a66").?;

    try testing.expectEqualStrings(device ++ "/service001f", found.path.slice());

    const tx = objects.find_characteristic(
        found.path.slice(),
        "6a4e2820-667b-11e3-949a-0800200c9a66",
    ).?;

    try testing.expect(tx.flags.notify);
    try testing.expect(tx.flags.write_without_response);
    try testing.expect(!tx.flags.write);
    try testing.expect(!tx.flags.read);
    try testing.expect(!tx.flags.indicate);
}

test "parse_properties_changed updates a device the table already holds" {
    var storage: [1024]u8 = undefined;
    const body = try stage_managed_objects(&storage);

    const objects = try testing.allocator.create(Objects);
    defer testing.allocator.destroy(objects);

    objects.reset();

    try parse_managed_objects(objects, body);

    var changed: [256]u8 = undefined;
    var writer = wire.Writer.init(&changed);

    try writer.put_string(device_interface);

    const properties = try writer.open_array(wire.align_of(wire.code_dict_entry));

    try variant.put_dict_entry_bool(&writer, "ServicesResolved", true);
    try writer.close_array(properties);

    const path = "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6";

    try parse_properties_changed(objects, path, writer.bytes());

    try testing.expectEqual(@as(u32, 1), objects.device_count);
    try testing.expect(objects.find_device(path).?.resolved);
}
