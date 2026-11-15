const std = @import("std");

const bounded = @import("bounded");

const dbus = @import("dbus.zig");
const time = @import("time.zig");

const assert = std.debug.assert;

const Client = dbus.Client;
const variant = dbus.variant;
const wire = dbus.wire;

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

pub const Error = Client.Error || wire.Error;

pub const Flags = struct {
    indicate: bool,
    notify: bool,
    read: bool,
    write: bool,
    write_without_response: bool,

    pub const none: Flags = .{
        .indicate = false,
        .notify = false,
        .read = false,
        .write = false,
        .write_without_response = false,
    };
};

pub const Path = bounded.BufferType(path_bytes_max);
pub const Address = bounded.BufferType(address_bytes_max);
pub const Name = bounded.BufferType(name_bytes_max);
pub const UUID = bounded.BufferType(uuid_bytes_max);

pub const Device = struct {
    address: Address,
    connected: bool,
    name: Name,
    path: Path,
    resolved: bool,
    rssi: i16,
};

pub const Service = struct {
    device: Path,
    path: Path,
    uuid: UUID,
};

pub const Characteristic = struct {
    flags: Flags,
    path: Path,
    service: Path,
    uuid: UUID,
};

pub const ServiceQuery = struct {
    device: []const u8,
    uuid: []const u8,
};

pub const CharacteristicQuery = struct {
    service: []const u8,
    uuid: []const u8,
};

pub const PropertiesChanged = struct {
    body: []const u8,
    path: []const u8,
};

pub const Removal = struct {
    adapter: []const u8,
    device: []const u8,
};

pub const Write = struct {
    bytes: []const u8,
    kind: Kind,
    path: []const u8,

    pub const Kind = enum {
        command,
        request,
    };
};

const Opening = struct {
    interface: []const u8,
    path: []const u8,
};

const Slot = union(enum) {
    adapter: void,
    characteristic: u32,
    device: u32,
    ignored: void,
    service: u32,
};

