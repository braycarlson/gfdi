const std = @import("std");

const fuzz = @import("../../../testing/fuzz.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const frame_bytes_max: u32 = 512;

comptime {
    assert(frame_bytes_max > wire.header_bytes_min);
}

pub fn main(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;

    assert(args.events_max >= 1);

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        var storage: [frame_bytes_max]u8 = undefined;
        const frame = build_frame(random, &storage);

        check_peek(frame);
        check_parse(frame);
        check_reader(frame);
    }

    assert(event == args.events_max);
}

fn build_frame(random: std.Random, storage: []u8) []u8 {
    assert(storage.len > wire.header_bytes_min);

    if (random.boolean()) {
        return random_noise(random, storage);
    }

    var writer = wire.Writer.init(storage);

    const kinds = [_]wire.Kind{ .method_call, .method_return, .error_reply, .signal };
    const kind = fuzz.random_from_slice(random, wire.Kind, &kinds);

    wire.write_header(&writer, .{
        .destination = if (random.boolean()) "org.freedesktop.DBus" else "",
        .interface = if (random.boolean()) "org.bluez.Adapter1" else "",
        .kind = kind,
        .member = if (random.boolean()) "StartDiscovery" else "",
        .path = if (random.boolean()) "/org/bluez/hci0" else "",
        .reply_serial = if (random.boolean()) random.int(u32) else null,
        .serial = 1 + random.uintLessThan(u32, 1024),
        .signature = if (random.boolean()) "s" else "",
    }, 0) catch return storage[0..0];

    const length = writer.length;

    corrupt(random, storage[0..length]);

    return storage[0..length];
}

fn random_noise(random: std.Random, storage: []u8) []u8 {
    const length = random.uintLessThan(usize, storage.len + 1);

    random.bytes(storage[0..length]);

    assert(length <= storage.len);

    return storage[0..length];
}

fn corrupt(random: std.Random, frame: []u8) void {
    if (frame.len == 0) {
        return;
    }

    const mutations = random.uintLessThan(u8, 4);

    var index: u8 = 0;

    while (index < mutations) : (index += 1) {
        const offset = random.uintLessThan(usize, frame.len);

        assert(offset < frame.len);

        frame[offset] = random.int(u8);
    }
}

fn check_peek(frame: []const u8) void {
    const peeked = wire.peek_length(frame) catch return;

    if (peeked) |total| {
        assert(total >= wire.header_bytes_min);
    }
}

fn check_parse(frame: []const u8) void {
    const header = wire.parse(frame) catch return;

    assert(header.kind.is_valid());
    assert(header.total_length <= frame.len);
    assert(header.body_length <= wire.body_bytes_max);
    assert(header.member.len <= wire.string_bytes_max);
    assert(header.path.len <= wire.string_bytes_max);
    assert(header.interface.len <= wire.string_bytes_max);
    assert(header.signature.len <= wire.signature_bytes_max);
}

fn check_reader(frame: []const u8) void {
    var reader = wire.Reader.init(frame);
    var steps: u8 = 0;

    while (steps < 16) : (steps += 1) {
        const before = reader.offset;

        _ = reader.take_u32() catch break;

        assert(reader.offset > before);
        assert(reader.offset <= frame.len);
    }

    assert(reader.remaining() <= frame.len);
}

const testing = std.testing;

test "wire fuzzer survives a fixed seed" {
    try main(testing.allocator, .{ .events_max = fuzz.events_max_smoke, .seed = 123 });
}

test "check_parse tolerates arbitrary noise" {
    const noise = [_]u8{ 0xFF, 0x01, 0x02, 0x03, 0x04 };

    check_parse(&noise);
    check_peek(&noise);
    check_reader(&noise);
}
