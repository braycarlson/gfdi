const std = @import("std");

const wire = @import("wire.zig");

const assert = std.debug.assert;

pub const CapacityError = wire.CapacityError;
pub const Error = wire.Error;
pub const MessageError = wire.MessageError;

pub const Writer = wire.Writer;

pub fn put_string(writer: *Writer, value: []const u8) CapacityError!void {
    assert(writer.length <= writer.buffer.len);
    assert(value.len <= wire.string_bytes_max);

    try writer.put_signature("s");
    try writer.put_string(value);
}

pub fn put_object(writer: *Writer, value: []const u8) CapacityError!void {
    assert(value.len > 0);
    assert(value[0] == '/');

    try writer.put_signature("o");
    try writer.put_string(value);
}

pub fn put_bool(writer: *Writer, value: bool) CapacityError!void {
    assert(writer.length <= writer.buffer.len);

    try writer.put_signature("b");
    try writer.put_bool(value);
}

pub fn put_u32(writer: *Writer, value: u32) CapacityError!void {
    assert(writer.length <= writer.buffer.len);

    try writer.put_signature("u");
    try writer.put_u32(value);
}

pub fn put_i32(writer: *Writer, value: i32) CapacityError!void {
    assert(writer.length <= writer.buffer.len);

    try writer.put_signature("i");
    try writer.put_i32(value);
}

pub const StringEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub fn put_dictionary_entry_string(writer: *Writer, entry: StringEntry) CapacityError!void {
    assert(entry.key.len > 0);
    assert(entry.value.len <= wire.string_bytes_max);

    try writer.pad_to(wire.align_of(wire.code_dictionary_entry));
    try writer.put_string(entry.key);
    try put_string(writer, entry.value);
}

pub fn put_dictionary_entry_bool(writer: *Writer, key: []const u8, value: bool) CapacityError!void {
    assert(writer.length <= writer.buffer.len);
    assert(key.len > 0);

    try writer.pad_to(wire.align_of(wire.code_dictionary_entry));
    try writer.put_string(key);
    try put_bool(writer, value);
}

pub fn put_dictionary_entry_i32(writer: *Writer, key: []const u8, value: i32) CapacityError!void {
    assert(writer.length <= writer.buffer.len);
    assert(key.len > 0);

    try writer.pad_to(wire.align_of(wire.code_dictionary_entry));
    try writer.put_string(key);
    try put_i32(writer, value);
}

pub fn put_empty_array(writer: *Writer, element_alignment: u8) CapacityError!void {
    assert(writer.length <= writer.buffer.len);
    assert(std.math.isPowerOfTwo(element_alignment));
    assert(element_alignment <= 8);

    const marker = try writer.open_array(element_alignment);

    try writer.close_array(marker);
}

pub const Value = union(enum) {
    boolean: bool,
    bytes: []const u8,
    integer: i64,
    other: void,
    strings: StringList,
    text: []const u8,
};

pub const StringList = struct {
    body: []const u8,

    pub fn contains(list: StringList, needle: []const u8) bool {
        assert(needle.len > 0);
        assert(list.body.len <= wire.array_bytes_max);

        var reader = wire.Reader.init(list.body);
        var scanned: u32 = 0;

        while (scanned < strings_scan_max) : (scanned += 1) {
            if (reader.remaining() == 0) break;

            const entry = reader.take_string() catch break;
            if (std.mem.eql(u8, entry, needle)) return true;
        }

        return false;
    }
};

const Frame = struct {
    cursor: u32,
    signature: []const u8,
};

pub const skip_steps_max: u32 = 4096;
pub const strings_scan_max: u32 = 256;

comptime {
    assert(skip_steps_max > wire.nesting_max);
    assert(strings_scan_max > 0);
}

pub fn take(reader: *wire.Reader) MessageError!Value {
    assert(reader.offset <= reader.buffer.len);
    assert(reader.buffer.len <= wire.receive_bytes_limit);

    const signature = try reader.take_signature();

    if (signature.len == 0) {
        return error.Malformed;
    }

    if (signature.len == 1) return take_basic(reader, signature[0]);

    if (std.mem.eql(u8, signature, "ay")) {
        return .{ .bytes = try take_array_body(reader, 1) };
    }

    if (std.mem.eql(u8, signature, "as")) {
        return .{ .strings = .{ .body = try take_array_body(reader, 4) } };
    }

    if (std.mem.eql(u8, signature, "ao")) {
        return .{ .strings = .{ .body = try take_array_body(reader, 4) } };
    }

    try skip_signature(reader, signature);

    return .other;
}

