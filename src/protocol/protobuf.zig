const std = @import("std");

const assert = std.debug.assert;

pub const Encoder = struct {
    buffer: []u8,
    len: u32 = 0,

    pub fn init(buffer: []u8) Encoder {
        return .{ .buffer = buffer };
    }

    pub fn written(encoder: *const Encoder) []const u8 {
        return encoder.buffer[0..encoder.len];
    }

    pub fn varint(encoder: *Encoder, value: u64) void {
        var remaining = value;
        var guard: u32 = 0;

        while (remaining >= 0x80) {
            guard += 1;
            assert(guard <= 10);
            encoder.byte(@intCast((remaining & 0x7F) | 0x80));
            remaining >>= 7;
        }

        encoder.byte(@intCast(remaining));
    }

    pub fn field_varint(encoder: *Encoder, field: u32, value: u64) void {
        encoder.tag(field, wire_varint);
        encoder.varint(value);
    }

    pub fn field_fixed64(encoder: *Encoder, field: u32, value: u64) void {
        encoder.tag(field, wire_i64);
        var index: u6 = 0;

        while (index < 8) : (index += 1) encoder.byte(@intCast((value >> (@as(
            u6,
            index,
        ) * 8)) & 0xFF));
    }

    pub fn field_bytes(encoder: *Encoder, field: u32, data: []const u8) void {
        encoder.tag(field, wire_len);
        encoder.varint(data.len);
        assert(encoder.len + data.len <= encoder.buffer.len);
        @memcpy(encoder.buffer[encoder.len .. encoder.len + data.len], data);
        encoder.len += @intCast(data.len);
    }

    fn tag(encoder: *Encoder, field: u32, wire: u3) void {
        encoder.varint((@as(u64, field) << 3) | wire);
    }

    fn byte(encoder: *Encoder, value: u8) void {
        assert(encoder.len < encoder.buffer.len);

        encoder.buffer[encoder.len] = value;
        encoder.len += 1;
    }
};

pub const Field = struct {
    number: u32,
    wire: u3,
    varint: u64 = 0,
    bytes: []const u8 = &.{},
};

pub const Decoder = struct {
    data: []const u8,
    position: u32 = 0,

    pub fn init(data: []const u8) Decoder {
        assert(data.len <= std.math.maxInt(u32));

        return .{ .data = data };
    }

    pub fn next(decoder: *Decoder) ?Field {
        assert(decoder.position <= decoder.data.len);

        if (decoder.position >= decoder.data.len) return null;

        const tag = decoder.read_varint() orelse return null;
        const number_wide = tag >> 3;

        if (number_wide == 0) return null;
        if (number_wide > field_number_max) return null;

        const number: u32 = @intCast(number_wide);
        const wire: u3 = @intCast(tag & 0x7);

        switch (wire) {
            wire_varint => {
                const value = decoder.read_varint() orelse return null;

                return .{ .number = number, .wire = wire, .varint = value };
            },
            wire_i64 => {
                if (decoder.position + 8 > decoder.data.len) return null;

                var value: u64 = 0;
                var index: u6 = 0;

                while (index < 8) : (index += 1) value |= @as(
                    u64,
                    decoder.data[decoder.position + index],
                ) << (@as(u6, index) * 8);
                decoder.position += 8;

                return .{ .number = number, .wire = wire, .varint = value };
            },
            wire_len => {
                const length = decoder.read_varint() orelse return null;

                const remaining = decoder.data.len - decoder.position;

                if (length > remaining) return null;

                const take: u32 = @intCast(length);
                const slice = decoder.data[decoder.position .. decoder.position + take];
                decoder.position += take;

                return .{ .number = number, .wire = wire, .bytes = slice };
            },
            wire_i32 => {
                if (decoder.position + 4 > decoder.data.len) return null;
                var value: u64 = 0;
                var index: u6 = 0;

                while (index < 4) : (index += 1) value |= @as(
                    u64,
                    decoder.data[decoder.position + index],
                ) << (@as(u6, index) * 8);
                decoder.position += 4;

                return .{ .number = number, .wire = wire, .varint = value };
            },
            else => return null,
        }
    }

    fn read_varint(decoder: *Decoder) ?u64 {
        assert(decoder.position <= decoder.data.len);

        var result: u64 = 0;
        var shift: u32 = 0;
        var guard: u32 = 0;

        while (decoder.position < decoder.data.len) {
            guard += 1;
            if (guard > 10) return null;

            const byte = decoder.data[decoder.position];
            decoder.position += 1;
            result |= @as(u64, byte & 0x7F) << @intCast(shift);

            if (byte & 0x80 == 0) return result;
            shift += 7;

            if (shift >= 64) return null;
        }
        return null;
    }
};

