const std = @import("std");

const sys = @import("../sys.zig");
const wire = @import("wire.zig");

const assert = std.debug.assert;

const linux = std.os.linux;

pub const address_bytes_max: u32 = 256;
pub const name_bytes_max: u32 = 128;
pub const header_bytes_max: u32 = 1024;
pub const send_bytes_max: u32 = 272 * 1024;
pub const receive_bytes_max: u32 = 320 * 1024;
pub const auth_bytes_max: u32 = 512;
pub const read_attempts_max: u32 = 4096;
pub const address_entries_max: u32 = 32;
pub const reply_scan_max: u32 = 64;
pub const reply_timeout_ms: i32 = 5_000;
pub const pending_bytes_max: u32 = 256 * 1024;
pub const pending_count_max: u16 = 512;
pub const match_bytes_max: u32 = 512;
pub const error_name_bytes_max: u32 = 128;

pub const system_bus_variable = "DBUS_SYSTEM_BUS_ADDRESS";
pub const system_bus_fallback = "unix:path=/run/dbus/system_bus_socket";

pub const Error = error{
    AddressUnsupported,
    AuthFailed,
    CallFailed,
    ConnectFailed,
    HelloFailed,
    MatchFailed,
    NotConnected,
    ReceiveFailed,
    ReplyTimeout,
    SendFailed,
    TooLarge,
};

pub const Message = struct {
    body: []const u8,
    header: wire.Header,
};

comptime {
    assert(address_bytes_max > 0);
    assert(header_bytes_max >= 256);
    assert(send_bytes_max > header_bytes_max);
    assert(send_bytes_max < receive_bytes_max);
    assert(auth_bytes_max > 64);
    assert(read_attempts_max > 0);
    assert(address_entries_max > 0);
    assert(reply_scan_max > 0);
    assert(reply_timeout_ms > 0);
    assert(pending_bytes_max <= receive_bytes_max);
    assert(pending_count_max > 0);
    assert(match_bytes_max > 0);
    assert(error_name_bytes_max > 0);
    assert(system_bus_variable.len > 0);
    assert(std.mem.startsWith(u8, system_bus_fallback, "unix:path="));
}

var socket_fd: ?sys.Fd = null;
var serial_next: u32 = 1;
var unique_name: [name_bytes_max]u8 = undefined;
var unique_name_len: u32 = 0;

var send_buffer: [send_bytes_max]u8 = undefined;
var receive_buffer: [receive_bytes_max]u8 = undefined;
var receive_length: u32 = 0;
var message_storage: [receive_bytes_max]u8 = undefined;

var pending_storage: [pending_bytes_max]u8 = undefined;
var pending_offsets: [pending_count_max]u32 = undefined;
var pending_lengths: [pending_count_max]u32 = undefined;
var last_error: [error_name_bytes_max]u8 = undefined;
var last_error_len: u32 = 0;

var pending_count: u16 = 0;
var pending_dropped: u32 = 0;
var pending_read: u16 = 0;
var pending_used: u32 = 0;

pub fn connect() Error!void {
    if (socket_fd != null) {
        return;
    }

    const address = sys.getenv(system_bus_variable) orelse system_bus_fallback;
    const path = parse_unix_path(address) orelse return Error.AddressUnsupported;

    if (path.value.len == 0 or path.value.len >= address_bytes_max) {
        return Error.AddressUnsupported;
    }

    const fd = sys.unix_socket() catch {
        return Error.ConnectFailed;
    };

    errdefer sys.close(fd);

    var sockaddr = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = undefined };

    @memset(&sockaddr.path, 0);

    var offset: u32 = 0;

    if (path.abstract) {
        sockaddr.path[0] = 0;
        offset = 1;
    }

    if (offset + path.value.len >= sockaddr.path.len) {
        return Error.AddressUnsupported;
    }

    var index: u32 = 0;

    while (index < path.value.len) : (index += 1) {
        assert(offset + index < sockaddr.path.len);

        sockaddr.path[offset + index] = path.value[index];
    }

    const length: u32 = @intCast(@offsetOf(linux.sockaddr.un, "path") +
        offset + path.value.len + @intFromBool(!path.abstract));

    sys.connect(fd, &sockaddr, length) catch {
        return Error.ConnectFailed;
    };

    try authenticate(fd);

    socket_fd = fd;
    serial_next = 1;
    receive_length = 0;
    unique_name_len = 0;
    pending_dropped = 0;

    clear_pending();

    hello() catch {
        socket_fd = null;

        return Error.HelloFailed;
    };

    assert(socket_fd != null);
}

