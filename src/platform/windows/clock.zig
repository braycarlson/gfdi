const std = @import("std");

const protocol = @import("../../protocol.zig");
const transport = @import("../../transport.zig");

const assert = std.debug.assert;

const windows = std.os.windows;

const SYSTEMTIME = extern struct {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    millisecond: u16,
};

const TIME_ZONE_INFORMATION = extern struct {
    bias: i32,
    standard_name: [32]u16,
    standard_date: SYSTEMTIME,
    standard_bias: i32,
    daylight_name: [32]u16,
    daylight_date: SYSTEMTIME,
    daylight_bias: i32,
};

pub const Clock = struct {
    pub fn now_garmin(clock: Clock) i32 {
        _ = clock;

        var file_time: windows.FILETIME = undefined;

        GetSystemTimeAsFileTime(&file_time);

        const ticks = (@as(u64, file_time.dwHighDateTime) << 32) | file_time.dwLowDateTime;
        const seconds_since_1601: i64 = @intCast(@divFloor(ticks, ticks_per_second));
        const seconds_since_1970 = seconds_since_1601 - seconds_1601_to_1970;

        const result: i32 = @intCast(
            seconds_since_1970 - protocol.gfdi.garmin_epoch_offset_seconds,
        );

        assert(result + protocol.gfdi.garmin_epoch_offset_seconds == seconds_since_1970);

        return result;
    }

    pub fn utc_offset_seconds(clock: Clock) i32 {
        _ = clock;

        var information: TIME_ZONE_INFORMATION = undefined;

        const id = GetTimeZoneInformation(&information);
        if (id == time_zone_id_invalid) return 0;

        var bias_active: i32 = information.bias;

        if (id == time_zone_id_daylight) {
            bias_active += information.daylight_bias;
        } else if (id == time_zone_id_standard) {
            bias_active += information.standard_bias;
        } else {}

        const offset_seconds = -bias_active * 60;

        assert(offset_seconds >= utc_offset_min);
        assert(offset_seconds <= utc_offset_max);

        return offset_seconds;
    }

    pub fn format_local_time(clock: Clock, buffer: []u8, unix_seconds: i64) ?[]const u8 {
        assert(buffer.len >= transport.naming.stamp_bytes);
        assert(unix_seconds >= 0);

        _ = clock;

        const ticks: u64 = (@as(u64, @intCast(unix_seconds)) + seconds_1601_to_1970) *
            ticks_per_second;

        const file_time = windows.FILETIME{
            .dwHighDateTime = @truncate(ticks >> 32),
            .dwLowDateTime = @truncate(ticks),
        };

        var utc: SYSTEMTIME = undefined;
        var local: SYSTEMTIME = undefined;

        if (FileTimeToSystemTime(&file_time, &utc) == 0) return null;
        if (SystemTimeToTzSpecificLocalTime(null, &utc, &local) == 0) return null;

        const result = std.mem.print(buffer, "{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}", .{
            local.year,
            local.month,
            local.day,
            local.hour,
            local.minute,
            local.second,
        }) catch return null;

        assert(result.len == transport.naming.stamp_bytes);

        return result;
    }
};

const seconds_1601_to_1970: u64 = 11_644_473_600;
const ticks_per_second: u64 = 10_000_000;
const time_zone_id_daylight: u32 = 2;
const time_zone_id_invalid: u32 = 0xFFFFFFFF;
const time_zone_id_standard: u32 = 1;
const utc_offset_max: i32 = 50_400;
const utc_offset_min: i32 = -utc_offset_max;

extern "kernel32" fn GetSystemTimeAsFileTime(file_time: *windows.FILETIME) callconv(.winapi) void;

extern "kernel32" fn GetTimeZoneInformation(
    information: *TIME_ZONE_INFORMATION,
) callconv(.winapi) u32;

extern "kernel32" fn FileTimeToSystemTime(
    file_time: *const windows.FILETIME,
    system_time: *SYSTEMTIME,
) callconv(.winapi) i32;

extern "kernel32" fn SystemTimeToTzSpecificLocalTime(
    time_zone: ?*const TIME_ZONE_INFORMATION,
    universal: *const SYSTEMTIME,
    local: *SYSTEMTIME,
) callconv(.winapi) i32;
