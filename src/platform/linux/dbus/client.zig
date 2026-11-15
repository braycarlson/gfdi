const std = @import("std");

const sys = @import("../sys.zig");
const wire = @import("wire.zig");

const assert = std.debug.assert;

const linux = std.os.linux;

const Client = @This();

socket_fd: ?sys.FD = null,
serial_next: u32 = 1,
unique_name: [name_bytes_max]u8 = undefined,
unique_name_length: u32 = 0,
send_buffer: [send_bytes_max]u8 = undefined,
receive_buffer: [receive_bytes_max]u8 = undefined,
receive_length: u32 = 0,
message_storage: [receive_bytes_max]u8 = undefined,
pending_storage: [pending_bytes_max]u8 = undefined,
pending_offsets: [pending_count_max]u32 = undefined,
pending_lengths: [pending_count_max]u32 = undefined,
error_name: [error_name_bytes_max]u8 = undefined,
error_name_length: u32 = 0,
pending_count: u16 = 0,
pending_dropped: u32 = 0,
pending_read: u16 = 0,
pending_used: u32 = 0,

pub const address_bytes_max: u32 = 256;
pub const name_bytes_max: u32 = 128;
pub const header_bytes_max: u32 = 1024;
pub const send_bytes_max: u32 = 272 * 1024;
pub const receive_bytes_max: u32 = 320 * 1024;
pub const authentication_bytes_max: u32 = 512;
pub const read_attempts_max: u32 = 4096;
pub const address_entries_max: u32 = 32;
pub const address_text_bytes_max: u32 = address_bytes_max * address_entries_max;
pub const reply_scan_max: u32 = 64;
pub const reply_timeout_ms: i32 = 5_000;
pub const pending_bytes_max: u32 = 256 * 1024;
pub const pending_count_max: u16 = 512;
pub const match_bytes_max: u32 = 512;
pub const error_name_bytes_max: u32 = 128;
pub const system_bus_variable = "DBUS_SYSTEM_BUS_ADDRESS";
pub const system_bus_fallback = "unix:path=/run/dbus/system_bus_socket";

pub const CapacityError = error{
    TooLarge,
};

pub const DaemonError = error{
    AuthenticationFailed,
    CallFailed,
    HelloFailed,
    MatchFailed,
    ReplyTimeout,
};

pub const SettingsError = error{
    AddressUnsupported,
};

pub const TransportError = error{
    ConnectFailed,
    NotConnected,
    ReceiveFailed,
    SendFailed,
};

pub const Error = CapacityError || DaemonError || SettingsError || TransportError;

pub const Wait = enum {
    blocking,
    immediate,
};

pub const Message = struct {
    body: []const u8,
    header: wire.Header,
};

pub const MessageTake = union(enum) {
    empty,
    message: Message,
};

pub const ReplyWait = union(enum) {
    exhausted,
    message: Message,
};