pub const Objects = struct {
    adapter: Path = .empty,
    characteristics: bounded.ArrayType(Characteristic, characteristics_max) = .empty,
    devices: bounded.ArrayType(Device, devices_max) = .empty,
    services: bounded.ArrayType(Service, services_max) = .empty,

    pub fn reset(objects: *Objects) void {
        assert(objects.devices.count <= devices_max);

        objects.adapter.clear();
        objects.characteristics.clear();
        objects.devices.clear();
        objects.services.clear();

        assert(objects.devices.count == 0);
    }

    pub fn find_device(objects: *const Objects, path: []const u8) ?*const Device {
        assert(path.len > 0);
        assert(objects.devices.count <= devices_max);

        for (objects.devices.slice()) |*device| {
            if (std.mem.eql(u8, device.path.slice(), path)) return device;
        }

        return null;
    }

    pub fn find_service(objects: *const Objects, query: ServiceQuery) ?*const Service {
        assert(query.device.len > 0);
        assert(query.uuid.len > 0);

        for (objects.services.slice()) |*candidate| {
            if (!std.mem.eql(u8, candidate.device.slice(), query.device)) continue;
            if (std.mem.eql(u8, candidate.uuid.slice(), query.uuid)) return candidate;
        }

        return null;
    }

    pub fn find_characteristic(
        objects: *const Objects,
        query: CharacteristicQuery,
    ) ?*const Characteristic {
        assert(query.service.len > 0);
        assert(query.uuid.len > 0);

        for (objects.characteristics.slice()) |*candidate| {
            if (!std.mem.eql(u8, candidate.service.slice(), query.service)) continue;
            if (std.mem.eql(u8, candidate.uuid.slice(), query.uuid)) return candidate;
        }

        return null;
    }

    fn open(objects: *Objects, opening: Opening) Slot {
        assert(opening.interface.len > 0);
        assert(opening.path.len > 0);

        if (std.mem.eql(u8, opening.interface, adapter_interface)) {
            if (objects.adapter.count() == 0) {
                text_set(path_bytes_max, &objects.adapter, opening.path);
            }

            return .adapter;
        }

        if (std.mem.eql(u8, opening.interface, device_interface)) {
            return objects.open_device(opening.path);
        }

        if (std.mem.eql(u8, opening.interface, gatt_service_interface)) {
            return objects.open_service(opening.path);
        }

        if (std.mem.eql(u8, opening.interface, gatt_characteristic_interface)) {
            return objects.open_characteristic(opening.path);
        }

        return .ignored;
    }

    fn open_device(objects: *Objects, path: []const u8) Slot {
        assert(path.len > 0);
        assert(objects.devices.count <= devices_max);

        for (objects.devices.slice(), 0..) |*device, index| {
            if (std.mem.eql(u8, device.path.slice(), path)) return .{ .device = @intCast(index) };
        }

        if (objects.devices.full()) return .ignored;

        const slot = objects.devices.push_slot_assume_capacity();

        slot.* = .{
            .address = .empty,
            .connected = false,
            .name = .empty,
            .path = .empty,
            .resolved = false,
            .rssi = 0,
        };

        text_set(path_bytes_max, &slot.path, path);

        return .{ .device = objects.devices.count - 1 };
    }

    fn open_service(objects: *Objects, path: []const u8) Slot {
        assert(path.len > 0);
        assert(objects.services.count <= services_max);

        for (objects.services.slice(), 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.path.slice(), path)) {
                return .{ .service = @intCast(index) };
            }
        }

        if (objects.services.full()) return .ignored;

        const slot = objects.services.push_slot_assume_capacity();

        slot.* = .{ .device = .empty, .path = .empty, .uuid = .empty };

        text_set(path_bytes_max, &slot.path, path);

        return .{ .service = objects.services.count - 1 };
    }

    fn open_characteristic(objects: *Objects, path: []const u8) Slot {
        assert(path.len > 0);
        assert(objects.characteristics.count <= characteristics_max);

        for (objects.characteristics.slice(), 0..) |*existing, index| {
            if (std.mem.eql(u8, existing.path.slice(), path)) {
                return .{ .characteristic = @intCast(index) };
            }
        }

        if (objects.characteristics.full()) return .ignored;

        const slot = objects.characteristics.push_slot_assume_capacity();

        slot.* = .{ .flags = .none, .path = .empty, .service = .empty, .uuid = .empty };

        text_set(path_bytes_max, &slot.path, path);

        return .{ .characteristic = objects.characteristics.count - 1 };
    }

    fn apply(objects: *Objects, slot: Slot, property: Property) void {
        assert(property.key.len > 0);
        assert(objects.devices.count <= devices_max);

        switch (slot) {
            .adapter, .ignored => {},
            .characteristic => |index| apply_characteristic(
                objects.characteristics.get_mutable(index),
                property,
            ),
            .device => |index| apply_device(objects.devices.get_mutable(index), property),
            .service => |index| apply_service(objects.services.get_mutable(index), property),
        }
    }
};

const Property = struct {
    key: []const u8,
    value: variant.Value,
};

fn text_set(
    comptime capacity: u32,
    buffer: *bounded.BufferType(capacity),
    value: []const u8,
) void {
    comptime assert(capacity > 0);
    assert(value.len <= Client.receive_bytes_max);

    const length = @min(value.len, capacity);

    buffer.clear();
    buffer.array.push_slice_assume_capacity(value[0..length]);

    assert(buffer.count() == length);
}

fn apply_device(device: *Device, property: Property) void {
    assert(property.key.len > 0);
    assert(device.path.count() > 0);

    const key = property.key;
    const value = property.value;

    if (std.mem.eql(u8, key, "Address")) {
        if (value == .text) text_set(address_bytes_max, &device.address, value.text);
    } else if (std.mem.eql(u8, key, "Name")) {
        if (value == .text) text_set(name_bytes_max, &device.name, value.text);
    } else if (std.mem.eql(u8, key, "Alias")) {
        if (value == .text) {
            if (device.name.count() == 0) text_set(name_bytes_max, &device.name, value.text);
        }
    } else {
        apply_device_state(device, property);
    }
}

fn apply_device_state(device: *Device, property: Property) void {
    assert(property.key.len > 0);
    assert(device.path.count() > 0);

    const key = property.key;
    const value = property.value;

    if (std.mem.eql(u8, key, "Connected")) {
        if (value == .boolean) device.connected = value.boolean;
    } else if (std.mem.eql(u8, key, "ServicesResolved")) {
        if (value == .boolean) device.resolved = value.boolean;
    } else if (std.mem.eql(u8, key, "RSSI")) {
        if (value == .integer) device.rssi = @truncate(value.integer);
    } else {}
}

