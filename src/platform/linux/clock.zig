const std = @import("std");

const zfit = @import("zfit");
const gfdi = @import("../../protocol/gfdi.zig");
const sys = @import("sys.zig");

const assert = std.debug.assert;

const linux = std.os.linux;

pub const zone_path = "/etc/localtime";
pub const zone_bytes_max: u32 = 512 * 1024;
pub const stamp_bytes_min: u32 = 19;

pub const utc_offset_min: i32 = -50_400;
pub const utc_offset_max: i32 = 50_400;

comptime {
    assert(zone_path[0] == '/');
    assert(zone_bytes_max > 0);
    assert(stamp_bytes_min == 19);
    assert(utc_offset_min < 0);
    assert(utc_offset_max == -utc_offset_min);
}

pub const LinuxClock = struct {
    zone: ?std.tz.Tz = null,

    pub fn init(arena: std.mem.Allocator, io: std.Io) LinuxClock {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            zone_path,
            arena,
            .limited(zone_bytes_max),
        ) catch return .{};

        var reader = std.Io.Reader.fixed(bytes);

        const zone = std.tz.Tz.parse(arena, &reader) catch return .{};

        return .{ .zone = zone };
    }

    pub fn now_garmin(clock: LinuxClock) i32 {
        _ = clock;

        return @intCast(now_unix() - gfdi.garmin_epoch_offset_sec);
    }

    pub fn utc_offset_seconds(clock: LinuxClock) i32 {
        const offset = clock.offset_at(now_unix());

        assert(offset >= utc_offset_min);
        assert(offset <= utc_offset_max);

        return offset;
    }

    pub fn format_local_time(clock: LinuxClock, buffer: []u8, fit_timestamp: u32) ?[]const u8 {
        assert(buffer.len >= stamp_bytes_min);

        const unix_seconds: i64 = zfit.epoch.to_unix_seconds(fit_timestamp);

        if (unix_seconds < 0) return null;

        const local = unix_seconds + clock.offset_at(unix_seconds);

        if (local < 0) return null;

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(local) };
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

    fn offset_at(clock: LinuxClock, unix_seconds: i64) i32 {
        const zone = clock.zone orelse return 0;

        var chosen: ?*const std.tz.Timetype = null;

        for (zone.transitions) |transition| {
            if (transition.ts > unix_seconds) break;

            chosen = transition.timetype;
        }

        const timetype = chosen orelse fallback_timetype(zone) orelse return 0;
        const offset = timetype.offset;

        if (offset < utc_offset_min or offset > utc_offset_max) return 0;

        return offset;
    }
};

fn fallback_timetype(zone: std.tz.Tz) ?*const std.tz.Timetype {
    for (zone.timetypes) |*timetype| {
        if (!timetype.isDst()) return timetype;
    }

    if (zone.timetypes.len > 0) return &zone.timetypes[0];

    return null;
}

fn now_unix() i64 {
    var value: linux.timespec = undefined;

    const raw = linux.clock_gettime(.REALTIME, &value);

    if (!sys.ok(raw)) return 0;

    return value.sec;
}

const testing = std.testing;

test "a clock without a parsed zone falls back to UTC" {
    const clock = LinuxClock{};
    var buffer: [32]u8 = undefined;

    try testing.expectEqual(@as(i32, 0), clock.utc_offset_seconds());

    try testing.expectEqualStrings(
        "1989-12-31-00-00-00",
        clock.format_local_time(&buffer, 0).?,
    );
}

test "the host zone parses and stays inside the offset bound" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const clock = LinuxClock.init(arena_state.allocator(), testing.io);
    const offset = clock.utc_offset_seconds();

    try testing.expect(offset >= utc_offset_min);
    try testing.expect(offset <= utc_offset_max);
}

test "format_local_time shifts a FIT timestamp by the zone offset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const clock = LinuxClock.init(arena_state.allocator(), testing.io);

    var local_buffer: [32]u8 = undefined;
    var utc_buffer: [32]u8 = undefined;

    const utc = LinuxClock{};
    const timestamp: u32 = 1_000_000_000;

    const local_text = clock.format_local_time(&local_buffer, timestamp).?;
    const utc_text = utc.format_local_time(&utc_buffer, timestamp).?;

    try testing.expectEqual(@as(usize, stamp_bytes_min), local_text.len);
    try testing.expectEqual(@as(usize, stamp_bytes_min), utc_text.len);

    if (clock.utc_offset_seconds() == 0) {
        try testing.expectEqualStrings(utc_text, local_text);
    }
}
