const std = @import("std");

const gfdi = @import("../protocol/gfdi.zig");
const multi_link = @import("../protocol/multi_link.zig");
const reassembly = @import("reassembly.zig");

const TransferStatus = @import("transport.zig").TransferStatus;

const assert = std.debug.assert;

const TestState = reassembly.GFDIStateType(reassembly.SingleThreadedLock);

pub const register_frame_len: u32 = 13;
pub const start_transfer_frame_len: u32 = 7;

comptime {
    assert(register_frame_len > start_transfer_frame_len);
    assert(register_frame_len <= multi_link.mtu_write_max);
}

pub fn LinkType(comptime Backend: type) type {
    assert_backend(Backend);

    return struct {
        const Instance = @This();

        backend: *Backend,
        state: *Backend.State,
        transfer_service_index: u32 = 0,

        pub fn send(instance: *Instance, message: []const u8) !void {
            assert(message.len > 0);
            assert(message.len <= gfdi.message_len_max);

            instance.state.mutex.lock();

            const ready = instance.state.handle_ready;
            const handle = instance.state.handle;

            instance.state.mutex.unlock();

            if (!ready) return;

            var encoded: [gfdi.message_len_max]u8 = undefined;
            const encoded_len = gfdi.cobs_encode(&encoded, message);

            assert(encoded_len <= encoded.len);

            const chunk_max = multi_link.mtu_write_max - 1;

            var position: u32 = 0;
            var guard: u32 = 0;

            while (position < encoded_len) : (guard += 1) {
                assert(guard <= gfdi.message_len_max);

                const take = @min(chunk_max, encoded_len - position);

                assert(take > 0);
                assert(take <= chunk_max);
                assert(position + take <= encoded_len);

                var frame: [multi_link.mtu_write_max]u8 = undefined;

                frame[0] = handle;

                @memcpy(frame[1 .. 1 + take], encoded[position .. position + take]);

                try instance.backend.write_raw(frame[0 .. 1 + take]);

                position += take;
            }

            assert(position == encoded_len);
        }

        pub fn register_service(instance: *Instance, service_code: u16) !void {
            var frame: [register_frame_len]u8 = undefined;

            @memset(&frame, 0);

            frame[1] = multi_link.register_request;
            frame[2] = multi_link.client_id;

            std.mem.writeInt(u16, frame[10..12], service_code, .little);

            try instance.backend.write_raw(&frame);
        }

        pub fn register_next_transfer_service(instance: *Instance) !void {
            const codes = multi_link.transfer_service_codes;
            const index = instance.transfer_service_index % codes.len;

            assert(index < codes.len);

            const code = codes[index];

            instance.transfer_service_index += 1;

            try instance.register_service(code);
        }

        pub fn start_transfer(instance: *Instance, file_handle: u32) !void {
            instance.state.mutex.lock();

            const handle = instance.state.transfer_handle;

            instance.state.mutex.unlock();

            var frame: [start_transfer_frame_len]u8 = undefined;

            @memset(&frame, 0);

            frame[0] = handle;

            std.mem.writeInt(u16, frame[3..5], @truncate(file_handle), .little);

            try instance.backend.write_raw(&frame);
        }

        pub fn next_message(instance: *Instance, out: []u8) ?u32 {
            return instance.state.dequeue(out);
        }

        pub fn transfer_status(instance: *Instance) TransferStatus {
            instance.state.mutex.lock();
            defer instance.state.mutex.unlock();

            return .{
                .ready = instance.state.transfer_ready,
                .closed = instance.state.transfer_closed,
                .overflow = instance.state.transfer_overflow,
                .handle = instance.state.transfer_handle,
                .len = instance.state.transfer_len,
            };
        }

        pub fn transfer_reset(instance: *Instance) void {
            instance.state.transfer_reset();
        }

        pub fn transfer_bytes(instance: *Instance, length: u32) []const u8 {
            assert(length <= instance.state.transfer_buffer.len);

            return instance.state.transfer_buffer[0..length];
        }

        pub fn transfer_capacity(instance: *Instance) u32 {
            return @intCast(instance.state.transfer_buffer.len);
        }

        pub fn poll(instance: *Instance) void {
            instance.backend.poll();
        }
    };
}

