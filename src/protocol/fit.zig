const std = @import("std");

const fit = @import("fit");

const assert = std.debug.assert;

pub const FileInformation = struct {
    activity_time: ?u32,
    file_type: ?u8,
    session_start: ?u32,
    time_created: ?u32,

    pub const unknown: FileInformation = .{
        .activity_time = null,
        .file_type = null,
        .session_start = null,
        .time_created = null,
    };

    pub fn name_timestamp(information: *const FileInformation) ?u32 {
        if (information.activity_time) |time| return time;
        if (information.session_start) |time| return time;
        return information.time_created;
    }
};

const message_activity: u16 = 34;
const message_file_id: u16 = 0;
const message_session: u16 = 18;
const field_start_time: u8 = 2;
const field_time_created: u8 = 4;
const field_timestamp: u8 = 253;
const field_type: u8 = 0;
const fit_epoch_unix_seconds: i64 = 631_065_600;
const file_type_invalid: u8 = 0xFF;
const timestamp_invalid: u32 = 0xFFFFFFFF;
const messages_max: u32 = fit.limits.message_count_max;

comptime {
    assert(messages_max > 0);
    assert(field_timestamp == fit.timestamp_field_number);
}

pub fn unix_seconds(fit_timestamp: u32) i64 {
    assert(fit_timestamp != timestamp_invalid);

    const result = fit.unix_seconds_of(fit_timestamp) orelse unreachable;

    assert(result >= fit_epoch_unix_seconds);
    assert(result - fit_epoch_unix_seconds == fit_timestamp);

    return result;
}

pub fn scan(data: []const u8) FileInformation {
    assert(data.len <= std.math.maxInt(u32));

    if (data.len > fit.limits.source_bytes_max) return .unknown;

    var information: FileInformation = .unknown;
    var parser: fit.Parser = undefined;

    parser.init(data) catch return information;

    for (0..messages_max) |_| {
        const next = parser.next() catch break;

        const message = switch (next) {
            .end => break,
            .message => |message| message,
        };

        take_message(&information, &message);
    }

    if (information.file_type) |file_type| assert(file_type != file_type_invalid);
    if (information.name_timestamp()) |time| assert(time != timestamp_invalid);

    return information;
}

fn take_message(information: *FileInformation, message: *const fit.Parser.DataMessage) void {
    assert(message.payload.len == message.definition.payload_size_bytes);

    var fields = message.fields();

    for (0..fit.limits.field_count_max) |_| {
        const field = fields.next() orelse break;

        switch (message.global_number) {
            message_file_id => take_file_id(information, &field),
            message_session => take_session(information, &field),
            message_activity => take_activity(information, &field),
            else => return,
        }
    }
}

fn take_file_id(information: *FileInformation, field: *const fit.Parser.Field) void {
    assert(field.bytes.len <= fit.limits.field_bytes_max);

    if (field.number == field_type) {
        if (field.bytes.len >= 1) {
            if (field.bytes[0] != file_type_invalid) {
                if (information.file_type == null) information.file_type = field.bytes[0];
            }
        }
    }

    if (field.number == field_time_created) {
        if (information.time_created == null) information.time_created = read_u32(field);
    }

    if (information.file_type) |file_type| assert(file_type != file_type_invalid);
}

fn take_session(information: *FileInformation, field: *const fit.Parser.Field) void {
    assert(field.bytes.len <= fit.limits.field_bytes_max);

    if (field.number != field_start_time) return;
    if (information.session_start == null) information.session_start = read_u32(field);

    if (information.session_start) |time| assert(time != timestamp_invalid);
}

fn take_activity(information: *FileInformation, field: *const fit.Parser.Field) void {
    assert(field.bytes.len <= fit.limits.field_bytes_max);

    if (field.number != field_timestamp) return;
    if (information.activity_time == null) information.activity_time = read_u32(field);

    if (information.activity_time) |time| assert(time != timestamp_invalid);
}

