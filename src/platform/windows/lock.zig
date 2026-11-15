const std = @import("std");

const reassembly = @import("../../transport.zig").reassembly;

const assert = std.debug.assert;

const SRWLOCK = extern struct { pointer: ?*anyopaque = null };

pub const Lock = struct {
    handle: SRWLOCK = .{},
    held: bool = false,

    pub fn lock(exclusive: *Lock) void {
        comptime assert(@sizeOf(SRWLOCK) == 8);

        AcquireSRWLockExclusive(&exclusive.handle);

        assert(!exclusive.held);

        exclusive.held = true;
    }

    pub fn unlock(exclusive: *Lock) void {
        comptime assert(@sizeOf(SRWLOCK) == 8);
        assert(exclusive.held);

        exclusive.held = false;

        ReleaseSRWLockExclusive(&exclusive.handle);
    }
};

pub const GFDIState = reassembly.GFDIStateType(Lock);

extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
