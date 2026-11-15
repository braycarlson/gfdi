const std = @import("std");

const fuzz = @import("../testing/fuzz.zig");
const gfdi = @import("../protocol/gfdi.zig");
const reassembly = @import("reassembly.zig");

const assert = std.debug.assert;

const GFDIState = reassembly.GFDIStateType(reassembly.SingleThreadedLock);

const SentMessages = struct {
    frames: [messages_per_event_max][frame_length_max]u8 = undefined,
    frame_lengths: [messages_per_event_max]u32 = undefined,
    count: u32 = 0,
};

const messages_per_event_max: u32 = 8;
const payload_length_max: u32 = 64;
const frame_length_max: u32 = payload_length_max + 6;
const garbage_length_max: u32 = 4;
const fragment_length_max: u32 = 40;
const stream_length_max: u32 = 8192;

comptime {
    assert(messages_per_event_max * 2 < reassembly.ring_slots);

    assert(messages_per_event_max * (frame_length_max + 3 + garbage_length_max) <=
        stream_length_max);
}

fn init(gpa: std.mem.Allocator) !*GFDIState {
    return gpa.create(GFDIState);
}

pub fn run(gpa: std.mem.Allocator, campaign: *const fuzz.Campaign) !void {
    assert(campaign.events_max > 0);

    var prng = std.Random.DefaultPrng.init(campaign.seed);

    const random = prng.random();

    const state = try init(gpa);
    defer gpa.destroy(state);

    var event: u32 = 0;

    while (event < campaign.events_max) : (event += 1) {
        try reassembly_one(random, state);
    }

    assert(event == campaign.events_max);
}

fn reassembly_one(random: std.Random, state: *GFDIState) !void {
    state.* = .{};

    var sent = SentMessages{};
    var stream: [stream_length_max]u8 = undefined;
    var stream_length: u32 = 0;

    const message_count = random.intRangeAtMost(u32, 1, messages_per_event_max);
    const inject_garbage = random.boolean();

    var index: u32 = 0;

    while (index < message_count) : (index += 1) {
        if (inject_garbage) {
            stream_length += write_garbage(random, stream[stream_length..]);
        }

        stream_length += write_message(random, &sent, stream[stream_length..]);

        assert(stream_length <= stream.len);
    }

    push_in_fragments(random, state, stream[0..stream_length]);

    var out: [gfdi.message_length_max]u8 = undefined;
    var matched: u32 = 0;

    while (state.dequeue(&out)) |length| {
        const parsed = gfdi.parse(out[0..length]) orelse continue;
        if (!parsed.crc_ok) continue;

        try std.testing.expect(matched < sent.count);

        try std.testing.expectEqualSlices(
            u8,
            sent.frames[matched][0..sent.frame_lengths[matched]],
            out[0..length],
        );

        matched += 1;
    }

    try std.testing.expectEqual(sent.count, matched);
    try std.testing.expectEqual(@as(u32, 0), state.dropped);
}

fn write_garbage(random: std.Random, stream: []u8) u32 {
    const garbage_length = random.intRangeAtMost(u32, 1, garbage_length_max);

    assert(garbage_length <= stream.len);

    var index: u32 = 0;

    while (index < garbage_length) : (index += 1) {
        stream[index] = random.intRangeAtMost(u8, 1, 255);
    }

    assert(std.mem.findScalar(u8, stream[0..garbage_length], 0) == null);

    return garbage_length;
}

fn write_message(random: std.Random, sent: *SentMessages, stream: []u8) u32 {
    assert(sent.count < messages_per_event_max);

    var payload: [payload_length_max]u8 = undefined;
    const payload_length = random.intRangeAtMost(u32, 0, payload_length_max);

    random.bytes(payload[0..payload_length]);

    const slot = sent.count;

    const frame_length = gfdi.build_frame(
        &sent.frames[slot],
        @fromBackingInt(random.int(u16)),
        payload[0..payload_length],
    );

    sent.frame_lengths[slot] = frame_length;
    sent.count += 1;

    var wire: [gfdi.cobs_encoded_length_max(frame_length_max)]u8 = undefined;
    const wire_length = gfdi.cobs_encode(&wire, sent.frames[slot][0..frame_length]);

    assert(wire_length <= stream.len);
    @memcpy(stream[0..wire_length], wire[0..wire_length]);

    return wire_length;
}

fn push_in_fragments(random: std.Random, state: *GFDIState, stream: []const u8) void {
    assert(stream.len <= stream_length_max);

    var position: u32 = 0;
    var iterations: u32 = 0;

    while (position < stream.len) {
        iterations += 1;

        assert(iterations <= stream.len);

        const remaining: u32 = @intCast(stream.len - position);
        const take = @min(random.intRangeAtMost(u32, 1, fragment_length_max), remaining);

        state.mutex.lock();
        state.push_fragment(stream[position..][0..take]);
        state.mutex.unlock();

        position += take;
    }

    assert(position == stream.len);
}

test "reassembly fuzz smoke" {
    try run(std.testing.allocator, &.{ .events_max = 50, .seed = 123 });
}
