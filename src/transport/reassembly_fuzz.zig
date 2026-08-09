const std = @import("std");

const fuzz = @import("../testing/fuzz.zig");
const gfdi = @import("../protocol/gfdi.zig");
const reassembly = @import("../transport/reassembly.zig");

const assert = std.debug.assert;

const GFDIState = reassembly.GFDIStateType(reassembly.SingleThreadedLock);

const SentMessages = struct {
    frames: [messages_per_event_max][frame_len_max]u8 = undefined,
    frame_lengths: [messages_per_event_max]u32 = undefined,
    count: u32 = 0,
};

const messages_per_event_max: u32 = 8;
const payload_len_max: u32 = 64;
const frame_len_max: u32 = payload_len_max + 6;
const garbage_len_max: u32 = 4;
const fragment_len_max: u32 = 40;
const stream_len_max: u32 = 8192;

comptime {
    assert(messages_per_event_max * 2 < reassembly.ring_slots);
    assert(messages_per_event_max * (frame_len_max + 3 + garbage_len_max) <= stream_len_max);
}

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    try fuzz_reassembly(gpa, args.seed, args.events_max);
}

pub fn fuzz_reassembly(gpa: std.mem.Allocator, seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const state = try gpa.create(GFDIState);
    defer gpa.destroy(state);

    var event: u32 = 0;

    while (event < events) : (event += 1) {
        try reassembly_one(random, state);
    }

    assert(event == events);
}

fn reassembly_one(random: std.Random, state: *GFDIState) !void {
    state.* = .{};

    var sent = SentMessages{};
    var stream: [stream_len_max]u8 = undefined;
    var stream_len: u32 = 0;

    const message_count = random.intRangeAtMost(u32, 1, messages_per_event_max);
    const inject_garbage = random.boolean();

    var index: u32 = 0;

    while (index < message_count) : (index += 1) {
        if (inject_garbage) {
            stream_len += write_garbage(random, stream[stream_len..]);
        }

        stream_len += write_message(random, &sent, stream[stream_len..]);
        assert(stream_len <= stream.len);
    }

    push_in_fragments(random, state, stream[0..stream_len]);

    var out: [gfdi.message_len_max]u8 = undefined;
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
    const garbage_len = random.intRangeAtMost(u32, 1, garbage_len_max);

    assert(garbage_len <= stream.len);

    var index: u32 = 0;

    while (index < garbage_len) : (index += 1) {
        stream[index] = random.intRangeAtMost(u8, 1, 255);
    }

    return garbage_len;
}

fn write_message(random: std.Random, sent: *SentMessages, stream: []u8) u32 {
    assert(sent.count < messages_per_event_max);

    var payload: [payload_len_max]u8 = undefined;
    const payload_len = random.intRangeAtMost(u32, 0, payload_len_max);

    random.bytes(payload[0..payload_len]);

    const slot = sent.count;

    const frame_len = gfdi.build_frame(
        &sent.frames[slot],
        @enumFromInt(random.int(u16)),
        payload[0..payload_len],
    );

    sent.frame_lengths[slot] = frame_len;
    sent.count += 1;

    var wire: [gfdi.cobs_encoded_len_max(frame_len_max)]u8 = undefined;
    const wire_len = gfdi.cobs_encode(&wire, sent.frames[slot][0..frame_len]);

    assert(wire_len <= stream.len);
    @memcpy(stream[0..wire_len], wire[0..wire_len]);

    return wire_len;
}

fn push_in_fragments(random: std.Random, state: *GFDIState, stream: []const u8) void {
    var position: u32 = 0;
    var iterations: u32 = 0;

    while (position < stream.len) {
        iterations += 1;
        assert(iterations <= stream.len);

        const remaining: u32 = @intCast(stream.len - position);
        const take = @min(random.intRangeAtMost(u32, 1, fragment_len_max), remaining);

        state.mutex.lock();
        state.push_fragment(stream[position..][0..take]);
        state.mutex.unlock();

        position += take;
    }

    assert(position == stream.len);
}

test "reassembly fuzz smoke" {
    try fuzz_reassembly(std.testing.allocator, 123, 50);
}
