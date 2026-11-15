const std = @import("std");

const fit = @import("fit.zig");
const fuzz = @import("../testing/fuzz.zig");

const assert = std.debug.assert;

const Planted = struct {
    file_type: u8,
    time_created: u32,
    session_start: ?u32,
    activity_time: ?u32,
};

const Builder = struct {
    buffer: [file_length_max]u8 = undefined,
    length: u32 = 0,

    fn byte(builder: *Builder, value: u8) void {
        assert(builder.length < file_length_max);

        builder.buffer[builder.length] = value;
        builder.length += 1;
    }

    fn word(builder: *Builder, value: u16) void {
        assert(builder.remaining() >= 2);

        builder.byte(@truncate(value));
        builder.byte(@truncate(value >> 8));

        assert(std.mem.readInt(u16, builder.buffer[builder.length - 2 ..][0..2], .little) == value);
    }

    fn quad(builder: *Builder, value: u32) void {
        assert(builder.remaining() >= 4);

        builder.word(@truncate(value));
        builder.word(@truncate(value >> 16));

        assert(std.mem.readInt(u32, builder.buffer[builder.length - 4 ..][0..4], .little) == value);
    }

    fn remaining(builder: *const Builder) u32 {
        assert(builder.length <= file_length_max);

        return file_length_max - builder.length;
    }
};

const file_length_max: u32 = 2048;
const noise_length_max: u32 = 1024;
const filler_records_max: u32 = 16;
const filler_fields_max: u32 = 3;
const filler_field_size_max: u32 = 4;
const filler_reserve_bytes: u32 = 64;
const flip_count_max: u32 = 8;
const header_bytes: u32 = 14;
const file_id_bytes: u32 = 18;
const record_bytes: u32 = 14;
const filler_bytes_max: u32 = 7 + filler_fields_max * (3 + filler_field_size_max);
const file_type_invalid: u8 = 0xFF;
const timestamp_invalid: u32 = 0xFFFF_FFFF;
const timestamp_invalid_odds: u32 = 8;

comptime {
    assert(filler_bytes_max + record_bytes <= filler_reserve_bytes);
    assert(header_bytes + file_id_bytes + record_bytes + filler_reserve_bytes <= file_length_max);
    assert(timestamp_invalid_odds > 1);
}

pub fn run(campaign: *const fuzz.Campaign) !void {
    assert(campaign.events_max > 0);

    try fuzz_scan_planted(campaign.seed, campaign.events_max);
    try fuzz_scan_noise(campaign.seed +% 1, campaign.events_max);
}

pub fn fuzz_scan_planted(seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var builder = Builder{};
    var event: u32 = 0;

    while (event < events) : (event += 1) {
        const planted = generate_file(random, &builder);
        const information = fit.scan(builder.buffer[0..builder.length]);

        try check_planted(&planted, &information);
    }

    assert(event == events);
}

pub fn fuzz_scan_noise(seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var builder = Builder{};
    var noise: [noise_length_max]u8 = undefined;
    var event: u32 = 0;

    while (event < events) : (event += 1) {
        const length = random.intRangeAtMost(u32, 0, noise_length_max);

        random.bytes(noise[0..length]);

        const noise_information = fit.scan(noise[0..length]);

        if (noise_information.file_type) |file_type| assert(file_type != file_type_invalid);

        _ = generate_file(random, &builder);

        assert(builder.length >= header_bytes + file_id_bytes);

        const flips = random.intRangeAtMost(u32, 1, flip_count_max);
        var flip: u32 = 0;

        while (flip < flips) : (flip += 1) {
            const index = random.uintLessThan(u32, builder.length);

            builder.buffer[index] ^= @as(u8, 1) << random.int(u3);
        }

        const flipped_information = fit.scan(builder.buffer[0..builder.length]);

        if (flipped_information.name_timestamp()) |time| assert(time != timestamp_invalid);
    }

    assert(event == events);
}

fn generate_file(random: std.Random, builder: *Builder) Planted {
    builder.length = 0;

    builder.byte(14);
    builder.byte(0x10);
    builder.word(0);
    builder.quad(0);
    builder.byte('.');
    builder.byte('F');
    builder.byte('I');
    builder.byte('T');
    builder.word(0);

    assert(builder.length == header_bytes);

    const planted = Planted{
        .file_type = random.int(u8),
        .time_created = draw_timestamp(random),
        .session_start = if (random.boolean()) draw_timestamp(random) else null,
        .activity_time = if (random.boolean()) draw_timestamp(random) else null,
    };

    write_file_id(builder, &planted);

    if (planted.session_start) |value| write_session(builder, value);

    const filler_count = random.intRangeAtMost(u32, 0, filler_records_max);
    var index: u32 = 0;

    while (index < filler_count) : (index += 1) {
        if (builder.remaining() < filler_reserve_bytes) break;

        write_filler(random, builder);
    }

    if (planted.activity_time) |value| write_activity(builder, value);

    const data_size = builder.length - header_bytes;

    assert(data_size >= file_id_bytes);

    std.mem.writeInt(u32, builder.buffer[4..8], data_size, .little);

    return planted;
}