comptime {
    assert(address_bytes_max > 0);
    assert(header_bytes_max >= 256);
    assert(send_bytes_max > header_bytes_max);
    assert(send_bytes_max < receive_bytes_max);
    assert(authentication_bytes_max > 64);
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

pub fn connect(client: *Client) Error!void {
    if (client.socket_fd != null) {
        return;
    }

    var environ: sys.Environ = .{};
    const address = sys.getenv(&environ, system_bus_variable) orelse system_bus_fallback;
    const path = parse_unix_path(address) orelse return Error.AddressUnsupported;
    if (path.value.len == 0) return Error.AddressUnsupported;
    if (path.value.len >= address_bytes_max) return Error.AddressUnsupported;

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

    client.socket_fd = fd;
    client.serial_next = 1;
    client.receive_length = 0;
    client.unique_name_length = 0;
    client.pending_dropped = 0;

    client.clear_pending();

    client.hello() catch {
        client.socket_fd = null;

        return Error.HelloFailed;
    };
}

pub fn disconnect(client: *Client) void {
    const fd = client.socket_fd orelse return;

    assert(fd >= 0);

    sys.close(fd);

    client.socket_fd = null;
    client.receive_length = 0;
    client.unique_name_length = 0;

    client.clear_pending();
}

pub fn is_connected(client: *const Client) bool {
    if (client.socket_fd) |fd| assert(fd >= 0);

    return client.socket_fd != null;
}

pub fn descriptor(client: *const Client) ?sys.FD {
    if (client.socket_fd) |fd| assert(fd >= 0);

    return client.socket_fd;
}

pub fn name(client: *const Client) []const u8 {
    assert(client.unique_name_length <= name_bytes_max);

    if (client.socket_fd != null) assert(client.unique_name_length > 0);

    return client.unique_name[0..client.unique_name_length];
}

pub fn next_serial(client: *Client) u32 {
    const result = client.serial_next;

    client.serial_next +%= 1;

    if (client.serial_next == 0) {
        client.serial_next = 1;
    }

    assert(result > 0);

    return result;
}

pub fn send(client: *Client, body: []const u8, options: wire.MessageOptions) Error!u32 {
    assert(options.serial > 0);
    assert(options.kind.is_valid());

    const fd = client.socket_fd orelse return Error.NotConnected;

    if (body.len > send_bytes_max - header_bytes_max) {
        return Error.TooLarge;
    }

    var writer = wire.Writer.init(&client.send_buffer);

    wire.write_header(&writer, @intCast(body.len), options) catch {
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

pub const FrameParse = union(enum) {
    frame: Frame,
    partial,
};

pub fn parse_frame(buffer: []const u8) Error!FrameParse {
    assert(buffer.len <= receive_bytes_max);

    const peeked = wire.peek_length(buffer) catch {
        return Error.ReceiveFailed;
    };

    const length = switch (peeked) {
        .length => |length| length,
        .partial => return .partial,
    };

    if (length > buffer.len) {
        return .partial;
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

    return .{ .frame = result };
}

pub fn take_message(client: *Client) Error!MessageTake {
    if (client.socket_fd == null) {
        return Error.NotConnected;
    }

    const pending = try client.take_pending();

    if (pending == .message) {
        return pending;
    }

    const peeked = try parse_frame(client.receive_buffer[0..client.receive_length]);

    const frame = switch (peeked) {
        .frame => |frame| frame,
        .partial => return .empty,
    };

    assert(frame.total <= client.receive_length);

    @memcpy(client.message_storage[0..frame.total], client.receive_buffer[0..frame.total]);

    client.consume(frame.total);

    const stored = client.message_storage[0..frame.total];

    const header = wire.parse(stored) catch {
        return Error.ReceiveFailed;
    };

    const message = Message{
        .body = stored[frame.body_start..frame.total],
        .header = header,
    };

    return .{ .message = message };
}

pub fn has_pending(client: *const Client) bool {
    assert(client.pending_read <= client.pending_count);

    return client.pending_read < client.pending_count;
}

fn take_pending(client: *Client) Error!MessageTake {
    if (client.pending_read == client.pending_count) {
        return .empty;
    }

    assert(client.pending_read < client.pending_count);

    const offset = client.pending_offsets[client.pending_read];
    const length = client.pending_lengths[client.pending_read];

    client.pending_read += 1;

    if (client.pending_read == client.pending_count) {
        client.clear_pending();
    }

    assert(length <= receive_bytes_max);

    @memcpy(client.message_storage[0..length], client.pending_storage[offset .. offset + length]);

    const stored = client.message_storage[0..length];

    const header = wire.parse(stored) catch {
        return Error.ReceiveFailed;
    };

    assert(header.body_length < length);

    const message = Message{
        .body = stored[length - header.body_length .. length],
        .header = header,
    };

    return .{ .message = message };
}

pub fn pending_drops(client: *const Client) u32 {
    assert(client.pending_count <= pending_count_max);

    return client.pending_dropped;
}

fn stash_frame(client: *Client, frame_bytes: []const u8) void {
    assert(frame_bytes.len > 0);

    if (client.pending_count == pending_count_max) {
        client.pending_dropped += 1;

        return;
    }

    if (frame_bytes.len > pending_bytes_max - client.pending_used) {
        client.pending_dropped += 1;

        return;
    }

    const offset = client.pending_used;

    @memcpy(client.pending_storage[offset .. offset + frame_bytes.len], frame_bytes);

    client.pending_offsets[client.pending_count] = offset;
    client.pending_lengths[client.pending_count] = @intCast(frame_bytes.len);
    client.pending_used += @intCast(frame_bytes.len);
    client.pending_count += 1;

    assert(client.pending_count <= pending_count_max);
    assert(client.pending_used <= pending_bytes_max);
}

fn clear_pending(client: *Client) void {
    assert(client.pending_read <= client.pending_count);
    assert(client.pending_count <= pending_count_max);

    client.pending_count = 0;
    client.pending_read = 0;
    client.pending_used = 0;
}

pub fn fill(client: *Client, wait: Wait) Error!bool {
    const fd = client.socket_fd orelse return Error.NotConnected;

    if (client.receive_length >= receive_bytes_max) {
        return Error.ReceiveFailed;
    }

    const count = sys.read(fd, client.receive_buffer[client.receive_length..]) catch |err| {
        switch (wait) {
            .blocking => {},
            .immediate => if (err == sys.Error.WouldBlock) return false,
        }

        return Error.ReceiveFailed;
    };

    if (count == 0) {
        return Error.ReceiveFailed;
    }

    client.receive_length += @intCast(count);

    assert(client.receive_length <= receive_bytes_max);

    return true;
}

pub fn wait_for_reply(client: *Client, serial: u32) Error!ReplyWait {
    assert(serial > 0);

    const fd = client.socket_fd orelse return Error.NotConnected;

    var attempts: u32 = 0;

    while (attempts < read_attempts_max) : (attempts += 1) {
        var scanned: u32 = 0;

        while (scanned < reply_scan_max) : (scanned += 1) {
            const peeked = try parse_frame(client.receive_buffer[0..client.receive_length]);

            const frame = switch (peeked) {
                .frame => |frame| frame,
                .partial => break,
            };

            assert(frame.total <= client.receive_length);

            if (frame.header.reply_serial == serial) {
                @memcpy(
                    client.message_storage[0..frame.total],
                    client.receive_buffer[0..frame.total],
                );

                client.consume(frame.total);

                const stored = client.message_storage[0..frame.total];

                const header = wire.parse(stored) catch {
                    return Error.ReceiveFailed;
                };

                const message = Message{
                    .body = stored[frame.body_start..frame.total],
                    .header = header,
                };

                return .{ .message = message };
            }

            client.stash_frame(client.receive_buffer[0..frame.total]);
            client.consume(frame.total);
        }

        const ready = sys.poll_in(fd, reply_timeout_ms) catch {
            return Error.ReceiveFailed;
        };

        if (!ready) {
            return Error.ReplyTimeout;
        }

        _ = try client.fill(.blocking);
    }

    return .exhausted;
}

fn consume(client: *Client, length: u32) void {
    assert(length <= client.receive_length);

    const rest = client.receive_length - length;

    var index: u32 = 0;

    while (index < rest) : (index += 1) {
        assert(length + index < receive_bytes_max);

        client.receive_buffer[index] = client.receive_buffer[length + index];
    }

    client.receive_length = rest;

    assert(client.receive_length <= receive_bytes_max);
}

pub const Call = struct {
    destination: []const u8,
    interface: []const u8,
    member: []const u8,
    path: []const u8,
    signature: []const u8 = "",
};

pub fn error_name_last(client: *const Client) []const u8 {
    assert(client.error_name_length <= error_name_bytes_max);

    return client.error_name[0..client.error_name_length];
}

pub fn call(client: *Client, body: []const u8, request: Call) Error!Message {
    assert(body.len <= send_bytes_max);
    assert(request.member.len > 0);
    assert(request.path.len > 0);

    const serial = client.next_serial();

    _ = try client.send(body, .{
        .destination = request.destination,
        .interface = request.interface,
        .kind = .method_call,
        .member = request.member,
        .path = request.path,
        .serial = serial,
        .signature = request.signature,
    });

    const reply = switch (try client.wait_for_reply(serial)) {
        .exhausted => return Error.ReplyTimeout,
        .message => |message| message,
    };

    if (reply.header.kind != .method_return) {
        client.record_error(reply.header.error_name);

        return Error.CallFailed;
    }

    client.error_name_length = 0;

    return reply;
}

fn record_error(client: *Client, failure: []const u8) void {
    assert(failure.len <= wire.string_bytes_max);

    const length = @min(failure.len, error_name_bytes_max);

    @memcpy(client.error_name[0..length], failure[0..length]);

    client.error_name_length = @intCast(length);

    assert(client.error_name_length <= error_name_bytes_max);
}

pub fn add_match(client: *Client, rule: []const u8) Error!void {
    assert(rule.len > 0);

    var storage: [match_bytes_max]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    writer.put_string(rule) catch {
        return Error.TooLarge;
    };

    const serial = client.next_serial();

    _ = try client.send(writer.bytes(), .{
        .destination = "org.freedesktop.DBus",
        .interface = "org.freedesktop.DBus",
        .kind = .method_call,
        .member = "AddMatch",
        .path = "/org/freedesktop/DBus",
        .serial = serial,
        .signature = "s",
    });

    const reply = switch (try client.wait_for_reply(serial)) {
        .exhausted => return Error.MatchFailed,
        .message => |message| message,
    };

    if (reply.header.kind != .method_return) {
        return Error.MatchFailed;
    }
}

fn hello(client: *Client) Error!void {
    const serial = client.next_serial();

    _ = try client.send(&.{}, .{
        .destination = "org.freedesktop.DBus",
        .interface = "org.freedesktop.DBus",
        .kind = .method_call,
        .member = "Hello",
        .path = "/org/freedesktop/DBus",
        .serial = serial,
    });

    const reply = switch (try client.wait_for_reply(serial)) {
        .exhausted => return Error.HelloFailed,
        .message => |message| message,
    };

    if (reply.header.kind != .method_return) {
        return Error.HelloFailed;
    }

    var reader = wire.Reader.init(reply.body);

    const assigned = reader.take_string() catch {
        return Error.HelloFailed;
    };

    if (assigned.len == 0) {
        return Error.HelloFailed;
    }

    if (assigned.len >= name_bytes_max) {
        return Error.HelloFailed;
    }

    var index: u32 = 0;

    while (index < assigned.len) : (index += 1) {
        assert(index < name_bytes_max);

        client.unique_name[index] = assigned[index];
    }

    client.unique_name_length = @intCast(assigned.len);

    assert(client.unique_name_length > 0);
}

fn authenticate(fd: sys.FD) Error!void {
    assert(fd >= 0);

    var request: [authentication_bytes_max]u8 = undefined;

    const uid = linux.getuid();

    var digits: [16]u8 = undefined;

    const decimal = std.mem.print(&digits, "{d}", .{uid}) catch {
        return Error.AuthenticationFailed;
    };

    var hex: [32]u8 = undefined;

    if (decimal.len * 2 > hex.len) {
        return Error.AuthenticationFailed;
    }

    var index: u32 = 0;

    while (index < decimal.len) : (index += 1) {
        assert(index * 2 + 1 < hex.len);

        hex[index * 2] = to_hex(decimal[index] >> 4);
        hex[index * 2 + 1] = to_hex(decimal[index] & 0x0F);
    }

    const line = std.mem.print(
        &request,
        "\x00AUTH EXTERNAL {s}\r\n",
        .{hex[0 .. decimal.len * 2]},
    ) catch {
        return Error.AuthenticationFailed;
    };

    sys.write_all(fd, line) catch {
        return Error.AuthenticationFailed;
    };

    var response: [authentication_bytes_max]u8 = undefined;
    const reply = try read_line(fd, &response);

    if (!std.mem.startsWith(u8, reply, "OK")) {
        return Error.AuthenticationFailed;
    }

    sys.write_all(fd, "BEGIN\r\n") catch {
        return Error.AuthenticationFailed;
    };
}

fn read_line(fd: sys.FD, buffer: []u8) Error![]const u8 {
    assert(fd >= 0);
    assert(buffer.len > 2);

    var length: u32 = 0;
    var attempts: u32 = 0;

    while (attempts < read_attempts_max) : (attempts += 1) {
        if (length >= buffer.len) {
            return Error.AuthenticationFailed;
        }

        const count = sys.read(fd, buffer[length .. length + 1]) catch {
            return Error.AuthenticationFailed;
        };

        if (count == 0) {
            return Error.AuthenticationFailed;
        }

        length += 1;

        if (std.mem.endsWith(u8, buffer[0..length], "\r\n")) {
            return buffer[0 .. length - 2];
        }
    }

    return Error.AuthenticationFailed;
}

fn to_hex(value: u8) u8 {
    assert(value < 16);

    const result: u8 = if (value < 10) '0' + value else 'a' + (value - 10);

    assert(std.ascii.isHex(result));

    return result;
}

const UnixPath = struct {
    abstract: bool,
    value: []const u8,
};

pub fn parse_unix_path(address: []const u8) ?UnixPath {
    if (address.len > address_text_bytes_max) return null;

    var entries = std.mem.splitScalar(u8, address, ';');

    for (0..address_entries_max + 1) |visited| {
        const entry = entries.next() orelse break;

        if (visited == address_entries_max) {
            return null;
        }

        if (!std.mem.startsWith(u8, entry, "unix:")) {
            continue;
        }

        var options = std.mem.splitScalar(u8, entry["unix:".len..], ',');

        for (0..address_entries_max + 1) |scanned| {
            const option = options.next() orelse break;

            if (scanned == address_entries_max) {
                return null;
            }

            if (std.mem.startsWith(u8, option, "path=")) {
                return .{ .abstract = false, .value = option["path=".len..] };
            }

            if (std.mem.startsWith(u8, option, "abstract=")) {
                return .{ .abstract = true, .value = option["abstract=".len..] };
            }
        } else unreachable;
    } else unreachable;

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
    const client = try testing.allocator.create(Client);
    defer testing.allocator.destroy(client);

    client.* = .{};
    client.serial_next = 0xFFFFFFFF;

    _ = client.next_serial();

    try testing.expectEqual(@as(u32, 1), client.serial_next);
}

test "send without a connection is rejected" {
    const client = try testing.allocator.create(Client);
    defer testing.allocator.destroy(client);

    client.* = .{};

    const sent = client.send(&.{}, .{ .kind = .signal, .serial = 1 });

    try testing.expectError(Error.NotConnected, sent);
}

const Staged = struct {
    member: []const u8,
    offset: u32,
    path: []const u8,
    serial: u32,
};

fn stage_frame(client: *Client, staged: Staged) !u32 {
    assert(staged.serial > 0);
    assert(staged.offset < receive_bytes_max);

    var storage: [512]u8 = undefined;
    var writer = wire.Writer.init(&storage);

    try wire.write_header(&writer, 0, .{
        .kind = .method_call,
        .member = staged.member,
        .path = staged.path,
        .serial = staged.serial,
    });

    const length = writer.length;

    @memcpy(client.receive_buffer[staged.offset..][0..length], storage[0..length]);

    return length;
}

test "two coalesced messages survive their own dispatch" {
    const client = try testing.allocator.create(Client);
    defer testing.allocator.destroy(client);

    client.* = .{};
    client.socket_fd = -1;

    const first = try stage_frame(client, .{
        .member = "First",
        .offset = 0,
        .path = "/one",
        .serial = 1,
    });

    const second = try stage_frame(client, .{
        .member = "Second",
        .offset = first,
        .path = "/two",
        .serial = 2,
    });

    client.receive_length = first + second;

    const one = switch (try client.take_message()) {
        .empty => return error.MissingFirstMessage,
        .message => |message| message,
    };

    try testing.expectEqualStrings("First", one.header.member);
    try testing.expectEqualStrings("/one", one.header.path);
    try testing.expectEqual(@as(u32, second), client.receive_length);

    const two = switch (try client.take_message()) {
        .empty => return error.MissingSecondMessage,
        .message => |message| message,
    };

    try testing.expectEqualStrings("Second", two.header.member);
    try testing.expectEqualStrings("/two", two.header.path);
    try testing.expectEqual(@as(u32, 0), client.receive_length);

    const three = try client.take_message();

    try testing.expect(three == .empty);
}
