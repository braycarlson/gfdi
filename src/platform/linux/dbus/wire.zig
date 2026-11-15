const std = @import("std");

const assert = std.debug.assert;

pub const protocol_version: u8 = 1;
pub const endian_little: u8 = 'l';
pub const endian_big: u8 = 'B';
pub const header_bytes_min: u32 = 16;
pub const body_bytes_max: u32 = 1 << 20;
pub const array_bytes_max: u32 = 1 << 26;
pub const string_bytes_max: u32 = 1 << 16;
pub const signature_bytes_max: u8 = 255;
pub const nesting_max: u8 = 32;
pub const receive_bytes_limit: u32 = 1 << 20;
pub const field_count_max: u8 = 16;
pub const code_byte: u8 = 'y';
pub const code_string: u8 = 's';
pub const code_dictionary_entry: u8 = '{';
pub const code_struct: u8 = '(';
pub const code_variant: u8 = 'v';

pub const CapacityError = error{
    Overflow,
};

pub const MessageError = error{
    Malformed,
    Truncated,
    UnsupportedEndian,
};

pub const Error = CapacityError || MessageError;

pub const Kind = enum(u8) {
    invalid = 0,
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,

    pub fn is_valid(kind: Kind) bool {
        comptime assert(@backingInt(Kind.invalid) == 0);
        comptime assert(@backingInt(Kind.signal) == 4);

        return @backingInt(kind) <= @backingInt(Kind.signal);
    }
};

pub const Field = enum(u8) {
    invalid = 0,
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
};

pub const Flags = struct {
    no_auto_start: bool = false,
    no_reply_expected: bool = false,

    pub fn to_uint(flags: Flags) u8 {
        var result: u8 = 0;

        if (flags.no_reply_expected) result |= 0x01;
        if (flags.no_auto_start) result |= 0x02;

        assert(result <= 0x03);
        assert((result & 0x01 != 0) == flags.no_reply_expected);

        return result;
    }
};

comptime {
    assert(header_bytes_min == 16);
    assert(body_bytes_max <= array_bytes_max);
    assert(string_bytes_max <= body_bytes_max);
    assert(nesting_max > 0);
    assert(receive_bytes_limit >= body_bytes_max);
    assert(field_count_max > 0);
    assert(@typeInfo(Kind).@"enum".field_names.len == 5);
    assert(@typeInfo(Field).@"enum".field_names.len == 10);
    assert(align_of(code_byte) == 1);
    assert(align_of(code_string) == 4);
    assert(align_of(code_variant) == 1);
    assert(align_of(code_dictionary_entry) == 8);
    assert(align_of(code_struct) == 8);
}

pub fn align_of(code: u8) u8 {
    comptime assert(code_struct == '(');

    const result: u8 = switch (code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'a' => 4,
        'x', 't', 'd', '(', '{', 'h' => 8,
        's', 'o' => 4,
        else => 1,
    };

    assert(result == 1 or result == 2 or result == 4 or result == 8);

    return result;
}

pub fn align_up(value: u32, alignment: u8) u32 {
    assert(alignment_valid(alignment));
    assert(value <= std.math.maxInt(u32) - 8);

    const mask: u32 = alignment - 1;
    const result = (value + mask) & ~mask;

    assert(result >= value);
    assert(result % alignment == 0);

    return result;
}

fn alignment_valid(alignment: u8) bool {
    return alignment == 1 or alignment == 2 or alignment == 4 or alignment == 8;
}

pub const ArrayMarker = struct {
    offset: u32,
    start: u32,
};

