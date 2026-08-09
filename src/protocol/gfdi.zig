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
    supported_file_types_req = 5031,
    synchronization = 5037,
    protobuf_request = 5043,
    protobuf_response = 5044,
    configuration = 5050,
    current_time_request = 5052,
    auth_negotiation = 5101,
    _,
};

pub const RequestType = enum(u8) {
    continuation = 0,
    new = 1,
    _,
};

pub const SystemEventType = enum(u8) {
    sync_complete = 0,
    pair_complete = 4,
    sync_ready = 8,
    time_updated = 16,
    _,
};

pub const DownloadRequest = struct {
    file_index: u16,
    data_offset: u32 = 0,
    request_type: RequestType = .new,
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
    total_size: u32,
    payload_len: u32,
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
        return entry.data_type == file_datatype_fit;
    }

    pub fn is_activity(entry: *const DirectoryEntry) bool {
        return entry.data_type == file_datatype_fit and entry.sub_type == file_subtype_activity;
    }

    pub fn is_empty(entry: *const DirectoryEntry) bool {
        return entry.file_index == 0 and entry.data_type == 0 and entry.sub_type == 0 and
            entry.file_number == 0 and entry.file_size == 0;
    }
};

pub const message_len_max: u32 = 8192;

comptime {
    assert(message_len_max <= std.math.maxInt(u16));
}

pub const garmin_epoch_offset_sec: i64 = 631065600;

pub const status_ack: u8 = 0;
pub const transfer_status_ok: u8 = 0;
pub const download_status_ok: u8 = 0;

pub const directory_entry_len: u32 = 16;
pub const file_datatype_fit: u8 = 128;
pub const file_subtype_activity: u8 = 4;

pub const host_bluetooth_name = "gfdi";
pub const host_manufacturer = "gfdi";
pub const host_device = "pc";

const host_protocol_version: u16 = 150;
const host_product_number: u16 = 0xFFFF;
const host_unit_number: u32 = 0xFFFFFFFF;
const host_software_version: u16 = 100;
const host_max_packet_size: u16 = 0xFFFF;

const crc_table = [16]u16{
    0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
    0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
};

pub fn crc16_seeded(initial: u16, data: []const u8) u16 {
    assert(data.len <= message_len_max);

    var crc: u16 = initial;
    var index: u32 = 0;

    while (index < data.len) : (index += 1) {
        const byte = data[index];
        crc = (((crc >> 4) & 0x0FFF) ^ crc_table[crc & 0x0F]) ^ crc_table[byte & 0x0F];
        crc = (((crc >> 4) & 0x0FFF) ^ crc_table[crc & 0x0F]) ^ crc_table[(byte >> 4) & 0x0F];
    }

    return crc;
}

pub fn crc16(data: []const u8) u16 {
    return crc16_seeded(0, data);
}

pub fn cobs_encoded_len_max(source_len: u32) u32 {
    return source_len + @divFloor(source_len, 0xFE) + 3;
}

pub fn cobs_encode(destination: []u8, source: []const u8) u32 {
    assert(source.len <= message_len_max);
    assert(destination.len >= cobs_encoded_len_max(@intCast(source.len)));

    var write_index: u32 = 0;
    destination[write_index] = 0x00;
    write_index += 1;

    var start: u32 = 0;
    var last_byte_was_zero = false;
    var iterations: u32 = 0;

    while (start < source.len) {
        iterations += 1;
        assert(iterations <= source.len + 1);

        var zero_index = start;

        while (zero_index < source.len and source[zero_index] != 0x00) zero_index += 1;
        last_byte_was_zero = zero_index < source.len;

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

    if (last_byte_was_zero) {
        destination[write_index] = 0x01;
        write_index += 1;
    }

    destination[write_index] = 0x00;
    write_index += 1;
    return write_index;
}

pub fn cobs_decode(destination: []u8, frame: []const u8) u32 {
    assert(frame.len <= cobs_encoded_len_max(message_len_max));

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

        if (code != 0xFF and read_index < frame.len) {
            assert(write_index < destination.len);
            destination[write_index] = 0x00;
            write_index += 1;
        }
    }

    return write_index;
}

