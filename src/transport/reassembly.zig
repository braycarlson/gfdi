const std = @import("std");

const gfdi = @import("../protocol/gfdi.zig");

const assert = std.debug.assert;

pub const SingleThreadedLock = struct {
    pub fn lock(_: *SingleThreadedLock) void {}

    pub fn unlock(_: *SingleThreadedLock) void {}
};

pub fn GFDIStateType(comptime Lock: type) type {
    return struct {
        const Instance = @This();

        mutex: Lock = .{},
        handle: u8 = 0,
        handle_ready: bool = false,

        transfer_handle: u8 = 0,
        transfer_ready: bool = false,
        transfer_started: bool = false,
        transfer_closed: bool = false,
        transfer_overflow: bool = false,
        transfer_len: u32 = 0,
        transfer_buffer: []u8 = &.{},
        reassembly_len: u32 = 0,
        reassembly: [gfdi.message_len_max]u8 = undefined,
        ring_head: u32 = 0,
        ring_tail: u32 = 0,
        ring_lengths: [ring_slots]u32 = undefined,
        ring_messages: [ring_slots][gfdi.message_len_max]u8 = undefined,
        dropped: u32 = 0,

        pub fn push_fragment(instance: *Instance, fragment: []const u8) void {
            assert(instance.reassembly_len <= instance.reassembly.len);

            if (instance.reassembly_len + fragment.len > instance.reassembly.len) {
                @branchHint(.cold);

                instance.reassembly_len = 0;
                instance.dropped += 1;
                return;
            }

            @memcpy(instance.reassembly[instance.reassembly_len..][0..fragment.len], fragment);
            instance.reassembly_len += @intCast(fragment.len);
            assert(instance.reassembly_len <= instance.reassembly.len);

            var guard: u32 = 0;

            while (guard < gfdi.message_len_max) : (guard += 1) {
                assert(guard < gfdi.message_len_max);

                const buffer = instance.reassembly[0..instance.reassembly_len];

                if (buffer.len < 2) break;

                if (buffer[0] != 0x00) {
                    var next_zero: u32 = 1;

                    while (next_zero < buffer.len and buffer[next_zero] != 0x00) next_zero += 1;

                    if (next_zero >= buffer.len) {
                        instance.reassembly_len = 0;
                        break;
                    }

                    instance.shift_left(next_zero);
                    continue;
                }

                var terminator: u32 = 1;

                while (terminator < buffer.len and buffer[terminator] != 0x00) terminator += 1;

                if (terminator >= buffer.len) break;

                if (terminator > 1) instance.enqueue_decoded(buffer[1..terminator]);

                instance.shift_left(terminator);
            }
        }

        pub fn transfer_append(instance: *Instance, chunk: []const u8) void {
            assert(instance.transfer_len <= instance.transfer_buffer.len);

            if (!instance.transfer_started) {
                instance.transfer_started = true;
                return;
            }

            if (instance.transfer_closed) return;

            if (instance.transfer_len + chunk.len > instance.transfer_buffer.len) {
                @branchHint(.cold);
                instance.transfer_overflow = true;
                return;
            }

            @memcpy(instance.transfer_buffer[instance.transfer_len..][0..chunk.len], chunk);
            instance.transfer_len += @intCast(chunk.len);
            assert(instance.transfer_len <= instance.transfer_buffer.len);
        }

        pub fn transfer_reset(instance: *Instance) void {
            instance.mutex.lock();
            defer instance.mutex.unlock();

            instance.transfer_handle = 0;
            instance.transfer_ready = false;
            instance.transfer_started = false;
            instance.transfer_closed = false;
            instance.transfer_overflow = false;
            instance.transfer_len = 0;
        }

        pub fn dequeue(instance: *Instance, out: []u8) ?u32 {
            instance.mutex.lock();
            defer instance.mutex.unlock();

            assert(instance.ring_tail < ring_slots);
            assert(instance.ring_head < ring_slots);

            if (instance.ring_tail == instance.ring_head) return null;
            const length = instance.ring_lengths[instance.ring_tail];

            assert(length <= gfdi.message_len_max);
            assert(length <= out.len);

            @memcpy(out[0..length], instance.ring_messages[instance.ring_tail][0..length]);

            instance.ring_tail = (instance.ring_tail + 1) % ring_slots;
            assert(instance.ring_tail < ring_slots);

            return length;
        }

        fn shift_left(instance: *Instance, count: u32) void {
            assert(count <= instance.reassembly_len);

            const remaining = instance.reassembly_len - count;

            std.mem.copyForwards(
                u8,
                instance.reassembly[0..remaining],
                instance.reassembly[count..instance.reassembly_len],
            );

            instance.reassembly_len = remaining;

            assert(instance.reassembly_len <= instance.reassembly.len);
        }

        fn enqueue_decoded(instance: *Instance, frame_body: []const u8) void {
            assert(instance.ring_head < ring_slots);

            const next = (instance.ring_head + 1) % ring_slots;

            if (next == instance.ring_tail) {
                @branchHint(.cold);

                instance.dropped += 1;
                return;
            }

            const slot = &instance.ring_messages[instance.ring_head];
            const length = gfdi.cobs_decode(slot, frame_body);

            assert(length <= gfdi.message_len_max);

            instance.ring_lengths[instance.ring_head] = length;
            instance.ring_head = next;

            assert(instance.ring_head < ring_slots);
        }
    };
}

pub const ring_slots: u32 = 32;
pub const transfer_buffer_max: u32 = 4 * 1024 * 1024;

