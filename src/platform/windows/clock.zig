const std = @import("std");

const zfit = @import("zfit");
const gfdi = @import("../../protocol/gfdi.zig");

const assert = std.debug.assert;

const FILETIME = extern struct { low: u32, high: u32 };

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

pub const WinClock = struct {
    pub fn now_garmin(clock: WinClock) i32 {
        _ = clock;

        var file_time: FILETIME = undefined;
        GetSystemTimeAsFileTime(&file_time);

        const ticks = (@as(u64, file_time.high) << 32) | file_time.low;
        const seconds_since_1601: i64 = @intCast(@divFloor(ticks, 10_000_000));
        const seconds_since_1970 = seconds_since_1601 - 11_644_473_600;

        return @intCast(seconds_since_1970 - gfdi.garmin_epoch_offset_sec);
    }

    pub fn utc_offset_seconds(clock: WinClock) i32 {
        _ = clock;

        var info: TIME_ZONE_INFORMATION = undefined;
        const id = GetTimeZoneInformation(&info);

        if (id == time_zone_id_invalid) return 0;

        var active_bias: i32 = info.bias;

        if (id == 2) {
            active_bias += info.daylight_bias;
        } else if (id == 1) {
            active_bias += info.standard_bias;
        }

        const offset_seconds = -active_bias * 60;

        assert(offset_seconds >= -50_400);
        assert(offset_seconds <= 50_400);
        return offset_seconds;
    }

    pub fn format_local_time(clock: WinClock, buffer: []u8, fit_timestamp: u32) ?[]const u8 {
        _ = clock;

        assert(buffer.len >= 19);
        const unix_seconds: i64 = zfit.epoch.to_unix_seconds(fit_timestamp);

        if (unix_seconds < 0) return null;
        const ticks: u64 = (@as(u64, @intCast(unix_seconds)) + 11_644_473_600) * 10_000_000;
        const file_time = FILETIME{ .low = @truncate(ticks), .high = @truncate(ticks >> 32) };

        var utc: SYSTEMTIME = undefined;

        if (FileTimeToSystemTime(&file_time, &utc) == 0) return null;
        var local: SYSTEMTIME = undefined;

        if (SystemTimeToTzSpecificLocalTime(null, &utc, &local) == 0) return null;

        return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}", .{
            local.year, local.month, local.day, local.hour, local.minute, local.second,
        }) catch null;
    }
};

const time_zone_id_invalid: u32 = 0xFFFFFFFF;

extern "kernel32" fn GetSystemTimeAsFileTime(file_time: *FILETIME) callconv(.winapi) void;
extern "kernel32" fn GetTimeZoneInformation(info: *TIME_ZONE_INFORMATION) callconv(.winapi) u32;

extern "kernel32" fn FileTimeToSystemTime(
    file_time: *const FILETIME,
    system_time: *SYSTEMTIME,
) callconv(.winapi) i32;

extern "kernel32" fn SystemTimeToTzSpecificLocalTime(
    time_zone: ?*const TIME_ZONE_INFORMATION,
    universal: *const SYSTEMTIME,
    local: *SYSTEMTIME,
) callconv(.winapi) i32;