pub fn build_frame(destination: []u8, message_type: MessageType, payload: []const u8) u32 {
    assert(payload.len + 4 <= message_len_max);
    const body_len: u32 = @intCast(4 + payload.len);
    assert(destination.len >= body_len + 2);

    const packet_size: u16 = @intCast(body_len + 2);
    std.mem.writeInt(u16, destination[0..2], packet_size, .little);
    std.mem.writeInt(u16, destination[2..4], @intFromEnum(message_type), .little);
    @memcpy(destination[4..body_len], payload);
    const crc = crc16(destination[0..body_len]);
    std.mem.writeInt(u16, destination[body_len..][0..2], crc, .little);
    return body_len + 2;
}

pub fn build_ack(destination: []u8, reference_type: MessageType) u32 {
    var payload: [3]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], @intFromEnum(reference_type), .little);
    payload[2] = status_ack;
    return build_frame(destination, .response, &payload);
}

pub fn build_time_response(destination: []u8, garmin_timestamp: i32, utc_offset_seconds: i32) u32 {
    var payload: [23]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], @intFromEnum(MessageType.current_time_request), .little);
    payload[2] = status_ack;
    std.mem.writeInt(u32, payload[3..7], 0, .little);
    std.mem.writeInt(i32, payload[7..11], garmin_timestamp, .little);
    std.mem.writeInt(i32, payload[11..15], utc_offset_seconds, .little);
    std.mem.writeInt(i32, payload[15..19], 0, .little);
    std.mem.writeInt(i32, payload[19..23], 0, .little);
    return build_frame(destination, .response, &payload);
}

pub fn build_system_event(destination: []u8, event_type: SystemEventType, value: u8) u32 {
    const payload = [_]u8{ @intFromEnum(event_type), value };

    return build_frame(destination, .system_event, &payload);
}

pub fn build_supported_file_types_request(destination: []u8) u32 {
    return build_frame(destination, .supported_file_types_req, &.{});
}

pub fn build_device_info_response(destination: []u8, protocol_flags: u8) u32 {
    var payload: [64]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], @intFromEnum(MessageType.device_information), .little);
    payload[2] = status_ack;
    std.mem.writeInt(u16, payload[3..5], host_protocol_version, .little);
    std.mem.writeInt(u16, payload[5..7], host_product_number, .little);
    std.mem.writeInt(u32, payload[7..11], host_unit_number, .little);
    std.mem.writeInt(u16, payload[11..13], host_software_version, .little);
    std.mem.writeInt(u16, payload[13..15], host_max_packet_size, .little);
    var length: u32 = 15;
    length += write_string(payload[length..], host_bluetooth_name);
    length += write_string(payload[length..], host_manufacturer);
    length += write_string(payload[length..], host_device);
    payload[length] = protocol_flags;
    length += 1;
    return build_frame(destination, .response, payload[0..length]);
}

fn write_string(buffer: []u8, value: []const u8) u32 {
    assert(value.len <= 255);
    buffer[0] = @intCast(value.len);
    @memcpy(buffer[1 .. 1 + value.len], value);
    return @intCast(1 + value.len);
}

pub fn build_download_request(destination: []u8, request: DownloadRequest) u32 {
    var payload: [13]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], request.file_index, .little);
    std.mem.writeInt(u32, payload[2..6], request.data_offset, .little);
    payload[6] = @intFromEnum(request.request_type);
    std.mem.writeInt(u16, payload[7..9], request.crc_seed, .little);
    std.mem.writeInt(u32, payload[9..13], request.data_size, .little);
    return build_frame(destination, .download_request, &payload);
}