fn apply_service(instance: *Service, property: Property) void {
    assert(property.key.len > 0);
    assert(instance.path.count() > 0);

    if (property.value != .text) return;

    if (std.mem.eql(u8, property.key, "UUID")) {
        text_set(uuid_bytes_max, &instance.uuid, property.value.text);
    } else if (std.mem.eql(u8, property.key, "Device")) {
        text_set(path_bytes_max, &instance.device, property.value.text);
    } else {}
}

fn apply_characteristic(characteristic: *Characteristic, property: Property) void {
    assert(property.key.len > 0);
    assert(characteristic.path.count() > 0);

    const key = property.key;
    const value = property.value;

    if (std.mem.eql(u8, key, "UUID")) {
        if (value == .text) text_set(uuid_bytes_max, &characteristic.uuid, value.text);
    } else if (std.mem.eql(u8, key, "Service")) {
        if (value == .text) text_set(path_bytes_max, &characteristic.service, value.text);
    } else if (std.mem.eql(u8, key, "Flags")) {
        if (value == .strings) characteristic.flags = read_flags(value.strings);
    } else {}
}

fn read_flags(list: variant.StringList) Flags {
    assert(list.body.len <= Client.receive_bytes_max);

    return .{
        .indicate = list.contains("indicate"),
        .notify = list.contains("notify"),
        .read = list.contains("read"),
        .write = list.contains("write"),
        .write_without_response = list.contains("write-without-response"),
    };
}

pub fn refresh(client: *Client, objects: *Objects) Error!void {
    assert(client.is_connected());
    assert(objects.devices.count <= devices_max);

    objects.reset();

    const reply = try client.call(&.{}, .{
        .destination = service,
        .interface = object_manager_interface,
        .member = "GetManagedObjects",
        .path = root_path,
        .signature = "",
    });

    try parse_managed_objects(objects, reply.body);
}

fn parse_managed_objects(objects: *Objects, body: []const u8) !void {
    assert(body.len <= Client.receive_bytes_max);
    assert(objects.devices.count <= devices_max);

    var reader = wire.Reader.init(body);

    const length = try reader.take_u32();

    try reader.skip_to(8);

    if (reader.remaining() < length) return error.Malformed;

    const end = reader.offset + length;

    for (0..objects_scan_max) |_| {
        if (reader.offset >= end) break;

        try parse_object(objects, &reader, end);
    }

    if (reader.offset < end) return error.Malformed;
}

fn parse_object(objects: *Objects, reader: *wire.Reader, end: u32) !void {
    assert(end <= reader.buffer.len);
    assert(reader.offset <= end);

    try reader.skip_to(8);

    if (reader.offset >= end) return;

    const path = try reader.take_string();
    const length = try reader.take_u32();

    try reader.skip_to(8);

    if (reader.remaining() < length) return error.Malformed;

    const interfaces_end = reader.offset + length;

    for (0..interfaces_scan_max) |_| {
        if (reader.offset >= interfaces_end) break;

        try parse_interface(objects, reader, path, interfaces_end);
    }

    if (reader.offset < interfaces_end) return error.Malformed;
}

fn parse_interface(objects: *Objects, reader: *wire.Reader, path: []const u8, end: u32) !void {
    assert(end <= reader.buffer.len);
    assert(reader.offset <= end);

    try reader.skip_to(8);

    if (reader.offset >= end) return;

    const interface = try reader.take_string();

    if (path.len == 0) return error.Malformed;
    if (interface.len == 0) return error.Malformed;

    const slot = objects.open(.{ .interface = interface, .path = path });

    try parse_properties(objects, reader, slot);
}

fn parse_properties(objects: *Objects, reader: *wire.Reader, slot: Slot) !void {
    assert(reader.offset <= reader.buffer.len);
    assert(objects.devices.count <= devices_max);

    const length = try reader.take_u32();

    try reader.skip_to(8);

    if (reader.remaining() < length) return error.Malformed;

    const end = reader.offset + length;

    for (0..properties_scan_max + 1) |_| {
        if (reader.offset >= end) return;

        try reader.skip_to(8);

        if (reader.offset >= end) return;

        const key = try reader.take_string();
        const value = try variant.take(reader);

        if (key.len == 0) return error.Malformed;

        objects.apply(slot, .{ .key = key, .value = value });
    }

    return error.Malformed;
}

