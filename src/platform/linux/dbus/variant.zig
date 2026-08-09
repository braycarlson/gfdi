const std = @import("std");

const wire = @import("wire.zig");

const assert = std.debug.assert;

pub const Error = wire.Error;

pub const Writer = wire.Writer;

pub fn put_string_variant(writer: *Writer, value: []const u8) Error!void {
    assert(value.len <= wire.string_bytes_max);

    try writer.put_signature("s");
    try writer.put_string(value);
}

pub fn put_object_variant(writer: *Writer, value: []const u8) Error!void {
    assert(value.len > 0);
    assert(value[0] == '/');

    try writer.put_signature("o");
    try writer.put_string(value);
}

pub fn put_bool_variant(writer: *Writer, value: bool) Error!void {
    try writer.put_signature("b");
    try writer.put_bool(value);
}

pub fn put_u32_variant(writer: *Writer, value: u32) Error!void {
    try writer.put_signature("u");
    try writer.put_u32(value);
}

pub fn put_i32_variant(writer: *Writer, value: i32) Error!void {
    try writer.put_signature("i");
    try writer.put_i32(value);
}

pub fn put_dict_entry_string(writer: *Writer, key: []const u8, value: []const u8) Error!void {
    assert(key.len > 0);

    try writer.pad_to(wire.align_of(wire.code_dict_entry));
    try writer.put_string(key);
    try put_string_variant(writer, value);
}

pub fn put_dict_entry_bool(writer: *Writer, key: []const u8, value: bool) Error!void {
    assert(key.len > 0);

    try writer.pad_to(wire.align_of(wire.code_dict_entry));
    try writer.put_string(key);
    try put_bool_variant(writer, value);
}

pub fn put_dict_entry_i32(writer: *Writer, key: []const u8, value: i32) Error!void {
    assert(key.len > 0);

    try writer.pad_to(wire.align_of(wire.code_dict_entry));
    try writer.put_string(key);
    try put_i32_variant(writer, value);
}