fn assert_backend(comptime Backend: type) void {
    comptime {
        if (!@hasDecl(Backend, "State")) {
            @compileError("Link backend " ++ @typeName(Backend) ++ " is missing 'State'");
        }

        if (@TypeOf(Backend.State) != type) {
            @compileError("Link backend " ++ @typeName(Backend) ++ " 'State' is not a type");
        }

        for ([_][]const u8{ "write_raw", "poll" }) |name| {
            if (!@hasDecl(Backend, name)) {
                @compileError("Link backend " ++ @typeName(Backend) ++
                    " is missing method '" ++ name ++ "'");
            }

            if (@typeInfo(@TypeOf(@field(Backend, name))) != .@"fn") {
                @compileError("Link backend " ++ @typeName(Backend) ++
                    " declaration '" ++ name ++ "' is not a function");
            }
        }
    }
}

pub fn route_frame(state: anytype, bytes: []const u8) void {
    assert(bytes.len > 0);

    const first = bytes[0];
    const is_mlr = (first & 0x80) != 0;
    const handle: u8 = if (is_mlr) (first & 0x70) >> 4 else first;

    state.mutex.lock();
    defer state.mutex.unlock();

    if (handle == 0x00 and !is_mlr) {
        route_control(state, bytes);

        return;
    }

    if (state.handle_ready and handle == state.handle) {
        state.push_fragment(bytes[1..]);
    } else if (state.transfer_ready and handle == state.transfer_handle) {
        state.transfer_append(bytes[1..]);
    }
}

fn route_control(state: anytype, bytes: []const u8) void {
    if (bytes.len < 2) return;

    const request = bytes[1];

    if (request == multi_link.register_response and bytes.len >= 14) {
        const service = std.mem.readInt(u16, bytes[10..12], .little);
        const status = bytes[12];
        const assigned = bytes[13];

        if (status == 0 and service == multi_link.service_gfdi) {
            state.handle = assigned;
            state.handle_ready = true;
            state.reassembly_len = 0;
        } else if (status == 0 and multi_link.is_transfer_service(service)) {
            state.transfer_handle = assigned;
            state.transfer_ready = true;
        }

        return;
    }

    if (request == multi_link.close_all_response) {
        state.handle_ready = false;
        state.reassembly_len = 0;

        return;
    }

    const closing = request == multi_link.close_handle_request or
        request == multi_link.close_handle_response;

    if (bytes.len >= 12 and closing) {
        const service = std.mem.readInt(u16, bytes[10..12], .little);

        if (multi_link.is_transfer_service(service)) state.transfer_closed = true;
    }
}

fn control_frame(request: u8, service: u16, status: u8, assigned: u8) [14]u8 {
    var frame = [_]u8{0} ** 14;

    frame[1] = request;
    frame[2] = multi_link.client_id;

    std.mem.writeInt(u16, frame[10..12], service, .little);

    frame[12] = status;
    frame[13] = assigned;

    return frame;
}

const CaptureBackend = struct {
    writes: [captures_max][multi_link.mtu_write_max]u8 = undefined,
    lengths: [captures_max]u32 = undefined,
    count: u32 = 0,
    polls: u32 = 0,

    pub const State = TestState;

    pub fn write_raw(backend: *CaptureBackend, bytes: []const u8) !void {
        assert(bytes.len > 0);
        assert(bytes.len <= multi_link.mtu_write_max);

        if (backend.count == captures_max) return error.CaptureFull;

        @memcpy(backend.writes[backend.count][0..bytes.len], bytes);

        backend.lengths[backend.count] = @intCast(bytes.len);
        backend.count += 1;
    }

    pub fn poll(backend: *CaptureBackend) void {
        backend.polls += 1;
    }

    fn get(backend: *const CaptureBackend, index: u32) []const u8 {
        assert(index < backend.count);

        return backend.writes[index][0..backend.lengths[index]];
    }
};

const CaptureLink = LinkType(CaptureBackend);