fn parse_properties_changed(objects: *Objects, change: *const PropertiesChanged) !void {
    assert(change.path.len > 0);
    assert(change.body.len <= Client.receive_bytes_max);

    var reader = wire.Reader.init(change.body);

    const interface = try reader.take_string();

    if (interface.len == 0) return error.Malformed;

    const slot = objects.open(.{ .interface = interface, .path = change.path });

    try parse_properties(objects, &reader, slot);
}

pub fn subscribe(client: *Client) Client.Error!void {
    assert(client.is_connected());

    try client.add_match(match_prefix ++ object_manager_interface ++ "'");
    try client.add_match(match_prefix ++ properties_interface ++ "'");
}

pub fn pump(
    client: *Client,
    objects: *Objects,
    deadline_ms: u64,
    comptime Notify: type,
    notify: *const Notify,
) void {
    comptime assert(@hasDecl(Notify, "on_properties"));
    assert(deadline_ms > 0);

    for (0..pump_messages_max) |_| {
        if (time.now_ms() >= deadline_ms) return;

        const message = client.take_message() catch return;

        switch (message) {
            .empty => {},
            .message => |received| {
                dispatch(objects, &received, Notify, notify);

                continue;
            },
        }

        const ready = client.fill(.immediate) catch return;

        if (!ready) time.sleep_ms(pump_poll_ms);
    }
}

pub fn drain(
    client: *Client,
    objects: *Objects,
    comptime Notify: type,
    notify: *const Notify,
) void {
    comptime assert(@hasDecl(Notify, "on_properties"));
    assert(objects.devices.count <= devices_max);

    for (0..pump_messages_max) |_| {
        const message = client.take_message() catch return;

        const received = switch (message) {
            .empty => {
                const ready = client.fill(.immediate) catch return;
                if (!ready) return;

                continue;
            },
            .message => |received| received,
        };

        dispatch(objects, &received, Notify, notify);
    }
}

fn dispatch(
    objects: *Objects,
    message: *const Client.Message,
    comptime Notify: type,
    notify: *const Notify,
) void {
    assert(message.body.len <= Client.receive_bytes_max);
    assert(objects.devices.count <= devices_max);

    if (message.header.kind != .signal) return;

    const member = message.header.member;

    if (std.mem.eql(u8, member, "InterfacesAdded")) {
        var reader = wire.Reader.init(message.body);

        parse_object(objects, &reader, @intCast(message.body.len)) catch return;

        return;
    }

    if (!std.mem.eql(u8, member, "PropertiesChanged")) return;
    if (message.header.path.len == 0) return;

    const change = PropertiesChanged{ .body = message.body, .path = message.header.path };

    parse_properties_changed(objects, &change) catch return;

    notify.on_properties(&change);
}

pub fn notification_bytes(body: []const u8) ?[]const u8 {
    assert(body.len <= Client.receive_bytes_max);

    var reader = wire.Reader.init(body);

    const interface = reader.take_string() catch return null;
    if (!std.mem.eql(u8, interface, gatt_characteristic_interface)) return null;

    const length = reader.take_u32() catch return null;

    reader.skip_to(8) catch return null;

    if (reader.remaining() < length) return null;

    const end = reader.offset + length;

    for (0..properties_scan_max) |_| {
        if (reader.offset >= end) return null;

        reader.skip_to(8) catch return null;

        if (reader.offset >= end) return null;

        const key = reader.take_string() catch return null;
        const value = variant.take(&reader) catch return null;

        if (!std.mem.eql(u8, key, "Value")) continue;
        if (value != .bytes) continue;
        return value.bytes;
    }

    return null;
}

pub const NoNotify = struct {
    pub fn on_properties(notify: *const NoNotify, change: *const PropertiesChanged) void {
        assert(change.path.len > 0);

        _ = notify;
    }
};

