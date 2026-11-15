const std = @import("std");

const assert = std.debug.assert;

pub const MessageType = enum(u16) {
    response = 5000,
    download_request = 5002,
    upload_request = 5003,
    file_transfer_data = 5004,
    create_file = 5005,
    filter = 5007,
    set_file_flag = 5008,
    fit_definition = 5011,
    fit_data = 5012,
    device_information = 5024,
    device_settings = 5026,
    system_event = 5030,
    supported_file_types_request = 5031,
    synchronization = 5037,
    protobuf_request = 5043,
    protobuf_response = 5044,
    configuration = 5050,
    current_time_request = 5052,
    authentication_negotiation = 5101,
    _,
};

pub const RequestType = enum(u8) {
    continuation = 0,
    new = 1,
    _,
};

pub const SystemEventType = enum(u8) {
    synchronization_complete = 0,
    pair_complete = 4,
    synchronization_ready = 8,
    time_updated = 16,
    _,
};

pub const CurrentTime = struct {
    garmin_timestamp: i32,
    utc_offset_seconds: i32,
};

pub const DownloadRequest = struct {
    file_index: u16,
    data_offset: u32 = 0,
    type: RequestType = .new,
    crc_seed: u16 = 0,
    data_size: u32 = 0,
};

pub const Message = struct {
    type: MessageType,
    sequence: u8,
    payload: []const u8,
    packet_size: u16,
    crc_ok: bool,
};

pub const ProtobufMessage = struct {
    request_id: u16,
    data_offset: u32,
    size_total: u32,
    payload_length: u32,
    payload: []const u8,
};

pub const DownloadStatus = struct {
    reference_type: MessageType,
    can_proceed: bool,
    file_size_max: u32,
};

pub const FileTransferData = struct {
    flags: u8,
    crc: u16,
    offset: u32,
    data: []const u8,
};

pub const DirectoryEntry = struct {
    file_index: u16,
    data_type: u8,
    sub_type: u8,
    file_number: u16,
    specific_flags: u8,
    file_flags: u8,
    file_size: u32,
    timestamp: u32,

    pub fn is_fit(entry: *const DirectoryEntry) bool {
        const result = entry.data_type == file_datatype_fit;

        if (result) assert(entry.data_type != 0);
        if (!result) assert(entry.data_type != file_datatype_fit);

        return result;
    }

    pub fn is_activity(entry: *const DirectoryEntry) bool {
        const result = entry.is_fit() and entry.sub_type == file_subtype_activity;

        if (result) assert(entry.is_fit());
        if (result) assert(entry.sub_type == file_subtype_activity);

        return result;
    }

    pub fn is_empty(entry: *const DirectoryEntry) bool {
        const identity_empty = entry.file_index == 0 and entry.file_number == 0;
        const kind_empty = entry.data_type == 0 and entry.sub_type == 0;
        const result = identity_empty and kind_empty and entry.file_size == 0;

        if (result) assert(!entry.is_fit());
        if (result) assert(entry.file_size == 0);

        return result;
    }
};

pub const message_length_max: u32 = 8192;

comptime {
    assert(message_length_max <= std.math.maxInt(u16));
}

pub const garmin_epoch_offset_seconds: i64 = 631065600;
pub const status_ack: u8 = 0;
pub const transfer_status_ok: u8 = 0;
pub const download_status_ok: u8 = 0;
pub const directory_entry_length: u32 = 16;
pub const file_datatype_fit: u8 = 128;
pub const file_subtype_activity: u8 = 4;
pub const host_bluetooth_name = "gfdi";
pub const host_manufacturer = "gfdi";
pub const host_device = "pc";
const host_protocol_version: u16 = 150;
const host_product_number: u16 = 0xFFFF;
const host_unit_number: u32 = 0xFFFFFFFF;
const host_software_version: u16 = 100;
const host_packet_size_max: u16 = 0xFFFF;

const crc_table = [16]u16{
    0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
    0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
};

pub fn crc16_seeded(initial: u16, data: []const u8) u16 {
    assert(data.len <= message_length_max);

    var crc = initial;

    for (data) |byte| crc = crc16_step(crc, byte);

    return crc;
}