fn take_basic(reader: *wire.Reader, code: u8) MessageError!Value {
    assert(reader.buffer.len <= wire.receive_bytes_limit);

    if (code == 0) return error.Malformed;

    assert(reader.offset <= reader.buffer.len);

    switch (code) {
        'b' => return .{ .boolean = (try reader.take_u32()) != 0 },
        'y' => return .{ .integer = try reader.take_byte() },
        'n' => return .{ .integer = @as(i16, @bitCast(try reader.take_u16())) },
        'q' => return .{ .integer = try reader.take_u16() },
        'i' => return .{ .integer = try reader.take_i32() },
        'u' => return .{ .integer = try reader.take_u32() },
        'x' => return .{ .integer = @bitCast(try reader.take_u64()) },
        't' => return .{ .integer = @bitCast(try reader.take_u64()) },
        's', 'o' => return .{ .text = try reader.take_string() },
        'g' => return .{ .text = try reader.take_signature() },
        else => {},
    }

    try skip_signature(reader, &[_]u8{code});

    return .other;
}

pub fn take_array_body(reader: *wire.Reader, element_alignment: u8) MessageError![]const u8 {
    assert(element_alignment > 0);
    assert(element_alignment <= 8);

    const length = try reader.take_u32();

    if (length > wire.array_bytes_max) {
        return error.Malformed;
    }

    try reader.skip_to(element_alignment);

    if (reader.remaining() < length) {
        return error.Truncated;
    }

    const body = reader.buffer[reader.offset..][0..length];

    reader.offset += length;

    assert(reader.offset <= reader.buffer.len);

    return body;
}

pub fn skip_signature(reader: *wire.Reader, signature: []const u8) MessageError!void {
    assert(signature.len <= wire.signature_bytes_max);
    assert(reader.offset <= reader.buffer.len);

    var stack: [wire.nesting_max]Frame = undefined;
    var depth: u32 = 1;
    var steps: u32 = 0;

    stack[0] = .{ .cursor = 0, .signature = signature };

    while (depth > 0) {
        steps += 1;

        if (steps > skip_steps_max) {
            return error.Malformed;
        }

        const frame = &stack[depth - 1];

        if (frame.cursor >= frame.signature.len) {
            depth -= 1;

            continue;
        }

        const code = frame.signature[frame.cursor];

        frame.cursor += 1;

        if (code == 'v') {
            if (depth == wire.nesting_max) {
                return error.Malformed;
            }

            stack[depth] = .{ .cursor = 0, .signature = try reader.take_signature() };
            depth += 1;

            continue;
        }

        if (code == 'a') {
            const element = try element_signature(frame.signature, frame.cursor);

            frame.cursor += @intCast(element.len);

            _ = try take_array_body(reader, wire.align_of(element[0]));

            continue;
        }

        try skip_scalar(reader, code);
    }
}

fn skip_scalar(reader: *wire.Reader, code: u8) MessageError!void {
    assert(reader.offset <= reader.buffer.len);
    comptime assert(wire.nesting_max > 0);

    switch (code) {
        'y' => _ = try reader.take_byte(),
        'b', 'h', 'i', 'u' => _ = try reader.take_u32(),
        'n', 'q' => _ = try reader.take_u16(),
        'd', 't', 'x' => _ = try reader.take_u64(),
        'g' => _ = try reader.take_signature(),
        'o', 's' => _ = try reader.take_string(),
        '(', '{' => try reader.skip_to(8),
        ')', '}' => {},
        else => return error.Malformed,
    }
}

fn element_signature(signature: []const u8, start: u32) MessageError![]const u8 {
    assert(signature.len <= wire.signature_bytes_max);
    assert(start <= wire.signature_bytes_max);

    if (start >= signature.len) {
        return error.Malformed;
    }

    var index = start;
    var depth: u32 = 0;
    var steps: u32 = 0;

    while (index < signature.len) {
        steps += 1;

        if (steps > wire.signature_bytes_max) {
            return error.Malformed;
        }

        const code = signature[index];

        index += 1;

        switch (code) {
            '(', '{' => depth += 1,
            ')', '}' => {
                if (depth == 0) return error.Malformed;

                depth -= 1;

                if (depth == 0) break;
            },
            'a' => {},
            else => {
                if (depth == 0) break;
            },
        }
    }

    if (depth != 0) {
        return error.Malformed;
    }

    return signature[start..index];
}

