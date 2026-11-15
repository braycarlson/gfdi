const std = @import("std");

const bounded = @import("bounded");

const File = @import("../store.zig").File;

const assert = std.debug.assert;

pub const MemoryStore = struct {
    entries: bounded.ArrayType(Entry, entry_count_max),

    pub const Entry = struct {
        data: bounded.BufferType(data_length_max),
        path: bounded.BufferType(path_length_max),
    };

    pub const Error = error{
        DataTooLong,
        PathTooLong,
        StoreFull,
    };

    pub const empty: MemoryStore = .{ .entries = .empty };

    pub fn write(store: *MemoryStore, file: *const File) Error!void {
        assert(file.path.len > 0);
        assert(store.entries.count <= entry_count_max);

        if (file.path.len > path_length_max) return error.PathTooLong;
        if (file.data.len > data_length_max) return error.DataTooLong;
        if (store.entries.full()) return error.StoreFull;

        const entry = store.entries.push_slot_assume_capacity();

        entry.* = .{ .data = .empty, .path = .empty };
        entry.data.set(file.data) catch return error.DataTooLong;
        entry.path.set(file.path) catch return error.PathTooLong;

        assert(std.mem.eql(u8, entry.path.slice(), file.path));
    }

    pub fn make_path(store: *MemoryStore, path: []const u8) void {
        assert(path.len > 0);
        assert(store.entries.count <= entry_count_max);
    }

    pub fn exists(store: *const MemoryStore, path: []const u8) bool {
        assert(path.len > 0);

        return store.find(path) != null;
    }

    pub fn get(store: *const MemoryStore, path: []const u8) ?[]const u8 {
        assert(path.len > 0);

        const index = store.find(path) orelse return null;
        const result = store.entries.get(index).data.slice();

        assert(result.len <= data_length_max);

        return result;
    }

    fn find(store: *const MemoryStore, path: []const u8) ?u32 {
        assert(path.len > 0);
        assert(store.entries.count <= entry_count_max);

        for (store.entries.slice(), 0..) |*entry, index| {
            if (!std.mem.eql(u8, entry.path.slice(), path)) continue;

            const result: u32 = @intCast(index);

            assert(result < store.entries.count);

            return result;
        }

        return null;
    }
};

pub const data_length_max: u32 = 4096;
pub const entry_count_max: u32 = 16;
pub const path_length_max: u32 = 128;

const testing = std.testing;

test MemoryStore {
    var store: MemoryStore = .empty;

    try store.write(&.{ .data = "abc", .path = "pulled/Activity/a.fit" });

    try testing.expect(store.exists("pulled/Activity/a.fit"));
    try testing.expect(!store.exists("pulled/Activity/b.fit"));
    try testing.expectEqualStrings("abc", store.get("pulled/Activity/a.fit").?);

    const path_long: [path_length_max + 1]u8 = @splat('p');
    const refused = store.write(&.{ .data = "", .path = &path_long });

    try testing.expectError(error.PathTooLong, refused);
}

test "a full store refuses one more file" {
    var store: MemoryStore = .empty;
    var buffer: [16]u8 = undefined;

    for (0..entry_count_max) |index| {
        const path = try std.mem.print(&buffer, "f{d}", .{index});

        try store.write(&.{ .data = "x", .path = path });
    }

    const refused = store.write(&.{ .data = "x", .path = "g" });

    try testing.expectError(error.StoreFull, refused);
}
