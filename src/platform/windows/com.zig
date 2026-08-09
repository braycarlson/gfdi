const std = @import("std");

const time = @import("time.zig");

const assert = std.debug.assert;

pub const GUID = std.os.windows.GUID;
pub const HANDLE = std.os.windows.HANDLE;
pub const HMODULE = std.os.windows.HMODULE;
pub const HRESULT = i32;
pub const HSTRING = ?*anyopaque;

pub const completion_timeout_ms: u64 = 5000;

pub const POINT = extern struct { x: i32, y: i32 };

pub const MSG = extern struct {
    hwnd: ?HANDLE,
    message: u32,
    w_param: usize,
    l_param: isize,
    time: u32,
    pt: POINT,
};

pub const RoInitialize_t = *const fn (init_type: c_int) callconv(.winapi) HRESULT;
pub const RoUninitialize_t = *const fn () callconv(.winapi) void;
pub const RoGetActivationFactory_t = *const fn (
    class_id: HSTRING,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;
pub const RoActivateInstance_t = *const fn (
    class_id: HSTRING,
    instance: *?*anyopaque,
) callconv(.winapi) HRESULT;
pub const CoCreateFreeThreadedMarshaler_t = *const fn (
    outer: *anyopaque,
    marshaler: *?*anyopaque,
) callconv(.winapi) HRESULT;
pub const WindowsCreateString_t = *const fn (
    source: ?[*]const u16,
    length: u32,
    string: *HSTRING,
) callconv(.winapi) HRESULT;
pub const WindowsDeleteString_t = *const fn (string: HSTRING) callconv(.winapi) HRESULT;
pub const WindowsGetStringRawBuffer_t = *const fn (
    string: HSTRING,
    length: ?*u32,
) callconv(.winapi) [*:0]const u16;

pub const Runtime = struct {
    arena: std.mem.Allocator,
    ro_initialize: RoInitialize_t,
    ro_uninitialize: RoUninitialize_t,
    ro_get_activation_factory: RoGetActivationFactory_t,
    ro_activate_instance: RoActivateInstance_t,
    co_create_ftm: CoCreateFreeThreadedMarshaler_t,
    create_string: WindowsCreateString_t,
    delete_string: WindowsDeleteString_t,
    get_string_raw_buffer: WindowsGetStringRawBuffer_t,

    pub fn init(arena: std.mem.Allocator) !Runtime {
        const combase = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("combase.dll")) orelse
            return error.NoCombase;
        const ole32 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("ole32.dll")) orelse
            return error.NoOle32;

        const runtime = Runtime{
            .arena = arena,
            .ro_initialize = try load(RoInitialize_t, combase, "RoInitialize"),
            .ro_uninitialize = try load(RoUninitialize_t, combase, "RoUninitialize"),
            .ro_get_activation_factory = try load(
                RoGetActivationFactory_t,
                combase,
                "RoGetActivationFactory",
            ),
            .ro_activate_instance = try load(RoActivateInstance_t, combase, "RoActivateInstance"),
            .co_create_ftm = try load(
                CoCreateFreeThreadedMarshaler_t,
                ole32,
                "CoCreateFreeThreadedMarshaler",
            ),
            .create_string = try load(WindowsCreateString_t, combase, "WindowsCreateString"),
            .delete_string = try load(WindowsDeleteString_t, combase, "WindowsDeleteString"),
            .get_string_raw_buffer = try load(
                WindowsGetStringRawBuffer_t,
                combase,
                "WindowsGetStringRawBuffer",
            ),
        };

        if (runtime.ro_initialize(RO_INIT_SINGLETHREADED) < 0) return error.RoInitializeFailed;
        return runtime;
    }

    pub fn deinit(runtime: *Runtime) void {
        runtime.ro_uninitialize();
    }

    pub fn string(runtime: *Runtime, text: []const u8) !HSTRING {
        const utf16 = try std.unicode.utf8ToUtf16LeAlloc(runtime.arena, text);
        assert(utf16.len <= std.math.maxInt(u32));
        var handle: HSTRING = null;

        if (runtime.create_string(
            utf16.ptr,
            @intCast(utf16.len),
            &handle,
        ) != S_OK) return error.CreateStringFailed;
        return handle;
    }

    pub fn delete(runtime: *Runtime, handle: HSTRING) void {
        _ = runtime.delete_string(handle);
    }

    pub fn to_utf8(runtime: *Runtime, handle: HSTRING) ![]u8 {
        var length: u32 = 0;
        const raw = runtime.get_string_raw_buffer(handle, &length);

        return std.unicode.utf16LeToUtf8Alloc(runtime.arena, raw[0..length]);
    }

    pub fn activation_factory(
        runtime: *Runtime,
        class_name: []const u8,
        iid: *const GUID,
    ) !*anyopaque {
        const class_id = try runtime.string(class_name);
        defer runtime.delete(class_id);

        var factory: ?*anyopaque = null;
        const result = runtime.ro_get_activation_factory(class_id, iid, &factory);

        if (result != S_OK) return error.NoActivationFactory;
        return factory orelse error.NoActivationFactory;
    }

    pub fn activate_instance(runtime: *Runtime, class_name: []const u8) !*anyopaque {
        const class_id = try runtime.string(class_name);
        defer runtime.delete(class_id);

        var instance: ?*anyopaque = null;

        if (runtime.ro_activate_instance(class_id, &instance) != S_OK) return error.ActivateFailed;
        return instance orelse error.ActivateFailed;
    }
};