fn read_u32(field: *const fit.Parser.Field) ?u32 {
    assert(field.bytes.len <= fit.limits.field_bytes_max);

    if (field.bytes.len != 4) return null;

    const value = std.mem.readInt(u32, field.bytes[0..4], field.architecture);
    if (value == timestamp_invalid) return null;
    return value;
}

const testing = std.testing;

test scan {
    var buffer: [128]u8 = undefined;

    buffer[0] = 14;
    buffer[1] = 0x10;

    std.mem.writeInt(u16, buffer[2..4], 0, .little);

    @memcpy(buffer[8..12], ".FIT");
    std.mem.writeInt(u16, buffer[12..14], 0, .little);

    var length: u32 = 14;

    const file_id_definition = [_]u8{
        0x40,
        0x00,
        0x00,
        0x00,
        0x00,
        0x02,
        0x00,
        0x01,
        0x00,
        0x04,
        0x04,
        0x86,
    };

    @memcpy(buffer[length..][0..file_id_definition.len], &file_id_definition);
    length += file_id_definition.len;

    buffer[length] = 0x00;
    length += 1;
    buffer[length] = 4;
    length += 1;

    std.mem.writeInt(u32, buffer[length..][0..4], 1000, .little);
    length += 4;

    const activity_definition = [_]u8{ 0x41, 0x00, 0x00, 0x22, 0x00, 0x01, 0xFD, 0x04, 0x86 };

    @memcpy(buffer[length..][0..activity_definition.len], &activity_definition);
    length += activity_definition.len;

    buffer[length] = 0x01;
    length += 1;

    std.mem.writeInt(u32, buffer[length..][0..4], 1001, .little);
    length += 4;

    std.mem.writeInt(u32, buffer[4..8], @intCast(length - 14), .little);

    const information = scan(buffer[0..length]);

    try testing.expectEqual(@as(?u8, 4), information.file_type);
    try testing.expectEqual(@as(?u32, 1000), information.time_created);
    try testing.expectEqual(@as(?u32, 1001), information.activity_time);
    try testing.expectEqual(@as(?u32, 1001), information.name_timestamp());
}

test "scan reads a big-endian message by its architecture" {
    var buffer: [64]u8 = undefined;

    buffer[0] = 14;
    buffer[1] = 0x10;

    std.mem.writeInt(u16, buffer[2..4], 0, .little);

    @memcpy(buffer[8..12], ".FIT");
    std.mem.writeInt(u16, buffer[12..14], 0, .little);

    var length: u32 = 14;

    const file_id_definition = [_]u8{
        0x40,
        0x00,
        0x01,
        0x00,
        0x00,
        0x02,
        0x00,
        0x01,
        0x00,
        0x04,
        0x04,
        0x86,
    };

    @memcpy(buffer[length..][0..file_id_definition.len], &file_id_definition);
    length += file_id_definition.len;

    buffer[length] = 0x00;
    length += 1;
    buffer[length] = 4;
    length += 1;

    std.mem.writeInt(u32, buffer[length..][0..4], 1000, .big);
    length += 4;

    std.mem.writeInt(u32, buffer[4..8], @intCast(length - 14), .little);

    const information = scan(buffer[0..length]);

    try testing.expectEqual(@as(?u8, 4), information.file_type);
    try testing.expectEqual(@as(?u32, 1000), information.time_created);
    try testing.expectEqual(@as(?u32, 1000), information.name_timestamp());
}

test "scan rejects input that is not a FIT file" {
    const information = scan("not a fit file at all 1234");

    try testing.expectEqual(@as(?u8, null), information.file_type);
    try testing.expectEqual(@as(?u32, null), information.name_timestamp());
}

test "name_timestamp falls back to the file_id creation time" {
    var information: FileInformation = .unknown;

    information.time_created = 500;

    try testing.expectEqual(@as(?u32, 500), information.name_timestamp());

    information.session_start = 600;

    try testing.expectEqual(@as(?u32, 600), information.name_timestamp());
}

test unix_seconds {
    try testing.expectEqual(fit_epoch_unix_seconds, unix_seconds(0));
    try testing.expectEqual(fit_epoch_unix_seconds + 1_000_000_000, unix_seconds(1_000_000_000));
}