const captures_max: u32 = 64;

fn capture_link(backend: *CaptureBackend, state: *TestState) CaptureLink {
    return .{ .backend = backend, .state = state };
}

const testing = std.testing;

test "send chunks a COBS encoded message behind the assigned handle" {
    var backend = CaptureBackend{};
    var state: TestState = .{};

    state.handle = 6;
    state.handle_ready = true;

    var instance = capture_link(&backend, &state);

    var message: [gfdi.message_len_max]u8 = undefined;
    const message_len = gfdi.build_frame(&message, .response, &([_]u8{0x5A} ** 64));

    try instance.send(message[0..message_len]);

    var encoded: [gfdi.message_len_max]u8 = undefined;
    const encoded_len = gfdi.cobs_encode(&encoded, message[0..message_len]);

    const chunk_max = multi_link.mtu_write_max - 1;

    try testing.expectEqual((encoded_len + chunk_max - 1) / chunk_max, backend.count);

    var position: u32 = 0;
    var index: u32 = 0;

    while (index < backend.count) : (index += 1) {
        const written = backend.get(index);
        const take = @min(chunk_max, encoded_len - position);

        try testing.expectEqual(@as(usize, take + 1), written.len);
        try testing.expectEqual(@as(u8, 6), written[0]);
        try testing.expectEqualSlices(u8, encoded[position..][0..take], written[1..]);

        position += take;
    }

    try testing.expectEqual(encoded_len, position);
}

test "send writes nothing before the GFDI handle is granted" {
    var backend = CaptureBackend{};
    var state: TestState = .{};

    var instance = capture_link(&backend, &state);

    try instance.send(&[_]u8{ 1, 2, 3 });

    try testing.expectEqual(@as(u32, 0), backend.count);
}

test "register_service writes the documented frame layout" {
    var backend = CaptureBackend{};
    var state: TestState = .{};

    var instance = capture_link(&backend, &state);

    try instance.register_service(multi_link.service_gfdi);

    const written = backend.get(0);

    try testing.expectEqual(@as(usize, register_frame_len), written.len);
    try testing.expectEqual(@as(u8, 0), written[0]);
    try testing.expectEqual(multi_link.register_request, written[1]);
    try testing.expectEqual(multi_link.client_id, written[2]);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 7, written[3..10]);

    const service = std.mem.readInt(u16, written[10..12], .little);

    try testing.expectEqual(multi_link.service_gfdi, service);
    try testing.expectEqual(@as(u8, 0), written[12]);
}

test "register_next_transfer_service walks the service codes in order" {
    var backend = CaptureBackend{};
    var state: TestState = .{};

    var instance = capture_link(&backend, &state);

    const codes = multi_link.transfer_service_codes;

    var index: u32 = 0;

    while (index < codes.len + 1) : (index += 1) {
        try instance.register_next_transfer_service();
    }

    try testing.expectEqual(@as(u32, codes.len + 1), backend.count);

    var seen: u32 = 0;

    while (seen < backend.count) : (seen += 1) {
        const written = backend.get(seen);
        const expected = codes[seen % codes.len];

        try testing.expectEqual(expected, std.mem.readInt(u16, written[10..12], .little));
    }
}

test "start_transfer writes the file handle behind the transfer handle" {
    var backend = CaptureBackend{};
    var state: TestState = .{};

    state.transfer_handle = 4;

    var instance = capture_link(&backend, &state);

    try instance.start_transfer(0x1234);

    const written = backend.get(0);

    try testing.expectEqual(@as(usize, start_transfer_frame_len), written.len);
    try testing.expectEqual(@as(u8, 4), written[0]);
    try testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, written[3..5], .little));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, written[1..3]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0 }, written[5..7]);
}