pub const wire_varint: u3 = 0;
pub const wire_i64: u3 = 1;
pub const wire_len: u3 = 2;
pub const wire_i32: u3 = 5;

pub const field_number_max: u32 = (1 << 29) - 1;

test "varint round-trips" {
    var buffer: [32]u8 = undefined;
    var encoder = Encoder.init(&buffer);
    encoder.field_varint(1, 0);
    encoder.field_varint(2, 300);
    encoder.field_varint(3, 0xFFFFFFFF);

    var decoder = Decoder.init(encoder.written());
    var field = decoder.next().?;

    try std.testing.expectEqual(@as(u32, 1), field.number);
    try std.testing.expectEqual(@as(u64, 0), field.varint);
    field = decoder.next().?;
    try std.testing.expectEqual(@as(u32, 2), field.number);
    try std.testing.expectEqual(@as(u64, 300), field.varint);
    field = decoder.next().?;
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF), field.varint);
    try std.testing.expect(decoder.next() == null);
}

test "fixed64 round-trips" {
    var buffer: [32]u8 = undefined;
    var encoder = Encoder.init(&buffer);
    encoder.field_fixed64(1, 0xA5A5);

    const expected = [_]u8{ 0x09, 0xA5, 0xA5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

    try std.testing.expectEqualSlices(u8, &expected, encoder.written());

    var decoder = Decoder.init(encoder.written());
    const field = decoder.next().?;

    try std.testing.expectEqual(@as(u3, wire_i64), field.wire);
    try std.testing.expectEqual(@as(u64, 0xA5A5), field.varint);
}

test "length-delimited nesting round-trips" {
    var inner_buffer: [16]u8 = undefined;
    var inner = Encoder.init(&inner_buffer);
    inner.field_varint(3, 7);

    var outer_buffer: [32]u8 = undefined;
    var outer = Encoder.init(&outer_buffer);
    outer.field_bytes(43, inner.written());

    var decoder = Decoder.init(outer.written());
    const field = decoder.next().?;

    try std.testing.expectEqual(@as(u32, 43), field.number);
    try std.testing.expectEqual(@as(u3, wire_len), field.wire);

    var nested = Decoder.init(field.bytes);
    const inner_field = nested.next().?;

    try std.testing.expectEqual(@as(u32, 3), inner_field.number);
    try std.testing.expectEqual(@as(u64, 7), inner_field.varint);
}

test "decoder rejects truncated length-delimited field" {
    const bad = [_]u8{ (1 << 3) | @as(u8, wire_len), 0x10, 0x01, 0x02 };
    var decoder = Decoder.init(&bad);

    try std.testing.expect(decoder.next() == null);
}

test "decoder rejects an overlong varint without overflowing the shift" {
    const bad = [_]u8{
        (1 << 3) | @as(u8, wire_varint),
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
    };

    var decoder = Decoder.init(&bad);

    try std.testing.expect(decoder.next() == null);
}

test "decoder rejects a zero field number" {
    const bad = [_]u8{ 0x00 | @as(u8, wire_varint), 0x01 };
    var decoder = Decoder.init(&bad);

    try std.testing.expect(decoder.next() == null);
}

test "decoder rejects a field number above the protobuf maximum" {
    const bad = [_]u8{
        0x80 | @as(u8, wire_varint),
        0x80,
        0x80,
        0x80,
        0x80,
        0x01,
        0x01,
    };

    var decoder = Decoder.init(&bad);

    try std.testing.expect(decoder.next() == null);
}

test "decoder rejects a length field larger than the remaining input" {
    const bad = [_]u8{
        (1 << 3) | @as(u8, wire_len),
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0x01,
        0xAA,
        0xBB,
    };

    var decoder = Decoder.init(&bad);

    try std.testing.expect(decoder.next() == null);
}
