const std = @import("std");

const fuzz = @import("../testing/fuzz.zig");
const protobuf = @import("protobuf.zig");

const assert = std.debug.assert;

const FieldKind = enum { varint, fixed64, bytes };

const ExpectedField = struct {
    kind: FieldKind,
    number: u32,
    varint: u64 = 0,
    bytes_len: u32 = 0,
    bytes: [bytes_field_len_max]u8 = undefined,
};

const fields_per_message_max: u32 = 16;
const bytes_field_len_max: u32 = 64;
const encode_buffer_len: u32 = 8192;
const noise_len_max: u32 = 512;

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    _ = gpa;

    const events = args.events_max;

    try fuzz_round_trip(args.seed, events);
    try fuzz_noise(args.seed +% 1, events);
}

pub fn fuzz_round_trip(seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var event: u32 = 0;

    while (event < events) : (event += 1) {
        try round_trip_one(random);
    }

    assert(event == events);
}

pub fn fuzz_noise(seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var noise: [noise_len_max]u8 = undefined;
    var event: u32 = 0;

    while (event < events) : (event += 1) {
        const len = random.intRangeAtMost(u32, 0, noise_len_max);

        random.bytes(noise[0..len]);

        var decoder = protobuf.Decoder.init(noise[0..len]);
        var iterations: u32 = 0;

        while (decoder.next()) |field| {
            iterations += 1;
            assert(iterations <= len + 1);
            assert(field.number >= 1);
            assert(field.number <= protobuf.field_number_max);
        }
    }

    assert(event == events);
}

fn round_trip_one(random: std.Random) !void {
    var expected: [fields_per_message_max]ExpectedField = undefined;
    const field_count = random.intRangeAtMost(u32, 1, fields_per_message_max);

    var buffer: [encode_buffer_len]u8 = undefined;
    var encoder = protobuf.Encoder.init(&buffer);

    var index: u32 = 0;

    while (index < field_count) : (index += 1) {
        expected[index] = generate_field(random);
        encode_field(&encoder, &expected[index]);
    }

    assert(encoder.len <= buffer.len);

    var decoder = protobuf.Decoder.init(encoder.written());

    index = 0;

    while (index < field_count) : (index += 1) {
        const field = decoder.next() orelse return error.MissingField;

        try check_field(&expected[index], &field);
    }

    if (decoder.next() != null) return error.TrailingField;
}

fn generate_field(random: std.Random) ExpectedField {
    const kind = random.enumValue(FieldKind);
    const number = random.intRangeAtMost(u32, 1, protobuf.field_number_max);

    var field = ExpectedField{ .kind = kind, .number = number };

    switch (kind) {
        .varint, .fixed64 => field.varint = random.int(u64),
        .bytes => {
            field.bytes_len = random.intRangeAtMost(u32, 0, bytes_field_len_max);
            random.bytes(field.bytes[0..field.bytes_len]);
        },
    }

    return field;
}

fn encode_field(encoder: *protobuf.Encoder, field: *const ExpectedField) void {
    assert(field.number >= 1);
    assert(field.number <= protobuf.field_number_max);

    switch (field.kind) {
        .varint => encoder.field_varint(field.number, field.varint),
        .fixed64 => encoder.field_fixed64(field.number, field.varint),
        .bytes => encoder.field_bytes(field.number, field.bytes[0..field.bytes_len]),
    }
}

fn check_field(expected: *const ExpectedField, actual: *const protobuf.Field) !void {
    try std.testing.expectEqual(expected.number, actual.number);

    switch (expected.kind) {
        .varint => {
            try std.testing.expectEqual(@as(u3, protobuf.wire_varint), actual.wire);
            try std.testing.expectEqual(expected.varint, actual.varint);
        },
        .fixed64 => {
            try std.testing.expectEqual(@as(u3, protobuf.wire_i64), actual.wire);
            try std.testing.expectEqual(expected.varint, actual.varint);
        },
        .bytes => {
            try std.testing.expectEqual(@as(u3, protobuf.wire_len), actual.wire);

            try std.testing.expectEqualSlices(
                u8,
                expected.bytes[0..expected.bytes_len],
                actual.bytes,
            );
        },
    }
}

test "protobuf fuzz smoke" {
    try fuzz_round_trip(123, 50);
    try fuzz_noise(123, 50);
}
