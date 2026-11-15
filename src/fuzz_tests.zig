const std = @import("std");

const fit_fuzz = @import("protocol/fit_fuzz.zig");
const fuzz = @import("testing/fuzz.zig");
const gfdi_fuzz = @import("protocol/gfdi_fuzz.zig");
const link_fuzz = @import("transport/link_fuzz.zig");
const platform = @import("platform.zig");
const protobuf_fuzz = @import("protocol/protobuf_fuzz.zig");
const reassembly_fuzz = @import("transport/reassembly_fuzz.zig");
const session_fuzz = @import("session_fuzz.zig");
const wire_fuzz = @import("platform/linux/dbus/wire_fuzz.zig");

const assert = std.debug.assert;

const Fuzzer = enum {
    canary,
    dbus_client,
    dbus_wire,
    fit,
    gfdi,
    link,
    protobuf,
    reassembly,
    session,
    smoke,
};

pub const Error = error{
    ArgumentsInvalid,
    CanaryTripped,
    FuzzerUnsupported,
};

const arguments_max: u32 = 4;
const arguments_min: u32 = 2;
const canary_odds: u32 = 1024;
const client_fuzz = if (dbus_hosted) @import("platform/linux/dbus/client_fuzz.zig") else struct {};
const dbus_hosted = platform.Native.capabilities.dbus;
const fuzzer_unhosted_count: u32 = if (dbus_hosted) 0 else 1;
const seed_smoke: u64 = 123;

const usage_text = "usage: fuzz <canary|dbus_client|dbus_wire|fit|gfdi|link|protobuf|" ++
    "reassembly|session|smoke> [seed] [events]\n";

comptime {
    assert(seed_smoke > 0);
    assert(canary_odds > 1);
    assert(arguments_min < arguments_max);
    assert(@typeInfo(Fuzzer).@"enum".field_names.len == 10);
}

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < arguments_min) return usage();
    if (arguments.len > arguments_max) return usage();

    const fuzzer = std.meta.stringToEnum(Fuzzer, arguments[1]) orelse return usage();

    if (fuzzer == .smoke) {
        if (arguments.len > arguments_min) return usage();

        std.debug.print("fuzz smoke: seed={d} events_max={d}\n", .{
            seed_smoke,
            fuzz.events_max_smoke,
        });

        _ = try smoke(init.gpa);

        return;
    }

    assert(fuzzer != .smoke);

    const seed = if (arguments.len > 2)
        try seed_parse(arguments[2])
    else
        fuzz.random_seed(init.io);

    const events_max = if (arguments.len > 3)
        try events_parse(arguments[3])
    else
        fuzz.events_max_default;

    std.debug.print("fuzz {t}: seed={d} events_max={d}\n", .{
        fuzzer,
        seed,
        events_max,
    });

    try run(init.gpa, fuzzer, &.{ .events_max = events_max, .seed = seed });
}

fn usage() Error {
    std.debug.print("{s}", .{usage_text});

    return error.ArgumentsInvalid;
}

fn seed_parse(text: []const u8) Error!u64 {
    assert(text.len > 0);

    return fuzz.parse_seed(text) catch return usage();
}

fn events_parse(text: []const u8) Error!u32 {
    assert(text.len > 0);

    const result = std.fmt.parseUnsigned(u32, text, 10) catch return usage();
    if (result == 0) return usage();
    return result;
}

fn smoke(gpa: std.mem.Allocator) !u32 {
    var count: u32 = 0;

    for (std.enums.values(Fuzzer)) |each| {
        if (each == .smoke) continue;
        if (each == .canary) continue;

        if (each == .dbus_client) {
            if (!dbus_hosted) continue;
        }

        try run(gpa, each, &.{ .events_max = fuzz.events_max_smoke, .seed = seed_smoke });

        count += 1;
    }

    assert(count == std.enums.values(Fuzzer).len - 2 - fuzzer_unhosted_count);

    return count;
}

fn run(gpa: std.mem.Allocator, fuzzer: Fuzzer, campaign: *const fuzz.Campaign) !void {
    assert(fuzzer != .smoke);
    assert(campaign.events_max > 0);

    switch (fuzzer) {
        .canary => try canary_run(campaign),
        .dbus_client => if (dbus_hosted)
            try client_fuzz.run(campaign)
        else
            return error.FuzzerUnsupported,
        .dbus_wire => try wire_fuzz.run(campaign),
        .fit => try fit_fuzz.run(campaign),
        .gfdi => try gfdi_fuzz.run(campaign),
        .link => try link_fuzz.run(gpa, campaign),
        .protobuf => try protobuf_fuzz.run(campaign),
        .reassembly => try reassembly_fuzz.run(gpa, campaign),
        .session => try session_fuzz.run(gpa, campaign),
        .smoke => unreachable,
    }
}

fn canary_run(campaign: *const fuzz.Campaign) Error!void {
    assert(campaign.events_max > 0);

    var prng = std.Random.DefaultPrng.init(campaign.seed);

    const random = prng.random();

    for (0..campaign.events_max) |_| {
        if (random.uintLessThan(u32, canary_odds) == 0) return error.CanaryTripped;
    }
}

const testing = std.testing;

test "smoke runs every registered fuzzer" {
    try testing.expectEqual(@as(u32, 8) - fuzzer_unhosted_count, try smoke(testing.allocator));
}

test "canary trips for at least one seed and replays from it" {
    var tripped: ?u64 = null;

    for (0..64) |seed| {
        canary_run(&.{ .events_max = 4096, .seed = seed }) catch {
            tripped = seed;
        };

        if (tripped != null) break;
    }

    try testing.expect(tripped != null);

    try testing.expectError(
        error.CanaryTripped,
        canary_run(&.{ .events_max = 4096, .seed = tripped.? }),
    );

    try testing.expectError(
        error.CanaryTripped,
        run(testing.allocator, .canary, &.{ .events_max = 4096, .seed = tripped.? }),
    );
}

test "canary passes for a short run" {
    var prng = std.Random.DefaultPrng.init(seed_smoke);

    try testing.expect(prng.random().uintLessThan(u32, canary_odds) != 0);
    try canary_run(&.{ .events_max = 1, .seed = seed_smoke });
}

test "usage names every fuzzer" {
    for (std.enums.values(Fuzzer)) |fuzzer| {
        try testing.expect(std.mem.find(u8, usage_text, @tagName(fuzzer)) != null);
    }

    try testing.expectEqual(std.enums.values(Fuzzer).len - 1, std.mem.count(u8, usage_text, "|"));
    try testing.expect(std.mem.startsWith(u8, usage_text, "usage: fuzz <"));
    try testing.expect(std.mem.endsWith(u8, usage_text, "> [seed] [events]\n"));
}

test "seed_parse and events_parse read decimal text" {
    try testing.expectEqual(seed_smoke, try seed_parse("123"));
    try testing.expectEqual(@as(u64, 0), try seed_parse("0"));
    try testing.expectEqual(fuzz.events_max_default, try events_parse("4096"));
    try testing.expectEqual(@as(u32, 1), try events_parse("1"));
    try testing.expectEqual(std.math.maxInt(u64), try seed_parse("18446744073709551615"));

    try testing.expectEqual(
        @as(u64, 0xABCDEF),
        try seed_parse("0000000000000000000000000000000000abcdef"),
    );
}