fn crc16_step(crc: u16, byte: u8) u16 {
    comptime assert(crc_table.len == 16);
    comptime assert(crc_table[0] == 0);

    const crc_low: u4 = @truncate(crc);
    const byte_low: u4 = @truncate(byte);
    const byte_high: u4 = @truncate(byte >> 4);
    const crc_mixed = ((crc >> 4) & 0x0FFF) ^ crc_table[crc_low] ^ crc_table[byte_low];
    const crc_mixed_low: u4 = @truncate(crc_mixed);

    return ((crc_mixed >> 4) & 0x0FFF) ^ crc_table[crc_mixed_low] ^ crc_table[byte_high];
}

pub fn crc16(data: []const u8) u16 {
    assert(data.len <= message_length_max);

    return crc16_seeded(0, data);
}

pub fn cobs_encoded_length_max(source_length: u32) u32 {
    assert(source_length <= message_length_max);

    const result = source_length + @divFloor(source_length, 0xFE) + 3;

    assert(result > source_length);

    return result;
}

pub fn cobs_encode(destination: []u8, source: []const u8) u32 {
    assert(source.len <= message_length_max);
    assert(destination.len >= cobs_encoded_length_max(@intCast(source.len)));

    var write_index: u32 = 0;
    destination[write_index] = 0x00;
    write_index += 1;

    var start: u32 = 0;
    var byte_last_was_zero = false;
    var iterations: u32 = 0;

    while (start < source.len) {
        iterations += 1;

        assert(iterations <= source.len + 1);

        const zero_index: u32 = @intCast(
            std.mem.findScalarPos(u8, source, start, 0x00) orelse source.len,
        );

        byte_last_was_zero = zero_index < source.len;

        var run = zero_index - start;

        while (run >= 0xFE) {
            destination[write_index] = 0xFF;
            write_index += 1;

            @memcpy(destination[write_index .. write_index + 0xFE], source[start .. start + 0xFE]);
            write_index += 0xFE;
            run -= 0xFE;
            start += 0xFE;
        }

        destination[write_index] = @intCast(run + 1);
        write_index += 1;

        @memcpy(destination[write_index .. write_index + run], source[start .. start + run]);
        write_index += run;
        start = zero_index + 1;
    }

    if (byte_last_was_zero) {
        destination[write_index] = 0x01;
        write_index += 1;
    }

    destination[write_index] = 0x00;
    write_index += 1;

    return write_index;
}

pub fn cobs_decode(destination: []u8, frame: []const u8) u32 {
    assert(destination.len >= message_length_max or destination.len + 1 >= frame.len);
    assert(frame.len <= cobs_encoded_length_max(message_length_max));

    var read_index: u32 = 0;
    var write_index: u32 = 0;
    var iterations: u32 = 0;

    while (read_index < frame.len) {
        iterations += 1;

        assert(iterations <= frame.len + 1);

        const code = frame[read_index];
        read_index += 1;

        if (code == 0x00) break;

        var run: u32 = code - 1;

        if (read_index + run > frame.len) run = @intCast(frame.len - read_index);
        assert(write_index + run <= destination.len);

        @memcpy(
            destination[write_index .. write_index + run],
            frame[read_index .. read_index + run],
        );

        write_index += run;
        read_index += run;

        if (code != 0xFF) {
            if (read_index < frame.len) {
                assert(write_index < destination.len);
                destination[write_index] = 0x00;
                write_index += 1;
            }
        }
    }

    return write_index;
}

pub fn build_frame(destination: []u8, message_type: MessageType, payload: []const u8) u32 {
    assert(payload.len + 4 <= message_length_max);
    const body_length: u32 = @intCast(4 + payload.len);

    assert(destination.len >= body_length + 2);

    const packet_size: u16 = @intCast(body_length + 2);

    std.mem.writeInt(u16, destination[0..2], packet_size, .little);
    std.mem.writeInt(u16, destination[2..4], @backingInt(message_type), .little);
    @memcpy(destination[4..body_length], payload);
    const crc = crc16(destination[0..body_length]);

    std.mem.writeInt(u16, destination[body_length..][0..2], crc, .little);

    const result = body_length + 2;

    assert(result <= destination.len);

    return result;
}

