const std = @import("std");

const transport = @import("../transport.zig");

const assert = std.debug.assert;

pub const FakeClock = struct {
    garmin_now: i32,
    offset_seconds: i32,

    pub const zero: FakeClock = .{ .garmin_now = 0, .offset_seconds = 0 };

    pub fn now_garmin(clock: FakeClock) i32 {
        assert(clock.offset_seconds >= utc_offset_min);
        assert(clock.offset_seconds <= utc_offset_max);

        return clock.garmin_now;
    }

    pub fn utc_offset_seconds(clock: FakeClock) i32 {
        assert(clock.offset_seconds >= utc_offset_min);
        assert(clock.offset_seconds <= utc_offset_max);

        return clock.offset_seconds;
    }

    pub fn format_local_time(clock: FakeClock, buffer: []u8, unix_seconds: i64) ?[]const u8 {
        assert(clock.offset_seconds >= utc_offset_min);
        assert(buffer.len >= transport.naming.stamp_bytes);
        assert(unix_seconds >= 0);

        const local = unix_seconds + clock.offset_seconds;

        return transport.naming.stamp_format(buffer, local);
    }
};

pub const utc_offset_max: i32 = 50_400;
pub const utc_offset_min: i32 = -utc_offset_max;

const testing = std.testing;

const fit_epoch_unix_seconds: i64 = 631_065_600;

test FakeClock {
    const clock: FakeClock = .zero;

    var buffer: [32]u8 = undefined;

    try testing.expectEqualStrings(
        "1989-12-31-00-00-00",
        clock.format_local_time(&buffer, fit_epoch_unix_seconds).?,
    );

    const ahead = FakeClock{ .garmin_now = 0, .offset_seconds = 3600 };

    try testing.expectEqualStrings(
        "1989-12-31-01-00-00",
        ahead.format_local_time(&buffer, fit_epoch_unix_seconds).?,
    );
}