pub const IBluetoothLEDeviceStatics = extern struct {
    vtable: *const Vtable,

    pub const Vtable = extern struct {
        query_interface: *const fn (
            *IBluetoothLEDeviceStatics,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        add_ref: *const fn (*IBluetoothLEDeviceStatics) callconv(.winapi) u32,
        release: *const fn (*IBluetoothLEDeviceStatics) callconv(.winapi) u32,
        get_iids: *const fn (*IBluetoothLEDeviceStatics, *u32, *?[*]GUID) callconv(.winapi) HRESULT,
        get_runtime_class_name: *const fn (
            *IBluetoothLEDeviceStatics,
            *HSTRING,
        ) callconv(.winapi) HRESULT,
        get_trust_level: *const fn (*IBluetoothLEDeviceStatics, *i32) callconv(.winapi) HRESULT,
        from_id_async: *const fn (
            *IBluetoothLEDeviceStatics,
            HSTRING,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        from_bluetooth_address_async: *const fn (
            *IBluetoothLEDeviceStatics,
            u64,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        get_device_selector: *const fn (
            *IBluetoothLEDeviceStatics,
            *HSTRING,
        ) callconv(.winapi) HRESULT,
    };

    pub fn get_device_selector(statics: *IBluetoothLEDeviceStatics) !HSTRING {
        var handle: HSTRING = null;

        if (statics.vtable.get_device_selector(
            statics,
            &handle,
        ) != S_OK) return error.GetDeviceSelectorFailed;
        return handle;
    }

    pub fn release(statics: *IBluetoothLEDeviceStatics) void {
        _ = statics.vtable.release(statics);
    }
};

pub const IUnknown = extern struct {
    vtable: *const Vtable,

    pub const Vtable = extern struct {
        query_interface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        add_ref: *const fn (*IUnknown) callconv(.winapi) u32,
        release: *const fn (*IUnknown) callconv(.winapi) u32,
    };

    pub fn query(unknown: *IUnknown, iid: *const GUID) ?*anyopaque {
        var out: ?*anyopaque = null;

        if (unknown.vtable.query_interface(unknown, iid, &out) != S_OK) return null;
        return out;
    }

    pub fn release(unknown: *IUnknown) void {
        _ = unknown.vtable.release(unknown);
    }
};

pub const IAsyncInfo = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_id: *const fn (*IAsyncInfo, *u32) callconv(.winapi) HRESULT,
        get_status: *const fn (*IAsyncInfo, *i32) callconv(.winapi) HRESULT,
    };
};

pub const IAsyncOperation = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        put_completed: *const anyopaque,
        get_completed: *const anyopaque,
        get_results: *const fn (*IAsyncOperation, *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

pub const IVectorView = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_at: *const fn (*IVectorView, u32, *?*anyopaque) callconv(.winapi) HRESULT,
        get_size: *const fn (*IVectorView, *u32) callconv(.winapi) HRESULT,
    };
};

