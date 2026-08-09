const std = @import("std");

const zfit = @import("zfit");

pub const FakeClock = struct {
    garmin_now: i32 = 0,
    offset_seconds: i32 = 0,

    pub fn now_garmin(clock: FakeClock) i32 {
        return clock.garmin_now;
    }

    pub fn utc_offset_seconds(clock: FakeClock) i32 {
        return clock.offset_seconds;
    }

    pub fn format_local_time(clock: FakeClock, buffer: []u8, fit_timestamp: u32) ?[]const u8 {
        _ = clock;
        const unix_seconds: i64 = zfit.epoch.to_unix_seconds(fit_timestamp);

        if (unix_seconds < 0) return null;
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_seconds) };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();

        return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}", .{
            year_day.year,
            month_day.month.numeric(),
            @as(u16, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        }) catch null;
    }
};

test "FakeClock formats a FIT timestamp as a UTC filename stem" {
    const clock = FakeClock{};
    var buffer: [32]u8 = undefined;

    try std.testing.expectEqualStrings(
        "1989-12-31-00-00-00",
        clock.format_local_time(&buffer, 0).?,
    );
}