pub fn disconnect() void {
    const fd = socket_fd orelse return;

    sys.close(fd);

    socket_fd = null;
    receive_length = 0;
    unique_name_len = 0;

    clear_pending();

    assert(socket_fd == null);
}

pub fn is_connected() bool {
    return socket_fd != null;
}

pub fn descriptor() ?sys.Fd {
    return socket_fd;
}

pub fn name() []const u8 {
    assert(unique_name_len <= name_bytes_max);

    return unique_name[0..unique_name_len];
}

pub fn next_serial() u32 {
    const result = serial_next;

    serial_next +%= 1;

    if (serial_next == 0) {
        serial_next = 1;
    }

    assert(result > 0);

    return result;
}

pub fn send(options: wire.MessageOptions, body: []const u8) Error!u32 {
    const fd = socket_fd orelse return Error.NotConnected;

    if (body.len > send_bytes_max - header_bytes_max) {
        return Error.TooLarge;
    }

    var writer = wire.Writer.init(&send_buffer);

    wire.write_header(&writer, options, @intCast(body.len)) catch {
        return Error.TooLarge;
    };

    writer.put_slice(body) catch {
        return Error.TooLarge;
    };

    sys.write_all(fd, writer.bytes()) catch {
        return Error.SendFailed;
    };

    return options.serial;
}

pub const Frame = struct {
    body_start: u32,
    header: wire.Header,
    total: u32,
};

pub fn parse_frame(buffer: []const u8) Error!?Frame {
    assert(buffer.len <= receive_bytes_max);

    const total = wire.peek_length(buffer) catch {
        return Error.ReceiveFailed;
    };

    const length = total orelse return null;

    if (length > buffer.len) {
        return null;
    }

    const header = wire.parse(buffer[0..length]) catch {
        return Error.ReceiveFailed;
    };

    if (header.body_length >= length) {
        return Error.ReceiveFailed;
    }

    const result = Frame{
        .body_start = length - header.body_length,
        .header = header,
        .total = length,
    };

    assert(result.body_start <= result.total);
    assert(result.total >= wire.header_bytes_min);

    return result;
}

pub fn take_message() Error!?Message {
    if (socket_fd == null) {
        return Error.NotConnected;
    }

    if (try take_pending()) |message| {
        return message;
    }

    const peeked = try parse_frame(receive_buffer[0..receive_length]);
    const frame = peeked orelse return null;

    assert(frame.total <= receive_length);

    @memcpy(message_storage[0..frame.total], receive_buffer[0..frame.total]);

    consume(frame.total);

    const stored = message_storage[0..frame.total];

    const header = wire.parse(stored) catch {
        return Error.ReceiveFailed;
    };

    const message = Message{
        .body = stored[frame.body_start..frame.total],
        .header = header,
    };

    return message;
}

pub fn has_pending() bool {
    return pending_read < pending_count;
}

fn take_pending() Error!?Message {
    if (pending_read == pending_count) {
        return null;
    }

    assert(pending_read < pending_count);

    const offset = pending_offsets[pending_read];
    const length = pending_lengths[pending_read];

    pending_read += 1;

    if (pending_read == pending_count) {
        clear_pending();
    }

    assert(length <= receive_bytes_max);

    @memcpy(message_storage[0..length], pending_storage[offset .. offset + length]);

    const stored = message_storage[0..length];

    const header = wire.parse(stored) catch {
        return Error.ReceiveFailed;
    };

    assert(header.body_length < length);

    const message = Message{
        .body = stored[length - header.body_length .. length],
        .header = header,
    };

    return message;
}

pub fn pending_drops() u32 {
    return pending_dropped;
}