pub const Writer = struct {
    buffer: []u8,
    length: u32,

    pub fn init(buffer: []u8) Writer {
        assert(buffer.len > 0);

        const result = Writer{
            .buffer = buffer,
            .length = 0,
        };

        assert(result.length == 0);

        return result;
    }

    pub fn bytes(writer: *const Writer) []const u8 {
        assert(writer.buffer.len > 0);
        assert(writer.length <= writer.buffer.len);

        return writer.buffer[0..writer.length];
    }

    pub fn reset(writer: *Writer) void {
        assert(writer.length <= writer.buffer.len);

        writer.length = 0;
    }

    pub fn pad_to(writer: *Writer, alignment: u8) CapacityError!void {
        assert(alignment_valid(alignment));
        assert(writer.length <= writer.buffer.len);

        const target = align_up(writer.length, alignment);

        if (target > writer.buffer.len) return error.Overflow;

        @memset(writer.buffer[writer.length..target], 0);

        writer.length = target;

        assert(writer.length % alignment == 0);
    }

    pub fn put_byte(writer: *Writer, value: u8) CapacityError!void {
        assert(writer.length <= writer.buffer.len);
        assert(writer.buffer.len > 0);

        if (writer.length >= writer.buffer.len) {
            return error.Overflow;
        }

        writer.buffer[writer.length] = value;
        writer.length += 1;
    }

    pub fn put_bool(writer: *Writer, value: bool) CapacityError!void {
        assert(writer.length <= writer.buffer.len);
        assert(writer.buffer.len > 0);

        const encoded: u32 = if (value) 1 else 0;

        try writer.put_u32(encoded);
    }

    pub fn put_i32(writer: *Writer, value: i32) CapacityError!void {
        assert(writer.length <= writer.buffer.len);
        assert(writer.buffer.len > 0);

        try writer.put_raw(i32, value);
    }

    pub fn put_u32(writer: *Writer, value: u32) CapacityError!void {
        assert(writer.length <= writer.buffer.len);
        assert(writer.buffer.len > 0);

        try writer.put_raw(u32, value);
    }

    pub fn put_u64(writer: *Writer, value: u64) CapacityError!void {
        assert(writer.length <= writer.buffer.len);
        assert(writer.buffer.len > 0);

        try writer.put_raw(u64, value);
    }

    pub fn put_string(writer: *Writer, value: []const u8) CapacityError!void {
        assert(writer.length <= writer.buffer.len);
        assert(writer.buffer.len > 0);

        if (value.len > string_bytes_max) {
            return error.Overflow;
        }

        try writer.put_u32(@intCast(value.len));
        try writer.put_slice(value);
        try writer.put_byte(0);
    }

    pub fn put_signature(writer: *Writer, value: []const u8) CapacityError!void {
        assert(writer.length <= writer.buffer.len);
        assert(writer.buffer.len > 0);

        if (value.len > signature_bytes_max) {
            return error.Overflow;
        }

        try writer.put_byte(@intCast(value.len));
        try writer.put_slice(value);
        try writer.put_byte(0);
    }

    pub fn put_slice(writer: *Writer, source: []const u8) CapacityError!void {
        if (source.len > writer.buffer.len - writer.length) return error.Overflow;

        assert(writer.length <= writer.buffer.len);

        @memcpy(writer.buffer[writer.length..][0..source.len], source);

        writer.length += @intCast(source.len);

        assert(writer.length <= writer.buffer.len);
    }

    pub fn open_array(writer: *Writer, element_alignment: u8) CapacityError!ArrayMarker {
        assert(alignment_valid(element_alignment));
        assert(writer.length <= writer.buffer.len);

        try writer.pad_to(4);

        const offset = writer.length;

        try writer.put_u32(0);
        try writer.pad_to(element_alignment);

        const result = ArrayMarker{ .offset = offset, .start = writer.length };

        assert(result.start >= result.offset + 4);

        return result;
    }

    pub fn close_array(writer: *Writer, marker: ArrayMarker) CapacityError!void {
        assert(marker.offset + 4 <= marker.start);
        assert(marker.start <= writer.length);

        const size = writer.length - marker.start;

        if (size > array_bytes_max) {
            return error.Overflow;
        }

        std.mem.writeInt(u32, writer.buffer[marker.offset..][0..4], size, .little);
    }

    fn put_raw(writer: *Writer, comptime T: type, value: T) CapacityError!void {
        assert(writer.length <= writer.buffer.len);
        assert(writer.buffer.len > 0);

        const size = @sizeOf(T);

        try writer.pad_to(size);

        if (writer.length + size > writer.buffer.len) {
            return error.Overflow;
        }

        std.mem.writeInt(T, writer.buffer[writer.length..][0..size], value, .little);

        writer.length += size;
    }
};

