const std = @import("std");

const client = @import("client.zig");
const fuzz = @import("../../../testing/fuzz.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const stream_bytes_max: u32 = 2048;
pub const frames_max: u32 = 4;
pub const scan_max: u32 = 16;

comptime {
    assert(stream_bytes_max > wire.header_bytes_min);
    assert(frames_max > 1);
    assert(scan_max > frames_max);
}

pub fn main(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;

    assert(args.events_max >= 1);

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        var storage: [stream_bytes_max]u8 = undefined;
        const stream = build_stream(random, &storage);

        check_torn(stream);
        check_coalesced(stream);
    }

    assert(event == args.events_max);
}

fn build_stream(random: std.Random, storage: []u8) []u8 {
    assert(storage.len > wire.header_bytes_min);

    if (random.boolean()) {
        const length = random.uintLessThan(usize, storage.len + 1);

        random.bytes(storage[0..length]);

        return storage[0..length];
    }

    const count = 1 + random.uintLessThan(u32, frames_max);

    var length: u32 = 0;
    var index: u32 = 0;

    while (index < count) : (index += 1) {
        const written = append_frame(random, storage[length..]) orelse break;

        length += written;
    }

    corrupt(random, storage[0..length]);

    return storage[0..length];
}

fn append_frame(random: std.Random, destination: []u8) ?u32 {
    if (destination.len <= wire.header_bytes_min) {
        return null;
    }

    var writer = wire.Writer.init(destination);

    const kinds = [_]wire.Kind{ .method_call, .method_return, .error_reply, .signal };
    const kind = fuzz.random_from_slice(random, wire.Kind, &kinds);

    wire.write_header(&writer, .{
        .destination = if (random.boolean()) "org.freedesktop.DBus" else "",
        .interface = if (random.boolean()) "org.bluez.Device1" else "",
        .kind = kind,
        .member = if (random.boolean()) "Connect" else "",
        .path = if (random.boolean()) "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" else "",
        .reply_serial = if (random.boolean()) random.int(u32) else null,
        .serial = 1 + random.uintLessThan(u32, 1024),
        .signature = if (random.boolean()) "s" else "",
    }, 0) catch return null;

    return writer.length;
}

fn corrupt(random: std.Random, stream: []u8) void {
    if (stream.len == 0) {
        return;
    }

    const mutations = random.uintLessThan(u8, 4);

    var index: u8 = 0;

    while (index < mutations) : (index += 1) {
        const offset = random.uintLessThan(usize, stream.len);

        assert(offset < stream.len);

        stream[offset] = random.int(u8);
    }
}

fn check_torn(stream: []const u8) void {
    var length: u32 = 0;

    while (length <= stream.len) : (length += 1) {
        assert(length <= stream_bytes_max);

        const frame = client.parse_frame(stream[0..length]) catch continue;

        if (frame) |live| {
            assert(live.total <= length);
            assert(live.body_start <= live.total);
            assert(live.header.body_length == live.total - live.body_start);
            assert(live.header.kind.is_valid());
        }
    }
}

fn check_coalesced(stream: []const u8) void {
    var offset: u32 = 0;
    var scanned: u32 = 0;

    while (scanned < scan_max) : (scanned += 1) {
        const frame = client.parse_frame(stream[offset..]) catch break;
        const live = frame orelse break;

        assert(live.total > 0);
        assert(offset + live.total <= stream.len);

        offset += live.total;

        assert(offset <= stream.len);
    }

    assert(offset <= stream.len);
}

const testing = std.testing;

test "client framing fuzzer survives a fixed seed" {
    try main(testing.allocator, .{ .events_max = fuzz.events_max_smoke, .seed = 123 });
}

test "parse_frame reports nothing for a torn header" {
    const short = [_]u8{ 'l', 1, 0, 1 };

    try testing.expectEqual(@as(?client.Frame, null), try client.parse_frame(&short));
}

test "parse_frame walks two coalesced frames" {
    var storage: [512]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    try wire.write_header(&writer, .{ .kind = .signal, .member = "First", .serial = 1 }, 0);

    const first = writer.length;

    var second_writer = wire.Writer.init(storage[first..]);

    try wire.write_header(
        &second_writer,
        .{ .kind = .signal, .member = "Second", .serial = 2 },
        0,
    );

    const total = first + second_writer.length;
    const one = (try client.parse_frame(storage[0..total])).?;

    try testing.expectEqualStrings("First", one.header.member);
    try testing.expectEqual(first, one.total);

    const two = (try client.parse_frame(storage[one.total..total])).?;

    try testing.expectEqualStrings("Second", two.header.member);
}