pub fn build_ack(destination: []u8, reference_type: MessageType) u32 {
    assert(destination.len >= 9);

    var payload: [3]u8 = undefined;

    std.mem.writeInt(u16, payload[0..2], @backingInt(reference_type), .little);
    payload[2] = status_ack;

    return build_frame(destination, .response, &payload);
}

pub fn build_time_response(destination: []u8, time: CurrentTime) u32 {
    assert(destination.len >= 29);

    var payload: [23]u8 = undefined;

    std.mem.writeInt(u16, payload[0..2], @backingInt(MessageType.current_time_request), .little);
    payload[2] = status_ack;

    std.mem.writeInt(u32, payload[3..7], 0, .little);
    std.mem.writeInt(i32, payload[7..11], time.garmin_timestamp, .little);
    std.mem.writeInt(i32, payload[11..15], time.utc_offset_seconds, .little);
    std.mem.writeInt(i32, payload[15..19], 0, .little);
    std.mem.writeInt(i32, payload[19..23], 0, .little);

    return build_frame(destination, .response, &payload);
}

pub fn build_system_event(destination: []u8, event_type: SystemEventType) u32 {
    assert(destination.len >= 8);
    assert(system_event_known(event_type));

    const payload = [_]u8{ @backingInt(event_type), 0 };

    return build_frame(destination, .system_event, &payload);
}

fn system_event_known(event_type: SystemEventType) bool {
    return switch (event_type) {
        .synchronization_complete, .pair_complete, .synchronization_ready, .time_updated => true,
        _ => false,
    };
}

pub fn build_supported_file_types_request(destination: []u8) u32 {
    assert(destination.len >= 6);

    return build_frame(destination, .supported_file_types_request, &.{});
}

pub fn build_device_information_response(destination: []u8, protocol_flags: u8) u32 {
    assert(destination.len >= 70);
    assert(protocol_flags <= 1);

    var payload: [64]u8 = undefined;

    std.mem.writeInt(u16, payload[0..2], @backingInt(MessageType.device_information), .little);
    payload[2] = status_ack;

    std.mem.writeInt(u16, payload[3..5], host_protocol_version, .little);
    std.mem.writeInt(u16, payload[5..7], host_product_number, .little);
    std.mem.writeInt(u32, payload[7..11], host_unit_number, .little);
    std.mem.writeInt(u16, payload[11..13], host_software_version, .little);
    std.mem.writeInt(u16, payload[13..15], host_packet_size_max, .little);
    var length: u32 = 15;
    length += write_string(payload[length..], host_bluetooth_name);
    length += write_string(payload[length..], host_manufacturer);
    length += write_string(payload[length..], host_device);
    payload[length] = protocol_flags;
    length += 1;

    return build_frame(destination, .response, payload[0..length]);
}

fn write_string(buffer: []u8, value: []const u8) u32 {
    assert(buffer.len > value.len);
    assert(value.len <= 255);
    buffer[0] = @intCast(value.len);

    @memcpy(buffer[1 .. 1 + value.len], value);

    const result: u32 = @intCast(1 + value.len);

    assert(result <= buffer.len);

    return result;
}

pub fn build_download_request(destination: []u8, request: DownloadRequest) u32 {
    assert(destination.len >= 19);
    assert(request.type == .new or request.type == .continuation);

    var payload: [13]u8 = undefined;

    std.mem.writeInt(u16, payload[0..2], request.file_index, .little);
    std.mem.writeInt(u32, payload[2..6], request.data_offset, .little);
    payload[6] = @backingInt(request.type);

    std.mem.writeInt(u16, payload[7..9], request.crc_seed, .little);
    std.mem.writeInt(u32, payload[9..13], request.data_size, .little);

    return build_frame(destination, .download_request, &payload);
}

pub fn build_file_transfer_data_status(destination: []u8, offset_next: u32) u32 {
    assert(destination.len >= 14);

    var payload: [8]u8 = undefined;

    std.mem.writeInt(u16, payload[0..2], @backingInt(MessageType.file_transfer_data), .little);
    payload[2] = status_ack;
    payload[3] = transfer_status_ok;

    std.mem.writeInt(u32, payload[4..8], offset_next, .little);

    return build_frame(destination, .response, &payload);
}