pub const Reader = struct {
    buffer: []const u8,
    offset: u32,

    pub fn init(buffer: []const u8) Reader {
        assert(buffer.len <= std.math.maxInt(u32));

        const result = Reader{
            .buffer = buffer,
            .offset = 0,
        };

        assert(result.offset == 0);

        return result;
    }

    pub fn remaining(reader: *const Reader) u32 {
        assert(reader.offset <= reader.buffer.len);

        const result: u32 = @intCast(reader.buffer.len - reader.offset);

        assert(result <= reader.buffer.len);

        return result;
    }

    pub fn skip_to(reader: *Reader, alignment: u8) MessageError!void {
        assert(alignment_valid(alignment));
        assert(reader.offset <= reader.buffer.len);

        const target = align_up(reader.offset, alignment);

        if (target > reader.buffer.len) {
            return error.Truncated;
        }

        reader.offset = target;

        assert(reader.offset % alignment == 0);
    }

    pub fn take_byte(reader: *Reader) MessageError!u8 {
        assert(reader.buffer.len <= receive_bytes_limit);
        assert(reader.offset <= reader.buffer.len);

        if (reader.offset >= reader.buffer.len) {
            return error.Truncated;
        }

        const result = reader.buffer[reader.offset];

        reader.offset += 1;

        return result;
    }

    pub fn take_u16(reader: *Reader) MessageError!u16 {
        assert(reader.buffer.len <= receive_bytes_limit);
        assert(reader.offset <= reader.buffer.len);

        return try reader.take_raw(u16);
    }

    pub fn take_u32(reader: *Reader) MessageError!u32 {
        assert(reader.buffer.len <= receive_bytes_limit);
        assert(reader.offset <= reader.buffer.len);

        return try reader.take_raw(u32);
    }

    pub fn take_i32(reader: *Reader) MessageError!i32 {
        assert(reader.offset <= reader.buffer.len);
        assert(reader.buffer.len <= receive_bytes_limit);

        return try reader.take_raw(i32);
    }

    pub fn take_u64(reader: *Reader) MessageError!u64 {
        assert(reader.offset <= reader.buffer.len);
        assert(reader.buffer.len <= receive_bytes_limit);

        return try reader.take_raw(u64);
    }

    pub fn take_string(reader: *Reader) MessageError![]const u8 {
        assert(reader.offset <= reader.buffer.len);

        const length = try reader.take_u32();

        if (length > string_bytes_max) {
            return error.Malformed;
        }

        if (reader.offset + length + 1 > reader.buffer.len) {
            return error.Truncated;
        }

        const result = reader.buffer[reader.offset..][0..length];

        reader.offset += length + 1;

        assert(reader.offset <= reader.buffer.len);

        return result;
    }

    pub fn take_signature(reader: *Reader) MessageError![]const u8 {
        assert(reader.offset <= reader.buffer.len);

        const length = try reader.take_byte();

        if (reader.offset + length + 1 > reader.buffer.len) {
            return error.Truncated;
        }

        const result = reader.buffer[reader.offset..][0..length];

        reader.offset += @as(u32, length) + 1;

        assert(reader.offset <= reader.buffer.len);
        assert(result.len <= signature_bytes_max);

        return result;
    }

    fn take_raw(reader: *Reader, comptime T: type) MessageError!T {
        assert(reader.offset <= reader.buffer.len);
        assert(reader.buffer.len <= receive_bytes_limit);

        const size = @sizeOf(T);

        try reader.skip_to(size);

        if (reader.offset + size > reader.buffer.len) {
            return error.Truncated;
        }

        const result = std.mem.readInt(T, reader.buffer[reader.offset..][0..size], .little);

        reader.offset += size;

        return result;
    }
};

