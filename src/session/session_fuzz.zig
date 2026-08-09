const std = @import("std");

const fuzz = @import("../testing/fuzz.zig");
const gfdi = @import("../protocol/gfdi.zig");
const protobuf = @import("../protocol/protobuf.zig");
const session_module = @import("session.zig");

const FakeClock = @import("../testing/fake_clock.zig").FakeClock;
const FakeTransport = @import("../testing/fake_transport.zig").FakeTransport;
const MemStore = @import("../testing/mem_store.zig").MemStore;

const assert = std.debug.assert;

const FakeEnv = struct {
    pub const Transport = FakeTransport;
    pub const Clock = FakeClock;
    pub const FileStore = MemStore;
};

const EventKind = enum {
    device_info,
    download_status,
    legacy_chunk,
    protobuf_page,
    notification,
    time_request,
    unknown_type,
    corrupt_crc,
    runt,
    random_bytes,
    transfer_poke,
};

const FuzzSession = session_module.SessionType(FakeEnv);

const message_len_max: u32 = 512;
const out_buffer_len: u32 = 64 * 1024;
const session_buffer_len: u32 = 4096;
const transfer_data_len: u32 = 256;

const event_kind_count = @typeInfo(EventKind).@"enum".fields.len;

pub fn main(gpa: std.mem.Allocator, args: fuzz.FuzzArgs) !void {
    try fuzz_session(gpa, args.seed, args.events_max);
}

pub fn fuzz_session(gpa: std.mem.Allocator, seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const session = try gpa.create(FuzzSession);
    defer gpa.destroy(session);

    var transport = FakeTransport{};
    var out_buffer: [out_buffer_len]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);
    var protobuf_buffer: [session_buffer_len]u8 = undefined;
    var inflate_buffer: [session_buffer_len]u8 = undefined;
    var legacy_buffer: [session_buffer_len]u8 = undefined;
    var transfer_data: [transfer_data_len]u8 = undefined;

    random.bytes(&transfer_data);
    transport.transfer_data = &transfer_data;

    session.* = .{
        .transport = &transport,
        .out = &out,
        .clock = .{},
        .store = .{},

        .protobuf = .{
            .buffer = &protobuf_buffer,
            .inflate_buffer = &inflate_buffer,
        },

        .legacy = .{ .buffer = &legacy_buffer },
    };

    const weights = swarm_weights(random);

    var event: u32 = 0;

    while (event < events) : (event += 1) {
        out.end = 0;
        apply_event(random, session, &transport, &weights);
        check_invariants(session);
    }

    assert(event == events);
}

fn swarm_weights(random: std.Random) [event_kind_count]u32 {
    var weights: [event_kind_count]u32 = undefined;

    for (&weights) |*weight| {
        weight.* = if (random.boolean()) random.intRangeAtMost(u32, 1, 100) else 0;
    }

    var total: u32 = 0;

    for (weights) |weight| total += weight;
    if (total == 0) weights[0] = 1;

    return weights;
}

fn apply_event(
    random: std.Random,
    session: *FuzzSession,
    transport: *FakeTransport,
    weights: *const [event_kind_count]u32,
) void {
    var message: [message_len_max]u8 = undefined;

    const length: u32 = switch (pick_event(random, weights)) {
        .device_info => event_device_info(random, &message),
        .download_status => event_download_status(random, &message),
        .legacy_chunk => event_legacy_chunk(random, session, &message),
        .protobuf_page => event_protobuf_page(random, &message),
        .notification => event_notification(random, &message),
        .time_request => gfdi.build_frame(&message, .current_time_request, &.{}),
        .unknown_type => gfdi.build_frame(&message, @enumFromInt(random.int(u16)), &.{}),
        .corrupt_crc => event_corrupt_crc(random, &message),
        .runt => event_random_bytes(random, &message, 0, 5),
        .random_bytes => event_random_bytes(random, &message, 6, 64),
        .transfer_poke => {
            event_transfer_poke(random, session, transport);
            return;
        },
    };

    session.process_message(message[0..length]) catch |err| switch (err) {
        error.WriteFailed => {},
    };
}

fn pick_event(random: std.Random, weights: *const [event_kind_count]u32) EventKind {
    var total: u32 = 0;

    for (weights) |weight| total += weight;
    assert(total > 0);

    var roll = random.uintLessThan(u32, total);

    for (weights, 0..) |weight, index| {
        if (roll < weight) return @enumFromInt(index);
        roll -= weight;
    }

    unreachable;
}

