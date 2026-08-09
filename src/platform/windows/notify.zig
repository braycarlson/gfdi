const std = @import("std");

const com = @import("com.zig");
const link = @import("../../transport/link.zig");
const lock = @import("lock.zig");

const assert = std.debug.assert;

pub const NotifierVtable = extern struct {
    query_interface: *const fn (
        *Notifier,
        *const com.GUID,
        *?*anyopaque,
    ) callconv(.winapi) com.HRESULT,
    add_ref: *const fn (*Notifier) callconv(.winapi) u32,
    release: *const fn (*Notifier) callconv(.winapi) u32,
    invoke: *const fn (*Notifier, ?*anyopaque, ?*anyopaque) callconv(.winapi) com.HRESULT,
};

pub const Notifier = extern struct {
    vtable: *const NotifierVtable,
    runtime: *com.Runtime,
    free_threaded_marshaler: ?*com.IUnknown,
    state: *lock.GFDIState,
};

const debug_rx_trace = false;

pub const notifier_vtable = NotifierVtable{
    .query_interface = notifier_query_interface,
    .add_ref = notifier_add_ref,
    .release = notifier_release,
    .invoke = notifier_invoke,
};

pub fn notifier_query_interface(
    notifier: *Notifier,
    iid: *const com.GUID,
    out: *?*anyopaque,
) callconv(.winapi) com.HRESULT {
    return com.delegate_query_interface(notifier, notifier.free_threaded_marshaler, iid, out);
}

pub fn notifier_add_ref(notifier: *Notifier) callconv(.winapi) u32 {
    _ = notifier;
    return 1;
}

pub fn notifier_release(notifier: *Notifier) callconv(.winapi) u32 {
    _ = notifier;
    return 1;
}

pub fn notifier_invoke(
    notifier: *Notifier,
    sender: ?*anyopaque,
    args: ?*anyopaque,
) callconv(.winapi) com.HRESULT {
    const event: *com.IGattValueChangedEventArgs = @ptrCast(
        @alignCast(args orelse return com.S_OK),
    );

    var buffer_ptr: ?*anyopaque = null;

    if (event.vtable.get_characteristic_value(event, &buffer_ptr) != com.S_OK) return com.S_OK;
    const buffer: *com.IBuffer = @ptrCast(@alignCast(buffer_ptr orelse return com.S_OK));
    defer _ = com.as_unknown(buffer).release();

    var length: u32 = 0;
    _ = buffer.vtable.get_length(buffer, &length);

    const access_ptr = com.as_unknown(buffer).query(&com.IID_IBufferByteAccess) orelse
        return com.S_OK;
    const access: *com.IBufferByteAccess = @ptrCast(@alignCast(access_ptr));
    defer _ = com.as_unknown(access).release();

    var data: ?[*]u8 = null;

    if (access.vtable.buffer(access, &data) != com.S_OK) return com.S_OK;
    const bytes = (data orelse return com.S_OK)[0..length];

    if (bytes.len == 0) return com.S_OK;
    assert(bytes.len == length);

    trace_rx(sender, bytes, length);

    link.route_frame(notifier.state, bytes);
    return com.S_OK;
}

fn trace_rx(sender: ?*anyopaque, bytes: []const u8, length: u32) void {
    if (!debug_rx_trace) return;

    var source: u32 = 0;

    if (sender) |sender_ptr| {
        const characteristic: *com.IGattCharacteristic = @ptrCast(@alignCast(sender_ptr));
        var uuid: com.GUID = undefined;
        _ = characteristic.vtable.get_uuid(characteristic, &uuid);
        source = uuid.Data1;
    }

    if (length < 64) {
        std.debug.print("RX [{x:0>8}] {d:>3}B: ", .{ source, length });
        for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
        std.debug.print("\n", .{});
    }
}
