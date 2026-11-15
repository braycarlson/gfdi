const std = @import("std");

const fuzz = @import("../testing/fuzz.zig");
const gfdi = @import("gfdi.zig");

const assert = std.debug.assert;

const payload_length_max: u32 = gfdi.message_length_max - 6;
const wire_length_max: u32 = gfdi.cobs_encoded_length_max(gfdi.message_length_max);
const noise_length_max: u32 = 512;

pub fn run(campaign: *const fuzz.Campaign) !void {
    assert(campaign.events_max > 0);

    try fuzz_cobs_round_trip(campaign.seed, campaign.events_max);
    try fuzz_frame_round_trip(campaign.seed +% 1, campaign.events_max);
    try fuzz_parse_noise(campaign.seed +% 2, campaign.events_max);
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

    var noise: [noise_length_max]u8 = undefined;
    var event: u32 = 0;

    while (event < events) : (event += 1) {
        const length = random.intRangeAtMost(u32, 0, noise_length_max);

        random.bytes(noise[0..length]);

        if (gfdi.parse(noise[0..length])) |message| assert(message.payload.len + 6 == length);

        _ = gfdi.parse_protobuf_message(noise[0..length]);
        _ = gfdi.parse_download_status(noise[0..length]);
        _ = gfdi.parse_file_transfer_data(noise[0..length]);
        _ = gfdi.status_reference_type(noise[0..length]);
    }

    assert(event == events);
}

fn cobs_round_trip_one(random: std.Random) !void {
    var source: [gfdi.message_length_max]u8 = undefined;
    const source_length = random.intRangeAtMost(u32, 0, gfdi.message_length_max);
    const zero_percent = random.intRangeAtMost(u32, 0, 100);

    var index: u32 = 0;

    while (index < source_length) : (index += 1) {
        if (random.intRangeLessThan(u32, 0, 100) < zero_percent) {
            source[index] = 0;
        } else {
            source[index] = random.int(u8);
        }
    }

    var wire: [wire_length_max]u8 = undefined;
    const wire_length = gfdi.cobs_encode(&wire, source[0..source_length]);

    assert(wire_length >= 2);
    assert(wire_length <= wire.len);
    try std.testing.expectEqual(@as(u8, 0), wire[0]);
    try std.testing.expectEqual(@as(u8, 0), wire[wire_length - 1]);

    var decoded: [gfdi.message_length_max]u8 = undefined;
    const decoded_length = gfdi.cobs_decode(&decoded, wire[1 .. wire_length - 1]);

    try std.testing.expectEqualSlices(u8, source[0..source_length], decoded[0..decoded_length]);
}

fn frame_round_trip_one(random: std.Random) !void {
    var payload: [payload_length_max]u8 = undefined;
    const payload_length = random.intRangeAtMost(u32, 0, payload_length_max);

    random.bytes(payload[0..payload_length]);

    const raw_type = random.int(u16);
    const message_type: gfdi.MessageType = @fromBackingInt(raw_type);

    var frame: [gfdi.message_length_max]u8 = undefined;
    const frame_length = gfdi.build_frame(&frame, message_type, payload[0..payload_length]);

    assert(frame_length == payload_length + 6);
    assert(frame_length <= frame.len);

    const parsed = gfdi.parse(frame[0..frame_length]) orelse return error.ParseFailed;

    try std.testing.expect(parsed.crc_ok);
    try std.testing.expectEqualSlices(u8, payload[0..payload_length], parsed.payload);

    if (raw_type & 0x8000 == 0) try std.testing.expectEqual(message_type, parsed.type);

    const flip_index = random.uintLessThan(u32, frame_length);
    const flip_mask = @as(u8, 1) << random.int(u3);

    frame[flip_index] ^= flip_mask;

    const corrupted = gfdi.parse(frame[0..frame_length]) orelse return;

    try std.testing.expect(!corrupted.crc_ok);
}

test "gfdi fuzz smoke" {
    try fuzz_cobs_round_trip(123, 50);
    try fuzz_frame_round_trip(123, 50);
    try fuzz_parse_noise(123, 50);
}