pub fn device_path(buffer: []u8, adapter: []const u8, address: u64) []const u8 {
    assert(address >> 48 == 0);
    assert(adapter.len > 0);
    assert(buffer.len >= path_bytes_max);

    const result = std.mem.print(
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

    assert(result.len <= buffer.len);

    return result;
}

pub fn format_address(buffer: []u8, address: u64) []const u8 {
    assert(buffer.len >= address_bytes_max);
    assert(address >> 48 == 0);

    return std.mem.print(
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

pub fn set_discovery_filter(client: *Client, adapter: []const u8) Error!void {
    assert(adapter.len > 0);
    assert(client.is_connected());

    var storage: [body_bytes_max]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    const marker = try writer.open_array(wire.align_of(wire.code_dictionary_entry));

    try variant.put_dictionary_entry_string(&writer, .{ .key = "Transport", .value = "le" });
    try writer.close_array(marker);

    _ = try client.call(writer.bytes(), .{
        .destination = service,
        .interface = adapter_interface,
        .member = "SetDiscoveryFilter",
        .path = adapter,
        .signature = "a{sv}",
    });
}

pub fn start_discovery(client: *Client, adapter: []const u8) Client.Error!void {
    assert(adapter.len > 0);
    assert(client.is_connected());

    _ = try client.call(&.{}, .{
        .destination = service,
        .interface = adapter_interface,
        .member = "StartDiscovery",
        .path = adapter,
        .signature = "",
    });
}

pub fn stop_discovery(client: *Client, adapter: []const u8) Client.Error!void {
    assert(adapter.len > 0);
    assert(client.is_connected());

    _ = try client.call(&.{}, .{
        .destination = service,
        .interface = adapter_interface,
        .member = "StopDiscovery",
        .path = adapter,
        .signature = "",
    });
}

pub fn remove_device(client: *Client, removal: Removal) Error!void {
    assert(removal.adapter.len > 0);
    assert(removal.device.len > 0);

    var storage: [body_bytes_max]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    try writer.put_string(removal.device);

    _ = try client.call(writer.bytes(), .{
        .destination = service,
        .interface = adapter_interface,
        .member = "RemoveDevice",
        .path = removal.adapter,
        .signature = "o",
    });
}

pub fn device_connect(client: *Client, path: []const u8) Client.Error!void {
    assert(path.len > 0);
    assert(client.is_connected());

    _ = try client.call(&.{}, .{
        .destination = service,
        .interface = device_interface,
        .member = "Connect",
        .path = path,
        .signature = "",
    });
}

pub fn device_disconnect(client: *Client, path: []const u8) Client.Error!void {
    assert(path.len > 0);
    assert(client.is_connected());

    _ = try client.call(&.{}, .{
        .destination = service,
        .interface = device_interface,
        .member = "Disconnect",
        .path = path,
        .signature = "",
    });
}

pub fn start_notify(client: *Client, path: []const u8) Client.Error!void {
    assert(path.len > 0);
    assert(client.is_connected());

    _ = try client.call(&.{}, .{
        .destination = service,
        .interface = gatt_characteristic_interface,
        .member = "StartNotify",
        .path = path,
        .signature = "",
    });
}

pub fn stop_notify(client: *Client, path: []const u8) Client.Error!void {
    assert(path.len > 0);
    assert(client.is_connected());

    _ = try client.call(&.{}, .{
        .destination = service,
        .interface = gatt_characteristic_interface,
        .member = "StopNotify",
        .path = path,
        .signature = "",
    });
}

pub fn write_value(client: *Client, write: *const Write) Error!void {
    assert(write.bytes.len > 0);
    assert(write.path.len > 0);

    var storage: [body_bytes_max]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    const payload = try writer.open_array(wire.align_of(wire.code_byte));

    try writer.put_slice(write.bytes);
    try writer.close_array(payload);

    const options = try writer.open_array(wire.align_of(wire.code_dictionary_entry));

    switch (write.kind) {
        .command => try variant.put_dictionary_entry_string(&writer, .{
            .key = "type",
            .value = "command",
        }),
        .request => {},
    }

    try writer.close_array(options);

    _ = try client.call(writer.bytes(), .{
        .destination = service,
        .interface = gatt_characteristic_interface,
        .member = "WriteValue",
        .path = write.path,
        .signature = "aya{sv}",
    });
}

const testing = std.testing;

test device_path {
    var buffer: [path_bytes_max]u8 = undefined;

    try testing.expectEqualStrings(
        "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6",
        device_path(&buffer, "/org/bluez/hci0", 0xF1E2D3C4B5A6),
    );
}

test format_address {
    var buffer: [address_bytes_max]u8 = undefined;

    try testing.expectEqualStrings("00:11:22:33:44:55", format_address(&buffer, 0x001122334455));
}

test "a name truncates rather than overflowing" {
    var name: Name = .empty;

    const long: [name_bytes_max + 8]u8 = @splat('x');
    const full: [name_bytes_max]u8 = @splat('x');

    text_set(name_bytes_max, &name, &long);

    try testing.expectEqual(name_bytes_max, name.count());
    try testing.expectEqualStrings(&full, name.slice());
}

fn stage_managed_objects(storage: []u8) ![]const u8 {
    assert(storage.len >= 1024);

    var writer = wire.Writer.init(storage);

    const outer = try writer.open_array(wire.align_of(wire.code_dictionary_entry));

    try stage_adapter(&writer);
    try stage_device(&writer);
    try writer.close_array(outer);

    return writer.bytes();
}

fn stage_adapter(writer: *wire.Writer) !void {
    assert(writer.length <= writer.buffer.len);
    assert(writer.buffer.len >= 1024);

    const interfaces = try stage_interface(writer, .{
        .interface = adapter_interface,
        .path = "/org/bluez/hci0",
    });

    const properties = try writer.open_array(wire.align_of(wire.code_dictionary_entry));
    const address: variant.StringEntry = .{ .key = "Address", .value = "AA:BB:CC:DD:EE:FF" };

    try variant.put_dictionary_entry_string(writer, address);
    try writer.close_array(properties);
    try writer.close_array(interfaces);
}

fn stage_device(writer: *wire.Writer) !void {
    assert(writer.length <= writer.buffer.len);
    assert(writer.buffer.len >= 1024);

    const interfaces = try stage_interface(writer, .{
        .interface = device_interface,
        .path = "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6",
    });

    const properties = try writer.open_array(wire.align_of(wire.code_dictionary_entry));

    try stage_device_properties(writer);
    try writer.close_array(properties);
    try writer.close_array(interfaces);
}

fn stage_device_properties(writer: *wire.Writer) !void {
    assert(writer.length <= writer.buffer.len);
    assert(writer.length % 8 == 0);

    const address: variant.StringEntry = .{ .key = "Address", .value = "F1:E2:D3:C4:B5:A6" };

    try variant.put_dictionary_entry_string(writer, address);
    try variant.put_dictionary_entry_string(writer, .{ .key = "Alias", .value = "fenix" });
    try variant.put_dictionary_entry_bool(writer, "Connected", true);
}

fn stage_interface(writer: *wire.Writer, opening: Opening) !wire.ArrayMarker {
    assert(opening.interface.len > 0);
    assert(opening.path.len > 0);

    try writer.pad_to(8);
    try writer.put_string(opening.path);

    const result = try writer.open_array(wire.align_of(wire.code_dictionary_entry));

    try writer.pad_to(8);
    try writer.put_string(opening.interface);

    return result;
}

test "parse_managed_objects records the adapter and its devices" {
    var storage: [1024]u8 = undefined;

    const body = try stage_managed_objects(&storage);
    const objects = try testing.allocator.create(Objects);
    defer testing.allocator.destroy(objects);

    objects.* = .{};

    try parse_managed_objects(objects, body);

    try testing.expectEqualStrings("/org/bluez/hci0", objects.adapter.slice());
    try testing.expectEqual(@as(u32, 1), objects.devices.count);

    const device = objects.find_device("/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6").?;

    try testing.expectEqualStrings("F1:E2:D3:C4:B5:A6", device.address.slice());
    try testing.expectEqualStrings("fenix", device.name.slice());
    try testing.expect(device.connected);
    try testing.expect(!device.resolved);
}

fn stage_gatt_objects(storage: []u8) ![]const u8 {
    assert(storage.len >= 2048);

    const device = "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6";

    var writer = wire.Writer.init(storage);

    const outer = try writer.open_array(wire.align_of(wire.code_dictionary_entry));

    try stage_gatt_service(&writer, device);
    try stage_gatt_characteristic(&writer, device);
    try writer.close_array(outer);

    return writer.bytes();
}

fn stage_gatt_service(writer: *wire.Writer, device: []const u8) !void {
    assert(device.len > 0);
    assert(writer.length <= writer.buffer.len);

    const interfaces = try stage_interface(writer, .{
        .interface = gatt_service_interface,
        .path = "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6/service001f",
    });

    const properties = try writer.open_array(wire.align_of(wire.code_dictionary_entry));

    try stage_service_properties(writer, device);
    try writer.close_array(properties);
    try writer.close_array(interfaces);
}

fn stage_service_properties(writer: *wire.Writer, device: []const u8) !void {
    assert(device.len > 0);
    assert(writer.length % 8 == 0);

    const uuid: variant.StringEntry = .{ .key = "UUID", .value = multi_link_service_uuid };

    try variant.put_dictionary_entry_string(writer, uuid);
    try writer.pad_to(8);
    try writer.put_string("Device");
    try variant.put_object(writer, device);
}

const multi_link_service_uuid = "6a4e2800-667b-11e3-949a-0800200c9a66";

fn stage_gatt_characteristic(writer: *wire.Writer, device: []const u8) !void {
    assert(device.len > 0);
    assert(writer.length <= writer.buffer.len);

    const interfaces = try stage_interface(writer, .{
        .interface = gatt_characteristic_interface,
        .path = "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6/service001f/char0020",
    });

    const properties = try writer.open_array(wire.align_of(wire.code_dictionary_entry));

    try stage_characteristic_properties(writer);
    try writer.close_array(properties);
    try writer.close_array(interfaces);
}

fn stage_characteristic_properties(writer: *wire.Writer) !void {
    assert(writer.length <= writer.buffer.len);
    assert(writer.length % 8 == 0);

    try variant.put_dictionary_entry_string(writer, .{
        .key = "UUID",
        .value = "6a4e2820-667b-11e3-949a-0800200c9a66",
    });

    try writer.pad_to(8);
    try writer.put_string("Service");
    try variant.put_object(writer, "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6/service001f");

    try writer.pad_to(8);
    try writer.put_string("Flags");
    try writer.put_signature("as");

    const flags = try writer.open_array(4);

    try writer.put_string("write-without-response");
    try writer.put_string("notify");
    try writer.close_array(flags);
}

test "parse_managed_objects records GATT services and their characteristics" {
    var storage: [2048]u8 = undefined;

    const body = try stage_gatt_objects(&storage);
    const objects = try testing.allocator.create(Objects);
    defer testing.allocator.destroy(objects);

    objects.* = .{};

    try parse_managed_objects(objects, body);

    try testing.expectEqual(@as(u32, 1), objects.services.count);
    try testing.expectEqual(@as(u32, 1), objects.characteristics.count);

    const device = "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6";

    const found = objects.find_service(.{
        .device = device,
        .uuid = "6a4e2800-667b-11e3-949a-0800200c9a66",
    }).?;

    try testing.expectEqualStrings(device ++ "/service001f", found.path.slice());

    const characteristic = objects.find_characteristic(.{
        .service = found.path.slice(),
        .uuid = "6a4e2820-667b-11e3-949a-0800200c9a66",
    }).?;

    try testing.expect(characteristic.flags.notify);
    try testing.expect(characteristic.flags.write_without_response);
    try testing.expect(!characteristic.flags.write);
    try testing.expect(!characteristic.flags.read);
    try testing.expect(!characteristic.flags.indicate);
}

test "parse_properties_changed updates a device the table already holds" {
    var storage: [1024]u8 = undefined;

    const body = try stage_managed_objects(&storage);
    const objects = try testing.allocator.create(Objects);
    defer testing.allocator.destroy(objects);

    objects.* = .{};

    try parse_managed_objects(objects, body);

    var changed: [256]u8 = undefined;
    var writer = wire.Writer.init(&changed);

    try writer.put_string(device_interface);

    const properties = try writer.open_array(wire.align_of(wire.code_dictionary_entry));

    try variant.put_dictionary_entry_bool(&writer, "ServicesResolved", true);
    try writer.close_array(properties);

    const path = "/org/bluez/hci0/dev_F1_E2_D3_C4_B5_A6";

    try parse_properties_changed(objects, &.{ .body = writer.bytes(), .path = path });

    try testing.expectEqual(@as(u32, 1), objects.devices.count);
    try testing.expect(objects.find_device(path).?.resolved);
}