fn stash_frame(frame_bytes: []const u8) void {
    assert(frame_bytes.len > 0);

    if (pending_count == pending_count_max) {
        pending_dropped += 1;

        return;
    }

    if (frame_bytes.len > pending_bytes_max - pending_used) {
        pending_dropped += 1;

        return;
    }

    const offset = pending_used;

    @memcpy(pending_storage[offset .. offset + frame_bytes.len], frame_bytes);

    pending_offsets[pending_count] = offset;
    pending_lengths[pending_count] = @intCast(frame_bytes.len);
    pending_used += @intCast(frame_bytes.len);
    pending_count += 1;

    assert(pending_count <= pending_count_max);
    assert(pending_used <= pending_bytes_max);
}

fn clear_pending() void {
    pending_count = 0;
    pending_read = 0;
    pending_used = 0;

    assert(pending_read == pending_count);
    assert(pending_used == 0);
}

pub fn fill(blocking: bool) Error!bool {
    const fd = socket_fd orelse return Error.NotConnected;

    if (receive_length >= receive_bytes_max) {
        return Error.ReceiveFailed;
    }

    const count = sys.read(fd, receive_buffer[receive_length..]) catch |err| {
        if (!blocking and err == sys.Error.WouldBlock) {
            return false;
        }

        return Error.ReceiveFailed;
    };

    if (count == 0) {
        return Error.ReceiveFailed;
    }

    receive_length += @intCast(count);

    assert(receive_length <= receive_bytes_max);

    return true;
}

pub fn wait_for_reply(serial: u32) Error!?Message {
    assert(serial > 0);

    const fd = socket_fd orelse return Error.NotConnected;

    var attempts: u32 = 0;

    while (attempts < read_attempts_max) : (attempts += 1) {
        var scanned: u32 = 0;

        while (scanned < reply_scan_max) : (scanned += 1) {
            const peeked = try parse_frame(receive_buffer[0..receive_length]);
            const frame = peeked orelse break;

            assert(frame.total <= receive_length);

            if (frame.header.reply_serial == serial) {
                @memcpy(message_storage[0..frame.total], receive_buffer[0..frame.total]);

                consume(frame.total);

                const stored = message_storage[0..frame.total];

                const header = wire.parse(stored) catch {
                    return Error.ReceiveFailed;
                };

                const message = Message{
                    .body = stored[frame.body_start..frame.total],
                    .header = header,
                };

                return message;
            }

            stash_frame(receive_buffer[0..frame.total]);
            consume(frame.total);
        }

        const ready = sys.poll_in(fd, reply_timeout_ms) catch {
            return Error.ReceiveFailed;
        };

        if (!ready) {
            return Error.ReplyTimeout;
        }

        _ = try fill(true);
    }

    return null;
}

fn consume(length: u32) void {
    assert(length <= receive_length);

    const rest = receive_length - length;

    var index: u32 = 0;

    while (index < rest) : (index += 1) {
        assert(length + index < receive_bytes_max);

        receive_buffer[index] = receive_buffer[length + index];
    }

    receive_length = rest;

    assert(receive_length <= receive_bytes_max);
}

pub const Call = struct {
    destination: []const u8,
    interface: []const u8,
    member: []const u8,
    path: []const u8,
    signature: []const u8 = "",
};

pub fn last_error_name() []const u8 {
    assert(last_error_len <= error_name_bytes_max);

    return last_error[0..last_error_len];
}

pub fn call(request: Call, body: []const u8) Error!Message {
    assert(request.member.len > 0);
    assert(request.path.len > 0);

    const serial = next_serial();

    _ = try send(.{
        .destination = request.destination,
        .interface = request.interface,
        .kind = .method_call,
        .member = request.member,
        .path = request.path,
        .serial = serial,
        .signature = request.signature,
    }, body);

    const reply = (try wait_for_reply(serial)) orelse return Error.ReplyTimeout;

    if (reply.header.kind != .method_return) {
        record_error(reply.header.error_name);

        return Error.CallFailed;
    }

    last_error_len = 0;

    return reply;
}