comptime {
    assert(ring_slots > 1);
}

const TestState = GFDIStateType(SingleThreadedLock);

fn encode_on_wire(wire: []u8, message_type: gfdi.MessageType, payload: []const u8) u32 {
    var message: [gfdi.message_len_max]u8 = undefined;
    const message_len = gfdi.build_frame(&message, message_type, payload);

    return gfdi.cobs_encode(wire, message[0..message_len]);
}

test "push_fragment reassembles one framed message and dequeue returns it" {
    var state: TestState = .{};

    var wire: [128]u8 = undefined;
    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const wire_len = encode_on_wire(&wire, .download_request, &payload);

    state.mutex.lock();
    state.push_fragment(wire[0..wire_len]);
    state.mutex.unlock();

    var out: [gfdi.message_len_max]u8 = undefined;
    const dequeued_len = state.dequeue(&out).?;
    const parsed = gfdi.parse(out[0..dequeued_len]).?;

    try std.testing.expect(parsed.crc_ok);
    try std.testing.expectEqual(gfdi.MessageType.download_request, parsed.type);
    try std.testing.expectEqualSlices(u8, &payload, parsed.payload);
    try std.testing.expect(state.dequeue(&out) == null);
}

test "push_fragment reassembles a message split across two fragments" {
    var state: TestState = .{};

    var wire: [128]u8 = undefined;
    const payload = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const wire_len = encode_on_wire(&wire, .response, &payload);

    state.mutex.lock();
    state.push_fragment(wire[0..3]);
    state.push_fragment(wire[3..wire_len]);
    state.mutex.unlock();

    var out: [gfdi.message_len_max]u8 = undefined;
    const dequeued_len = state.dequeue(&out).?;
    const parsed = gfdi.parse(out[0..dequeued_len]).?;

    try std.testing.expect(parsed.crc_ok);
    try std.testing.expectEqual(gfdi.MessageType.response, parsed.type);
    try std.testing.expect(state.dequeue(&out) == null);
}

test "push_fragment extracts two back-to-back messages in one fragment" {
    var state: TestState = .{};

    var wire: [128]u8 = undefined;
    const payload = [_]u8{ 0xAA, 0xBB };
    const wire_len = encode_on_wire(&wire, .device_information, &payload);

    var both: [256]u8 = undefined;
    @memcpy(both[0..wire_len], wire[0..wire_len]);
    @memcpy(both[wire_len..][0..wire_len], wire[0..wire_len]);

    state.mutex.lock();
    state.push_fragment(both[0 .. wire_len * 2]);
    state.mutex.unlock();

    var out: [gfdi.message_len_max]u8 = undefined;
    const first = state.dequeue(&out).?;

    try std.testing.expectEqual(
        gfdi.MessageType.device_information,
        gfdi.parse(out[0..first]).?.type,
    );

    const second = state.dequeue(&out).?;

    try std.testing.expectEqual(
        gfdi.MessageType.device_information,
        gfdi.parse(out[0..second]).?.type,
    );

    try std.testing.expect(state.dequeue(&out) == null);
}

test "ring drops frames when full rather than overwriting unread ones" {
    var state: TestState = .{};

    var wire: [128]u8 = undefined;
    const wire_len = encode_on_wire(&wire, .response, &.{0x01});

    var index: u32 = 0;
    state.mutex.lock();
    while (index < ring_slots + 4) : (index += 1) {
        state.push_fragment(wire[0..wire_len]);
    }
    state.mutex.unlock();
    try std.testing.expect(state.dropped > 0);

    var out: [gfdi.message_len_max]u8 = undefined;
    var drained: u32 = 0;

    while (state.dequeue(&out)) |length| {
        try std.testing.expect(gfdi.parse(out[0..length]).?.crc_ok);
        drained += 1;
    }
    try std.testing.expect(drained >= 1);
    try std.testing.expect(drained <= ring_slots - 1);
}

test "transfer_append skips the start marker then accumulates the body" {
    var state: TestState = .{};
    var buffer: [256]u8 = undefined;
    state.transfer_buffer = &buffer;

    state.mutex.lock();

    state.transfer_append("\x00\x00\x00");
    state.transfer_append("hello");
    state.transfer_append(" world");
    state.mutex.unlock();

    try std.testing.expectEqual(@as(u32, 11), state.transfer_len);

    try std.testing.expectEqualSlices(
        u8,
        "hello world",
        state.transfer_buffer[0..state.transfer_len],
    );

    try std.testing.expect(!state.transfer_overflow);
}

test "transfer_append flags overflow past the buffer end" {
    var state: TestState = .{};
    var buffer: [4]u8 = undefined;
    state.transfer_buffer = &buffer;

    state.mutex.lock();

    state.transfer_append("marker");

    state.transfer_append("toolong");
    state.mutex.unlock();

    try std.testing.expect(state.transfer_overflow);
    try std.testing.expectEqual(@as(u32, 0), state.transfer_len);
}

test "transfer_reset clears the channel for the next file" {
    var state: TestState = .{};
    var buffer: [16]u8 = undefined;
    state.transfer_buffer = &buffer;

    state.mutex.lock();

    state.transfer_append("marker");
    state.transfer_append("data");
    state.mutex.unlock();
    state.transfer_ready = true;

    state.transfer_reset();
    try std.testing.expectEqual(@as(u32, 0), state.transfer_len);
    try std.testing.expect(!state.transfer_ready);
    try std.testing.expect(!state.transfer_started);
    try std.testing.expect(!state.transfer_closed);
}