fn event_device_info(random: std.Random, message: []u8) u32 {
    var payload: [16]u8 = undefined;
    const payload_len = random.intRangeAtMost(u32, 0, 16);

    random.bytes(payload[0..payload_len]);
    return gfdi.build_frame(message, .device_information, payload[0..payload_len]);
}

fn event_download_status(random: std.Random, message: []u8) u32 {
    var payload: [8]u8 = undefined;

    std.mem.writeInt(
        u16,
        payload[0..2],
        @intFromEnum(gfdi.MessageType.download_request),
        .little,
    );

    payload[2] = if (random.boolean()) 0 else random.int(u8);
    payload[3] = if (random.boolean()) 0 else random.int(u8);
    std.mem.writeInt(u32, payload[4..8], random.intRangeAtMost(u32, 0, 8192), .little);
    return gfdi.build_frame(message, .response, &payload);
}

fn event_legacy_chunk(random: std.Random, session: *FuzzSession, message: []u8) u32 {
    var payload: [64]u8 = undefined;
    const data_len = random.intRangeAtMost(u32, 0, 32);

    payload[0] = 0;

    const offset = if (random.boolean())
        session.legacy.received
    else
        random.intRangeAtMost(u32, 0, 8192);

    std.mem.writeInt(u16, payload[1..3], random.int(u16), .little);
    std.mem.writeInt(u32, payload[3..7], offset, .little);
    random.bytes(payload[7 .. 7 + data_len]);
    return gfdi.build_frame(message, .file_transfer_data, payload[0 .. 7 + data_len]);
}

fn event_protobuf_page(random: std.Random, message: []u8) u32 {
    var proto_bytes: [64]u8 = undefined;
    const proto_len = random.intRangeAtMost(u32, 0, 64);

    random.bytes(proto_bytes[0..proto_len]);
    return gfdi.build_protobuf_request(message, random.int(u16), proto_bytes[0..proto_len]);
}

fn event_notification(random: std.Random, message: []u8) u32 {
    var type_buffer: [32]u8 = undefined;
    var file_type = protobuf.Encoder.init(&type_buffer);

    file_type.field_bytes(2, "FIT_TYPE_4");
    file_type.field_varint(3, 4);

    var file_buffer: [64]u8 = undefined;
    var file = protobuf.Encoder.init(&file_buffer);

    file.field_bytes(2, file_type.written());
    file.field_varint(3, random.intRangeAtMost(u32, 0, 100_000));

    var service_buffer: [96]u8 = undefined;
    var service = protobuf.Encoder.init(&service_buffer);

    service.field_bytes(12, file.written());

    var smart_buffer: [128]u8 = undefined;
    var smart = protobuf.Encoder.init(&smart_buffer);

    smart.field_bytes(43, service.written());
    return gfdi.build_protobuf_request(message, random.int(u16), smart.written());
}

fn event_corrupt_crc(random: std.Random, message: []u8) u32 {
    const length = gfdi.build_frame(message, .device_information, &.{ 0x01, 0x02 });

    message[random.uintLessThan(u32, length)] ^= @as(u8, 1) << random.int(u3);
    return length;
}

fn event_random_bytes(random: std.Random, message: []u8, len_min: u32, len_max: u32) u32 {
    assert(len_min <= len_max);
    assert(len_max <= message.len);

    const length = random.intRangeAtMost(u32, len_min, len_max);

    random.bytes(message[0..length]);
    return length;
}

fn event_transfer_poke(
    random: std.Random,
    session: *FuzzSession,
    transport: *FakeTransport,
) void {
    transport.status = .{
        .ready = random.boolean(),
        .closed = random.boolean(),
        .overflow = random.boolean(),
        .handle = random.int(u8),
        .len = random.intRangeAtMost(u32, 0, transfer_data_len),
    };

    session.poll_transfer() catch |err| switch (err) {
        error.WriteFailed => {},
    };
}

fn check_invariants(session: *const FuzzSession) void {
    assert(session.protobuf.len <= session.protobuf.buffer.len);
    assert(session.legacy.received <= session.legacy.buffer.len);
    assert(session.queue.len <= session.queue.items.len);
    assert(session.queue.position <= session.queue.len);

    if (session.finished) assert(session.phase == .done);
}

test "session fuzz smoke" {
    try fuzz_session(std.testing.allocator, 123, 200);
}
