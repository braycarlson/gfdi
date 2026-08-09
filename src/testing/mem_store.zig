const std = @import("std");

pub const MemStore = struct {
    paths: [entries_max][path_len_max]u8 = undefined,
    path_lengths: [entries_max]u32 = undefined,
    data: [entries_max][data_len_max]u8 = undefined,
    data_lengths: [entries_max]u32 = undefined,
    count: u32 = 0,

    pub fn write(store: *MemStore, path: []const u8, bytes: []const u8) !void {
        if (store.count >= entries_max) return error.MemStoreFull;
        if (path.len > path_len_max) return error.PathTooLong;
        if (bytes.len > data_len_max) return error.DataTooLong;
        const slot = store.count;
        @memcpy(store.paths[slot][0..path.len], path);
        store.path_lengths[slot] = @intCast(path.len);
        @memcpy(store.data[slot][0..bytes.len], bytes);
        store.data_lengths[slot] = @intCast(bytes.len);
        store.count += 1;
    }

    pub fn make_path(store: *MemStore, path: []const u8) void {
        _ = store;
        _ = path;
    }

    pub fn exists(store: *MemStore, path: []const u8) bool {
        return store.find(path) != null;
    }

    pub fn get(store: *MemStore, path: []const u8) ?[]const u8 {
        const index = store.find(path) orelse return null;

        return store.data[index][0..store.data_lengths[index]];
    }

    fn find(store: *MemStore, path: []const u8) ?u32 {
        var index: u32 = 0;

        while (index < store.count) : (index += 1) {
            const stored = store.paths[index][0..store.path_lengths[index]];

            if (std.mem.eql(u8, stored, path)) return index;
        }

        return null;
    }
};

pub const entries_max: u32 = 16;
pub const path_len_max: u32 = 128;
pub const data_len_max: u32 = 2048;
