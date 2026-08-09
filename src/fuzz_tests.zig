const std = @import("std");
const builtin = @import("builtin");

const fuzz = @import("testing/fuzz.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const dbus_hosted = builtin.os.tag == .linux;

const Fuzzers = if (dbus_hosted) .{
    .dbus_client = @import("platform/linux/dbus/client_fuzz.zig"),
    .dbus_wire = @import("platform/linux/dbus/wire_fuzz.zig"),
    .fit = @import("protocol/fit_fuzz.zig"),
    .gfdi = @import("protocol/gfdi_fuzz.zig"),
    .link = @import("transport/link_fuzz.zig"),
    .protobuf = @import("protocol/protobuf_fuzz.zig"),
    .reassembly = @import("transport/reassembly_fuzz.zig"),
    .session = @import("session/session_fuzz.zig"),
    .canary = {},
    .smoke = {},
} else .{
    .dbus_wire = @import("platform/linux/dbus/wire_fuzz.zig"),
    .fit = @import("protocol/fit_fuzz.zig"),
    .gfdi = @import("protocol/gfdi_fuzz.zig"),
    .link = @import("transport/link_fuzz.zig"),
    .protobuf = @import("protocol/protobuf_fuzz.zig"),
    .reassembly = @import("transport/reassembly_fuzz.zig"),
    .session = @import("session/session_fuzz.zig"),
    .canary = {},
    .smoke = {},
};

pub const Fuzzer = std.meta.FieldEnum(@TypeOf(Fuzzers));

pub const Error = error{
    BadUsage,
    CanaryTripped,
    UnknownFuzzer,
};

const seed_smoke: u64 = 123;
const canary_odds: u32 = 1024;
const arguments_min: u32 = 2;
const arguments_max: u32 = 4;

const usage = build_usage();

comptime {
    assert(seed_smoke > 0);
    assert(canary_odds > 1);
    assert(arguments_min < arguments_max);
    assert(@typeInfo(Fuzzer).@"enum".fields.len > 2);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);

    if (arguments.len < arguments_min or arguments.len > arguments_max) {
        std.debug.print(usage, .{});

        return Error.BadUsage;
    }

    const fuzzer = std.meta.stringToEnum(Fuzzer, arguments[1]) orelse {
        std.debug.print(usage, .{});

        return Error.UnknownFuzzer;
    };

    const smoke = fuzzer == .smoke;

    const seed = if (arguments.len > 2)
        try fuzz.parse_seed(arguments[2])
    else if (smoke)
        seed_smoke
    else
        fuzz.random_seed(init.io);

    const events_max = if (arguments.len > 3)
        try std.fmt.parseUnsigned(u32, arguments[3], 10)
    else if (smoke)
        fuzz.events_max_smoke
    else
        fuzz.events_max_default;

    if (events_max < 1) {
        std.debug.print(usage, .{});

        return Error.BadUsage;
    }

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer assert(debug_allocator.deinit() == .ok);

    const gpa = debug_allocator.allocator();

    std.debug.print("fuzzer={s} seed={d} events={d}\n", .{
        @tagName(fuzzer),
        seed,
        events_max,
    });

    try run(gpa, fuzzer, .{ .seed = seed, .events_max = events_max });
}

pub fn run(gpa: Allocator, fuzzer: Fuzzer, args: fuzz.FuzzArgs) !void {
    assert(args.events_max >= 1);

    switch (fuzzer) {
        .smoke => try run_smoke(gpa, args),
        .canary => try run_canary(args),
        inline else => |tag| try @field(Fuzzers, @tagName(tag)).main(gpa, args),
    }
}

pub fn run_smoke(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    assert(args.events_max >= 1);

    inline for (@typeInfo(Fuzzer).@"enum".fields) |field| {
        const fuzzer = @field(Fuzzers, field.name);

        if (@TypeOf(fuzzer) != void) try fuzzer.main(gpa, args);
    }
}

fn run_canary(args: fuzz.FuzzArgs) !void {
    assert(args.events_max >= 1);

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        assert(event < args.events_max);

        if (random.uintLessThan(u32, canary_odds) == 0) return Error.CanaryTripped;
    }

    assert(event == args.events_max);
}

fn build_usage() []const u8 {
    var text: []const u8 = "usage: fuzz <fuzzer> [seed] [events]\n\nfuzzers:";

    for (@typeInfo(Fuzzer).@"enum".fields) |field| {
        text = text ++ " " ++ field.name;
    }

    return text ++ "\n";
}

const testing = std.testing;

test "smoke runs every registered fuzzer" {
    try run_smoke(testing.allocator, .{
        .seed = seed_smoke,
        .events_max = fuzz.events_max_smoke,
    });
}

test "canary trips for at least one seed" {
    var tripped = false;
    var seed: u64 = 0;

    while (seed < 64 and !tripped) : (seed += 1) {
        run_canary(.{ .seed = seed, .events_max = 4096 }) catch {
            tripped = true;
        };
    }

    assert(seed <= 64);

    try testing.expect(tripped);
}

test "canary passes for a short run" {
    try run_canary(.{ .seed = seed_smoke, .events_max = 1 });
}

test "usage lists every fuzzer" {
    inline for (@typeInfo(Fuzzer).@"enum".fields) |field| {
        try testing.expect(std.mem.indexOf(u8, usage, field.name) != null);
    }
}
