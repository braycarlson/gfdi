const std = @import("std");

const fuzz = @import("testing/fuzz.zig");
const gfdi = @import("protocol/gfdi.zig");
const protobuf = @import("protocol/protobuf.zig");
const session_module = @import("session.zig");

const FakeClock = @import("testing/fake_clock.zig").FakeClock;
const FakeTransport = @import("testing/fake_transport.zig").FakeTransport;
const MemoryStore = @import("testing/memory_store.zig").MemoryStore;
const SessionType = session_module.SessionType;

const assert = std.debug.assert;

const FakeEnvironment = struct {
    pub const Transport = FakeTransport;
    pub const Clock = FakeClock;
    pub const FileStore = MemoryStore;
};

const EventKind = enum {
    device_information,
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

const FuzzSession = SessionType(FakeEnvironment);
const message_length_max: u32 = 512;
const out_buffer_length: u32 = 64 * 1024;
const session_buffer_length: u32 = 4096;
const transfer_data_length: u32 = 256;
const event_kind_count = @typeInfo(EventKind).@"enum".field_names.len;

pub fn run(gpa: std.mem.Allocator, campaign: *const fuzz.Campaign) !void {
    assert(campaign.events_max > 0);

    try fuzz_session(gpa, campaign.seed, campaign.events_max);
}

pub fn fuzz_session(gpa: std.mem.Allocator, seed: u64, events: u32) !void {
    assert(events > 0);

    var prng = std.Random.DefaultPrng.init(seed);

    const random = prng.random();

    const fixture = try init(gpa, random);
    defer gpa.destroy(fixture);

    const weights = swarm_weights(random);

    for (0..events) |_| {
        fixture.out.end = 0;

        apply_event(random, &fixture.session, &fixture.transport, &weights);
        check_invariants(&fixture.session);

        assert(fixture.out.end <= out_buffer_length);
    }
}

const Fixture = struct {
    out: std.Io.Writer,
    out_buffer: [out_buffer_length]u8,
    session: FuzzSession,
    storage: FuzzStorage,
    transfer_data: [transfer_data_length]u8,
    transport: FakeTransport,
};

const FuzzStorage = session_module.StorageType(.{
    .inflate_bytes_max = session_buffer_length,
    .legacy_bytes_max = session_buffer_length,
    .protobuf_bytes_max = session_buffer_length,
    .transfer_bytes_max = transfer_data_length,
});

fn init(gpa: std.mem.Allocator, random: std.Random) !*Fixture {
    const fixture = try gpa.create(Fixture);

    fixture.out = .fixed(&fixture.out_buffer);
    fixture.transport = .empty;

    random.bytes(&fixture.transfer_data);

    fixture.transport.transfer_data = &fixture.transfer_data;

    const storage = fixture.storage.slices();

    fixture.session.init(&storage, &fixture.transport, &fixture.out, .zero, .empty);

    return fixture;
}

fn swarm_weights(random: std.Random) [event_kind_count]u32 {
    var weights: [event_kind_count]u32 = undefined;

    for (&weights) |*weight| {
        weight.* = if (random.boolean()) random.intRangeAtMost(u32, 1, 100) else 0;
    }

    var total: u32 = 0;

    for (weights) |weight| total += weight;
    assert(total <= event_kind_count * 100);

    if (total == 0) weights[0] = 1;

    assert(std.mem.max(u32, &weights) > 0);

    return weights;
}

fn apply_event(
    random: std.Random,
    session: *FuzzSession,
    transport: *FakeTransport,
    weights: *const [event_kind_count]u32,
) void {
    assert(session.transport == transport);

    var message: [message_length_max]u8 = undefined;

    const length: u32 = switch (pick_event(random, weights)) {
        .device_information => event_device_information(random, &message),
        .download_status => event_download_status(random, &message),
        .legacy_chunk => event_legacy_chunk(random, session, &message),
        .protobuf_page => event_protobuf_page(random, &message),
        .notification => event_notification(random, &message),
        .time_request => gfdi.build_frame(&message, .current_time_request, &.{}),
        .unknown_type => gfdi.build_frame(&message, @fromBackingInt(random.int(u16)), &.{}),
        .corrupt_crc => event_corrupt_crc(random, &message),
        .runt => event_random_bytes(random, &message, .{ .maximum = 5, .minimum = 0 }),
        .random_bytes => event_random_bytes(random, &message, .{ .maximum = 64, .minimum = 6 }),
        .transfer_poke => {
            event_transfer_poke(random, session, transport);

            return;
        },
    };

    assert(length <= message_length_max);

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
        if (roll < weight) return @fromBackingInt(@intCast(index));

        roll -= weight;
    }

    unreachable;
}