pub fn put_empty_array(writer: *Writer, element_alignment: u32) Error!void {
    assert(element_alignment == 1 or element_alignment == 2 or
        element_alignment == 4 or element_alignment == 8);

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

pub fn take_variant(reader: *wire.Reader) Error!Value {
    const signature = try reader.take_signature();

    if (signature.len == 0) {
        return Error.Malformed;
    }

    if (signature.len == 1) return take_basic(reader, signature[0]);

    if (std.mem.eql(u8, signature, "ay")) {
        return .{ .bytes = try take_array_body(reader, 1) };
    }

    if (std.mem.eql(u8, signature, "as") or std.mem.eql(u8, signature, "ao")) {
        return .{ .strings = .{ .body = try take_array_body(reader, 4) } };
    }

    try skip_signature(reader, signature);

    return .other;
}

fn take_basic(reader: *wire.Reader, code: u8) Error!Value {
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

pub fn take_array_body(reader: *wire.Reader, element_alignment: u32) Error![]const u8 {
    const length = try reader.take_u32();

    if (length > wire.array_bytes_max) {
        return Error.Malformed;
    }

    try reader.skip_to(element_alignment);

    if (reader.remaining() < length) {
        return Error.Truncated;
    }

    const body = reader.buffer[reader.offset..][0..length];

    reader.offset += length;

    assert(reader.offset <= reader.buffer.len);

    return body;
}

pub fn skip_signature(reader: *wire.Reader, signature: []const u8) Error!void {
    var stack: [wire.nesting_max]Frame = undefined;
    var depth: u32 = 1;
    var steps: u32 = 0;

    stack[0] = .{ .cursor = 0, .signature = signature };

    while (depth > 0) {
        steps += 1;

        if (steps > skip_steps_max) {
            return Error.Malformed;
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
                return Error.Malformed;
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

fn skip_scalar(reader: *wire.Reader, code: u8) Error!void {
    switch (code) {
        'y' => _ = try reader.take_byte(),
        'b', 'h', 'i', 'u' => _ = try reader.take_u32(),
        'n', 'q' => _ = try reader.take_u16(),
        'd', 't', 'x' => _ = try reader.take_u64(),
        'g' => _ = try reader.take_signature(),
        'o', 's' => _ = try reader.take_string(),
        '(', '{' => try reader.skip_to(8),
        ')', '}' => {},
        else => return Error.Malformed,
    }
}

fn element_signature(signature: []const u8, start: u32) Error![]const u8 {
    if (start >= signature.len) {
        return Error.Malformed;
    }

    var index = start;
    var depth: u32 = 0;
    var steps: u32 = 0;

    while (index < signature.len) {
        steps += 1;

        if (steps > wire.signature_bytes_max) {
            return Error.Malformed;
        }

        const code = signature[index];

        index += 1;

        if (code == '(' or code == '{') {
            depth += 1;

            continue;
        }

        if (code == ')' or code == '}') {
            if (depth == 0) return Error.Malformed;

            depth -= 1;

            if (depth == 0) break;

            continue;
        }

        if (code != 'a' and depth == 0) break;
    }

    if (depth != 0) {
        return Error.Malformed;
    }

    return signature[start..index];
}

const testing = std.testing;

test "put_string_variant writes a signature and a value" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_string_variant(&writer, "wisp");

    var reader = wire.Reader.init(writer.bytes());

    try testing.expectEqualStrings("s", try reader.take_signature());
    try testing.expectEqualStrings("wisp", try reader.take_string());
}

test "put_bool_variant writes a four byte boolean" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_bool_variant(&writer, true);

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
}

test "put_dict_entry_string writes a keyed variant" {
    var storage: [128]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_dict_entry_string(&writer, "label", "Quit");

    var reader = wire.Reader.init(writer.bytes());

    try testing.expectEqualStrings("label", try reader.take_string());
    try testing.expectEqualStrings("s", try reader.take_signature());
    try testing.expectEqualStrings("Quit", try reader.take_string());
}

test "take_variant reads the string form BlueZ uses for Address" {
    var storage: [128]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_string_variant(&writer, "F1:E2:D3:C4:B5:A6");

    var reader = wire.Reader.init(writer.bytes());
    const value = try take_variant(&reader);

    try testing.expectEqualStrings("F1:E2:D3:C4:B5:A6", value.text);
}

test "take_variant reads the boolean form BlueZ uses for ServicesResolved" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try put_bool_variant(&writer, true);

    var reader = wire.Reader.init(writer.bytes());
    const value = try take_variant(&reader);

    try testing.expect(value.boolean);
}

test "take_variant reads a signed sixteen bit RSSI" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.put_signature("n");
    try writer.pad_to(2);
    try writer.put_slice(&[_]u8{ 0xC4, 0xFF });

    var reader = wire.Reader.init(writer.bytes());
    const value = try take_variant(&reader);

    try testing.expectEqual(@as(i64, -60), value.integer);
}

test "take_variant reads a byte array as the raw notification payload" {
    var storage: [64]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.put_signature("ay");

    const marker = try writer.open_array(1);

    try writer.put_slice(&[_]u8{ 1, 2, 3, 4 });
    try writer.close_array(marker);

    var reader = wire.Reader.init(writer.bytes());
    const value = try take_variant(&reader);

    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, value.bytes);
}

test "take_variant reads a string array and answers membership" {
    var storage: [256]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.put_signature("as");

    const marker = try writer.open_array(4);

    try writer.put_string("read");
    try writer.put_string("write-without-response");
    try writer.put_string("notify");
    try writer.close_array(marker);

    var reader = wire.Reader.init(writer.bytes());
    const value = try take_variant(&reader);

    try testing.expect(value.strings.contains("notify"));
    try testing.expect(value.strings.contains("write-without-response"));
    try testing.expect(!value.strings.contains("indicate"));
}

test "take_variant skips a container it does not model and stays in step" {
    var storage: [256]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.put_signature("a{sv}");

    const marker = try writer.open_array(8);

    try put_dict_entry_string(&writer, "Nested", "value");
    try writer.close_array(marker);
    try writer.put_string("after");

    var reader = wire.Reader.init(writer.bytes());
    const value = try take_variant(&reader);

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
