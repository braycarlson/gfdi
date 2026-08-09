const std = @import("std");

const assert = std.debug.assert;

pub const FuzzArgs = struct {
    seed: u64,
    events_max: u32,
};

pub const Error = error{
    InvalidSeed,
};

pub const events_max_default: u32 = 4096;
pub const events_max_smoke: u32 = 64;
pub const weight_max: u32 = 100;
pub const field_count_max: u32 = 64;
pub const commit_hash_len: u8 = 40;

comptime {
    assert(events_max_smoke >= 1);
    assert(events_max_smoke < events_max_default);
    assert(weight_max >= 1);
    assert(field_count_max >= 1);
    assert(commit_hash_len == 40);
}

pub fn parse_seed(text: []const u8) Error!u64 {
    assert(text.len > 0);

    if (text.len == commit_hash_len) {
        const hash = std.fmt.parseUnsigned(u160, text, 16) catch return Error.InvalidSeed;

        return @truncate(hash);
    }

    return std.fmt.parseUnsigned(u64, text, 10) catch return Error.InvalidSeed;
}

pub fn random_seed(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;

    io.random(&bytes);

    return std.mem.readInt(u64, &bytes, .little);
}

pub fn random_int_exponential(random: std.Random, comptime T: type, mean: T) T {
    comptime assert(@typeInfo(T) == .int);
    comptime assert(@typeInfo(T).int.signedness == .unsigned);
    assert(mean > 0);

    const uniform = random.float(f64);

    assert(uniform >= 0.0);
    assert(uniform < 1.0);

    const scale: f64 = @floatFromInt(mean);
    const exponential = -@log(1.0 - uniform) * scale;
    const bound: f64 = @floatFromInt(std.math.maxInt(T));

    if (exponential <= 0.0) return 0;
    if (exponential >= bound) return std.math.maxInt(T);

    const result: T = @intFromFloat(exponential);

    assert(result <= std.math.maxInt(T));

    return result;
}

pub fn EnumWeightsType(comptime Enum: type) type {
    const fields = @typeInfo(Enum).@"enum".fields;

    comptime assert(fields.len > 0);
    comptime assert(fields.len <= field_count_max);

    return [fields.len]u32;
}

pub fn random_enum_weights(random: std.Random, comptime Enum: type) EnumWeightsType(Enum) {
    const count = @typeInfo(Enum).@"enum".fields.len;

    comptime assert(count > 0);
    comptime assert(count <= field_count_max);

    var weights: EnumWeightsType(Enum) = [_]u32{0} ** count;
    var total: u32 = 0;
    var index: u32 = 0;

    while (index < count) : (index += 1) {
        assert(index < count);

        if (random.boolean()) {
            weights[index] = random.intRangeAtMost(u32, 1, weight_max);
            total += weights[index];
        }
    }

    assert(index == count);
    assert(total <= weight_max * count);

    if (total == 0) {
        const forced = random.uintLessThan(u32, count);

        assert(forced < count);

        weights[forced] = random.intRangeAtMost(u32, 1, weight_max);
        total = weights[forced];
    }

    assert(total > 0);

    return weights;
}

pub fn random_enum_weighted(
    random: std.Random,
    comptime Enum: type,
    weights: EnumWeightsType(Enum),
) Enum {
    const values = comptime enum_values(Enum);

    comptime assert(values.len > 0);
    comptime assert(values.len <= field_count_max);

    const total = weight_total(&weights);

    assert(total > 0);

    var choice = random.uintLessThan(u32, total);
    var index: u32 = 0;

    while (index < values.len) : (index += 1) {
        assert(index < values.len);

        if (choice < weights[index]) return values[index];

        choice -= weights[index];
    }

    unreachable;
}

pub fn random_enum_uniform(random: std.Random, comptime Enum: type) Enum {
    const values = comptime enum_values(Enum);

    comptime assert(values.len > 0);
    comptime assert(values.len <= field_count_max);

    const index = random.uintLessThan(u32, values.len);

    assert(index < values.len);

    return values[index];
}