pub fn parse(message: []const u8) ?Message {
    if (message.len < 6) return null;
    if (message.len > message_length_max) return null;

    const packet_size = std.mem.readInt(u16, message[0..2], .little);
    var raw_type = std.mem.readInt(u16, message[2..4], .little);
    var sequence: u8 = 0;

    if (raw_type & 0x8000 != 0) {
        sequence = @intCast((raw_type >> 8) & 0x7F);
        raw_type = (raw_type & 0x00FF) + 5000;
    }

    const body_length = message.len - 2;
    const crc_received = std.mem.readInt(u16, message[body_length..][0..2], .little);
    const crc_computed = crc16(message[0..body_length]);

    const result = Message{
        .type = @fromBackingInt(raw_type),
        .sequence = sequence,
        .payload = message[4..body_length],
        .packet_size = packet_size,
        .crc_ok = crc_received == crc_computed and packet_size == message.len,
    };

    assert(result.payload.len + 6 == message.len);
    assert(result.sequence <= 0x7F);

    return result;
}

pub fn parse_protobuf_message(payload: []const u8) ?ProtobufMessage {
    if (payload.len < 14) return null;

    const payload_length = std.mem.readInt(u32, payload[10..14], .little);
    const available = payload[14..];
    const take = @min(payload_length, @as(u32, @intCast(available.len)));

    const result = ProtobufMessage{
        .request_id = std.mem.readInt(u16, payload[0..2], .little),
        .data_offset = std.mem.readInt(u32, payload[2..6], .little),
        .size_total = std.mem.readInt(u32, payload[6..10], .little),
        .payload_length = payload_length,
        .payload = available[0..take],
    };

    assert(result.payload.len <= result.payload_length);
    assert(result.payload.len + 14 <= payload.len);

    return result;
}

pub fn build_protobuf_request(destination: []u8, request_id: u16, proto_bytes: []const u8) u32 {
    assert(proto_bytes.len <= message_length_max - 20);

    const payload_length: u32 = @intCast(14 + proto_bytes.len);

    assert(payload_length + 4 <= message_length_max);

    const body_length: u32 = 4 + payload_length;

    assert(destination.len >= body_length + 2);

    const proto_length: u32 = @intCast(proto_bytes.len);
    const packet_size: u16 = @intCast(body_length + 2);

    std.mem.writeInt(u16, destination[0..2], packet_size, .little);
    std.mem.writeInt(u16, destination[2..4], @backingInt(MessageType.protobuf_request), .little);
    std.mem.writeInt(u16, destination[4..6], request_id, .little);
    std.mem.writeInt(u32, destination[6..10], 0, .little);
    std.mem.writeInt(u32, destination[10..14], proto_length, .little);
    std.mem.writeInt(u32, destination[14..18], proto_length, .little);
    @memcpy(destination[18 .. 18 + proto_bytes.len], proto_bytes);
    const crc = crc16(destination[0..body_length]);

    std.mem.writeInt(u16, destination[body_length..][0..2], crc, .little);

    const result = body_length + 2;

    assert(result <= destination.len);

    return result;
}

pub fn build_protobuf_ack(
    destination: []u8,
    reference_type: MessageType,
    request_id: u16,
    data_offset: u32,
) u32 {
    assert(destination.len >= 17);

    var payload: [11]u8 = undefined;

    std.mem.writeInt(u16, payload[0..2], @backingInt(reference_type), .little);
    payload[2] = status_ack;

    std.mem.writeInt(u16, payload[3..5], request_id, .little);
    std.mem.writeInt(u32, payload[5..9], data_offset, .little);

    payload[9] = 0;

    payload[10] = 0;

    return build_frame(destination, .response, &payload);
}

pub fn status_reference_type(payload: []const u8) ?MessageType {
    if (payload.len < 2) return null;

    const raw = std.mem.readInt(u16, payload[0..2], .little);

    return @fromBackingInt(raw);
}

