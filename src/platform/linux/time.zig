const std = @import("std");

const sys = @import("sys.zig");

const assert = std.debug.assert;

const linux = std.os.linux;

pub const sleep_retry_max: u32 = 64;
pub const sleep_ms_max: u32 = 24 * 60 * 60 * 1000;

comptime {
    assert(sleep_retry_max > 0);
}

pub fn now_ms() u64 {
    var value: linux.timespec = undefined;

    const raw = linux.clock_gettime(.MONOTONIC, &value);
    if (!sys.ok(raw)) return 0;
    if (value.sec < 0) return 0;

    const seconds: u64 = @intCast(value.sec);
    const nanoseconds: u64 = @intCast(@max(value.nsec, 0));

    assert(nanoseconds < std.time.ns_per_s);

    const result = seconds * std.time.ms_per_s + @divFloor(nanoseconds, std.time.ns_per_ms);

    assert(result >= seconds);

    return result;
}

pub fn sleep_ms(milliseconds: u32) void {
    assert(milliseconds <= sleep_ms_max);

    var request = linux.timespec{
        .sec = @intCast(@divFloor(milliseconds, std.time.ms_per_s)),
        .nsec = @intCast((milliseconds % std.time.ms_per_s) * std.time.ns_per_ms),
    };

    assert(request.nsec < std.time.ns_per_s);

    var remaining: linux.timespec = undefined;
    var retries: u32 = 0;

    while (retries < sleep_retry_max) : (retries += 1) {
        const raw = linux.nanosleep(&request, &remaining);
        if (sys.ok(raw)) return;

        if (remaining.sec == 0) {
            if (remaining.nsec == 0) return;
        }

        request = remaining;
    }
}

const testing = std.testing;

test "now_ms advances across a short sleep" {
    const before = now_ms();

    sleep_ms(5);

    const after = now_ms();

    try testing.expect(after >= before);
    try testing.expect(after - before >= 5);
}

test "sleep_ms returns immediately for a zero request" {
    const before = now_ms();

    sleep_ms(0);

    const after = now_ms();

    try testing.expect(before > 0);
    try testing.expect(after - before < 1000);
}