fn record_error(failure: []const u8) void {
    const length = @min(failure.len, error_name_bytes_max);

    @memcpy(last_error[0..length], failure[0..length]);

    last_error_len = @intCast(length);

    assert(last_error_len <= error_name_bytes_max);
}

pub fn add_match(rule: []const u8) Error!void {
    assert(rule.len > 0);

    var storage: [match_bytes_max]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    writer.put_string(rule) catch {
        return Error.TooLarge;
    };

    const serial = next_serial();

    _ = try send(.{
        .destination = "org.freedesktop.DBus",
        .interface = "org.freedesktop.DBus",
        .kind = .method_call,
        .member = "AddMatch",
        .path = "/org/freedesktop/DBus",
        .serial = serial,
        .signature = "s",
    }, writer.bytes());

    const reply = (try wait_for_reply(serial)) orelse return Error.MatchFailed;

    if (reply.header.kind != .method_return) {
        return Error.MatchFailed;
    }
}

fn hello() Error!void {
    const serial = next_serial();

    _ = try send(.{
        .destination = "org.freedesktop.DBus",
        .interface = "org.freedesktop.DBus",
        .kind = .method_call,
        .member = "Hello",
        .path = "/org/freedesktop/DBus",
        .serial = serial,
    }, &.{});

    const reply = (try wait_for_reply(serial)) orelse return Error.HelloFailed;

    if (reply.header.kind != .method_return) {
        return Error.HelloFailed;
    }

    var reader = wire.Reader.init(reply.body);

    const assigned = reader.take_string() catch {
        return Error.HelloFailed;
    };

    if (assigned.len == 0 or assigned.len >= name_bytes_max) {
        return Error.HelloFailed;
    }

    var index: u32 = 0;

    while (index < assigned.len) : (index += 1) {
        assert(index < name_bytes_max);

        unique_name[index] = assigned[index];
    }

    unique_name_len = @intCast(assigned.len);

    assert(unique_name_len > 0);
}

fn authenticate(fd: sys.Fd) Error!void {
    var request: [auth_bytes_max]u8 = undefined;

    const uid = linux.getuid();

    var digits: [16]u8 = undefined;

    const decimal = std.fmt.bufPrint(&digits, "{d}", .{uid}) catch {
        return Error.AuthFailed;
    };

    var hex: [32]u8 = undefined;

    if (decimal.len * 2 > hex.len) {
        return Error.AuthFailed;
    }

    var index: u32 = 0;

    while (index < decimal.len) : (index += 1) {
        assert(index * 2 + 1 < hex.len);

        hex[index * 2] = to_hex(decimal[index] >> 4);
        hex[index * 2 + 1] = to_hex(decimal[index] & 0x0F);
    }

    const line = std.fmt.bufPrint(
        &request,
        "\x00AUTH EXTERNAL {s}\r\n",
        .{hex[0 .. decimal.len * 2]},
    ) catch {
        return Error.AuthFailed;
    };

    sys.write_all(fd, line) catch {
        return Error.AuthFailed;
    };

    var response: [auth_bytes_max]u8 = undefined;
    const reply = try read_line(fd, &response);

    if (!std.mem.startsWith(u8, reply, "OK")) {
        return Error.AuthFailed;
    }

    sys.write_all(fd, "BEGIN\r\n") catch {
        return Error.AuthFailed;
    };
}

fn read_line(fd: sys.Fd, buffer: []u8) Error![]const u8 {
    var length: u32 = 0;
    var attempts: u32 = 0;

    while (attempts < read_attempts_max) : (attempts += 1) {
        if (length >= buffer.len) {
            return Error.AuthFailed;
        }

        const count = sys.read(fd, buffer[length .. length + 1]) catch {
            return Error.AuthFailed;
        };

        if (count == 0) {
            return Error.AuthFailed;
        }

        length += 1;

        if (length >= 2 and buffer[length - 2] == '\r' and buffer[length - 1] == '\n') {
            return buffer[0 .. length - 2];
        }
    }

    return Error.AuthFailed;
}

fn to_hex(value: u8) u8 {
    assert(value < 16);

    const result: u8 = if (value < 10) '0' + value else 'a' + (value - 10);

    return result;
}

const UnixPath = struct {
    abstract: bool,
    value: []const u8,
};