pub const IDeviceInformationStatics = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        create_from_id_async: *const anyopaque,
        create_from_id_async_additional: *const anyopaque,
        find_all_async: *const anyopaque,
        find_all_async_device_class: *const anyopaque,
        find_all_async_aqs: *const fn (
            *IDeviceInformationStatics,
            HSTRING,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IDeviceInformation = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_id: *const fn (*IDeviceInformation, *HSTRING) callconv(.winapi) HRESULT,
        get_name: *const fn (*IDeviceInformation, *HSTRING) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEAdvertisementWatcher = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_min_sampling_interval: *const anyopaque,
        get_max_sampling_interval: *const anyopaque,
        get_min_out_of_range_timeout: *const anyopaque,
        get_max_out_of_range_timeout: *const anyopaque,
        get_status: *const anyopaque,
        get_scanning_mode: *const anyopaque,
        put_scanning_mode: *const fn (
            *IBluetoothLEAdvertisementWatcher,
            i32,
        ) callconv(.winapi) HRESULT,
        get_signal_strength_filter: *const anyopaque,
        put_signal_strength_filter: *const anyopaque,
        get_advertisement_filter: *const anyopaque,
        put_advertisement_filter: *const anyopaque,
        start: *const fn (*IBluetoothLEAdvertisementWatcher) callconv(.winapi) HRESULT,
        stop: *const fn (*IBluetoothLEAdvertisementWatcher) callconv(.winapi) HRESULT,
        add_received: *const fn (
            *IBluetoothLEAdvertisementWatcher,
            ?*anyopaque,
            *i64,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEAdvertisementReceivedEventArgs = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_raw_signal_strength: *const anyopaque,
        get_bluetooth_address: *const fn (
            *IBluetoothLEAdvertisementReceivedEventArgs,
            *u64,
        ) callconv(.winapi) HRESULT,
        get_advertisement_type: *const anyopaque,
        get_timestamp: *const anyopaque,
        get_advertisement: *const fn (
            *IBluetoothLEAdvertisementReceivedEventArgs,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEAdvertisement = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_flags: *const anyopaque,
        put_flags: *const anyopaque,
        get_local_name: *const fn (*IBluetoothLEAdvertisement, *HSTRING) callconv(.winapi) HRESULT,
    };
};

pub const HandlerVtable = extern struct {
    query_interface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    add_ref: *const fn (*anyopaque) callconv(.winapi) u32,
    release: *const fn (*anyopaque) callconv(.winapi) u32,
    invoke: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) HRESULT,
};