pub fn parse_download_status(payload: []const u8) ?DownloadStatus {
    if (payload.len < 8) return null;

    const raw_type = std.mem.readInt(u16, payload[0..2], .little);
    const reference_type: MessageType = @fromBackingInt(raw_type);
    const status = payload[2];
    const download_status = payload[3];
    const file_size_max = std.mem.readInt(u32, payload[4..8], .little);

    const result = DownloadStatus{
        .reference_type = reference_type,
        .can_proceed = status == status_ack and download_status == download_status_ok,
        .file_size_max = file_size_max,
    };

    if (result.can_proceed) assert(status == status_ack);
    if (result.can_proceed) assert(download_status == download_status_ok);

    return result;
}

pub fn parse_file_transfer_data(payload: []const u8) ?FileTransferData {
    if (payload.len < 7) return null;

    const result = FileTransferData{
        .flags = payload[0],
        .crc = std.mem.readInt(u16, payload[1..3], .little),
        .offset = std.mem.readInt(u32, payload[3..7], .little),
        .data = payload[7..],
    };

    assert(result.data.len + 7 == payload.len);
    assert(result.flags == payload[0]);

    return result;
}

pub fn parse_directory_entry(record: *const [directory_entry_length]u8) DirectoryEntry {
    comptime assert(directory_entry_length == 16);

    const result = DirectoryEntry{
        .file_index = std.mem.readInt(u16, record[0..2], .little),
        .data_type = record[2],
        .sub_type = record[3],
        .file_number = std.mem.readInt(u16, record[4..6], .little),
        .specific_flags = record[6],
        .file_flags = record[7],
        .file_size = std.mem.readInt(u32, record[8..12], .little),
        .timestamp = std.mem.readInt(u32, record[12..16], .little),
    };

    assert(result.data_type == record[2]);

    return result;
}

pub fn device_information_protocol_version(payload: []const u8) ?u16 {
    if (payload.len < 2) return null;

    const result = std.mem.readInt(u16, payload[0..2], .little);

    assert(result == @as(u16, payload[0]) | (@as(u16, payload[1]) << 8));

    return result;
}

pub fn device_information_protocol_flags(protocol_version: u16) u8 {
    const result: u8 = if (@divFloor(protocol_version, 100) == 1) 1 else 0;

    if (result == 1) assert(protocol_version >= 100);
    if (result == 1) assert(protocol_version < 200);

    return result;
}

test "crc16 matches reference vectors" {
    try std.testing.expectEqual(@as(u16, 0xBB3D), crc16("123456789"));
    try std.testing.expectEqual(@as(u16, 0x0000), crc16(""));

    try std.testing.expectEqual(
        @as(u16, 0xD035),
        crc16_seeded(0x1234, &.{ 0xDE, 0xAD, 0xBE, 0xEF }),
    );
}

test "build_ack matches reference bytes (ref 5024)" {
    var buffer: [64]u8 = undefined;
    const length = build_ack(&buffer, .device_information);
    const expected = [_]u8{ 0x09, 0x00, 0x88, 0x13, 0xA0, 0x13, 0x00, 0x70, 0x89 };

    try std.testing.expectEqualSlices(u8, &expected, buffer[0..length]);
}

test "cobs round-trips bytes with embedded zeros" {
    const source = [_]u8{ 0x11, 0x22, 0x00, 0x33, 0x00, 0x00, 0x44 };
    var encoded: [64]u8 = undefined;
    const encoded_length = cobs_encode(&encoded, &source);
    const expected_encoded = [_]u8{ 0x00, 0x03, 0x11, 0x22, 0x02, 0x33, 0x01, 0x02, 0x44, 0x00 };

    try std.testing.expectEqualSlices(u8, &expected_encoded, encoded[0..encoded_length]);

    var decoded: [64]u8 = undefined;
    const decoded_length = cobs_decode(&decoded, encoded[1 .. encoded_length - 1]);

    try std.testing.expectEqualSlices(u8, &source, decoded[0..decoded_length]);
}

