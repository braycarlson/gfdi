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
    buffer: [file_len_max]u8 = undefined,
    len: u32 = 0,

    fn byte(builder: *Builder, value: u8) void {
        assert(builder.len < file_len_max);

        builder.buffer[builder.len] = value;
        builder.len += 1;
    }

    fn word(builder: *Builder, value: u16) void {
        builder.byte(@truncate(value));
        builder.byte(@truncate(value >> 8));
    }

    fn quad(builder: *Builder, value: u32) void {
        builder.word(@truncate(value));
        builder.word(@truncate(value >> 16));
    }

    fn remaining(builder: *const Builder) u32 {
        assert(builder.len <= file_len_max);
        return file_len_max - builder.len;
    }
};

const file_len_max: u32 = 2048;
const noise_len_max: u32 = 1024;
const filler_records_max: u32 = 16;
const filler_fields_max: u32 = 3;
const filler_field_size_max: u32 = 4;
const filler_reserve_bytes: u32 = 64;
const flip_count_max: u32 = 8;

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;

    const events = args.events_max;

    try fuzz_scan_planted(args.seed, events);
    try fuzz_scan_noise(args.seed +% 1, events);
}

pub fn fuzz_scan_planted(seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var builder = Builder{};
    var event: u32 = 0;

    while (event < events) : (event += 1) {
        const planted = generate_file(random, &builder);
        const info = fit.scan(builder.buffer[0..builder.len]);

        try check_planted(&planted, &info);
    }

    assert(event == events);
}

pub fn fuzz_scan_noise(seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var builder = Builder{};
    var noise: [noise_len_max]u8 = undefined;
    var event: u32 = 0;

    while (event < events) : (event += 1) {
        const len = random.intRangeAtMost(u32, 0, noise_len_max);

        random.bytes(noise[0..len]);
        _ = fit.scan(noise[0..len]);

        _ = generate_file(random, &builder);

        const flips = random.intRangeAtMost(u32, 1, flip_count_max);
        var flip: u32 = 0;

        while (flip < flips) : (flip += 1) {
            const index = random.uintLessThan(u32, builder.len);

            builder.buffer[index] ^= @as(u8, 1) << random.int(u3);
        }

        _ = fit.scan(builder.buffer[0..builder.len]);
    }

    assert(event == events);
}

fn generate_file(random: std.Random, builder: *Builder) Planted {
    builder.len = 0;

    builder.byte(14);
    builder.byte(0x10);
    builder.word(0);
    builder.quad(0);
    builder.byte('.');
    builder.byte('F');
    builder.byte('I');
    builder.byte('T');
    builder.word(0);

    const planted = Planted{
        .file_type = random.int(u8),
        .time_created = random.int(u32),
        .session_start = if (random.boolean()) random.int(u32) else null,
        .activity_time = if (random.boolean()) random.int(u32) else null,
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

    const data_size = builder.len - 14;

    std.mem.writeInt(u32, builder.buffer[4..8], data_size, .little);
    return planted;
}

fn write_file_id(builder: *Builder, planted: *const Planted) void {
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
}

fn write_session(builder: *Builder, session_start: u32) void {
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
}

fn write_activity(builder: *Builder, activity_time: u32) void {
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
}

fn write_filler(random: std.Random, builder: *Builder) void {
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
}

fn check_planted(planted: *const Planted, info: *const fit.FileInfo) !void {
    try std.testing.expectEqual(@as(?u8, planted.file_type), info.file_type);
    try std.testing.expectEqual(@as(?u32, planted.time_created), info.time_created);
    try std.testing.expectEqual(planted.session_start, info.session_start);
    try std.testing.expectEqual(planted.activity_time, info.activity_time);

    const expected_name = planted.activity_time orelse
        planted.session_start orelse planted.time_created;

    try std.testing.expectEqual(@as(?u32, expected_name), info.name_timestamp());
}

test "fit fuzz smoke" {
    try fuzz_scan_planted(123, 50);
    try fuzz_scan_noise(123, 50);
}
