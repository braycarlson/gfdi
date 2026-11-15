const std = @import("std");

const com = @import("com.zig");

const assert = std.debug.assert;

const Slot = extern struct {
    index: u32,
    function: *const anyopaque,
};

const Table = extern struct {
    slots: [slots_max]*const anyopaque,
};

const Static = extern struct {
    vtable: *const Table,
};

const StaticEntry = extern struct {
    iid: *const com.GUID,
    object: *const Static,
};

pub const Interface = extern struct {
    iid: *const com.GUID = &com.IID_IUnknown,
    object: ?*Object = null,
};

pub const Object = extern struct {
    vtable: *const Table,
    references: u32 = 0,
    acquisitions: u32 = 0,
    product: ?*Object = null,
    interfaces: [interfaces_max]Interface = @splat(.{ .iid = &com.IID_IUnknown, .object = null }),
};

const async_status_completed: i32 = 1;
const interfaces_max = 2;
const slots_max = 13;

const counted_entries = [_]Slot{
    slot(com.IUnknown.Vtable, "query_interface", &query_interface),
    slot(com.IUnknown.Vtable, "add_reference", &add_reference),
    slot(com.IUnknown.Vtable, "release", &release),
};

const static_entries = [_]Slot{
    slot(com.IUnknown.Vtable, "add_reference", &static_reference),
    slot(com.IUnknown.Vtable, "release", &static_reference),
};

const device_statics_table = table_with(.static, &.{
    slot(
        com.IBluetoothLEDeviceStatics2.Vtable,
        "from_bluetooth_address_with_type_async",
        &produce_from_address,
    ),
});

const preferred_statics_table = table_with(.static, &.{
    slot(
        com.IBluetoothLEPreferredConnectionParametersStatics.Vtable,
        "get_throughput_optimized",
        &produce_preset,
    ),
});

const preset_table = table_with(.static, &.{});
const device_statics: Static = .{ .vtable = &device_statics_table };
const preferred_statics: Static = .{ .vtable = &preferred_statics_table };
const preset: Static = .{ .vtable = &preset_table };

const statics = [_]StaticEntry{
    .{ .iid = &com.IID_IBluetoothLEDeviceStatics2, .object = &device_statics },
    .{
        .iid = &com.IID_IBluetoothLEPreferredConnectionParametersStatics,
        .object = &preferred_statics,
    },
};

pub const async_operation_slots = table_with(.counted, &.{
    slot(com.IUnknown.Vtable, "query_interface", &query_async_information),
    slot(com.IAsyncInfo.Vtable, "get_status", &status_completed),
    slot(com.IAsyncOperation.Vtable, "get_results", &produce),
});

pub const device3_slots = table_with(.counted, &.{
    slot(com.IBluetoothLEDevice3.Vtable, "get_gatt_services_async", &produce),
});

pub const device6_slots = table_with(.counted, &.{
    slot(
        com.IBluetoothLEDevice6.Vtable,
        "request_preferred_connection_parameters",
        &produce_from_preset,
    ),
});

pub const services_result_slots = table_with(.counted, &.{
    slot(com.IGattDeviceServicesResult.Vtable, "get_services", &produce),
});

pub const unknown_slots = table_with(.counted, &.{});

pub const vector_view_slots = table_with(.counted, &.{
    slot(com.IVectorView.Vtable, "get_size", &size_empty),
});

fn acquire(object: *Object) *Object {
    assert(object.references <= object.acquisitions);

    object.references += 1;
    object.acquisitions += 1;

    assert(object.references <= object.acquisitions);

    return object;
}

fn activation_factory(
    class_id: com.HSTRING,
    iid: *const com.GUID,
    factory: *?*com.IUnknown,
) callconv(.winapi) com.HRESULT {
    assert(!std.meta.eql(iid.*, com.GUID_NULL));
    assert(class_id != null);

    for (statics) |entry| {
        if (std.meta.eql(entry.iid.*, iid.*)) {
            factory.* = @ptrCast(@constCast(entry.object));

            return com.S_OK;
        }
    }

    factory.* = null;

    return com.E_NOINTERFACE;
}

fn add_reference(object: *Object) callconv(.winapi) u32 {
    assert(object.references <= object.acquisitions);
    assert(object.references > 0);

    return acquire(object).references;
}

fn create_string(
    source: ?[*]const u16,
    length: u32,
    string: *com.HSTRING,
) callconv(.winapi) com.HRESULT {
    assert(source != null);
    assert(length > 0);

    string.* = @ptrCast(@constCast(source.?));

    return com.S_OK;
}

fn delete_string(string: com.HSTRING) callconv(.winapi) com.HRESULT {
    assert(string != null);

    return com.S_OK;
}