pub const Header = struct {
    body_length: u32,
    destination: []const u8,
    error_name: []const u8,
    fields_length: u32,
    interface: []const u8,
    kind: Kind,
    length_total: u32,
    member: []const u8,
    path: []const u8,
    reply_serial: u32,
    sender: []const u8,
    serial: u32,
    signature: []const u8,

    pub fn empty() Header {
        comptime assert(header_bytes_min > 0);

        const result = Header{
            .body_length = 0,
            .destination = "",
            .error_name = "",
            .fields_length = 0,
            .interface = "",
            .kind = .invalid,
            .length_total = 0,
            .member = "",
            .path = "",
            .reply_serial = 0,
            .sender = "",
            .serial = 0,
            .signature = "",
        };

        assert(result.kind == .invalid);

        return result;
    }
};

pub const LengthPeek = union(enum) {
    length: u32,
    partial,
};

pub fn peek_length(buffer: []const u8) MessageError!LengthPeek {
    assert(buffer.len <= receive_bytes_limit);

    if (buffer.len < header_bytes_min) {
        return .partial;
    }

    if (buffer[0] != endian_little) {
        return error.UnsupportedEndian;
    }

    if (buffer[3] != protocol_version) {
        return error.Malformed;
    }

    const body_length = std.mem.readInt(u32, buffer[4..8], .little);
    const fields_length = std.mem.readInt(u32, buffer[12..16], .little);

    if (body_length > body_bytes_max) {
        return error.Malformed;
    }

    if (fields_length > array_bytes_max) {
        return error.Malformed;
    }

    const header_end = align_up(header_bytes_min + fields_length, 8);
    const total = header_end + body_length;

    assert(total >= header_end);

    return .{ .length = total };
}

pub fn parse(buffer: []const u8) MessageError!Header {
    comptime assert(receive_bytes_limit <= std.math.maxInt(u32));
    assert(buffer.len <= receive_bytes_limit);

    const total = switch (try peek_length(buffer)) {
        .length => |length| length,
        .partial => return error.Truncated,
    };

    if (buffer.len < total) {
        return error.Truncated;
    }

    var reader = Reader.init(buffer);
    var header = Header.empty();

    try take_header_fixed(&reader, &header, total);

    if (header.fields_length > buffer.len - reader.offset) return error.Truncated;

    const fields_end = reader.offset + header.fields_length;

    try take_header_fields(&reader, &header, fields_end);

    return header;
}

fn take_header_fixed(reader: *Reader, header: *Header, total: u32) MessageError!void {
    assert(total >= header_bytes_min);
    assert(reader.offset == 0);

    const endian = try reader.take_byte();

    if (endian != endian_little) {
        return error.UnsupportedEndian;
    }

    const raw_kind = try reader.take_byte();

    if (raw_kind > @backingInt(Kind.signal)) {
        return error.Malformed;
    }

    header.kind = @fromBackingInt(raw_kind);

    _ = try reader.take_byte();

    const version = try reader.take_byte();

    if (version != protocol_version) {
        return error.Malformed;
    }

    header.body_length = try reader.take_u32();
    header.serial = try reader.take_u32();
    header.fields_length = try reader.take_u32();
    header.length_total = total;
}

fn take_header_fields(reader: *Reader, header: *Header, fields_end: u32) MessageError!void {
    assert(fields_end <= reader.buffer.len);
    assert(reader.offset <= fields_end);

    var visited: u8 = 0;

    while (reader.offset < fields_end) {
        if (visited >= field_count_max) {
            return error.Malformed;
        }

        visited += 1;

        try reader.skip_to(8);

        if (reader.offset >= fields_end) {
            break;
        }

        const code = try reader.take_byte();
        const signature = try reader.take_signature();

        if (signature.len != 1) {
            return error.Malformed;
        }

        try take_field(reader, header, code, signature);
    }

    if (reader.offset > fields_end) {
        return error.Malformed;
    }
}

fn take_field(reader: *Reader, header: *Header, code: u8, signature: []const u8) MessageError!void {
    assert(signature.len == 1);
    assert(reader.offset <= reader.buffer.len);

    switch (signature[0]) {
        's', 'o' => {
            const value = try reader.take_string();

            store_string(header, code, value);
        },
        'g' => {
            const value = try reader.take_signature();

            store_string(header, code, value);
        },
        'u' => {
            const value = try reader.take_u32();

            if (code == @backingInt(Field.reply_serial)) header.reply_serial = value;
        },
        else => return error.Malformed,
    }
}