pub fn build_file_transfer_data_status(destination: []u8, next_offset: u32) u32 {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], @intFromEnum(MessageType.file_transfer_data), .little);
    payload[2] = status_ack;
    payload[3] = transfer_status_ok;
    std.mem.writeInt(u32, payload[4..8], next_offset, .little);
    return build_frame(destination, .response, &payload);
}

pub fn parse(message: []const u8) ?Message {
    if (message.len < 6 or message.len > message_len_max) return null;

    const packet_size = std.mem.readInt(u16, message[0..2], .little);
    var raw_type = std.mem.readInt(u16, message[2..4], .little);
    var sequence: u8 = 0;

    if (raw_type & 0x8000 != 0) {
        sequence = @intCast((raw_type >> 8) & 0x7F);
        raw_type = (raw_type & 0x00FF) + 5000;
    }

    const body_len = message.len - 2;
    const crc_received = std.mem.readInt(u16, message[body_len..][0..2], .little);
    const crc_computed = crc16(message[0..body_len]);

    return .{
        .type = @enumFromInt(raw_type),
        .sequence = sequence,
        .payload = message[4..body_len],
        .packet_size = packet_size,
        .crc_ok = crc_received == crc_computed and packet_size == message.len,
    };
}

pub fn parse_protobuf_message(payload: []const u8) ?ProtobufMessage {
    if (payload.len < 14) return null;

    const payload_len = std.mem.readInt(u32, payload[10..14], .little);
    const available = payload[14..];
    const take = @min(payload_len, @as(u32, @intCast(available.len)));

    return .{
        .request_id = std.mem.readInt(u16, payload[0..2], .little),
        .data_offset = std.mem.readInt(u32, payload[2..6], .little),
        .total_size = std.mem.readInt(u32, payload[6..10], .little),
        .payload_len = payload_len,
        .payload = available[0..take],
    };
}

pub fn build_protobuf_request(destination: []u8, request_id: u16, proto_bytes: []const u8) u32 {
    const payload_len: u32 = @intCast(14 + proto_bytes.len);
    assert(payload_len + 4 <= message_len_max);

    const body_len: u32 = 4 + payload_len;
    assert(destination.len >= body_len + 2);

    const proto_len: u32 = @intCast(proto_bytes.len);
    const packet_size: u16 = @intCast(body_len + 2);
    std.mem.writeInt(u16, destination[0..2], packet_size, .little);
    std.mem.writeInt(u16, destination[2..4], @intFromEnum(MessageType.protobuf_request), .little);
    std.mem.writeInt(u16, destination[4..6], request_id, .little);
    std.mem.writeInt(u32, destination[6..10], 0, .little);
    std.mem.writeInt(u32, destination[10..14], proto_len, .little);
    std.mem.writeInt(u32, destination[14..18], proto_len, .little);
    @memcpy(destination[18 .. 18 + proto_bytes.len], proto_bytes);
    const crc = crc16(destination[0..body_len]);
    std.mem.writeInt(u16, destination[body_len..][0..2], crc, .little);
    return body_len + 2;
}

pub fn build_protobuf_ack(
    destination: []u8,
    reference_type: MessageType,
    request_id: u16,
    data_offset: u32,
) u32 {
    var payload: [11]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], @intFromEnum(reference_type), .little);
    payload[2] = status_ack;
    std.mem.writeInt(u16, payload[3..5], request_id, .little);
    std.mem.writeInt(u32, payload[5..9], data_offset, .little);

    payload[9] = 0;

    payload[10] = 0;
    return build_frame(destination, .response, &payload);
}

pub fn status_reference_type(payload: []const u8) ?MessageType {
    if (payload.len < 2) return null;
    return @enumFromInt(std.mem.readInt(u16, payload[0..2], .little));
}

pub fn parse_download_status(payload: []const u8) ?DownloadStatus {
    if (payload.len < 8) return null;
    const reference_type: MessageType = @enumFromInt(std.mem.readInt(u16, payload[0..2], .little));
    const status = payload[2];
    const download_status = payload[3];
    const file_size_max = std.mem.readInt(u32, payload[4..8], .little);

    return .{
        .reference_type = reference_type,
        .can_proceed = status == status_ack and download_status == download_status_ok,
        .file_size_max = file_size_max,
    };
}

