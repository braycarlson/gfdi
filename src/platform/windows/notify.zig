const std = @import("std");

const com = @import("com.zig");
const lock = @import("lock.zig");
const transport = @import("../../transport.zig");

const assert = std.debug.assert;

pub const NotifierVtable = extern struct {
    query_interface: *const fn (
        *Notifier,
        *const com.GUID,
        *?*com.IUnknown,
    ) callconv(.winapi) com.HRESULT,
    add_reference: *const fn (*Notifier) callconv(.winapi) u32,
    release: *const fn (*Notifier) callconv(.winapi) u32,
    invoke: *const fn (*Notifier, ?*com.IUnknown, ?*com.IUnknown) callconv(.winapi) com.HRESULT,
};

pub const Notifier = extern struct {
    vtable: *const NotifierVtable,
    runtime: *com.Runtime,
    free_threaded_marshaler: ?*com.IUnknown,
    state: *lock.GFDIState,
};

const receive_trace_enabled = false;
const receive_trace_bytes_max: u32 = 64;

pub const notifier_vtable = NotifierVtable{
    .add_reference = notifier_add_reference,
    .invoke = notifier_invoke,
    .query_interface = notifier_query_interface,
    .release = notifier_release,
};

pub fn notifier_query_interface(
    notifier: *Notifier,
    iid: *const com.GUID,
    out: *?*com.IUnknown,
) callconv(.winapi) com.HRESULT {
    assert(notifier.vtable == &notifier_vtable);
    assert(notifier.runtime.initialized);

    return com.delegate_query_interface(
        @ptrCast(notifier),
        notifier.free_threaded_marshaler,
        iid,
        out,
    );
}

pub fn notifier_add_reference(notifier: *Notifier) callconv(.winapi) u32 {
    assert(notifier.runtime.initialized);
    assert(notifier.vtable == &notifier_vtable);

    return 1;
}

pub fn notifier_release(notifier: *Notifier) callconv(.winapi) u32 {
    assert(notifier.runtime.initialized);
    assert(notifier.vtable == &notifier_vtable);

    return 1;
}

pub fn notifier_invoke(
    notifier: *Notifier,
    sender: ?*com.IUnknown,
    arguments: ?*com.IUnknown,
) callconv(.winapi) com.HRESULT {
    assert(sender != null);
    assert(arguments != null);

    const event: *com.IGattValueChangedEventArgs = @ptrCast(
        @alignCast(arguments orelse return com.S_OK),
    );

    var buffer_object: ?*com.IUnknown = null;

    if (event.vtable.get_characteristic_value(event, &buffer_object) != com.S_OK) return com.S_OK;

    const object = buffer_object orelse return com.S_OK;
    defer object.release();

    const buffer: *com.IBuffer = @ptrCast(@alignCast(object));

    var length: u32 = 0;

    _ = buffer.vtable.get_length(buffer, &length);

    const access_object = object.query(&com.IID_IBufferByteAccess) orelse return com.S_OK;
    defer access_object.release();

    const access: *com.IBufferByteAccess = @ptrCast(@alignCast(access_object));
    const bytes = access.bytes(length) orelse return com.S_OK;

    if (bytes.len == 0) return com.S_OK;

    receive_trace(sender, bytes);

    transport.link.route_frame(lock.GFDIState, notifier.state, bytes);

    return com.S_OK;
}

fn receive_trace(sender: ?*com.IUnknown, bytes: []const u8) void {
    assert(sender != null);
    assert(bytes.len > 0);

    if (!receive_trace_enabled) return;
    if (bytes.len >= receive_trace_bytes_max) return;

    var source: u32 = 0;

    if (sender) |object| {
        const characteristic: *com.IGattCharacteristic = @ptrCast(@alignCast(object));

        var uuid: com.GUID = undefined;

        _ = characteristic.vtable.get_uuid(characteristic, &uuid);

        source = uuid.Data1;
    }

    std.debug.print("RX [{x:0>8}] {d:>3}B: {x}\n", .{ source, bytes.len, bytes });
}