fn store_string(header: *Header, code: u8, value: []const u8) void {
    assert(value.len <= string_bytes_max);
    assert(header.length_total >= header_bytes_min);

    switch (code) {
        @backingInt(Field.path) => header.path = value,
        @backingInt(Field.interface) => header.interface = value,
        @backingInt(Field.member) => header.member = value,
        @backingInt(Field.error_name) => header.error_name = value,
        @backingInt(Field.destination) => header.destination = value,
        @backingInt(Field.sender) => header.sender = value,
        @backingInt(Field.signature) => header.signature = value,
        else => {},
    }
}

pub const MessageOptions = struct {
    destination: []const u8 = "",
    error_name: []const u8 = "",
    flags: Flags = .{},
    interface: []const u8 = "",
    kind: Kind,
    member: []const u8 = "",
    path: []const u8 = "",
    reply_serial: ?u32 = null,
    serial: u32,
    signature: []const u8 = "",
};

pub fn write_header(writer: *Writer, body_length: u32, options: MessageOptions) CapacityError!void {
    assert(options.kind.is_valid());
    assert(options.serial > 0);

    writer.reset();

    try writer.put_byte(endian_little);
    try writer.put_byte(@backingInt(options.kind));
    try writer.put_byte(options.flags.to_uint());
    try writer.put_byte(protocol_version);
    try writer.put_u32(body_length);
    try writer.put_u32(options.serial);

    const fields = try writer.open_array(align_of(code_struct));

    try write_header_fields(writer, &options);
    try writer.close_array(fields);
    try writer.pad_to(8);

    assert(writer.length % 8 == 0);
}

fn write_header_fields(writer: *Writer, options: *const MessageOptions) CapacityError!void {
    assert(options.serial > 0);
    assert(writer.length % 8 == 0);

    try write_string_field(writer, .path, 'o', options.path);
    try write_string_field(writer, .interface, 's', options.interface);
    try write_string_field(writer, .member, 's', options.member);
    try write_string_field(writer, .error_name, 's', options.error_name);
    try write_string_field(writer, .destination, 's', options.destination);
    try write_string_field(writer, .signature, 'g', options.signature);

    if (options.reply_serial) |serial| {
        try writer.pad_to(8);
        try writer.put_byte(@backingInt(Field.reply_serial));
        try writer.put_signature("u");
        try writer.put_u32(serial);
    }
}

fn write_string_field(
    writer: *Writer,
    field: Field,
    signature: u8,
    value: []const u8,
) CapacityError!void {
    assert(signature == 'o' or signature == 's' or signature == 'g');
    assert(value.len <= string_bytes_max);

    if (value.len == 0) {
        return;
    }

    try writer.pad_to(8);
    try writer.put_byte(@backingInt(field));
    try writer.put_signature(&[_]u8{signature});

    if (signature == 'g') {
        try writer.put_signature(value);

        return;
    }

    try writer.put_string(value);
}

const testing = std.testing;

test "align_up rounds to the requested boundary" {
    try testing.expectEqual(@as(u32, 0), align_up(0, 8));
    try testing.expectEqual(@as(u32, 8), align_up(1, 8));
    try testing.expectEqual(@as(u32, 8), align_up(8, 8));
    try testing.expectEqual(@as(u32, 16), align_up(9, 8));
    try testing.expectEqual(@as(u32, 4), align_up(3, 4));
}

test "align_of matches the specification" {
    try testing.expectEqual(@as(u8, 1), align_of('y'));
    try testing.expectEqual(@as(u8, 2), align_of('q'));
    try testing.expectEqual(@as(u8, 4), align_of('u'));
    try testing.expectEqual(@as(u8, 4), align_of('s'));
    try testing.expectEqual(@as(u8, 8), align_of('t'));
    try testing.expectEqual(@as(u8, 8), align_of('('));
}