pub fn parse_file_transfer_data(payload: []const u8) ?FileTransferData {
    if (payload.len < 7) return null;

    return .{
        .flags = payload[0],
        .crc = std.mem.readInt(u16, payload[1..3], .little),
        .offset = std.mem.readInt(u32, payload[3..7], .little),
        .data = payload[7..],
    };
}

pub fn parse_directory_entry(record: *const [directory_entry_len]u8) DirectoryEntry {
    return .{
        .file_index = std.mem.readInt(u16, record[0..2], .little),
        .data_type = record[2],
        .sub_type = record[3],
        .file_number = std.mem.readInt(u16, record[4..6], .little),
        .specific_flags = record[6],
        .file_flags = record[7],
        .file_size = std.mem.readInt(u32, record[8..12], .little),
        .timestamp = std.mem.readInt(u32, record[12..16], .little),
    };
}

pub fn device_info_protocol_version(payload: []const u8) ?u16 {
    if (payload.len < 2) return null;
    return std.mem.readInt(u16, payload[0..2], .little);
}

pub fn device_info_protocol_flags(protocol_version: u16) u8 {
    return if (@divFloor(protocol_version, 100) == 1) 1 else 0;
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
    const encoded_len = cobs_encode(&encoded, &source);
    const expected_encoded = [_]u8{ 0x00, 0x03, 0x11, 0x22, 0x02, 0x33, 0x01, 0x02, 0x44, 0x00 };

    try std.testing.expectEqualSlices(u8, &expected_encoded, encoded[0..encoded_len]);

    var decoded: [64]u8 = undefined;
    const decoded_len = cobs_decode(&decoded, encoded[1 .. encoded_len - 1]);

    try std.testing.expectEqualSlices(u8, &source, decoded[0..decoded_len]);
}

test "cobs round-trips a run longer than 254 bytes" {
    var source: [300]u8 = undefined;

    for (&source, 0..) |*byte, index| byte.* = @intCast((index % 255) + 1);

    var encoded: [400]u8 = undefined;
    const encoded_len = cobs_encode(&encoded, &source);
    var decoded: [400]u8 = undefined;
    const decoded_len = cobs_decode(&decoded, encoded[1 .. encoded_len - 1]);

    try std.testing.expectEqualSlices(u8, source[0..], decoded[0..decoded_len]);
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
    const length = build_time_response(&buffer, 0x12345678, 3600);

    const expected = [_]u8{
        0x1D, 0x00, 0x88, 0x13, 0xBC, 0x13, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x78, 0x56, 0x34, 0x12, 0x10, 0x0E, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x28, 0x28,
    };

    try std.testing.expectEqualSlices(u8, &expected, buffer[0..length]);
}

test "build_system_event sync-ready matches reference bytes" {
    var buffer: [64]u8 = undefined;
    const length = build_system_event(&buffer, .sync_ready, 0);
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

test "build_device_info_response matches reference bytes" {
    var buffer: [128]u8 = undefined;
    const length = build_device_info_response(&buffer, 1);

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

test "device_info_protocol_flags follows the 1xx rule" {
    try std.testing.expectEqual(@as(u8, 1), device_info_protocol_flags(150));
    try std.testing.expectEqual(@as(u8, 0), device_info_protocol_flags(242));
}

test "parse decodes the sequence-flagged short form" {
    var buffer: [32]u8 = undefined;
    const payload = [_]u8{ 0xAA, 0xBB };
    const length = build_frame(&buffer, @enumFromInt(0x822B), &payload);
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
    try std.testing.expectEqual(@as(u32, proto_bytes.len), protobuf.total_size);
    try std.testing.expectEqual(@as(u32, proto_bytes.len), protobuf.payload_len);
    try std.testing.expectEqualSlices(u8, &proto_bytes, protobuf.payload);
}
