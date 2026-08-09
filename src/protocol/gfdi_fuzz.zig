const std = @import("std");

const fuzz = @import("../testing/fuzz.zig");
const gfdi = @import("gfdi.zig");

const assert = std.debug.assert;

const payload_len_max: u32 = gfdi.message_len_max - 6;
const wire_len_max: u32 = gfdi.cobs_encoded_len_max(gfdi.message_len_max);
const noise_len_max: u32 = 512;

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;

    const events = args.events_max;

    try fuzz_cobs_round_trip(args.seed, events);
    try fuzz_frame_round_trip(args.seed +% 1, events);
    try fuzz_parse_noise(args.seed +% 2, events);
}

pub fn fuzz_cobs_round_trip(seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var event: u32 = 0;

    while (event < events) : (event += 1) {
        try cobs_round_trip_one(random);
    }

    assert(event == events);
}

pub fn fuzz_frame_round_trip(seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var event: u32 = 0;

    while (event < events) : (event += 1) {
        try frame_round_trip_one(random);
    }

    assert(event == events);
}

pub fn fuzz_parse_noise(seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var noise: [noise_len_max]u8 = undefined;
    var event: u32 = 0;

    while (event < events) : (event += 1) {
        const len = random.intRangeAtMost(u32, 0, noise_len_max);

        random.bytes(noise[0..len]);

        if (gfdi.parse(noise[0..len])) |message| {
            assert(message.payload.len + 6 == len);
        }

        _ = gfdi.parse_protobuf_message(noise[0..len]);
        _ = gfdi.parse_download_status(noise[0..len]);
        _ = gfdi.parse_file_transfer_data(noise[0..len]);
        _ = gfdi.status_reference_type(noise[0..len]);
    }

    assert(event == events);
}

fn cobs_round_trip_one(random: std.Random) !void {
    var source: [gfdi.message_len_max]u8 = undefined;
    const source_len = random.intRangeAtMost(u32, 0, gfdi.message_len_max);
    const zero_percent = random.intRangeAtMost(u32, 0, 100);

    var index: u32 = 0;

    while (index < source_len) : (index += 1) {
        if (random.intRangeLessThan(u32, 0, 100) < zero_percent) {
            source[index] = 0;
        } else {
            source[index] = random.int(u8);
        }
    }

    var wire: [wire_len_max]u8 = undefined;
    const wire_len = gfdi.cobs_encode(&wire, source[0..source_len]);

    assert(wire_len >= 2);
    assert(wire_len <= wire.len);
    try std.testing.expectEqual(@as(u8, 0), wire[0]);
    try std.testing.expectEqual(@as(u8, 0), wire[wire_len - 1]);

    var decoded: [gfdi.message_len_max]u8 = undefined;
    const decoded_len = gfdi.cobs_decode(&decoded, wire[1 .. wire_len - 1]);

    try std.testing.expectEqualSlices(u8, source[0..source_len], decoded[0..decoded_len]);
}

fn frame_round_trip_one(random: std.Random) !void {
    var payload: [payload_len_max]u8 = undefined;
    const payload_len = random.intRangeAtMost(u32, 0, payload_len_max);

    random.bytes(payload[0..payload_len]);

    const raw_type = random.int(u16);
    const message_type: gfdi.MessageType = @enumFromInt(raw_type);

    var frame: [gfdi.message_len_max]u8 = undefined;
    const frame_len = gfdi.build_frame(&frame, message_type, payload[0..payload_len]);

    assert(frame_len == payload_len + 6);
    assert(frame_len <= frame.len);

    const parsed = gfdi.parse(frame[0..frame_len]) orelse return error.ParseFailed;

    try std.testing.expect(parsed.crc_ok);
    try std.testing.expectEqualSlices(u8, payload[0..payload_len], parsed.payload);

    if (raw_type & 0x8000 == 0) {
        try std.testing.expectEqual(message_type, parsed.type);
    }

    const flip_index = random.uintLessThan(u32, frame_len);
    const flip_mask = @as(u8, 1) << random.int(u3);

    frame[flip_index] ^= flip_mask;

    const corrupted = gfdi.parse(frame[0..frame_len]) orelse return;

    try std.testing.expect(!corrupted.crc_ok);
}

test "gfdi fuzz smoke" {
    try fuzz_cobs_round_trip(123, 50);
    try fuzz_frame_round_trip(123, 50);
    try fuzz_parse_noise(123, 50);
}
