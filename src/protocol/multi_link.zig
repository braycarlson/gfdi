const std = @import("std");

const assert = std.debug.assert;

pub const client_id: u8 = 2;
pub const service_gfdi: u16 = 1;
pub const register_request: u8 = 0;
pub const register_response: u8 = 1;
pub const close_handle_request: u8 = 2;
pub const close_handle_response: u8 = 3;
pub const close_all_response: u8 = 6;

pub const transfer_service_codes = [_]u16{ 0x2018, 0x4018, 0x6018, 0xA018, 0xC018, 0xE018 };

pub const mtu_write_max: u32 = 20;

pub const service_uuid: u128 = 0x6A4E2800_667B_11E3_949A_0800200C9A66;
pub const tx_uuid: u128 = 0x6A4E2820_667B_11E3_949A_0800200C9A66;

pub const uuid_text_len: u32 = 36;

pub const close_all_frame = [_]u8{
    0x00, 0x05, 0x00, 0x00, client_id, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,      0x00,
};

pub const register_gfdi_frame = [_]u8{
    0x00, 0x00, client_id, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00,      0x01, 0x00, 0x00,
};

comptime {
    if (mtu_write_max < 2) @compileError("mtu_write_max must be >= 2");

    assert(service_uuid != tx_uuid);
    assert(uuid_text_len == 36);
    assert(close_all_frame.len <= mtu_write_max);
    assert(register_gfdi_frame.len == close_all_frame.len);
    assert(uuid_text(service_uuid).len == uuid_text_len);
}

pub fn uuid_text(comptime value: u128) []const u8 {
    const hex = std.fmt.comptimePrint("{x:0>32}", .{value});

    return hex[0..8] ++ "-" ++ hex[8..12] ++ "-" ++ hex[12..16] ++ "-" ++
        hex[16..20] ++ "-" ++ hex[20..32];
}

pub fn is_transfer_service(code: u16) bool {
    for (transfer_service_codes) |candidate| {
        if (candidate == code) return true;
    }

    return false;
}

const testing = std.testing;

test "uuid_text renders the lowercase hyphenated form BlueZ uses" {
    try testing.expectEqualStrings("6a4e2800-667b-11e3-949a-0800200c9a66", uuid_text(service_uuid));
    try testing.expectEqualStrings("6a4e2820-667b-11e3-949a-0800200c9a66", uuid_text(tx_uuid));
}

test "is_transfer_service accepts every registered code and nothing else" {
    for (transfer_service_codes) |code| {
        try testing.expect(is_transfer_service(code));
    }

    try testing.expect(!is_transfer_service(service_gfdi));
    try testing.expect(!is_transfer_service(0x0000));
}
