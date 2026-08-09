const std = @import("std");

const fuzz = @import("../testing/fuzz.zig");
const gfdi = @import("../protocol/gfdi.zig");
const link = @import("link.zig");
const multi_link = @import("../protocol/multi_link.zig");
const reassembly = @import("reassembly.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const GFDIState = reassembly.GFDIStateType(reassembly.SingleThreadedLock);

const Shape = enum {
    close_all,
    close_handle,
    data,
    noise,
    register,
    transfer,
};

const frames_per_event_max: u32 = 96;
const transfer_bytes_max: u32 = 8 * 1024;
const control_bytes_min: u32 = 14;

comptime {
    assert(frames_per_event_max > 0);
    assert(transfer_bytes_max > multi_link.mtu_write_max);
    assert(control_bytes_min <= multi_link.mtu_write_max);
    assert(@typeInfo(Shape).@"enum".fields.len == 6);
}

pub fn main(gpa: Allocator, args: fuzz.FuzzArgs) !void {
    assert(args.events_max >= 1);

    var prng = std.Random.DefaultPrng.init(args.seed);
    const random = prng.random();

    const state = try gpa.create(GFDIState);
    defer gpa.destroy(state);

    const transfer = try gpa.alloc(u8, transfer_bytes_max);
    defer gpa.free(transfer);

    var event: u32 = 0;

    while (event < args.events_max) : (event += 1) {
        state.* = .{};
        state.transfer_buffer = transfer;

        route_one(random, state);
    }

    assert(event == args.events_max);
}

fn route_one(random: std.Random, state: *GFDIState) void {
    const count = random.intRangeAtMost(u32, 1, frames_per_event_max);

    var index: u32 = 0;

    while (index < count) : (index += 1) {
        var frame: [multi_link.mtu_write_max]u8 = undefined;
        const length = build_frame(random, state, &frame);

        assert(length > 0);
        assert(length <= frame.len);

        link.route_frame(state, frame[0..length]);
        check_state(state);
    }

    drain(state);
}

fn build_frame(random: std.Random, state: *const GFDIState, frame: []u8) u32 {
    assert(frame.len == multi_link.mtu_write_max);

    return switch (fuzz.random_enum_uniform(random, Shape)) {
        .close_all => build_control(random, frame, multi_link.close_all_response, 0),
        .close_handle => build_close_handle(random, frame),
        .data => build_body(random, frame, state.handle),
        .noise => build_noise(random, frame),
        .register => build_register(random, frame),
        .transfer => build_body(random, frame, state.transfer_handle),
    };
}

fn build_register(random: std.Random, frame: []u8) u32 {
    const codes = multi_link.transfer_service_codes;
    const service = if (random.boolean())
        multi_link.service_gfdi
    else
        fuzz.random_from_slice(random, u16, &codes);

    const length = build_control(random, frame, multi_link.register_response, service);

    assert(length >= control_bytes_min);

    frame[12] = if (random.boolean()) 0 else random.int(u8);
    frame[13] = random.int(u8);

    return length;
}

fn build_close_handle(random: std.Random, frame: []u8) u32 {
    const codes = multi_link.transfer_service_codes;
    const service = fuzz.random_from_slice(random, u16, &codes);

    const request = if (random.boolean())
        multi_link.close_handle_request
    else
        multi_link.close_handle_response;

    return build_control(random, frame, request, service);
}

fn build_control(random: std.Random, frame: []u8, request: u8, service: u16) u32 {
    assert(frame.len >= control_bytes_min);

    const length = random.intRangeAtMost(u32, control_bytes_min, @intCast(frame.len));

    @memset(frame[0..length], 0);

    frame[0] = 0;
    frame[1] = request;
    frame[2] = multi_link.client_id;

    std.mem.writeInt(u16, frame[10..12], service, .little);

    assert(length <= frame.len);

    return length;
}

fn build_body(random: std.Random, frame: []u8, handle: u8) u32 {
    const length = random.intRangeAtMost(u32, 1, @intCast(frame.len));

    random.bytes(frame[0..length]);

    frame[0] = if (random.boolean()) handle else random.int(u8);

    assert(length > 0);

    return length;
}

fn build_noise(random: std.Random, frame: []u8) u32 {
    const length = random.intRangeAtMost(u32, 1, @intCast(frame.len));

    random.bytes(frame[0..length]);

    assert(length > 0);

    return length;
}

fn check_state(state: *const GFDIState) void {
    assert(state.reassembly_len <= state.reassembly.len);
    assert(state.transfer_len <= state.transfer_buffer.len);
    assert(state.ring_head < reassembly.ring_slots);
    assert(state.ring_tail < reassembly.ring_slots);

    if (state.transfer_len > 0) assert(state.transfer_started);
}

fn drain(state: *GFDIState) void {
    var out: [gfdi.message_len_max]u8 = undefined;
    var drained: u32 = 0;

    while (state.dequeue(&out)) |length| {
        drained += 1;

        assert(drained < reassembly.ring_slots);
        assert(length <= gfdi.message_len_max);
    }

    assert(state.ring_head == state.ring_tail);
}

const testing = std.testing;

test "link fuzzer survives a fixed seed" {
    try main(testing.allocator, .{ .events_max = fuzz.events_max_smoke, .seed = 123 });
}