fn draw_timestamp(random: std.Random) u32 {
    if (random.uintLessThan(u32, timestamp_invalid_odds) == 0) return timestamp_invalid;

    return random.int(u32);
}

fn expected_timestamp(time: u32) ?u32 {
    return if (time == timestamp_invalid) null else time;
}

fn write_file_id(builder: *Builder, planted: *const Planted) void {
    assert(builder.remaining() >= file_id_bytes);

    builder.byte(0x40);
    builder.byte(0);
    builder.byte(0);
    builder.word(0);
    builder.byte(2);
    builder.byte(0);
    builder.byte(1);
    builder.byte(0x00);
    builder.byte(4);
    builder.byte(4);
    builder.byte(0x86);

    builder.byte(0x00);
    builder.byte(planted.file_type);
    builder.quad(planted.time_created);

    assert(builder.buffer[builder.length - file_id_bytes] == 0x40);
}

fn write_session(builder: *Builder, session_start: u32) void {
    assert(builder.remaining() >= record_bytes);

    builder.byte(0x41);
    builder.byte(0);
    builder.byte(0);
    builder.word(18);
    builder.byte(1);
    builder.byte(2);
    builder.byte(4);
    builder.byte(0x86);

    builder.byte(0x01);
    builder.quad(session_start);

    assert(builder.buffer[builder.length - record_bytes] == 0x41);
}

fn write_activity(builder: *Builder, activity_time: u32) void {
    assert(builder.remaining() >= record_bytes);

    builder.byte(0x42);
    builder.byte(0);
    builder.byte(0);
    builder.word(34);
    builder.byte(1);
    builder.byte(253);
    builder.byte(4);
    builder.byte(0x86);

    builder.byte(0x02);
    builder.quad(activity_time);

    assert(builder.buffer[builder.length - record_bytes] == 0x42);
}

fn write_filler(random: std.Random, builder: *Builder) void {
    assert(builder.remaining() >= filler_reserve_bytes);

    const local_type: u8 = random.intRangeAtMost(u8, 3, 15);
    const global: u16 = random.intRangeAtMost(u16, 100, 200);
    const field_count = random.intRangeAtMost(u32, 1, filler_fields_max);

    builder.byte(0x40 | local_type);
    builder.byte(0);
    builder.byte(0);
    builder.word(global);
    builder.byte(@intCast(field_count));

    var sizes: [filler_fields_max]u8 = undefined;
    var index: u32 = 0;

    while (index < field_count) : (index += 1) {
        sizes[index] = random.intRangeAtMost(u8, 1, filler_field_size_max);

        builder.byte(random.int(u8));
        builder.byte(sizes[index]);
        builder.byte(0x86);
    }

    builder.byte(local_type);

    index = 0;

    while (index < field_count) : (index += 1) {
        var size_index: u8 = 0;

        while (size_index < sizes[index]) : (size_index += 1) {
            builder.byte(random.int(u8));
        }
    }

    assert(builder.remaining() >= filler_reserve_bytes - filler_bytes_max);
}

fn check_planted(planted: *const Planted, information: *const fit.FileInformation) !void {
    const file_type: ?u8 = if (planted.file_type == file_type_invalid) null else planted.file_type;
    const time_created = expected_timestamp(planted.time_created);
    const session_start = if (planted.session_start) |time| expected_timestamp(time) else null;
    const activity_time = if (planted.activity_time) |time| expected_timestamp(time) else null;

    try std.testing.expectEqual(file_type, information.file_type);
    try std.testing.expectEqual(time_created, information.time_created);
    try std.testing.expectEqual(session_start, information.session_start);
    try std.testing.expectEqual(activity_time, information.activity_time);

    const expected_name = activity_time orelse session_start orelse time_created;

    try std.testing.expectEqual(expected_name, information.name_timestamp());
}

test "fit fuzz smoke" {
    var prng = std.Random.DefaultPrng.init(123);
    var builder = Builder{};

    const planted = generate_file(prng.random(), &builder);
    const information = fit.scan(builder.buffer[0..builder.length]);
    const data_size = std.mem.readInt(u32, builder.buffer[4..8], .little);

    try std.testing.expectEqualSlices(u8, ".FIT", builder.buffer[8..12]);
    try std.testing.expectEqual(builder.length - header_bytes, data_size);

    try std.testing.expectEqual(
        fit.FileInformation.unknown,
        fit.scan(builder.buffer[0..header_bytes]),
    );

    try check_planted(&planted, &information);
    try fuzz_scan_planted(123, 50);
    try fuzz_scan_noise(123, 50);
}
