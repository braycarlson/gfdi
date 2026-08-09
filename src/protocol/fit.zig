const std = @import("std");

const zfit = @import("zfit");

const assert = std.debug.assert;

const DataMessage = zfit.DataMessage;

pub const FileInfo = struct {
    activity_time: ?u32 = null,
    file_type: ?u8 = null,
    session_start: ?u32 = null,
    time_created: ?u32 = null,

    pub fn name_timestamp(info: *const FileInfo) ?u32 {
        return info.activity_time orelse info.session_start orelse info.time_created;
    }
};

const message_activity: u16 = 34;
const message_file_id: u16 = 0;
const message_session: u16 = 18;

const field_start_time: u8 = 2;
const field_time_created: u8 = 4;
const field_timestamp: u8 = 253;
const field_type: u8 = 0;

const messages_max: u32 = zfit.Decoder.message_count_max;

comptime {
    assert(messages_max > 0);
    assert(field_timestamp == zfit.Decoder.timestamp_field_number);
}

pub fn scan(data: []const u8) FileInfo {
    var info = FileInfo{};
    var reader = std.Io.Reader.fixed(data);

    var decoder = zfit.Decoder.init(&reader) catch {
        return info;
    };

    var seen: u32 = 0;

    while (seen < messages_max) : (seen += 1) {
        const message = decoder.next() catch break orelse break;

        take_message(&info, &message);
    }

    return info;
}

fn take_message(info: *FileInfo, message: *const DataMessage) void {
    var fields = message.fields();

    while (fields.next()) |field| {
        switch (message.global_message_number) {
            message_file_id => take_file_id(info, field),
            message_session => {
                if (field.field_definition_number == field_start_time) {
                    info.session_start = info.session_start orelse read_u32(field.data);
                }
            },
            message_activity => {
                if (field.field_definition_number == field_timestamp) {
                    info.activity_time = info.activity_time orelse read_u32(field.data);
                }
            },
            else => return,
        }
    }
}

fn take_file_id(info: *FileInfo, field: zfit.Field) void {
    if (field.field_definition_number == field_type and field.data.len >= 1) {
        info.file_type = info.file_type orelse field.data[0];
    }

    if (field.field_definition_number == field_time_created) {
        info.time_created = info.time_created orelse read_u32(field.data);
    }
}

fn read_u32(bytes: []const u8) ?u32 {
    if (bytes.len != 4) return null;

    return std.mem.readInt(u32, bytes[0..4], .little);
}

const testing = std.testing;

test "scan extracts file_id type and prefers activity timestamp for naming" {
    var buffer: [128]u8 = undefined;
    var length: u32 = 0;

    buffer[0] = 14;
    buffer[1] = 0x10;
    std.mem.writeInt(u16, buffer[2..4], 0, .little);

    @memcpy(buffer[8..12], ".FIT");
    std.mem.writeInt(u16, buffer[12..14], 0, .little);
    length = 14;

    const file_id_def = [_]u8{
        0x40, 0x00, 0x00, 0x00, 0x00, 0x02,
        0x00, 0x01, 0x00, 0x04, 0x04, 0x86,
    };

    @memcpy(buffer[length..][0..file_id_def.len], &file_id_def);
    length += file_id_def.len;

    buffer[length] = 0x00;
    length += 1;
    buffer[length] = 4;
    length += 1;
    std.mem.writeInt(u32, buffer[length..][0..4], 1000, .little);
    length += 4;

    const activity_def = [_]u8{ 0x41, 0x00, 0x00, 0x22, 0x00, 0x01, 0xFD, 0x04, 0x86 };
    @memcpy(buffer[length..][0..activity_def.len], &activity_def);
    length += activity_def.len;

    buffer[length] = 0x01;
    length += 1;
    std.mem.writeInt(u32, buffer[length..][0..4], 1001, .little);
    length += 4;

    std.mem.writeInt(u32, buffer[4..8], @intCast(length - 14), .little);

    const info = scan(buffer[0..length]);

    try testing.expectEqual(@as(?u8, 4), info.file_type);
    try testing.expectEqual(@as(?u32, 1000), info.time_created);
    try testing.expectEqual(@as(?u32, 1001), info.activity_time);
    try testing.expectEqual(@as(?u32, 1001), info.name_timestamp());
}

test "scan rejects non-fit input" {
    const info = scan("not a fit file at all 1234");

    try testing.expectEqual(@as(?u8, null), info.file_type);
    try testing.expectEqual(@as(?u32, null), info.name_timestamp());
}

test "name_timestamp falls back to file_id time when no activity/session" {
    const info = FileInfo{ .time_created = 500 };

    try testing.expectEqual(@as(?u32, 500), info.name_timestamp());
}