test "the link forwards polling and transfer state to the backend and the state" {
    var backend = CaptureBackend{};
    var state: TestState = .{};
    var buffer: [32]u8 = undefined;

    state.transfer_buffer = &buffer;
    state.transfer_ready = true;
    state.transfer_len = 3;

    var instance = capture_link(&backend, &state);

    instance.poll();

    try testing.expectEqual(@as(u32, 1), backend.polls);
    try testing.expectEqual(@as(u32, 32), instance.transfer_capacity());
    try testing.expectEqual(@as(usize, 3), instance.transfer_bytes(3).len);

    const status = instance.transfer_status();

    try testing.expect(status.ready);
    try testing.expectEqual(@as(u32, 3), status.len);

    instance.transfer_reset();

    try testing.expect(!instance.transfer_status().ready);
}

test "route_frame grants the GFDI handle from a register response" {
    var state: TestState = .{};

    const frame = control_frame(multi_link.register_response, multi_link.service_gfdi, 0, 3);

    route_frame(&state, &frame);

    try testing.expect(state.handle_ready);
    try testing.expectEqual(@as(u8, 3), state.handle);
    try testing.expect(!state.transfer_ready);
}

test "route_frame ignores a register response that failed" {
    var state: TestState = .{};

    const frame = control_frame(multi_link.register_response, multi_link.service_gfdi, 1, 3);

    route_frame(&state, &frame);

    try testing.expect(!state.handle_ready);
    try testing.expectEqual(@as(u8, 0), state.handle);
}

test "route_frame grants a transfer handle from a register response" {
    var state: TestState = .{};

    const service = multi_link.transfer_service_codes[0];
    const frame = control_frame(multi_link.register_response, service, 0, 5);

    route_frame(&state, &frame);

    try testing.expect(state.transfer_ready);
    try testing.expectEqual(@as(u8, 5), state.transfer_handle);
    try testing.expect(!state.handle_ready);
}

test "route_frame drops the GFDI handle on a close-all response" {
    var state: TestState = .{};

    state.handle = 3;
    state.handle_ready = true;
    state.reassembly_len = 7;

    const frame = control_frame(multi_link.close_all_response, 0, 0, 0);

    route_frame(&state, &frame);

    try testing.expect(!state.handle_ready);
    try testing.expectEqual(@as(u32, 0), state.reassembly_len);
}

test "route_frame closes the transfer channel on a close-handle frame" {
    var state: TestState = .{};

    const service = multi_link.transfer_service_codes[1];
    const frame = control_frame(multi_link.close_handle_request, service, 0, 0);

    route_frame(&state, &frame);

    try testing.expect(state.transfer_closed);
}

test "route_frame feeds a data frame on the GFDI handle into reassembly" {
    var state: TestState = .{};

    state.handle = 2;
    state.handle_ready = true;

    var message: [gfdi.message_len_max]u8 = undefined;
    const message_len = gfdi.build_frame(&message, .response, &.{ 0xAB, 0xCD });

    var wire: [64]u8 = undefined;
    const wire_len = gfdi.cobs_encode(&wire, message[0..message_len]);

    var frame: [multi_link.mtu_write_max]u8 = undefined;

    frame[0] = 2;

    @memcpy(frame[1 .. 1 + wire_len], wire[0..wire_len]);

    route_frame(&state, frame[0 .. 1 + wire_len]);

    var out: [gfdi.message_len_max]u8 = undefined;
    const dequeued = state.dequeue(&out).?;

    try testing.expectEqualSlices(u8, message[0..message_len], out[0..dequeued]);
}

test "route_frame appends a data frame on the transfer handle" {
    var state: TestState = .{};
    var buffer: [64]u8 = undefined;

    state.transfer_buffer = &buffer;
    state.transfer_handle = 4;
    state.transfer_ready = true;

    route_frame(&state, &[_]u8{ 4, 0, 0, 0 });
    route_frame(&state, &[_]u8{ 4, 'o', 'k' });

    try testing.expectEqual(@as(u32, 2), state.transfer_len);
    try testing.expectEqualSlices(u8, "ok", state.transfer_buffer[0..state.transfer_len]);
}

test "route_frame ignores a data frame for an unassigned handle" {
    var state: TestState = .{};

    route_frame(&state, &[_]u8{ 9, 1, 2, 3 });

    try testing.expectEqual(@as(u32, 0), state.reassembly_len);
    try testing.expectEqual(@as(u32, 0), state.dropped);
}