test "cobs round-trips a run longer than 254 bytes" {
    var source: [300]u8 = undefined;

    for (&source, 0..) |*byte, index| byte.* = @intCast((index % 255) + 1);

    var encoded: [400]u8 = undefined;
    const encoded_length = cobs_encode(&encoded, &source);
    var decoded: [400]u8 = undefined;
    const decoded_length = cobs_decode(&decoded, encoded[1 .. encoded_length - 1]);

    try std.testing.expectEqualSlices(u8, source[0..], decoded[0..decoded_length]);
}

test "build_frame round-trips through parse" {
    var buffer: [64]u8 = undefined;
    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const length = build_frame(&buffer, .download_request, &payload);
    const message = parse(buffer[0..length]).?;

    try std.testing.expectEqual(MessageType.download_request, message.type);
    try std.testing.expect(message.crc_ok);
    try std.testing.expectEqualSlices(u8, &payload, message.payload);
}

test "parse rejects a corrupted CRC" {
    var buffer: [64]u8 = undefined;
    const length = build_ack(&buffer, .device_information);

    buffer[length - 1] ^= 0xFF;
    const message = parse(buffer[0..length]).?;

    try std.testing.expect(!message.crc_ok);
}

test "build_time_response matches reference bytes" {
    var buffer: [64]u8 = undefined;

    const length = build_time_response(&buffer, .{
        .garmin_timestamp = 0x12345678,
        .utc_offset_seconds = 3600,
    });

    const expected = [_]u8{
        0x1D, 0x00, 0x88, 0x13, 0xBC, 0x13, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x78, 0x56, 0x34, 0x12, 0x10, 0x0E, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28, 0x28,
    };

    try std.testing.expectEqualSlices(u8, &expected, buffer[0..length]);
}

test "build_system_event sync-ready matches reference bytes" {
    var buffer: [64]u8 = undefined;
    const length = build_system_event(&buffer, .synchronization_ready);
    const expected = [_]u8{ 0x08, 0x00, 0xA6, 0x13, 0x08, 0x00, 0xD5, 0xC5 };

    try std.testing.expectEqualSlices(u8, &expected, buffer[0..length]);
}

test "build_supported_file_types_request matches reference bytes" {
    var buffer: [64]u8 = undefined;
    const length = build_supported_file_types_request(&buffer);
    const expected = [_]u8{ 0x06, 0x00, 0xA7, 0x13, 0x3B, 0x75 };

    try std.testing.expectEqualSlices(u8, &expected, buffer[0..length]);
}

test "build_download_request (directory) matches reference bytes" {
    var buffer: [64]u8 = undefined;
    const length = build_download_request(&buffer, .{ .file_index = 0 });

    const expected = [_]u8{
        0x13, 0x00, 0x8A, 0x13, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF5, 0x41,
    };

    try std.testing.expectEqualSlices(u8, &expected, buffer[0..length]);
}

test "build_file_transfer_data_status matches reference bytes" {
    var buffer: [64]u8 = undefined;
    const length = build_file_transfer_data_status(&buffer, 0x100);

    const expected = [_]u8{
        0x0E, 0x00, 0x88, 0x13, 0x8C, 0x13, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x00, 0xCD, 0xD1,
    };

    try std.testing.expectEqualSlices(u8, &expected, buffer[0..length]);
}

test "build_device_information_response matches reference bytes" {
    var buffer: [128]u8 = undefined;
    const length = build_device_information_response(&buffer, 1);

    const expected = [_]u8{
        0x23, 0x00, 0x88, 0x13, 0xA0, 0x13, 0x00, 0x96, 0x00, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x64, 0x00, 0xFF, 0xFF, 0x04,
        0x67, 0x66, 0x64, 0x69, 0x04, 0x67, 0x66, 0x64, 0x69, 0x02,
        0x70, 0x63, 0x01, 0xBF, 0xAF,
    };

    try std.testing.expectEqualSlices(u8, &expected, buffer[0..length]);
}