test "Writer round trips scalars through Reader" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.put_byte(7);
    try writer.put_u32(0xDEADBEEF);
    try writer.put_u64(0x0123456789ABCDEF);

    var reader = Reader.init(writer.bytes());

    try testing.expectEqual(@as(u8, 7), try reader.take_byte());
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try reader.take_u32());
    try testing.expectEqual(@as(u64, 0x0123456789ABCDEF), try reader.take_u64());
}

test "Writer round trips strings and signatures" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.put_string("umbra");
    try writer.put_signature("sa{sv}");

    var reader = Reader.init(writer.bytes());

    try testing.expectEqualStrings("umbra", try reader.take_string());
    try testing.expectEqualStrings("sa{sv}", try reader.take_signature());
}

test "Writer reports overflow" {
    var storage: [4]u8 = undefined;
    var writer = Writer.init(&storage);

    try testing.expectError(Error.Overflow, writer.put_string("too long for four bytes"));
}

test "Reader reports truncation" {
    const buffer = [_]u8{ 4, 0, 0 };

    var reader = Reader.init(&buffer);

    try testing.expectError(Error.Truncated, reader.take_u32());
}

test "peek_length needs a full fixed header" {
    const short = [_]u8{ 'l', 1, 0, 1 };
    const peeked = try peek_length(&short);

    try testing.expect(peeked == .partial);
}

test "peek_length rejects big endian" {
    var buffer: [header_bytes_min]u8 = @splat(0);

    buffer[0] = endian_big;
    buffer[3] = protocol_version;

    try testing.expectError(Error.UnsupportedEndian, peek_length(&buffer));
}

test "write_header and parse agree on a method call" {
    var storage: [512]u8 = undefined;
    var writer = Writer.init(&storage);

    const options: MessageOptions = .{
        .destination = "org.freedesktop.DBus",
        .interface = "org.freedesktop.DBus",
        .kind = .method_call,
        .member = "Hello",
        .path = "/org/freedesktop/DBus",
        .serial = 1,
    };

    try write_header(&writer, 0, options);

    const header = try parse(writer.bytes());

    try testing.expectEqual(Kind.method_call, header.kind);
    try testing.expectEqual(@as(u32, 1), header.serial);
    try testing.expectEqual(@as(u32, 0), header.body_length);
    try testing.expectEqualStrings("Hello", header.member);
    try testing.expectEqualStrings("/org/freedesktop/DBus", header.path);
    try testing.expectEqualStrings("org.freedesktop.DBus", header.interface);
    try testing.expectEqualStrings("org.freedesktop.DBus", header.destination);
}

test "write_header carries a reply serial and a signature" {
    var storage: [512]u8 = undefined;
    var writer = Writer.init(&storage);

    const options: MessageOptions = .{
        .kind = .method_return,
        .reply_serial = 9,
        .serial = 3,
        .signature = "s",
    };

    try write_header(&writer, 0, options);

    const header = try parse(writer.bytes());

    try testing.expectEqual(Kind.method_return, header.kind);
    try testing.expectEqual(@as(u32, 9), header.reply_serial);
    try testing.expectEqualStrings("s", header.signature);
}

test "parse rejects an unknown message kind" {
    var storage: [512]u8 = undefined;
    var writer = Writer.init(&storage);

    try write_header(&writer, 0, .{ .kind = .signal, .serial = 1 });

    const mutable = storage[0..writer.length];

    mutable[1] = 9;

    try testing.expectError(Error.Malformed, parse(mutable));
}

test "parse reports truncation before the body arrives" {
    var storage: [512]u8 = undefined;
    var writer = Writer.init(&storage);

    try write_header(&writer, 16, .{ .kind = .signal, .serial = 1, .signature = "s" });

    try testing.expectError(Error.Truncated, parse(writer.bytes()));
}

test "Flags encode the documented bits" {
    try testing.expectEqual(@as(u8, 0), (Flags{}).to_uint());
    try testing.expectEqual(@as(u8, 1), (Flags{ .no_reply_expected = true }).to_uint());
    try testing.expectEqual(@as(u8, 2), (Flags{ .no_auto_start = true }).to_uint());

    try testing.expectEqual(
        @as(u8, 3),
        (Flags{ .no_auto_start = true, .no_reply_expected = true }).to_uint(),
    );
}