pub const IBluetoothLEDeviceStatics2 = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_device_selector_from_pairing_state: *const anyopaque,
        get_device_selector_from_connection_status: *const anyopaque,
        get_device_selector_from_device_name: *const anyopaque,
        get_device_selector_from_bluetooth_address: *const anyopaque,
        get_device_selector_from_bluetooth_address_with_type: *const anyopaque,
        get_device_selector_from_appearance: *const anyopaque,
        from_bluetooth_address_with_type_async: *const fn (
            *IBluetoothLEDeviceStatics2,
            u64,
            i32,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEDevice3 = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_device_access_information: *const anyopaque,
        request_access_async: *const anyopaque,
        get_gatt_services_async: *const fn (
            *IBluetoothLEDevice3,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEDevice6 = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_connection_parameters: *const fn (
            *IBluetoothLEDevice6,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        get_connection_phy: *const anyopaque,
        request_preferred_connection_parameters: *const fn (
            *IBluetoothLEDevice6,
            *anyopaque,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEConnectionParameters = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_link_timeout: *const anyopaque,
        get_connection_latency: *const anyopaque,
        get_connection_interval: *const fn (
            *IBluetoothLEConnectionParameters,
            *u16,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEPreferredConnectionParametersStatics = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_balanced: *const anyopaque,
        get_throughput_optimized: *const fn (
            *IBluetoothLEPreferredConnectionParametersStatics,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IGattDeviceServicesResult = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_status: *const anyopaque,
        get_protocol_error: *const anyopaque,
        get_services: *const fn (
            *IGattDeviceServicesResult,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IGattDeviceService = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_characteristics: *const anyopaque,
        get_included_services: *const anyopaque,
        get_device_id: *const anyopaque,
        get_uuid: *const fn (*IGattDeviceService, *GUID) callconv(.winapi) HRESULT,
    };
};

pub const IGattDeviceService3 = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_device_access_information: *const anyopaque,
        get_session: *const anyopaque,
        get_sharing_mode: *const anyopaque,
        request_access_async: *const anyopaque,
        open_async: *const anyopaque,
        get_characteristics_async: *const fn (
            *IGattDeviceService3,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IGattCharacteristicsResult = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_status: *const anyopaque,
        get_protocol_error: *const anyopaque,
        get_characteristics: *const fn (
            *IGattCharacteristicsResult,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IGattCharacteristic = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_descriptors: *const anyopaque,
        get_characteristic_properties: *const fn (
            *IGattCharacteristic,
            *u32,
        ) callconv(.winapi) HRESULT,
        get_protection_level: *const anyopaque,
        put_protection_level: *const anyopaque,
        get_user_description: *const anyopaque,
        get_uuid: *const fn (*IGattCharacteristic, *GUID) callconv(.winapi) HRESULT,
        get_attribute_handle: *const anyopaque,
        get_presentation_formats: *const anyopaque,
        read_value_async: *const anyopaque,
        read_value_with_cache_mode_async: *const anyopaque,
        write_value_async: *const anyopaque,
        write_value_with_option_async: *const fn (
            *IGattCharacteristic,
            ?*anyopaque,
            i32,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        read_cccd_async: *const anyopaque,
        write_cccd_async: *const fn (
            *IGattCharacteristic,
            i32,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        add_value_changed: *const fn (
            *IGattCharacteristic,
            ?*anyopaque,
            *i64,
        ) callconv(.winapi) HRESULT,
        remove_value_changed: *const fn (
            *IGattCharacteristic,
            i64,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IGattValueChangedEventArgs = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_characteristic_value: *const fn (
            *IGattValueChangedEventArgs,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBuffer = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_capacity: *const anyopaque,
        get_length: *const fn (*IBuffer, *u32) callconv(.winapi) HRESULT,
        put_length: *const fn (*IBuffer, u32) callconv(.winapi) HRESULT,
    };
};

pub const IBufferFactory = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        create: *const fn (*IBufferFactory, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

pub const IBufferByteAccess = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_ref: *const anyopaque,
        release: *const anyopaque,
        buffer: *const fn (*IBufferByteAccess, *?[*]u8) callconv(.winapi) HRESULT,
    };
};

pub const RO_INIT_SINGLETHREADED: c_int = 0;
pub const RO_INIT_MULTITHREADED: c_int = 1;
pub const S_OK: HRESULT = 0;

pub const IID_IBluetoothLEDeviceStatics = GUID{
    .Data1 = 0xC8CF1A19,
    .Data2 = 0xF0B6,
    .Data3 = 0x4BF0,
    .Data4 = .{ 0x86, 0x89, 0x41, 0x30, 0x3D, 0xE2, 0xD9, 0xF4 },
};

pub const IID_IAsyncInfo = GUID{
    .Data1 = 0x00000036,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

pub const IID_IDeviceInformationStatics = GUID{
    .Data1 = 0xC17F100E,
    .Data2 = 0x3A46,
    .Data3 = 0x4A78,
    .Data4 = .{ 0x80, 0x13, 0x76, 0x9D, 0xC9, 0xB9, 0x73, 0x90 },
};

pub const IID_IDeviceInformation = GUID{
    .Data1 = 0xABA0FB95,
    .Data2 = 0x4398,
    .Data3 = 0x489D,
    .Data4 = .{ 0x8E, 0x44, 0xE6, 0x13, 0x09, 0x27, 0x01, 0x1F },
};

pub const IID_IBluetoothLEAdvertisementWatcher = GUID{
    .Data1 = 0xA6AC336F,
    .Data2 = 0xF3D3,
    .Data3 = 0x4297,
    .Data4 = .{ 0x8D, 0x6C, 0xC8, 0x1E, 0xA6, 0x62, 0x3F, 0x40 },
};

pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

pub const IID_IMarshal = GUID{
    .Data1 = 0x00000003,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

pub const IID_IInspectable = GUID{
    .Data1 = 0xAF86E2E0,
    .Data2 = 0xB12D,
    .Data3 = 0x4C6A,
    .Data4 = .{ 0x9C, 0x5A, 0xD7, 0xAA, 0x65, 0x10, 0x1E, 0x90 },
};

pub const IID_INoMarshal = GUID{
    .Data1 = 0xECC8691B,
    .Data2 = 0xC1DB,
    .Data3 = 0x4DC0,
    .Data4 = .{ 0x85, 0x5E, 0x65, 0xF6, 0xC5, 0x51, 0xAF, 0x49 },
};

pub const IID_IUnknown = GUID{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

pub const IID_IAgileObject = GUID{
    .Data1 = 0x94EA2B94,
    .Data2 = 0xE9CC,
    .Data3 = 0x49E0,
    .Data4 = .{ 0xC0, 0xFF, 0xEE, 0x64, 0xCA, 0x8F, 0x5B, 0x90 },
};

pub const IID_ITypedEventHandler = GUID{
    .Data1 = 0x90EB4ECA,
    .Data2 = 0xD465,
    .Data3 = 0x5EA0,
    .Data4 = .{ 0xA6, 0x1C, 0x03, 0x3C, 0x8C, 0x5E, 0xCE, 0xF2 },
};

pub const IID_IStdMarshalInfo = GUID{
    .Data1 = 0x0000001B,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

pub const IID_IBluetoothLEDeviceStatics2 = GUID{
    .Data1 = 0x5F12C06B,
    .Data2 = 0x3BAC,
    .Data3 = 0x43E8,
    .Data4 = .{ 0xAD, 0x16, 0x56, 0x32, 0x71, 0xBD, 0x41, 0xC2 },
};

pub const IID_IBluetoothLEDevice3 = GUID{
    .Data1 = 0xAEE9E493,
    .Data2 = 0x44AC,
    .Data3 = 0x40DC,
    .Data4 = .{ 0xAF, 0x33, 0xB2, 0xC1, 0x3C, 0x01, 0xCA, 0x46 },
};

pub const IID_IGattDeviceServicesResult = GUID{
    .Data1 = 0x171DD3EE,
    .Data2 = 0x016D,
    .Data3 = 0x419D,
    .Data4 = .{ 0x83, 0x8A, 0x57, 0x6C, 0xF4, 0x75, 0xA3, 0xD8 },
};

pub const IID_IBluetoothLEDevice6 = GUID{
    .Data1 = 0xCA7190EF,
    .Data2 = 0x0CAE,
    .Data3 = 0x573C,
    .Data4 = .{ 0xA1, 0xCA, 0xE1, 0xFC, 0x5B, 0xFC, 0x39, 0xE2 },
};

pub const IID_IBluetoothLEConnectionParameters = GUID{
    .Data1 = 0x33CB0771,
    .Data2 = 0x8DA9,
    .Data3 = 0x508F,
    .Data4 = .{ 0xA3, 0x66, 0x1C, 0xA3, 0x88, 0xC9, 0x29, 0xAB },
};

pub const IID_IBluetoothLEPreferredConnectionParametersStatics = GUID{
    .Data1 = 0x0E3E8EDC,
    .Data2 = 0x2751,
    .Data3 = 0x55AA,
    .Data4 = .{ 0xA8, 0x38, 0x8F, 0xAE, 0xEE, 0x81, 0x8D, 0x72 },
};

pub const IID_IGattDeviceService3 = GUID{
    .Data1 = 0xB293A950,
    .Data2 = 0x0C53,
    .Data3 = 0x437C,
    .Data4 = .{ 0xA9, 0xB3, 0x5C, 0x32, 0x10, 0xC6, 0xE5, 0x69 },
};

pub const IID_IGattValueChangedEventArgs = GUID{
    .Data1 = 0xD21BDB54,
    .Data2 = 0x06E3,
    .Data3 = 0x4ED8,
    .Data4 = .{ 0xA2, 0x63, 0xAC, 0xFA, 0xC8, 0xBA, 0x73, 0x13 },
};

pub const IID_IBufferByteAccess = GUID{
    .Data1 = 0x905A0FEF,
    .Data2 = 0xBC53,
    .Data3 = 0x11DF,
    .Data4 = .{ 0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x86, 0xDA },
};

pub const IID_IBufferFactory = GUID{
    .Data1 = 0x71AF914D,
    .Data2 = 0xC10F,
    .Data3 = 0x484B,
    .Data4 = .{ 0xBC, 0x50, 0x14, 0xBC, 0x62, 0x3B, 0x3A, 0x27 },
};

pub extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(
    module: HMODULE,
    name: [*:0]const u8,
) callconv(.winapi) ?std.os.windows.FARPROC;
pub extern "user32" fn PeekMessageW(
    msg: *MSG,
    hwnd: ?HANDLE,
    filter_min: u32,
    filter_max: u32,
    remove: u32,
) callconv(.winapi) i32;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) i32;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) isize;

pub fn load(comptime T: type, module: HMODULE, name: [*:0]const u8) !T {
    const proc = GetProcAddress(module, name) orelse return error.SymbolNotFound;

    return @ptrCast(proc);
}

pub fn as_unknown(pointer: anytype) *IUnknown {
    return @ptrCast(@alignCast(pointer));
}

pub fn await_operation(operation: *anyopaque) !*anyopaque {
    const info_ptr = as_unknown(operation).query(&IID_IAsyncInfo) orelse return error.NoAsyncInfo;
    const async_info: *IAsyncInfo = @ptrCast(@alignCast(info_ptr));
    defer as_unknown(async_info).release();

    var status: i32 = 0;
    var spins: u32 = 0;

    while (spins < 1500) : (spins += 1) {
        if (async_info.vtable.get_status(async_info, &status) != S_OK) return error.StatusFailed;

        if (status != 0) break;

        var pump: MSG = undefined;

        while (PeekMessageW(&pump, null, 0, 0, 1) != 0) {
            _ = TranslateMessage(&pump);
            _ = DispatchMessageW(&pump);
        }

        time.sleep_ms(10);
    }

    if (status != 1) return error.AsyncNotCompleted;

    const op: *IAsyncOperation = @ptrCast(@alignCast(operation));
    var result: ?*anyopaque = null;

    if (op.vtable.get_results(op, &result) != S_OK) return error.GetResultsFailed;
    return result orelse error.NullResult;
}

pub fn guid_eql(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

pub fn delegate_query_interface(
    object: *anyopaque,
    marshaler: ?*IUnknown,
    iid: *const GUID,
    out: *?*anyopaque,
) HRESULT {
    if (guid_eql(iid, &IID_IMarshal)) {
        if (marshaler) |ftm| return ftm.vtable.query_interface(ftm, iid, out);
        out.* = null;
        return E_NOINTERFACE;
    }

    if (guid_eql(iid, &IID_INoMarshal) or guid_eql(
        iid,
        &IID_IStdMarshalInfo,
    ) or guid_eql(iid, &IID_IInspectable)) {
        out.* = null;
        return E_NOINTERFACE;
    }

    out.* = object;
    return S_OK;
}

pub fn make_buffer(runtime: *Runtime, data: []const u8) !*anyopaque {
    assert(data.len > 0);
    assert(data.len <= std.math.maxInt(u32));

    const factory_ptr = try runtime.activation_factory(
        "Windows.Storage.Streams.Buffer",
        &IID_IBufferFactory,
    );

    const factory: *IBufferFactory = @ptrCast(@alignCast(factory_ptr));
    defer _ = as_unknown(factory).release();

    var buffer_any: ?*anyopaque = null;

    if (factory.vtable.create(
        factory,
        @intCast(data.len),
        &buffer_any,
    ) != S_OK) return error.BufferCreateFailed;
    const buffer = buffer_any orelse return error.BufferCreateFailed;
    const ibuffer: *IBuffer = @ptrCast(@alignCast(buffer));

    const access_ptr = as_unknown(ibuffer).query(&IID_IBufferByteAccess) orelse
        return error.NoByteAccess;
    const access: *IBufferByteAccess = @ptrCast(@alignCast(access_ptr));
    defer _ = as_unknown(access).release();

    var dest: ?[*]u8 = null;

    if (access.vtable.buffer(access, &dest) != S_OK) return error.BufferAccessFailed;
    @memcpy((dest orelse return error.BufferAccessFailed)[0..data.len], data);
    if (ibuffer.vtable.put_length(
        ibuffer,
        @intCast(data.len),
    ) != S_OK) return error.PutLengthFailed;

    return buffer;
}

pub fn write_characteristic(characteristic: *IGattCharacteristic, buffer: *anyopaque) !void {
    var operation: ?*anyopaque = null;

    if (characteristic.vtable.write_value_with_option_async(
        characteristic,
        buffer,
        1,
        &operation,
    ) != S_OK) return error.WriteFailed;
    try await_completion(operation orelse return error.WriteFailed);
}

pub fn await_completion(operation: *anyopaque) !void {
    const info_ptr = as_unknown(operation).query(&IID_IAsyncInfo) orelse return error.NoAsyncInfo;
    const async_info: *IAsyncInfo = @ptrCast(@alignCast(info_ptr));
    defer as_unknown(async_info).release();

    var status: i32 = 0;

    const start = time.now_ms();

    while (time.now_ms() - start < completion_timeout_ms) {
        if (async_info.vtable.get_status(async_info, &status) != S_OK) return error.StatusFailed;
        if (status != 0) break;
        var pump: MSG = undefined;

        while (PeekMessageW(&pump, null, 0, 0, 1) != 0) {
            _ = TranslateMessage(&pump);
            _ = DispatchMessageW(&pump);
        }

        time.sleep_ms(0);
    }

    if (status != 1) {
        @branchHint(.cold);
        std.debug.print("async terminal status={d} (0=Started,2=Canceled,3=Error)\n", .{status});
        return error.AsyncNotCompleted;
    }
}