fn event_device_information(random: std.Random, message: []u8) u32 {
    assert(message.len >= message_length_max);

    var payload: [16]u8 = undefined;
    const payload_length = random.intRangeAtMost(u32, 0, 16);

    random.bytes(payload[0..payload_length]);

    const length = gfdi.build_frame(message, .device_information, payload[0..payload_length]);

    assert(length > payload_length);

    return length;
}

fn event_download_status(random: std.Random, message: []u8) u32 {
    assert(message.len >= message_length_max);

    var payload: [8]u8 = undefined;

    std.mem.writeInt(
        u16,
        payload[0..2],
        @backingInt(gfdi.MessageType.download_request),
        .little,
    );

    payload[2] = if (random.boolean()) 0 else random.int(u8);
    payload[3] = if (random.boolean()) 0 else random.int(u8);

    std.mem.writeInt(u32, payload[4..8], random.intRangeAtMost(u32, 0, 8192), .little);

    const length = gfdi.build_frame(message, .response, &payload);

    assert(length > payload.len);

    return length;
}

fn event_legacy_chunk(random: std.Random, session: *FuzzSession, message: []u8) u32 {
    assert(message.len >= message_length_max);

    var payload: [64]u8 = undefined;
    const data_length = random.intRangeAtMost(u32, 0, 32);

    payload[0] = 0;

    const offset = if (random.boolean())
        session.legacy.received
    else
        random.intRangeAtMost(u32, 0, 8192);

    std.mem.writeInt(u16, payload[1..3], random.int(u16), .little);
    std.mem.writeInt(u32, payload[3..7], offset, .little);
    random.bytes(payload[7 .. 7 + data_length]);

    const result = gfdi.build_frame(message, .file_transfer_data, payload[0 .. 7 + data_length]);

    assert(result <= message.len);

    return result;
}

fn event_protobuf_page(random: std.Random, message: []u8) u32 {
    assert(message.len >= message_length_max);

    var proto_bytes: [64]u8 = undefined;
    const proto_length = random.intRangeAtMost(u32, 0, 64);

    random.bytes(proto_bytes[0..proto_length]);

    const length = gfdi.build_protobuf_request(
        message,
        random.int(u16),
        proto_bytes[0..proto_length],
    );

    assert(length > proto_length);

    return length;
}

fn event_notification(random: std.Random, message: []u8) u32 {
    assert(message.len >= message_length_max);

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

    const smart_bytes = smart.written();
    const length = gfdi.build_protobuf_request(message, random.int(u16), smart_bytes);

    assert(length > smart_bytes.len);

    return length;
}

fn event_corrupt_crc(random: std.Random, message: []u8) u32 {
    assert(message.len >= message_length_max);

    const length = gfdi.build_frame(message, .device_information, &.{ 0x01, 0x02 });

    assert(length > 2);

    message[random.uintLessThan(u32, length)] ^= @as(u8, 1) << random.int(u3);

    return length;
}

const Lengths = struct {
    maximum: u32,
    minimum: u32,
};

fn event_random_bytes(random: std.Random, message: []u8, lengths: Lengths) u32 {
    assert(lengths.minimum <= lengths.maximum);
    assert(lengths.maximum <= message.len);

    const length = random.intRangeAtMost(u32, lengths.minimum, lengths.maximum);

    random.bytes(message[0..length]);

    return length;
}

fn event_transfer_poke(
    random: std.Random,
    session: *FuzzSession,
    transport: *FakeTransport,
) void {
    assert(session.transport == transport);

    transport.status = .{
        .closed = random.boolean(),
        .handle = random.int(u8),
        .length = random.intRangeAtMost(u32, 0, transfer_data_length),
        .overflow = random.boolean(),
        .ready = random.boolean(),
    };

    session.poll_transfer() catch |err| switch (err) {
        error.WriteFailed => {},
    };
}

fn check_invariants(session: *const FuzzSession) void {
    assert(session.protobuf.length <= session.protobuf.buffer.len);
    assert(session.legacy.received <= session.legacy.buffer.len);
    assert(session.queue.files.count <= @TypeOf(session.queue.files).capacity_max);
    assert(session.queue.position <= session.queue.files.count);

    if (session.finished) assert(session.phase == .done);
}

test "session fuzz smoke" {
    var prng = std.Random.DefaultPrng.init(7);
    var weights: [event_kind_count]u32 = @splat(0);

    weights[@backingInt(EventKind.notification)] = 3;

    for (0..64) |_| {
        try std.testing.expectEqual(EventKind.notification, pick_event(prng.random(), &weights));
    }

    weights[@backingInt(EventKind.runt)] = 3;

    var runts: u32 = 0;

    for (0..64) |_| {
        if (pick_event(prng.random(), &weights) == .runt) runts += 1;
    }

    try std.testing.expect(runts > 0);
    try std.testing.expect(runts < 64);

    const swarm = swarm_weights(prng.random());

    try std.testing.expect(std.mem.max(u32, &swarm) > 0);
    try fuzz_session(std.testing.allocator, 123, 200);
}
