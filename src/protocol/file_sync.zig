const std = @import("std");

const protobuf = @import("protobuf.zig");

const assert = std.debug.assert;

pub const FileSyncMessage = union(enum) {
    file_list_response: []const u8,
    file_response: []const u8,
    new_file_notification: []const u8,
    other,
};

pub const File = struct {
    id1: u64 = 0,
    id2: u64 = 0,
    type_code: u32 = 0,
    type_name: []const u8 = &.{},
    size: u32 = 0,
    page_id: u32 = 0,
    raw: []const u8 = &.{},
};

pub const FileListResponse = struct {
    bytes: []const u8,
    next_page_id: u32,
};

pub const FileIterator = struct {
    decoder: protobuf.Decoder,

    pub fn next(iterator: *FileIterator) ?File {
        var iterations: u32 = 0;

        while (iterator.decoder.next()) |field| {
            iterations += 1;
            assert(iterations <= iterator.decoder.data.len + 1);

            if (field.number == 4 and field.wire == protobuf.wire_len) {
                return parse_file(field.bytes);
            }
        }

        return null;
    }
};

pub const FileResponse = struct {
    status: u32 = 0,
    handle: u32 = 0,
};

const flags_magic: u64 = 42405;

const smart_file_sync_service: u32 = 43;

const file_sync_file_request: u32 = 1;
const file_sync_file_response: u32 = 2;
const file_sync_file_list_request: u32 = 9;
const file_sync_file_list_response: u32 = 10;
const file_sync_new_file_notification: u32 = 12;

const file_request_unknown_2: u64 = 24;
const file_request_unknown_5: u64 = 15;

const wanted_type_names = [_][]const u8{
    "FIT_TYPE_4",  "FIT_TYPE_32", "FIT_TYPE_44", "FIT_TYPE_41", "FIT_TYPE_68",
    "FIT_TYPE_49", "FIT_TYPE_61", "FIT_TYPE_73", "FIT_TYPE_38", "FIT_TYPE_70",
    "FIT_TYPE_71", "FIT_TYPE_82", "FIT_TYPE_35",
};

pub fn is_wanted_type(name: []const u8) bool {
    for (wanted_type_names) |wanted| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }

    return false;
}

pub fn build_file_list_request(destination: []u8, start_page_id: ?u32) u32 {
    var id_buffer: [32]u8 = undefined;
    var id = protobuf.Encoder.init(&id_buffer);

    id.field_fixed64(1, flags_magic);
    id.field_fixed64(2, flags_magic);

    var request_buffer: [96]u8 = undefined;
    var request = protobuf.Encoder.init(&request_buffer);

    if (start_page_id) |page| request.field_varint(2, page);
    request.field_bytes(4, id.written());
    request.field_bytes(5, id.written());

    var service_buffer: [128]u8 = undefined;
    var service = protobuf.Encoder.init(&service_buffer);
    service.field_bytes(file_sync_file_list_request, request.written());

    var smart = protobuf.Encoder.init(destination);
    smart.field_bytes(smart_file_sync_service, service.written());
    return smart.len;
}

pub fn build_file_request(destination: []u8, file_bytes: []const u8) u32 {
    var request_buffer: [320]u8 = undefined;
    var request = protobuf.Encoder.init(&request_buffer);

    request.field_bytes(1, file_bytes);
    request.field_varint(2, file_request_unknown_2);
    request.field_varint(3, 0);
    request.field_varint(4, 0);
    request.field_varint(5, file_request_unknown_5);

    var service_buffer: [384]u8 = undefined;
    var service = protobuf.Encoder.init(&service_buffer);
    service.field_bytes(file_sync_file_request, request.written());

    var smart = protobuf.Encoder.init(destination);
    smart.field_bytes(smart_file_sync_service, service.written());
    return smart.len;
}