pub fn parse_unix_path(address: []const u8) ?UnixPath {
    var entries = std.mem.splitScalar(u8, address, ';');
    var visited: u32 = 0;

    while (entries.next()) |entry| {
        if (visited >= address_entries_max) {
            return null;
        }

        visited += 1;

        if (!std.mem.startsWith(u8, entry, "unix:")) {
            continue;
        }

        var options = std.mem.splitScalar(u8, entry["unix:".len..], ',');
        var scanned: u32 = 0;

        while (options.next()) |option| {
            if (scanned >= address_entries_max) {
                return null;
            }

            scanned += 1;

            if (std.mem.startsWith(u8, option, "path=")) {
                return .{ .abstract = false, .value = option["path=".len..] };
            }

            if (std.mem.startsWith(u8, option, "abstract=")) {
                return .{ .abstract = true, .value = option["abstract=".len..] };
            }
        }
    }

    return null;
}

const testing = std.testing;

test "parse_unix_path reads a filesystem socket" {
    const parsed = parse_unix_path("unix:path=/run/user/1000/bus");

    try testing.expect(parsed != null);
    try testing.expect(!parsed.?.abstract);
    try testing.expectEqualStrings("/run/user/1000/bus", parsed.?.value);
}

test "parse_unix_path reads an abstract socket" {
    const parsed = parse_unix_path("unix:abstract=/tmp/dbus-abc,guid=deadbeef");

    try testing.expect(parsed != null);
    try testing.expect(parsed.?.abstract);
    try testing.expectEqualStrings("/tmp/dbus-abc", parsed.?.value);
}

test "parse_unix_path skips a non unix transport" {
    try testing.expect(parse_unix_path("tcp:host=localhost,port=1234") == null);
}

test "parse_unix_path scans every semicolon separated entry" {
    const parsed = parse_unix_path("tcp:host=x;unix:path=/run/bus");

    try testing.expect(parsed != null);
    try testing.expectEqualStrings("/run/bus", parsed.?.value);
}

test "to_hex covers the whole nibble range" {
    try testing.expectEqual(@as(u8, '0'), to_hex(0));
    try testing.expectEqual(@as(u8, '9'), to_hex(9));
    try testing.expectEqual(@as(u8, 'a'), to_hex(10));
    try testing.expectEqual(@as(u8, 'f'), to_hex(15));
}

test "next_serial never hands out zero" {
    const saved = serial_next;

    serial_next = 0xFFFFFFFF;

    _ = next_serial();

    try testing.expectEqual(@as(u32, 1), serial_next);

    serial_next = saved;
}

test "send without a connection is rejected" {
    if (is_connected()) {
        return;
    }

    try testing.expectError(Error.NotConnected, send(.{ .kind = .signal, .serial = 1 }, &.{}));
}

fn stage_frame(offset: u32, member: []const u8, path: []const u8, serial: u32) !u32 {
    var storage: [512]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    try wire.write_header(&writer, .{
        .kind = .method_call,
        .member = member,
        .path = path,
        .serial = serial,
    }, 0);

    const length = writer.length;

    @memcpy(receive_buffer[offset .. offset + length], storage[0..length]);

    return length;
}

test "two coalesced messages survive their own dispatch" {
    if (is_connected()) {
        return;
    }

    const saved_length = receive_length;

    socket_fd = -1;
    defer {
        socket_fd = null;
        receive_length = saved_length;
    }

    const first = try stage_frame(0, "First", "/one", 1);
    const second = try stage_frame(first, "Second", "/two", 2);

    receive_length = first + second;

    const one = (try take_message()) orelse return error.MissingFirstMessage;

    try testing.expectEqualStrings("First", one.header.member);
    try testing.expectEqualStrings("/one", one.header.path);
    try testing.expectEqual(@as(u32, second), receive_length);

    const two = (try take_message()) orelse return error.MissingSecondMessage;

    try testing.expectEqualStrings("Second", two.header.member);
    try testing.expectEqualStrings("/two", two.header.path);
    try testing.expectEqual(@as(u32, 0), receive_length);
    try testing.expect((try take_message()) == null);
}
