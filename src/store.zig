const std = @import("std");

const assert = std.debug.assert;

pub const DiskStore = struct {
    io: std.Io,

    pub fn write(store: DiskStore, path: []const u8, bytes: []const u8) !void {
        assert(path.len > 0);
        try std.Io.Dir.cwd().writeFile(store.io, .{ .sub_path = path, .data = bytes });
    }

    pub fn make_path(store: DiskStore, path: []const u8) void {
        assert(path.len > 0);
        std.Io.Dir.cwd().createDirPath(store.io, path) catch return;
    }

    pub fn exists(store: DiskStore, path: []const u8) bool {
        assert(path.len > 0);
        std.Io.Dir.cwd().access(store.io, path, .{}) catch return false;
        return true;
    }
};
