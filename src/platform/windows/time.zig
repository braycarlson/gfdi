const std = @import("std");

const assert = std.debug.assert;

const sleep_ms_max: u32 = 24 * 60 * 60 * 1000;
const timer_period_ms: u32 = 1;

comptime {
    assert(timer_period_ms > 0);
}

pub fn now_ms() u64 {
    comptime assert(timer_period_ms > 0);

    const result = tick_count();

    assert(result < std.math.maxInt(u64));

    return result;
}

pub fn sleep_ms(milliseconds: u32) void {
    comptime assert(sleep_ms_max > 0);
    assert(milliseconds <= sleep_ms_max);

    sleep(milliseconds);
}

pub fn begin_precise() void {
    comptime assert(timer_period_ms > 0);
    comptime assert(timer_period_ms <= 16);

    _ = period_begin(timer_period_ms);
}

pub fn end_precise() void {
    comptime assert(timer_period_ms > 0);
    comptime assert(timer_period_ms <= 16);

    _ = period_end(timer_period_ms);
}

const tick_count = @extern(*const fn () callconv(.winapi) u64, .{
    .library_name = "kernel32",
    .name = "GetTickCount64",
});

const sleep = @extern(*const fn (u32) callconv(.winapi) void, .{
    .library_name = "kernel32",
    .name = "Sleep",
});

const period_begin = @extern(*const fn (u32) callconv(.winapi) u32, .{
    .library_name = "winmm",
    .name = "timeBeginPeriod",
});

const period_end = @extern(*const fn (u32) callconv(.winapi) u32, .{
    .library_name = "winmm",
    .name = "timeEndPeriod",
});