pub fn parse_smart(smart: []const u8) ?FileSyncMessage {
    var decoder = protobuf.Decoder.init(smart);
    var iterations: u32 = 0;

    while (decoder.next()) |field| {
        iterations += 1;
        assert(iterations <= smart.len + 1);

        if (field.number != smart_file_sync_service or field.wire != protobuf.wire_len) continue;
        var service = protobuf.Decoder.init(field.bytes);

        while (service.next()) |sub| {
            switch (sub.number) {
                file_sync_file_list_response => return .{ .file_list_response = sub.bytes },
                file_sync_file_response => return .{ .file_response = sub.bytes },
                file_sync_new_file_notification => return .{ .new_file_notification = sub.bytes },
                else => {},
            }
        }

        return .other;
    }

    return null;
}

pub fn parse_file(bytes: []const u8) File {
    var file = File{ .raw = bytes };
    var decoder = protobuf.Decoder.init(bytes);
    var iterations: u32 = 0;

    while (decoder.next()) |field| {
        iterations += 1;
        assert(iterations <= bytes.len + 1);

        switch (field.number) {
            1 => {
                var id = protobuf.Decoder.init(field.bytes);

                while (id.next()) |sub| switch (sub.number) {
                    1 => file.id1 = sub.varint,
                    2 => file.id2 = sub.varint,
                    else => {},
                };
            },

            2 => {
                var file_type = protobuf.Decoder.init(field.bytes);

                while (file_type.next()) |sub| switch (sub.number) {
                    2 => file.type_name = sub.bytes,
                    3 => file.type_code = std.math.cast(u32, sub.varint) orelse 0,
                    else => {},
                };
            },
            3 => file.size = std.math.cast(u32, field.varint) orelse 0,
            5 => file.page_id = std.math.cast(u32, field.varint) orelse 0,
            else => {},
        }
    }
    return file;
}

pub fn parse_file_list_response(bytes: []const u8) FileListResponse {
    var next_page_id: u32 = 0;
    var decoder = protobuf.Decoder.init(bytes);
    var iterations: u32 = 0;

    while (decoder.next()) |field| {
        iterations += 1;
        assert(iterations <= bytes.len + 1);

        if (field.number == 3 and field.wire == protobuf.wire_varint) {
            next_page_id = std.math.cast(u32, field.varint) orelse 0;
        }
    }

    return .{ .bytes = bytes, .next_page_id = next_page_id };
}

pub fn file_iterator(file_list_response_bytes: []const u8) FileIterator {
    return .{ .decoder = protobuf.Decoder.init(file_list_response_bytes) };
}

pub fn parse_file_response(bytes: []const u8) FileResponse {
    var response = FileResponse{};
    var decoder = protobuf.Decoder.init(bytes);
    var iterations: u32 = 0;

    while (decoder.next()) |field| {
        iterations += 1;
        assert(iterations <= bytes.len + 1);

        switch (field.number) {
            1 => response.status = std.math.cast(u32, field.varint) orelse std.math.maxInt(u32),
            3 => response.handle = std.math.cast(u32, field.varint) orelse 0,
            else => {},
        }
    }

    return response;
}

test "file list request wraps Smart->FileSyncService->FileListRequest" {
    var buffer: [128]u8 = undefined;
    const length = build_file_list_request(&buffer, null);

    var smart = protobuf.Decoder.init(buffer[0..length]);
    const service_field = smart.next().?;

    try std.testing.expectEqual(smart_file_sync_service, service_field.number);

    var service = protobuf.Decoder.init(service_field.bytes);
    const request_field = service.next().?;

    try std.testing.expectEqual(file_sync_file_list_request, request_field.number);

    var request = protobuf.Decoder.init(request_field.bytes);
    const flags1 = request.next().?;

    try std.testing.expectEqual(@as(u32, 4), flags1.number);
    var id = protobuf.Decoder.init(flags1.bytes);
    const id1 = id.next().?;

    try std.testing.expectEqual(flags_magic, id1.varint);
}

