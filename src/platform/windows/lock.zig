const reassembly = @import("../../transport/reassembly.zig");

const SRWLOCK = extern struct { pointer: ?*anyopaque = null };

pub const Lock = struct {
    handle: SRWLOCK = .{},

    pub fn lock(exclusive: *Lock) void {
        AcquireSRWLockExclusive(&exclusive.handle);
    }

    pub fn unlock(exclusive: *Lock) void {
        ReleaseSRWLockExclusive(&exclusive.handle);
    }
};

pub const GFDIState = reassembly.GFDIStateType(Lock);

extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
