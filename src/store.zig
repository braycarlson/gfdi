const std = @import("std");

const assert = std.debug.assert;

pub const File = struct {
    data: []const u8,
    path: []const u8,
};

pub const DiskStore = struct {
    io: std.Io,

    pub const Error = std.Io.Dir.WriteFileError;

    pub fn write(store: *const DiskStore, file: *const File) Error!void {
        assert(file.path.len > 0);
        assert(file.path[0] != '/');

        try std.Io.Dir.cwd().writeFile(store.io, .{ .data = file.data, .sub_path = file.path });
    }

    pub fn make_path(store: *const DiskStore, path: []const u8) void {
        assert(path.len > 0);
        assert(path[0] != '/');

        std.Io.Dir.cwd().createDirPath(store.io, path) catch return;
    }

    pub fn exists(store: *const DiskStore, path: []const u8) bool {
        assert(path.len > 0);
        assert(path[0] != '/');

        const options: std.Io.Dir.AccessOptions = .{
            .execute = false,
            .follow_symlinks = true,
            .read = false,
            .write = false,
        };

        std.Io.Dir.cwd().access(store.io, path, options) catch return false;

        return true;
    }
};
