const std = @import("std");

const bounded = @import("bounded");

const fake_transport = @import("../testing/fake_transport.zig");
const interface = @import("interface.zig");
const memory_store = @import("../testing/memory_store.zig");
const protocol = @import("../protocol.zig");
const session_module = @import("../session.zig");
const transport_module = @import("../transport.zig");

const assert = std.debug.assert;

const FakeClock = @import("../testing/fake_clock.zig").FakeClock;
const FakeTransport = fake_transport.FakeTransport;
const MemoryStore = memory_store.MemoryStore;
const RunnerType = session_module.runner.RunnerType;
const Writer = std.Io.Writer;

const Fake = @This();

calls: std.EnumArray(interface.Command, u32),
elapsed_ms: u64,
failure: interface.Diagnostic,
options: Options,
session: Runner.Session,
storage: session_module.StorageType(capacity),
store: MemoryStore,
transport: FakeTransport,

pub const Options = struct {
    address: u64,
    files: []const []const u8,
    name: []const u8,
};

pub const capabilities: interface.Capabilities = .{ .dbus = false };

const FakeEnvironment = struct {
    pub const Clock = FakeClock;
    pub const FileStore = *MemoryStore;
    pub const Transport = FakeTransport;
};

const Attempt = struct {
    fake: *Fake,
    out: *Writer,

    pub const Error = bounded.Error || Writer.Error;

    pub fn once(attempt: *const Attempt) Error!bool {
        assert(attempt.fake.options.files.len <= files_max);

        return attempt.fake.observe_once(attempt.out);
    }
};

const Runner = RunnerType(FakeEnvironment, session_module.runner.FakeTime);

const capacity: session_module.Capacity = .{
    .inflate_bytes_max = file_bytes_max,
    .legacy_bytes_max = file_bytes_max,
    .protobuf_bytes_max = file_bytes_max,
    .transfer_bytes_max = file_bytes_max,
};

const no_hooks: session_module.runner.NoHooks = .{};
const chunk_bytes_max: u32 = fake_transport.message_length_max - frame_overhead_bytes;
const download_refused: u8 = 1;
const file_bytes_max: u32 = memory_store.data_length_max;
const files_max: u32 = 4;
const frame_overhead_bytes: u32 = 6 + transfer_header_bytes;
const protocol_version: u16 = 150;
const status_bytes: u32 = 8;
const transfer_header_bytes: u32 = 7;

comptime {
    interface.assert_backend(Fake);

    assert(chunk_bytes_max > 0);
    assert(file_bytes_max <= std.math.maxInt(u32));
    assert(files_max * 2 < memory_store.entry_count_max);
}

pub fn init(fake: *Fake, io: std.Io, options: Options) void {
    assert(options.address >> 48 == 0);
    assert(options.files.len <= files_max);

    _ = io;

    for (options.files) |file| {
        assert(file.len > 0);
        assert(file.len <= file_bytes_max);
    }

    fake.calls = .initFill(0);
    fake.elapsed_ms = 0;
    fake.failure = .none;
    fake.options = options;
    fake.store = .empty;
    fake.transport = .empty;

    assert(script_message_count(options.files) <= fake_transport.inbound_count_max);
}

pub fn deinit(fake: *Fake) void {
    assert(fake.store.entries.count <= memory_store.entry_count_max);
    assert(fake.transport.inbound_position <= fake.transport.inbound.count);
}

pub fn diagnostic(fake: *const Fake) interface.Diagnostic {
    assert(fake.failure.cause.len <= std.math.maxInt(u16));

    return fake.failure;
}

pub fn stored_count(fake: *const Fake) u32 {
    assert(fake.store.entries.count <= memory_store.entry_count_max);

    return fake.store.entries.count;
}

pub fn stored_path(fake: *const Fake, index: u32) []const u8 {
    assert(index < fake.store.entries.count);

    const result = fake.store.entries.get(index).path.slice();

    assert(result.len > 0);

    return result;
}

pub fn observe(fake: *Fake, out: *Writer, address: u64) interface.Error!void {
    assert(address >> 48 == 0);
    assert(fake.options.files.len <= files_max);

    fake.calls.getPtr(.observe).* += 1;

    if (address != fake.options.address) {
        return fake.watch_missing(out);
    }

    const attempt = Attempt{ .fake = fake, .out = out };
    const fake_time = fake.time();

    Runner.attempts_run(Attempt, &attempt, out, &fake_time) catch |err| {
        return fake.failed(err);
    };
}

pub fn enumerate(fake: *Fake, out: *Writer) interface.Error!void {
    assert(fake.options.name.len > 0);

    fake.calls.getPtr(.enumerate).* += 1;

    try out.print("BLE devices known to the fake: 1\n  [0] {s}\n", .{fake.options.name});
}

pub fn scan(fake: *Fake, out: *Writer) interface.Error!void {
    assert(fake.options.name.len > 0);

    fake.calls.getPtr(.scan).* += 1;

    var buffer: [interface.address_text_bytes]u8 = undefined;

    try out.print("Advertisers seen: 1\n  {s}  {s}\n", .{
        address_format(&buffer, fake.options.address),
        fake.options.name,
    });
}

