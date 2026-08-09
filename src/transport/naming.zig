const std = @import("std");

const assert = std.debug.assert;

pub const output_root = "pulled";
pub const state_dir = "pulled/.state";

pub fn type_dir(file_type: ?u8) []const u8 {
    const code = file_type orelse return "Unknown";

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

pub fn dir_path(buffer: []u8, file_type: ?u8) ?[]const u8 {
    assert(buffer.len > 0);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ output_root, type_dir(file_type) }) catch null;
}

pub fn activity_path(buffer: []u8, dir: []const u8, stamp: []const u8, suffix: u32) ?[]const u8 {
    assert(buffer.len > 0);
    assert(dir.len > 0);
    assert(stamp.len > 0);
    assert(suffix >= 1);

    if (suffix == 1) {
        return std.fmt.bufPrint(buffer, "{s}/{s}.fit", .{ dir, stamp }) catch null;
    }

    return std.fmt.bufPrint(buffer, "{s}/{s}_{d}.fit", .{ dir, stamp, suffix }) catch null;
}

pub fn index_path(buffer: []u8, dir: []const u8, index: u16) ?[]const u8 {
    assert(buffer.len > 0);
    assert(dir.len > 0);

    return std.fmt.bufPrint(buffer, "{s}/idx{d}.fit", .{ dir, index }) catch null;
}

pub fn marker_path(buffer: []u8, index: u16) []const u8 {
    assert(buffer.len > 0);

    return std.fmt.bufPrint(buffer, "{s}/{d}", .{ state_dir, index }) catch |err| switch (err) {
        error.NoSpaceLeft => @panic("marker_path buffer too small"),
    };
}

test "type_dir maps known types and buckets unknowns" {
    try std.testing.expectEqualStrings("Activity", type_dir(4));
    try std.testing.expectEqualStrings("Monitor", type_dir(32));
    try std.testing.expectEqualStrings("Other", type_dir(99));
    try std.testing.expectEqualStrings("Unknown", type_dir(null));
}

test "dir_path joins the output root and type directory" {
    var buffer: [96]u8 = undefined;

    try std.testing.expectEqualStrings("pulled/Activity", dir_path(&buffer, 4).?);
    try std.testing.expectEqualStrings("pulled/Unknown", dir_path(&buffer, null).?);
}

test "activity_path suffixes only collisions past the first" {
    var buffer: [160]u8 = undefined;

    try std.testing.expectEqualStrings(
        "pulled/Activity/2024-08-23-17-56-01.fit",
        activity_path(&buffer, "pulled/Activity", "2024-08-23-17-56-01", 1).?,
    );

    try std.testing.expectEqualStrings(
        "pulled/Activity/2024-08-23-17-56-01_2.fit",
        activity_path(&buffer, "pulled/Activity", "2024-08-23-17-56-01", 2).?,
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