pub fn random_from_slice(random: std.Random, comptime T: type, items: []const T) T {
    assert(items.len > 0);

    const index = random.uintLessThan(usize, items.len);

    assert(index < items.len);

    return items[index];
}

pub fn random_bytes(random: std.Random, buffer: []u8) []u8 {
    assert(buffer.len > 0);

    const length = random.uintLessThan(usize, buffer.len + 1);

    random.bytes(buffer[0..length]);

    assert(length <= buffer.len);

    return buffer[0..length];
}

fn enum_values(comptime Enum: type) [@typeInfo(Enum).@"enum".fields.len]Enum {
    const fields = @typeInfo(Enum).@"enum".fields;

    comptime assert(fields.len > 0);
    comptime assert(fields.len <= field_count_max);

    var values: [fields.len]Enum = undefined;

    for (fields, 0..) |field, index| {
        values[index] = @enumFromInt(field.value);
    }

    return values;
}

fn weight_total(weights: []const u32) u32 {
    assert(weights.len > 0);
    assert(weights.len <= field_count_max);

    var total: u32 = 0;
    var index: u32 = 0;

    while (index < weights.len) : (index += 1) {
        assert(index < weights.len);
        assert(total <= weight_max * field_count_max);

        total += weights[index];
    }

    assert(index == weights.len);

    return total;
}

const testing = std.testing;

const Operation = enum {
    first,
    second,
    third,
};

test "parse_seed decimal" {
    try testing.expectEqual(@as(u64, 12345), try parse_seed("12345"));
    try testing.expectEqual(@as(u64, 0), try parse_seed("0"));
}

test "parse_seed commit hash" {
    const hash = "0123456789abcdef0123456789abcdef01234567";

    comptime assert(hash.len == commit_hash_len);

    try testing.expectEqual(@as(u64, 0x89abcdef01234567), try parse_seed(hash));
}

test "parse_seed rejects garbage" {
    try testing.expectError(Error.InvalidSeed, parse_seed("not_a_number"));
    try testing.expectError(Error.InvalidSeed, parse_seed("-1"));
}

test "random_int_exponential stays within bounds" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var total: u64 = 0;
    var event: u32 = 0;

    while (event < 1000) : (event += 1) {
        const value = random_int_exponential(random, u8, 10);

        total += value;
    }

    assert(event == 1000);

    try testing.expect(total > 0);
}

test "random_enum_weights always leaves one variant reachable" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var event: u32 = 0;

    while (event < 1000) : (event += 1) {
        const weights = random_enum_weights(random, Operation);
        const total = weight_total(&weights);

        try testing.expect(total > 0);

        const value = random_enum_weighted(random, Operation, weights);

        try testing.expect(weights[@intFromEnum(value)] > 0);
    }

    assert(event == 1000);
}

test "random_enum_weighted respects zero weights" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const weights = EnumWeightsType(Operation){ 0, 7, 0 };
    var event: u32 = 0;

    while (event < 100) : (event += 1) {
        try testing.expectEqual(Operation.second, random_enum_weighted(random, Operation, weights));
    }

    assert(event == 100);
}

test "random_enum_uniform reaches every variant" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var seen = [_]bool{false} ** 3;
    var event: u32 = 0;

    while (event < 1000) : (event += 1) {
        seen[@intFromEnum(random_enum_uniform(random, Operation))] = true;
    }

    assert(event == 1000);

    try testing.expect(seen[0]);
    try testing.expect(seen[1]);
    try testing.expect(seen[2]);
}

test "random_from_slice stays in range" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const items = [_]u8{ 10, 20, 30 };
    var event: u32 = 0;

    while (event < 100) : (event += 1) {
        const value = random_from_slice(random, u8, &items);

        try testing.expect(value == 10 or value == 20 or value == 30);
    }

    assert(event == 100);
}

test "random_bytes never exceeds the buffer" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var buffer: [32]u8 = undefined;
    var event: u32 = 0;

    while (event < 100) : (event += 1) {
        const filled = random_bytes(random, &buffer);

        try testing.expect(filled.len <= buffer.len);
    }
}
