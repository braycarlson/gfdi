const std = @import("std");

const assert = std.debug.assert;

const linux = std.os.linux;
const posix = std.posix;

pub const Fd = linux.fd_t;

pub const Error = error{
    Failed,
    Interrupted,
    WouldBlock,
};

pub const environ_bytes_max: u32 = 8 * 1024;
pub const environ_entries_max: u32 = 1024;
pub const environ_path = "/proc/self/environ";
pub const interrupt_retry_max: u32 = 64;
pub const write_attempts_max: u32 = 4096;

comptime {
    assert(environ_bytes_max > 0);
    assert(environ_entries_max > 0);
    assert(environ_path.len > 0);
    assert(interrupt_retry_max > 0);
    assert(write_attempts_max > 0);
}

var environ_storage: [environ_bytes_max]u8 = undefined;
var environ_length: u32 = 0;
var environ_loaded: bool = false;

pub fn ok(raw: usize) bool {
    return posix.errno(raw) == .SUCCESS;
}

pub fn close(fd: Fd) void {
    _ = linux.close(fd);
}

pub fn read(fd: Fd, buffer: []u8) Error!usize {
    assert(buffer.len > 0);

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.read(fd, buffer.ptr, buffer.len);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            assert(raw <= buffer.len);

            return raw;
        }

        if (status == .AGAIN) {
            return Error.WouldBlock;
        }

        if (status != .INTR) {
            return Error.Failed;
        }
    }

    return Error.Interrupted;
}

pub fn write(fd: Fd, bytes: []const u8) Error!usize {
    assert(bytes.len > 0);

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.write(fd, bytes.ptr, bytes.len);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            assert(raw <= bytes.len);

            return raw;
        }

        if (status == .AGAIN) {
            return Error.WouldBlock;
        }

        if (status != .INTR) {
            return Error.Failed;
        }
    }

    return Error.Interrupted;
}

pub fn write_all(fd: Fd, bytes: []const u8) Error!void {
    assert(bytes.len > 0);

    var written: usize = 0;
    var attempts: u32 = 0;

    while (written < bytes.len and attempts < write_attempts_max) : (attempts += 1) {
        const count = try write(fd, bytes[written..]);

        if (count == 0) {
            return Error.Failed;
        }

        written += count;
    }

    if (written < bytes.len) {
        return Error.Failed;
    }
}

pub fn poll_in(fd: Fd, timeout_ms: i32) Error!bool {
    var descriptors = [_]linux.pollfd{.{
        .fd = fd,
        .events = linux.POLL.IN,
        .revents = 0,
    }};

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.poll(&descriptors, descriptors.len, timeout_ms);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            return raw > 0;
        }

        if (status != .INTR) {
            return Error.Failed;
        }
    }

    return Error.Interrupted;
}

pub fn unix_socket() Error!Fd {
    const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);

    if (!ok(raw)) {
        return Error.Failed;
    }

    const result: Fd = @intCast(raw);

    return result;
}

pub fn connect(fd: Fd, address: *const linux.sockaddr.un, length: u32) Error!void {
    const raw = linux.connect(fd, @ptrCast(address), length);

    if (!ok(raw)) {
        return Error.Failed;
    }
}

pub fn getenv(key: []const u8) ?[]const u8 {
    assert(key.len > 0);

    load_environ();

    if (environ_length == 0) {
        return null;
    }

    var start: u32 = 0;
    var visited: u32 = 0;

    while (start < environ_length and visited < environ_entries_max) : (visited += 1) {
        const end = find_terminator(start);
        const entry = environ_storage[start..end];

        if (entry.len > key.len and entry[key.len] == '=') {
            if (std.mem.eql(u8, entry[0..key.len], key)) {
                return entry[key.len + 1 ..];
            }
        }

        start = end + 1;
    }

    return null;
}

fn find_terminator(start: u32) u32 {
    var index = start;

    while (index < environ_length) : (index += 1) {
        assert(index < environ_bytes_max);

        if (environ_storage[index] == 0) return index;
    }

    return environ_length;
}

fn load_environ() void {
    if (environ_loaded) {
        return;
    }

    environ_loaded = true;
    environ_length = 0;

    const path: [*:0]const u8 = environ_path;
    const raw = linux.open(path, .{}, 0);

    if (!ok(raw)) {
        return;
    }

    const fd: Fd = @intCast(raw);
    defer close(fd);

    var offset: u32 = 0;
    var attempts: u32 = 0;

    while (offset < environ_bytes_max and attempts < interrupt_retry_max) : (attempts += 1) {
        const count = read(fd, environ_storage[offset..]) catch break;

        if (count == 0) {
            break;
        }

        offset += @intCast(count);
    }

    environ_length = offset;

    assert(environ_length <= environ_bytes_max);
}

fn reset_environ() void {
    environ_loaded = false;
    environ_length = 0;

    assert(!environ_loaded);
}

const testing = std.testing;

test "ok distinguishes success from failure" {
    try testing.expect(ok(0));
    try testing.expect(!ok(@bitCast(@as(isize, -2))));
}

test "getenv finds a variable the kernel exported" {
    reset_environ();

    const path = getenv("PATH");
    const missing = getenv("GFDI_DEFINITELY_NOT_SET_1234");

    try testing.expect(missing == null);

    if (path) |value| {
        try testing.expect(value.len > 0);
    }
}

test "getenv rejects a prefix that is not a whole key" {
    reset_environ();

    const partial = getenv("PAT");

    try testing.expect(partial == null or partial.?.len > 0);
}

test "write_all reports failure on a closed descriptor" {
    const fd: Fd = -1;

    try testing.expectError(Error.Failed, write_all(fd, "x"));
}
