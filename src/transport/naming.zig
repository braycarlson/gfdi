const std = @import("std");

const assert = std.debug.assert;

pub const file_type_invalid: u8 = 0xFF;
pub const stamp_bytes: u32 = 19;
pub const output_root = "pulled";
pub const state_directory = "pulled/.state";

pub fn type_directory(file_type: ?u8) []const u8 {
    assert(file_type != file_type_invalid);

    if (file_type) |code| return type_directory_known(code);
    return "Unknown";
}

fn type_directory_known(code: u8) []const u8 {
    return switch (code) {
        1 => "Device",
        2 => "Settings",
        3 => "Sports",
        4 => "Activity",
        5 => "Workouts",
        6 => "Courses",
        7 => "Schedule",
        8 => "Location",
        9 => "Weight",
        10 => "Totals",
        11 => "Goals",
        20 => "Summary",
        28 => "MonitorDaily",
        29 => "Records",
        32 => "Monitor",
        33 => "MltSport",
        34 => "Segment",
        35 => "SegmentList",
        38 => "ScoreCards",
        39 => "Adjustments",
        41 => "ChangeLog",
        44 => "Metrics",
        49 => "Sleep",
        59 => "MuscleMap",
        60 => "RunningTrack",
        62 => "Benchmark",
        65 => "Calendar",
        68 => "HRVStatus",
        70 => "HSA",
        71 => "ComAct",
        72 => "FbtBackup",
        74 => "FbtPtdBackup",
        77 => "Coach",
        79 => "SleepDisruption",
        else => "Other",
    };
}

pub fn stamp_format(buffer: []u8, seconds: i64) ?[]const u8 {
    assert(buffer.len >= stamp_bytes);

    if (seconds < 0) return null;

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const result = std.mem.print(buffer, "{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u16, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch return null;

    assert(result.len == stamp_bytes);

    return result;
}

pub fn directory_path(buffer: []u8, file_type: ?u8) ?[]const u8 {
    assert(buffer.len > 0);
    assert(file_type != file_type_invalid);

    return std.mem.print(buffer, "{s}/{s}", .{ output_root, type_directory(file_type) }) catch null;
}

pub const Activity = struct {
    directory: []const u8,
    stamp: []const u8,
    suffix: u32,
};

pub fn activity_path(buffer: []u8, activity: Activity) ?[]const u8 {
    assert(buffer.len > 0);
    assert(activity.directory.len > 0);
    assert(activity.stamp.len > 0);
    assert(activity.suffix >= 1);

    if (activity.suffix == 1) {
        return std.mem.print(buffer, "{s}/{s}.fit", .{ activity.directory, activity.stamp }) catch
            null;
    }

    return std.mem.print(buffer, "{s}/{s}_{d}.fit", .{
        activity.directory,
        activity.stamp,
        activity.suffix,
    }) catch null;
}

pub fn index_path(buffer: []u8, directory: []const u8, index: u16) ?[]const u8 {
    assert(index > 0);
    assert(buffer.len > 0);
    assert(directory.len > 0);

    return std.mem.print(buffer, "{s}/idx{d}.fit", .{ directory, index }) catch null;
}

pub fn marker_path(buffer: []u8, index: u16) []const u8 {
    assert(index > 0);
    assert(buffer.len > 0);

    return std.mem.print(buffer, "{s}/{d}", .{ state_directory, index }) catch |err| switch (err) {
        error.NoSpaceLeft => @panic("marker_path buffer too small"),
    };
}

test "type_directory maps known types and buckets unknowns" {
    try std.testing.expectEqualStrings("Activity", type_directory(4));
    try std.testing.expectEqualStrings("Monitor", type_directory(32));
    try std.testing.expectEqualStrings("Other", type_directory(99));
    try std.testing.expectEqualStrings("Unknown", type_directory(null));
}

test "directory_path joins the output root and type directory" {
    var buffer: [96]u8 = undefined;

    try std.testing.expectEqualStrings("pulled/Activity", directory_path(&buffer, 4).?);
    try std.testing.expectEqualStrings("pulled/Unknown", directory_path(&buffer, null).?);
}

test "activity_path suffixes only collisions past the first" {
    var buffer: [160]u8 = undefined;

    try std.testing.expectEqualStrings(
        "pulled/Activity/2024-08-23-17-56-01.fit",
        activity_path(&buffer, .{
            .directory = "pulled/Activity",
            .stamp = "2024-08-23-17-56-01",
            .suffix = 1,
        }).?,
    );

    try std.testing.expectEqualStrings(
        "pulled/Activity/2024-08-23-17-56-01_2.fit",
        activity_path(&buffer, .{
            .directory = "pulled/Activity",
            .stamp = "2024-08-23-17-56-01",
            .suffix = 2,
        }).?,
    );
}

test "index_path names the timestamp-less fallback" {
    var buffer: [96]u8 = undefined;

    try std.testing.expectEqualStrings(
        "pulled/Activity/idx7.fit",
        index_path(&buffer, "pulled/Activity", 7).?,
    );
}

test "marker_path locates the per-index resume marker" {
    var buffer: [64]u8 = undefined;

    try std.testing.expectEqualStrings("pulled/.state/5", marker_path(&buffer, 5));
}

test stamp_format {
    var buffer: [stamp_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("1970-01-01-00-00-00", stamp_format(&buffer, 0).?);
    const stamp = stamp_format(&buffer, 1_000_000_000).?;

    try std.testing.expectEqualStrings("2001-09-09-01-46-40", stamp);
    try std.testing.expect(stamp_format(&buffer, -1) == null);
}
