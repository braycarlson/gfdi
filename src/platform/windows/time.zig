const std = @import("std");

const assert = std.debug.assert;

const timer_period_ms: u32 = 1;

comptime {
    assert(timer_period_ms > 0);
}

pub fn now_ms() u64 {
    return GetTickCount64();
}

pub fn sleep_ms(milliseconds: u32) void {
    Sleep(milliseconds);
}

pub fn begin_precise() void {
    _ = timeBeginPeriod(timer_period_ms);
}

pub fn end_precise() void {
    _ = timeEndPeriod(timer_period_ms);
}

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

extern "winmm" fn timeBeginPeriod(period: u32) callconv(.winapi) u32;
extern "winmm" fn timeEndPeriod(period: u32) callconv(.winapi) u32;