fn produce(object: *Object, out: *?*com.IUnknown) callconv(.winapi) com.HRESULT {
    assert(object.product != null);
    assert(object.references > 0);

    out.* = @ptrCast(acquire(object.product.?));

    return com.S_OK;
}

fn produce_from_address(
    object: *const Static,
    address: u64,
    address_type: i32,
    out: *?*com.IUnknown,
) callconv(.winapi) com.HRESULT {
    assert(address >> 48 == 0);
    assert(object == &device_statics);
    assert(address_type >= 0);

    const operation: *Object = @ptrFromInt(@as(usize, @intCast(address)));

    out.* = @ptrCast(acquire(operation));

    return com.S_OK;
}

fn produce_from_preset(
    object: *Object,
    parameters: *com.IUnknown,
    out: *?*com.IUnknown,
) callconv(.winapi) com.HRESULT {
    assert(object.references > 0);
    assert(@intFromPtr(parameters) == @intFromPtr(&preset));

    return produce(object, out);
}

fn produce_preset(object: *const Static, out: *?*com.IUnknown) callconv(.winapi) com.HRESULT {
    assert(object.vtable == &preferred_statics_table);
    assert(object == &preferred_statics);

    out.* = @ptrCast(@constCast(&preset));

    return com.S_OK;
}

fn query_async_information(
    object: *Object,
    iid: *const com.GUID,
    out: *?*com.IUnknown,
) callconv(.winapi) com.HRESULT {
    assert(object.vtable == &async_operation_slots);
    assert(object.references > 0);

    if (std.meta.eql(iid.*, com.IID_IAsyncInfo)) {
        out.* = @ptrCast(acquire(object));

        return com.S_OK;
    }

    return query_interface(object, iid, out);
}

fn query_interface(
    object: *Object,
    iid: *const com.GUID,
    out: *?*com.IUnknown,
) callconv(.winapi) com.HRESULT {
    assert(object.references <= object.acquisitions);
    assert(object.references > 0);
    assert(!std.meta.eql(iid.*, com.GUID_NULL));

    for (object.interfaces) |interface| {
        if (!std.meta.eql(interface.iid.*, iid.*)) continue;

        out.* = @ptrCast(acquire(interface.object orelse continue));

        return com.S_OK;
    }

    out.* = null;

    return com.E_NOINTERFACE;
}

fn release(object: *Object) callconv(.winapi) u32 {
    assert(object.references > 0);
    assert(object.references <= object.acquisitions);

    object.references -= 1;

    return object.references;
}

fn size_empty(object: *Object, size: *u32) callconv(.winapi) com.HRESULT {
    assert(object.vtable == &vector_view_slots);
    assert(object.references > 0);

    size.* = 0;

    return com.S_OK;
}

fn slot(comptime Vtable: type, comptime name: []const u8, comptime function: anytype) Slot {
    comptime assert(name.len > 0);
    comptime assert(@typeInfo(@TypeOf(function)) == .pointer);

    const index = @divExact(@offsetOf(Vtable, name), @sizeOf(*const fn () void));

    comptime assert(index < slots_max);

    return .{ .function = @ptrCast(function), .index = index };
}

const Base = enum {
    counted,
    static,
};

fn table_with(comptime base: Base, comptime entries: []const Slot) Table {
    comptime assert(entries.len < slots_max);

    const unknown: []const Slot = switch (base) {
        .counted => &counted_entries,
        .static => &static_entries,
    };

    var table: Table = .{ .slots = @splat(@ptrCast(&unexpected)) };

    for (unknown ++ entries) |entry| {
        assert(entry.index < slots_max);

        table.slots[entry.index] = entry.function;
    }

    return table;
}

fn static_reference(object: *const Static) callconv(.winapi) u32 {
    assert(object == &device_statics or object == &preferred_statics or object == &preset);

    return 1;
}

fn status_completed(object: *Object, status: *i32) callconv(.winapi) com.HRESULT {
    assert(object.vtable == &async_operation_slots);
    assert(object.references > 0);

    status.* = async_status_completed;

    return com.S_OK;
}

fn unexpected() callconv(.winapi) noreturn {
    unreachable;
}

pub fn address_of(operation: *Object) u64 {
    assert(operation.vtable == &async_operation_slots);

    const result: u64 = @intFromPtr(operation);

    assert(result >> 48 == 0);

    return result;
}

pub fn runtime() com.Runtime {
    return .{
        .activate_instance_function = @ptrCast(&unexpected),
        .create_free_threaded_marshaler = @ptrCast(&unexpected),
        .create_string = &create_string,
        .delete_string = &delete_string,
        .get_activation_factory = &activation_factory,
        .get_string_raw_buffer = @ptrCast(&unexpected),
        .initialize = @ptrCast(&unexpected),
        .initialized = true,
        .uninitialize = @ptrCast(&unexpected),
    };
}