const testing = std.testing;

test "put_string writes a signature and a value" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_string(&writer, "umbra");

    var reader = wire.Reader.init(writer.bytes());

    try testing.expectEqualStrings("s", try reader.take_signature());
    try testing.expectEqualStrings("umbra", try reader.take_string());
}

test "put_bool writes a four byte boolean" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_bool(&writer, true);

    var reader = wire.Reader.init(writer.bytes());

    try testing.expectEqualStrings("b", try reader.take_signature());
    try testing.expectEqual(@as(u32, 1), try reader.take_u32());
}

test "put_empty_array writes a zero length" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_empty_array(&writer, 8);

    var reader = wire.Reader.init(writer.bytes());

    try testing.expectEqual(@as(u32, 0), try reader.take_u32());
    try testing.expectEqual(@as(usize, 8), writer.bytes().len);
}

test "put_dictionary_entry_string writes a keyed variant" {
    var storage: [128]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_dictionary_entry_string(&writer, .{ .key = "label", .value = "Quit" });

    var reader = wire.Reader.init(writer.bytes());

    try testing.expectEqualStrings("label", try reader.take_string());
    try testing.expectEqualStrings("s", try reader.take_signature());
    try testing.expectEqualStrings("Quit", try reader.take_string());
}

test "take reads the string form BlueZ uses for Address" {
    var storage: [128]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_string(&writer, "F1:E2:D3:C4:B5:A6");

    var reader = wire.Reader.init(writer.bytes());
    const value = try take(&reader);

    try testing.expectEqualStrings("F1:E2:D3:C4:B5:A6", value.text);
}

test "take reads the boolean form BlueZ uses for ServicesResolved" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_bool(&writer, true);

    var reader = wire.Reader.init(writer.bytes());
    const value = try take(&reader);

    try testing.expect(value.boolean);
    try testing.expectEqual(@as(u32, 0), reader.remaining());
}

test "take reads a signed sixteen bit RSSI" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.put_signature("n");
    try writer.pad_to(2);
    try writer.put_slice(&[_]u8{ 0xC4, 0xFF });

    var reader = wire.Reader.init(writer.bytes());
    const value = try take(&reader);

    try testing.expectEqual(@as(i64, -60), value.integer);
}

test "take reads a byte array as the raw notification payload" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.put_signature("ay");

    const marker = try writer.open_array(1);

    try writer.put_slice(&[_]u8{ 1, 2, 3, 4 });
    try writer.close_array(marker);

    var reader = wire.Reader.init(writer.bytes());
    const value = try take(&reader);

    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, value.bytes);
}

test "take reads a string array and answers membership" {
    var storage: [256]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.put_signature("as");

    const marker = try writer.open_array(4);

    try writer.put_string("read");
    try writer.put_string("write-without-response");
    try writer.put_string("notify");
    try writer.close_array(marker);

    var reader = wire.Reader.init(writer.bytes());
    const value = try take(&reader);

    try testing.expect(value.strings.contains("notify"));
    try testing.expect(value.strings.contains("write-without-response"));
    try testing.expect(!value.strings.contains("indicate"));
}

test "take skips a container it does not model and stays in step" {
    var storage: [256]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.put_signature("a{sv}");

    const marker = try writer.open_array(8);

    try put_dictionary_entry_string(&writer, .{ .key = "Nested", .value = "value" });
    try writer.close_array(marker);
    try writer.put_string("after");

    var reader = wire.Reader.init(writer.bytes());
    const value = try take(&reader);

    try testing.expectEqual(Value.other, value);
    try testing.expectEqualStrings("after", try reader.take_string());
}

test "element_signature isolates one complete type" {
    try testing.expectEqualStrings("s", try element_signature("sv", 0));
    try testing.expectEqualStrings("{sv}", try element_signature("{sv}", 0));
    try testing.expectEqualStrings("a{sv}", try element_signature("a{sv}s", 0));
    try testing.expectEqualStrings("(oa{sv})", try element_signature("(oa{sv})s", 0));
    try testing.expectError(Error.Malformed, element_signature("{sv", 0));
}