test "parse_download_status reads an incoming download status" {
    const message = [_]u8{
        0x0E, 0x00, 0x88, 0x13, 0x8A, 0x13, 0x00,
        0x00, 0x00, 0x40, 0x00, 0x00, 0x1D, 0xEF,
    };

    const parsed = parse(&message).?;

    try std.testing.expect(parsed.crc_ok);
    try std.testing.expectEqual(MessageType.response, parsed.type);
    const status = parse_download_status(parsed.payload).?;

    try std.testing.expectEqual(MessageType.download_request, status.reference_type);
    try std.testing.expect(status.can_proceed);
    try std.testing.expectEqual(@as(u32, 0x4000), status.file_size_max);
}

test "parse_file_transfer_data reads an incoming chunk" {
    const message = [_]u8{
        0x12, 0x00, 0x8C, 0x13, 0x00, 0xCD, 0xAB, 0x00, 0x00,
        0x00, 0x00, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x58, 0x4E,
    };

    const parsed = parse(&message).?;

    try std.testing.expect(parsed.crc_ok);
    try std.testing.expectEqual(MessageType.file_transfer_data, parsed.type);
    const chunk = parse_file_transfer_data(parsed.payload).?;

    try std.testing.expectEqual(@as(u8, 0), chunk.flags);
    try std.testing.expectEqual(@as(u16, 0xABCD), chunk.crc);
    try std.testing.expectEqual(@as(u32, 0), chunk.offset);
    try std.testing.expectEqualSlices(u8, "hello", chunk.data);
}

test "parse_directory_entry reads an activity record" {
    const record = [_]u8{
        0x05, 0x00, 0x80, 0x04, 0x07, 0x00, 0x00, 0x00,
        0x34, 0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };

    const entry = parse_directory_entry(&record);

    try std.testing.expectEqual(@as(u16, 5), entry.file_index);
    try std.testing.expectEqual(@as(u8, 128), entry.data_type);
    try std.testing.expectEqual(@as(u8, 4), entry.sub_type);
    try std.testing.expectEqual(@as(u32, 0x1234), entry.file_size);
    try std.testing.expect(entry.is_fit());
    try std.testing.expect(entry.is_activity());
    try std.testing.expect(!entry.is_empty());
}

test "device_information_protocol_flags follows the 1xx rule" {
    try std.testing.expectEqual(@as(u8, 1), device_information_protocol_flags(150));
    try std.testing.expectEqual(@as(u8, 0), device_information_protocol_flags(242));
}

test "parse decodes the sequence-flagged short form" {
    var buffer: [32]u8 = undefined;
    const payload = [_]u8{ 0xAA, 0xBB };
    const length = build_frame(&buffer, @fromBackingInt(0x822B), &payload);
    const message = parse(buffer[0..length]).?;

    try std.testing.expect(message.crc_ok);
    try std.testing.expectEqual(MessageType.protobuf_request, message.type);
    try std.testing.expectEqual(@as(u8, 2), message.sequence);
}

test "build_protobuf_ack references the incoming type" {
    var buffer: [32]u8 = undefined;
    const length = build_protobuf_ack(&buffer, .protobuf_response, 0x0102, 0x03040506);
    const message = parse(buffer[0..length]).?;

    try std.testing.expect(message.crc_ok);
    try std.testing.expectEqual(MessageType.response, message.type);

    try std.testing.expectEqual(
        MessageType.protobuf_response,
        status_reference_type(message.payload).?,
    );
}

test "protobuf request round-trips through parse_protobuf_message" {
    var buffer: [64]u8 = undefined;
    const proto_bytes = [_]u8{ 0xDA, 0x02, 0x02, 0xAA, 0xBB };
    const length = build_protobuf_request(&buffer, 0x2A, &proto_bytes);
    const message = parse(buffer[0..length]).?;

    try std.testing.expect(message.crc_ok);
    try std.testing.expectEqual(MessageType.protobuf_request, message.type);
    const protobuf = parse_protobuf_message(message.payload).?;

    try std.testing.expectEqual(@as(u16, 0x2A), protobuf.request_id);
    try std.testing.expectEqual(@as(u32, 0), protobuf.data_offset);
    try std.testing.expectEqual(@as(u32, proto_bytes.len), protobuf.size_total);
    try std.testing.expectEqual(@as(u32, proto_bytes.len), protobuf.payload_length);
    try std.testing.expectEqualSlices(u8, &proto_bytes, protobuf.payload);
}