pub fn connect(fake: *Fake, out: *Writer, address: u64) interface.Error!void {
    assert(address >> 48 == 0);

    fake.calls.getPtr(.connect).* += 1;

    if (address != fake.options.address) return fake.watch_missing(out);

    try out.print("GATT services: 1\n  {s}\n", .{service_uuid});
}

pub fn pull(fake: *Fake, out: *Writer, address: u64) interface.Error!void {
    assert(address >> 48 == 0);

    fake.calls.getPtr(.pull).* += 1;

    if (address != fake.options.address) return fake.watch_missing(out);

    try out.print("GATT services: 1\n  {s}\n      characteristic {s} [wN]\n", .{
        service_uuid,
        send_uuid,
    });
}

pub fn smoke(fake: *Fake, out: *Writer) interface.Error!void {
    assert(fake.calls.get(.smoke) < std.math.maxInt(u32));

    fake.calls.getPtr(.smoke).* += 1;

    try out.print("fake Bluetooth runtime OK.\n", .{});
}

const service_uuid = protocol.multi_link.uuid_text(protocol.multi_link.service_uuid);
const send_uuid = protocol.multi_link.uuid_text(protocol.multi_link.send_uuid);

fn watch_missing(fake: *Fake, out: *Writer) interface.Error!void {
    assert(fake.options.address >> 48 == 0);

    fake.failure = .{ .cause = "AddressUnknown" };

    try out.print("watch not seen advertising.\n", .{});

    return error.BluetoothFailed;
}

fn time(fake: *Fake) session_module.runner.FakeTime {
    assert(fake.elapsed_ms < @divFloor(std.math.maxInt(u64), 2));

    return .{ .elapsed_ms = &fake.elapsed_ms };
}

fn failed(fake: *Fake, err: Attempt.Error) interface.Error {
    fake.failure = .{ .cause = @errorName(err) };

    const result: interface.Error = switch (err) {
        error.WriteFailed => error.WriteFailed,
        else => error.BluetoothFailed,
    };

    assert((result == error.WriteFailed) == (err == error.WriteFailed));
    assert(result == error.WriteFailed or result == error.BluetoothFailed);

    return result;
}

fn observe_once(fake: *Fake, out: *Writer) !bool {
    assert(fake.options.files.len <= files_max);
    assert(fake.store.entries.count <= memory_store.entry_count_max);

    try fake.script();

    const storage = fake.storage.slices();

    fake.session.init(&storage, &fake.transport, out, .zero, &fake.store);

    const fake_time = fake.time();

    try Runner.pump_run(session_module.runner.NoHooks, &no_hooks, &fake.session, &fake_time);

    return fake.session.archive.complete;
}

fn script(fake: *Fake) !void {
    assert(fake.options.files.len <= files_max);

    fake.transport = .empty;

    var version: [2]u8 = undefined;

    std.mem.writeInt(u16, &version, protocol_version, .little);

    try fake.queue_frame(.device_information, &version);
    try fake.queue_status(null);

    for (fake.options.files, 0..) |file, offset| {
        var marker: [64]u8 = undefined;

        const index: u16 = @intCast(offset + session_module.archive_index_first);
        const path = transport_module.naming.marker_path(&marker, index);

        if (fake.store.exists(path)) continue;

        try fake.queue_status(@intCast(file.len));
        try fake.queue_chunks(file);
    }

    for (0..session_module.archive_refusals_max) |_| try fake.queue_status(null);

    assert(fake.transport.inbound.count <= fake_transport.inbound_count_max);
}

fn queue_status(fake: *Fake, size: ?u32) !void {
    assert((size orelse 1) > 0);
    assert(fake.transport.inbound.count < fake_transport.inbound_count_max);

    var payload: [status_bytes]u8 = undefined;

    const reference = @backingInt(protocol.gfdi.MessageType.download_request);

    std.mem.writeInt(u16, payload[0..2], reference, .little);

    payload[2] = protocol.gfdi.status_ack;
    payload[3] = if (size == null) download_refused else protocol.gfdi.download_status_ok;

    std.mem.writeInt(u32, payload[4..8], size orelse 0, .little);

    try fake.queue_frame(.response, &payload);
}

fn queue_chunks(fake: *Fake, file: []const u8) !void {
    assert(file.len > 0);
    assert(file.len <= file_bytes_max);

    var offset: u32 = 0;

    for (0..file.len) |_| {
        if (offset == file.len) break;

        const length = @min(chunk_bytes_max, file.len - offset);

        var payload: [transfer_header_bytes + chunk_bytes_max]u8 = undefined;

        payload[0] = 0;

        std.mem.writeInt(u16, payload[1..3], 0, .little);
        std.mem.writeInt(u32, payload[3..7], offset, .little);

        @memcpy(payload[transfer_header_bytes..][0..length], file[offset..][0..length]);

        try fake.queue_frame(.file_transfer_data, payload[0 .. transfer_header_bytes + length]);

        offset += @intCast(length);
    }

    assert(offset == file.len);
}