test "file list request carries start_page_id when set" {
    var buffer: [128]u8 = undefined;
    const length = build_file_list_request(&buffer, 7);
    var smart = protobuf.Decoder.init(buffer[0..length]);
    var service = protobuf.Decoder.init(smart.next().?.bytes);
    var request = protobuf.Decoder.init(service.next().?.bytes);
    const first = request.next().?;

    try std.testing.expectEqual(@as(u32, 2), first.number);
    try std.testing.expectEqual(@as(u64, 7), first.varint);
}

test "parse a File and round-trip it through a synthetic FileListResponse" {
    var id_buffer: [32]u8 = undefined;
    var id = protobuf.Encoder.init(&id_buffer);
    id.field_fixed64(1, 0x1111);
    id.field_fixed64(2, 0x2222);

    var type_buffer: [32]u8 = undefined;
    var file_type = protobuf.Encoder.init(&type_buffer);
    file_type.field_bytes(2, "FIT_TYPE_4");
    file_type.field_varint(3, 4);

    var file_buffer: [96]u8 = undefined;
    var file = protobuf.Encoder.init(&file_buffer);
    file.field_bytes(1, id.written());
    file.field_bytes(2, file_type.written());
    file.field_varint(3, 5000);
    file.field_varint(5, 9);

    var list_buffer: [128]u8 = undefined;
    var list = protobuf.Encoder.init(&list_buffer);

    list.field_varint(3, 42);
    list.field_bytes(4, file.written());

    const list_response = parse_file_list_response(list.written());

    try std.testing.expectEqual(@as(u32, 42), list_response.next_page_id);

    var iterator = file_iterator(list.written());
    const parsed = iterator.next().?;

    try std.testing.expectEqual(@as(u64, 0x1111), parsed.id1);
    try std.testing.expectEqual(@as(u64, 0x2222), parsed.id2);
    try std.testing.expectEqual(@as(u32, 4), parsed.type_code);
    try std.testing.expectEqual(@as(u32, 5000), parsed.size);
    try std.testing.expectEqualSlices(u8, "FIT_TYPE_4", parsed.type_name);
    try std.testing.expect(is_wanted_type(parsed.type_name));
    try std.testing.expect(iterator.next() == null);

    var request_buffer: [256]u8 = undefined;
    const request_length = build_file_request(&request_buffer, parsed.raw);
    var smart = protobuf.Decoder.init(request_buffer[0..request_length]);
    var service = protobuf.Decoder.init(smart.next().?.bytes);
    const request_field = service.next().?;

    try std.testing.expectEqual(file_sync_file_request, request_field.number);
}

test "parse file response" {
    var buffer: [16]u8 = undefined;
    var encoder = protobuf.Encoder.init(&buffer);

    encoder.field_varint(1, 0);

    encoder.field_varint(3, 1234);

    const response = parse_file_response(encoder.written());

    try std.testing.expectEqual(@as(u32, 0), response.status);
    try std.testing.expectEqual(@as(u32, 1234), response.handle);
}

test "parse_smart routes the file sync sub-message" {
    var inner_buffer: [16]u8 = undefined;
    var inner = protobuf.Encoder.init(&inner_buffer);
    inner.field_varint(1, 0);
    inner.field_varint(3, 99);

    var service_buffer: [32]u8 = undefined;
    var service = protobuf.Encoder.init(&service_buffer);
    service.field_bytes(file_sync_file_response, inner.written());

    var smart_buffer: [48]u8 = undefined;
    var smart = protobuf.Encoder.init(&smart_buffer);
    smart.field_bytes(smart_file_sync_service, service.written());

    const message = parse_smart(smart.written()).?;

    switch (message) {
        .file_response => |bytes| {
            const response = parse_file_response(bytes);

            try std.testing.expectEqual(@as(u32, 99), response.handle);
        },
        else => return error.WrongVariant,
    }
}
