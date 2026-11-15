const std = @import("std");

const protocol = @import("../../protocol.zig");
const sys = @import("sys.zig");
const transport = @import("../../transport.zig");

const assert = std.debug.assert;

const linux = std.os.linux;

pub const Zone = struct {
    file: [zone_file_bytes_max]u8,
    memory: [zone_memory_bytes_max]u8,
};

pub const zone_path = "/etc/localtime";
pub const zone_file_bytes_max: u32 = 64 * 1024;
pub const zone_memory_bytes_max: u32 = 128 * 1024;
pub const utc_offset_min: i32 = -50_400;
pub const utc_offset_max: i32 = 50_400;

comptime {
    assert(zone_path[0] == '/');
    assert(zone_file_bytes_max > 0);
    assert(zone_memory_bytes_max >= zone_file_bytes_max);
    assert(utc_offset_min < 0);
    assert(utc_offset_max == -utc_offset_min);
}

pub const Clock = struct {
    zone: ?std.tz.Tz,

    pub const utc: Clock = .{ .zone = null };

    pub fn init(zone: *Zone, io: std.Io) Clock {
        assert(zone.file.len == zone_file_bytes_max);
        assert(zone.memory.len == zone_memory_bytes_max);

        const bytes = std.Io.Dir.cwd().readFile(io, zone_path, &zone.file) catch return .utc;
        if (bytes.len == zone.file.len) return .utc;

        var reader = std.Io.Reader.fixed(bytes);
        var memory = std.heap.FixedBufferAllocator.init(&zone.memory);
        const parsed = std.tz.Tz.parse(memory.allocator(), &reader) catch return .utc;

        return .{ .zone = parsed };
    }

    pub fn now_garmin(clock: *const Clock) i32 {
        assert(clock.offset_at(0) >= utc_offset_min);

        return @intCast(now_unix() - protocol.gfdi.garmin_epoch_offset_seconds);
    }

    pub fn utc_offset_seconds(clock: *const Clock) i32 {
        const offset = clock.offset_at(now_unix());

        assert(offset >= utc_offset_min);
        assert(offset <= utc_offset_max);

        return offset;
    }

    pub fn format_local_time(clock: *const Clock, buffer: []u8, unix_seconds: i64) ?[]const u8 {
        assert(buffer.len >= transport.naming.stamp_bytes);
        assert(unix_seconds >= 0);

        const local = unix_seconds + clock.offset_at(unix_seconds);

        return transport.naming.stamp_format(buffer, local);
    }

    fn offset_at(clock: *const Clock, unix_seconds: i64) i32 {
        assert(unix_seconds > std.math.minInt(i64));

        const zone = clock.zone orelse return 0;

        var chosen: ?*const std.tz.Timetype = null;

        for (zone.transitions) |transition| {
            if (transition.ts > unix_seconds) break;

            chosen = transition.timetype;
        }

        const timetype = chosen orelse fallback_timetype(&zone) orelse return 0;
        const offset = timetype.offset;

        if (offset < utc_offset_min) return 0;
        if (offset > utc_offset_max) return 0;
        return offset;
    }
};

fn fallback_timetype(zone: *const std.tz.Tz) ?*const std.tz.Timetype {
    assert(zone.timetypes.len <= zone_memory_bytes_max);

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

    assert(value.nsec >= 0);
    assert(value.nsec < std.time.ns_per_s);

    return value.sec;
}

const testing = std.testing;

const fit_epoch_unix_seconds: i64 = 631_065_600;

test "a clock without a parsed zone falls back to UTC" {
    const clock: Clock = .utc;

    var buffer: [32]u8 = undefined;

    try testing.expectEqual(@as(i32, 0), clock.utc_offset_seconds());

    try testing.expectEqualStrings(
        "1989-12-31-00-00-00",
        clock.format_local_time(&buffer, fit_epoch_unix_seconds).?,
    );

    try testing.expect(clock.now_garmin() > 0);
}

test "the host zone parses and stays inside the offset bound" {
    const zone = try testing.allocator.create(Zone);
    defer testing.allocator.destroy(zone);

    const clock = Clock.init(zone, testing.io);
    const offset = clock.utc_offset_seconds();

    try testing.expect(offset >= utc_offset_min);
    try testing.expect(offset <= utc_offset_max);
}

test "format_local_time shifts a FIT timestamp by the zone offset" {
    const zone = try testing.allocator.create(Zone);
    defer testing.allocator.destroy(zone);

    const clock = Clock.init(zone, testing.io);
    const utc: Clock = .utc;
    const timestamp: i64 = fit_epoch_unix_seconds + 1_000_000_000;

    var local_buffer: [32]u8 = undefined;
    var utc_buffer: [32]u8 = undefined;

    const local_text = clock.format_local_time(&local_buffer, timestamp).?;
    const utc_text = utc.format_local_time(&utc_buffer, timestamp).?;

    try testing.expectEqual(@as(usize, transport.naming.stamp_bytes), local_text.len);
    try testing.expectEqual(@as(usize, transport.naming.stamp_bytes), utc_text.len);
    try testing.expectEqualStrings("2021-09-08-01-46-40", utc_text);

    if (clock.utc_offset_seconds() == 0) try testing.expectEqualStrings(utc_text, local_text);
}