fn queue_frame(fake: *Fake, kind: protocol.gfdi.MessageType, payload: []const u8) !void {
    assert(payload.len > 0);
    assert(payload.len + 6 <= fake_transport.message_length_max);

    var frame: [fake_transport.message_length_max]u8 = undefined;

    const length = protocol.gfdi.build_frame(&frame, kind, payload);

    try fake.transport.queue_inbound(frame[0..length]);
}

fn script_message_count(files: []const []const u8) u32 {
    assert(files.len <= files_max);

    var result: u32 = 2 + session_module.archive_refusals_max;

    for (files) |file| {
        const chunks: u32 = @intCast(@divCeil(file.len, chunk_bytes_max));

        result += 1 + chunks;
    }

    assert(result >= 2 + session_module.archive_refusals_max);

    return result;
}

fn address_format(buffer: *[interface.address_text_bytes]u8, address: u64) []const u8 {
    assert(address >> 48 == 0);

    for (0..interface.address_octet_count) |octet| {
        const shift: u6 = @intCast((interface.address_octet_count - 1 - octet) * 8);
        const value: u8 = @truncate(address >> shift);
        const digits = "0123456789ABCDEF";

        buffer[octet * 3] = digits[value >> 4];
        buffer[octet * 3 + 1] = digits[value & 0x0F];

        if (octet + 1 < interface.address_octet_count) buffer[octet * 3 + 2] = ':';
    }

    assert(if (interface.address_parse(buffer)) |parsed| parsed == address else |_| false);

    return buffer;
}

const testing = std.testing;

const test_address: u64 = 0xA1B2C3D4E5F6;

fn test_file() [64]u8 {
    var result: [64]u8 = @splat(0x5A);

    result[0] = 14;

    return result;
}

test Fake {
    const fake = try testing.allocator.create(Fake);
    defer testing.allocator.destroy(fake);

    const file = test_file();

    fake.init(testing.io, .{ .address = test_address, .files = &.{&file}, .name = "Forerunner" });
    defer fake.deinit();

    var buffer: [16 * 1024]u8 = undefined;
    var out = Writer.fixed(&buffer);

    try fake.observe(&out, test_address);

    try testing.expectEqual(@as(u32, 1), fake.calls.get(.observe));
    try testing.expect(fake.session.archive.complete);
    try testing.expectEqual(@as(u32, 1), fake.session.archive.saved);
    try testing.expectEqualStrings("pulled/Unknown/idx1.fit", fake.stored_path(0));
    try testing.expectEqualSlices(u8, &file, fake.store.get("pulled/Unknown/idx1.fit").?);
    try testing.expectEqual(@as(u32, 2), fake.stored_count());
}

test "a second observe resumes past the files already pulled" {
    const fake = try testing.allocator.create(Fake);
    defer testing.allocator.destroy(fake);

    const file = test_file();

    fake.init(testing.io, .{ .address = test_address, .files = &.{&file}, .name = "Forerunner" });
    defer fake.deinit();

    var buffer: [16 * 1024]u8 = undefined;
    var out = Writer.fixed(&buffer);

    try fake.observe(&out, test_address);

    out.end = 0;

    try fake.observe(&out, test_address);

    try testing.expectEqual(@as(u32, 2), fake.calls.get(.observe));
    try testing.expectEqual(@as(u32, 0), fake.session.archive.saved);
    try testing.expectEqual(@as(u32, 2), fake.stored_count());
}

test "an unknown address fails with a diagnostic" {
    const fake = try testing.allocator.create(Fake);
    defer testing.allocator.destroy(fake);

    fake.init(testing.io, .{ .address = test_address, .files = &.{}, .name = "Forerunner" });
    defer fake.deinit();

    var buffer: [256]u8 = undefined;
    var out = Writer.fixed(&buffer);

    try testing.expectError(error.BluetoothFailed, fake.connect(&out, 0x000000000001));
    try testing.expectEqualStrings("AddressUnknown", fake.diagnostic().cause);
    try testing.expectError(error.BluetoothFailed, fake.observe(&out, 0x000000000001));
    try testing.expectEqual(@as(u32, 0), fake.stored_count());
}

test "scan and smoke report from the fake's own state" {
    const fake = try testing.allocator.create(Fake);
    defer testing.allocator.destroy(fake);

    fake.init(testing.io, .{ .address = test_address, .files = &.{}, .name = "Forerunner" });
    defer fake.deinit();

    var buffer: [256]u8 = undefined;
    var out = Writer.fixed(&buffer);

    try fake.scan(&out);
    try fake.smoke(&out);

    try testing.expect(std.mem.find(u8, out.buffered(), "A1:B2:C3:D4:E5:F6") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "runtime OK") != null);
    try testing.expectEqual(@as(u32, 1), fake.calls.get(.scan));
}
