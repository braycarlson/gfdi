const std = @import("std");

const assert = std.debug.assert;

const linux = std.os.linux;
const posix = std.posix;

pub const FD = linux.fd_t;

pub const Error = error{
    Failed,
    Interrupted,
    WouldBlock,
};

pub const Environ = struct {
    length: u32 = 0,
    loaded: bool = false,
    storage: [environ_bytes_max]u8 = undefined,
};

pub const environ_bytes_max: u32 = 8 * 1024;
pub const environ_entries_max: u32 = 1024;
pub const environ_path = "/proc/self/environ";
pub const interrupt_retry_max: u32 = 64;
pub const write_attempts_max: u32 = 4096;
const errno_max: u64 = 4095;

comptime {
    assert(@import("builtin").target.ptrBitWidth() == 64);
    assert(environ_bytes_max > 0);
    assert(environ_entries_max > 0);
    assert(environ_path.len > 0);
    assert(interrupt_retry_max > 0);
    assert(write_attempts_max > 0);
}

pub fn ok(raw: u64) bool {
    return raw <= std.math.maxInt(u64) - errno_max;
}

pub fn close(fd: FD) void {
    assert(fd >= 0);

    _ = linux.close(fd);
}

pub fn read(fd: FD, buffer: []u8) Error!u32 {
    assert(fd >= 0);
    assert(buffer.len > 0);
    assert(buffer.len <= std.math.maxInt(u32));

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.read(fd, buffer.ptr, buffer.len);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            assert(raw <= buffer.len);

            return @intCast(raw);
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

pub fn write(fd: FD, bytes: []const u8) Error!u32 {
    assert(fd >= 0);
    assert(bytes.len > 0);
    assert(bytes.len <= std.math.maxInt(u32));

    var retries: u32 = 0;

    while (retries < interrupt_retry_max) : (retries += 1) {
        const raw = linux.write(fd, bytes.ptr, bytes.len);
        const status = posix.errno(raw);

        if (status == .SUCCESS) {
            assert(raw <= bytes.len);

            return @intCast(raw);
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

pub fn write_all(fd: FD, bytes: []const u8) Error!void {
    assert(fd >= 0);
    assert(bytes.len > 0);

    var written: u32 = 0;
    var attempts: u32 = 0;

    while (attempts < write_attempts_max) : (attempts += 1) {
        if (written >= bytes.len) break;

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

pub fn poll_in(fd: FD, timeout_ms: i32) Error!bool {
    assert(fd >= 0);
    assert(timeout_ms >= 0);

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

pub fn unix_socket() Error!FD {
    const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);

    if (!ok(raw)) {
        return Error.Failed;
    }

    return @intCast(raw);
}

pub fn connect(fd: FD, address: *const linux.sockaddr.un, length: u32) Error!void {
    assert(fd >= 0);
    assert(length <= @sizeOf(linux.sockaddr.un));

    const raw = linux.connect(fd, @ptrCast(address), length);

    if (!ok(raw)) {
        return Error.Failed;
    }
}

pub fn getenv(environ: *Environ, key: []const u8) ?[]const u8 {
    assert(key.len > 0);

    load_environ(environ);

    if (environ.length == 0) {
        return null;
    }

    var start: u32 = 0;
    var visited: u32 = 0;

    while (visited < environ_entries_max) : (visited += 1) {
        if (start >= environ.length) break;

        const end = find_terminator(environ, start);
        const entry = environ.storage[start..end];

        assert(end <= environ.length);

        if (std.mem.startsWith(u8, entry, key)) {
            const rest = entry[key.len..];

            if (std.mem.startsWith(u8, rest, "=")) {
                return rest[1..];
            }
        }

        start = end + 1;
    }

    return null;
}

fn find_terminator(environ: *const Environ, start: u32) u32 {
    assert(start < environ.length);
    assert(environ.length <= environ_bytes_max);

    var index = start;

    while (index < environ.length) : (index += 1) {
        assert(index < environ_bytes_max);

        if (environ.storage[index] == 0) return index;
    }

    return environ.length;
}

fn load_environ(environ: *Environ) void {
    if (environ.loaded) {
        return;
    }

    environ.loaded = true;
    environ.length = 0;

    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    const raw = linux.open(environ_path, flags, 0);

    if (!ok(raw)) {
        return;
    }

    const fd: FD = @intCast(raw);
    defer close(fd);

    var offset: u32 = 0;
    var attempts: u32 = 0;

    while (attempts < interrupt_retry_max) : (attempts += 1) {
        if (offset >= environ_bytes_max) break;

        const count = read(fd, environ.storage[offset..]) catch break;

        if (count == 0) {
            break;
        }

        offset += @intCast(count);

        assert(offset <= environ_bytes_max);
    }

    environ.length = offset;

    assert(environ.length <= environ_bytes_max);
}

const testing = std.testing;

test "ok distinguishes success from failure" {
    try testing.expect(ok(0));
    try testing.expect(!ok(@bitCast(@as(isize, -2))));
    try testing.expect(ok(std.math.maxInt(u64) - errno_max));
    try testing.expect(!ok(std.math.maxInt(u64) - errno_max + 1));
}

test "getenv finds a variable the kernel exported" {
    var environ: Environ = .{};
    const path = getenv(&environ, "PATH");
    const missing = getenv(&environ, "GFDI_DEFINITELY_NOT_SET_1234");

    try testing.expect(missing == null);

    if (path) |value| try testing.expect(value.len > 0);
}

test "getenv rejects a prefix that is not a whole key" {
    var environ: Environ = .{};
    const partial = getenv(&environ, "PAT");

    try testing.expect(partial == null or partial.?.len > 0);
}

test "write_all reports failure on a closed descriptor" {
    const fd = try unix_socket();

    try testing.expect(fd >= 0);

    close(fd);

    try testing.expectError(Error.Failed, write_all(fd, "x"));
}
