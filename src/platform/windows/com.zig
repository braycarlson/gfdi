const std = @import("std");

const time = @import("time.zig");

const assert = std.debug.assert;

const windows = std.os.windows;

pub const GUID = windows.GUID;
pub const HANDLE = windows.HANDLE;
pub const HMODULE = windows.HMODULE;
pub const HRESULT = i32;
pub const HSTRING = ?*opaque {};

pub const POINT = extern struct {
    horizontal: i32,
    vertical: i32,
};

pub const MSG = extern struct {
    hwnd: ?HANDLE,
    message: u32,
    word_parameter: windows.ULONG_PTR,
    long_parameter: windows.LPARAM,
    time: u32,
    point: POINT,
};

pub const Runtime = extern struct {
    activate_instance_function: *const fn (HSTRING, *?*IUnknown) callconv(.winapi) HRESULT,
    create_free_threaded_marshaler: *const fn (
        *IUnknown,
        *?*IUnknown,
    ) callconv(.winapi) HRESULT,
    create_string: *const fn (?[*]const u16, u32, *HSTRING) callconv(.winapi) HRESULT,
    delete_string: *const fn (HSTRING) callconv(.winapi) HRESULT,
    get_activation_factory: *const fn (
        HSTRING,
        *const GUID,
        *?*IUnknown,
    ) callconv(.winapi) HRESULT,
    get_string_raw_buffer: *const fn (HSTRING, ?*u32) callconv(.winapi) [*:0]const u16,
    initialize: *const fn (c_int) callconv(.winapi) HRESULT,
    initialized: bool,
    uninitialize: *const fn () callconv(.winapi) void,

    pub fn init() LoadError!Runtime {
        const combase_name = std.unicode.utf8ToUtf16LeStringLiteral("combase.dll");
        const ole32_name = std.unicode.utf8ToUtf16LeStringLiteral("ole32.dll");
        const combase = LoadLibraryW(combase_name) orelse return error.LibraryMissing;
        const ole32 = LoadLibraryW(ole32_name) orelse return error.LibraryMissing;

        const runtime = Runtime{
            .activate_instance_function = try load(combase, .activate_instance_function),
            .create_free_threaded_marshaler = try load(ole32, .create_free_threaded_marshaler),
            .create_string = try load(combase, .create_string),
            .delete_string = try load(combase, .delete_string),
            .get_activation_factory = try load(combase, .get_activation_factory),
            .get_string_raw_buffer = try load(combase, .get_string_raw_buffer),
            .initialize = try load(combase, .initialize),
            .initialized = true,
            .uninitialize = try load(combase, .uninitialize),
        };

        if (runtime.initialize(RO_INIT_SINGLETHREADED) < 0) return error.InitializeFailed;
        return runtime;
    }

    pub fn deinit(runtime: *Runtime) void {
        assert(runtime.initialized);

        runtime.uninitialize();
        runtime.initialized = false;
    }

    pub fn string(runtime: *Runtime, text: []const u8) Error!String {
        if (text.len > string_bytes_max) return error.StringTooLong;

        assert(runtime.initialized);

        var units: [string_bytes_max]u16 = undefined;

        const count = std.unicode.utf8ToUtf16Le(&units, text) catch return error.StringInvalid;

        assert(count <= text.len);

        var handle: HSTRING = null;

        if (runtime.create_string(&units, @intCast(count), &handle) != S_OK) {
            return error.CreateStringFailed;
        }

        return .{ .handle = handle, .runtime = runtime };
    }

    pub fn delete(runtime: *Runtime, text: *const String) void {
        assert(text.runtime == runtime);
        assert(runtime.initialized);

        _ = runtime.delete_string(text.handle);
    }

    pub fn to_utf8(runtime: *Runtime, text: *const String, buffer: []u8) Error![]const u8 {
        assert(text.runtime == runtime);
        assert(buffer.len > 0);
        assert(runtime.initialized);

        var length: u32 = 0;

        const raw = runtime.get_string_raw_buffer(text.handle, &length);

        return utf8_from_utf16(raw[0..length], buffer);
    }

    fn utf8_from_utf16(units: []const u16, buffer: []u8) Error![]const u8 {
        assert(buffer.len > 0);
        assert(units.len <= std.math.maxInt(u32));

        var length: u64 = 0;

        for (units) |unit| {
            length += switch (std.mem.littleToNative(u16, unit)) {
                0x0000...0x007F => 1,
                0x0080...0x07FF => 2,
                0xD800...0xDFFF => 2,
                else => 3,
            };
        }

        if (length > buffer.len) return error.StringTooLong;

        const count = std.unicode.utf16LeToUtf8(buffer, units) catch return error.StringInvalid;

        assert(count == length);

        return buffer[0..count];
    }

    pub fn activation_factory(
        runtime: *Runtime,
        class_name: []const u8,
        iid: *const GUID,
    ) Error!*IUnknown {
        assert(!std.meta.eql(iid.*, GUID_NULL));
        assert(class_name.len > 0);
        assert(runtime.initialized);

        const class_id = try runtime.string(class_name);
        defer runtime.delete(&class_id);

        var factory: ?*IUnknown = null;

        if (runtime.get_activation_factory(class_id.handle, iid, &factory) != S_OK) {
            return error.ActivationFactoryMissing;
        }

        return factory orelse error.ActivationFactoryMissing;
    }

    pub fn activate_instance(runtime: *Runtime, class_name: []const u8) Error!*IUnknown {
        assert(class_name.len <= string_bytes_max);
        assert(class_name.len > 0);
        assert(runtime.initialized);

        const class_id = try runtime.string(class_name);
        defer runtime.delete(&class_id);

        var instance: ?*IUnknown = null;

        if (runtime.activate_instance_function(class_id.handle, &instance) != S_OK) {
            return error.ActivateFailed;
        }

        return instance orelse error.ActivateFailed;
    }

    pub fn marshaler_create(runtime: *Runtime, outer: *IUnknown) Error!*IUnknown {
        assert(runtime.initialized);

        var marshaler: ?*IUnknown = null;

        if (runtime.create_free_threaded_marshaler(outer, &marshaler) != S_OK) {
            return error.MarshalerFailed;
        }

        const result = marshaler orelse return error.MarshalerFailed;

        assert(result != outer);

        return result;
    }
};

pub const String = struct {
    handle: HSTRING,
    runtime: *Runtime,
};

pub const CallError = error{
    ActivateFailed,
    ActivationFactoryMissing,
    AsyncNotCompleted,
    BufferAccessFailed,
    BufferCreateFailed,
    CreateStringFailed,
    DeviceSelectorFailed,
    MarshalerFailed,
    NoAsyncInformation,
    NoByteAccess,
    NullResult,
    PutLengthFailed,
    ResultsFailed,
    StatusFailed,
    StringInvalid,
    ValueWriteFailed,
};

pub const CapacityError = error{
    StringTooLong,
};

pub const LoadError = error{
    InitializeFailed,
    LibraryMissing,
    SymbolMissing,
};

pub const Error = CallError || CapacityError || LoadError;

pub const completion_timeout_ms: u64 = 5000;
pub const string_bytes_max: u32 = 256;
const async_status_completed: i32 = 1;
const async_status_started: i32 = 0;
const operation_spins_max: u32 = 1500;
const operation_spin_sleep_ms: u32 = 10;
const message_remove: u32 = 1;

pub const IBluetoothLEDeviceStatics = extern struct {
    vtable: *const Vtable,

    pub const Vtable = extern struct {
        query_interface: *const fn (
            *IBluetoothLEDeviceStatics,
            *const GUID,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
        add_reference: *const fn (*IBluetoothLEDeviceStatics) callconv(.winapi) u32,
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
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,

        from_bluetooth_address_async: *const fn (
            *IBluetoothLEDeviceStatics,
            u64,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,

        get_device_selector: *const fn (
            *IBluetoothLEDeviceStatics,
            *HSTRING,
        ) callconv(.winapi) HRESULT,
    };

    pub fn get_device_selector(statics: *IBluetoothLEDeviceStatics) Error!HSTRING {
        var handle: HSTRING = null;

        if (statics.vtable.get_device_selector(
            statics,
            &handle,
        ) != S_OK) return error.DeviceSelectorFailed;

        return handle;
    }
};

pub const IUnknown = extern struct {
    vtable: *const Vtable,

    pub const Vtable = extern struct {
        query_interface: *const fn (*IUnknown, *const GUID, *?*IUnknown) callconv(.winapi) HRESULT,
        add_reference: *const fn (*IUnknown) callconv(.winapi) u32,
        release: *const fn (*IUnknown) callconv(.winapi) u32,
    };

    pub fn query(unknown: *IUnknown, iid: *const GUID) ?*IUnknown {
        assert(!std.meta.eql(iid.*, GUID_NULL));

        var out: ?*IUnknown = null;

        if (unknown.vtable.query_interface(unknown, iid, &out) != S_OK) return null;

        return out;
    }

    pub fn release(unknown: *IUnknown) void {
        const count = unknown.vtable.release(unknown);

        assert(count != std.math.maxInt(u32));
    }
};

pub const IAsyncInfo = extern struct {
    vtable: *const Vtable,
    pub const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
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
    pub const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        put_completed: *const anyopaque,
        get_completed: *const anyopaque,
        get_results: *const fn (*IAsyncOperation, *?*IUnknown) callconv(.winapi) HRESULT,
    };
};

pub const IVectorView = extern struct {
    vtable: *const Vtable,
    pub const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_at: *const fn (*IVectorView, u32, *?*IUnknown) callconv(.winapi) HRESULT,
        get_size: *const fn (*IVectorView, *u32) callconv(.winapi) HRESULT,
    };
};

pub const IDeviceInformationStatics = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
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
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IDeviceInformation = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
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
        add_reference: *const anyopaque,
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
            ?*IUnknown,
            *i64,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEAdvertisementReceivedEventArgs = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
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
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEAdvertisement = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
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
    query_interface: *const fn (*IUnknown, *const GUID, *?*IUnknown) callconv(.winapi) HRESULT,
    add_reference: *const fn (*IUnknown) callconv(.winapi) u32,
    release: *const fn (*IUnknown) callconv(.winapi) u32,
    invoke: *const fn (*IUnknown, ?*IUnknown, ?*IUnknown) callconv(.winapi) HRESULT,
};

pub const IBluetoothLEDeviceStatics2 = extern struct {
    vtable: *const Vtable,
    pub const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
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
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEDevice3 = extern struct {
    vtable: *const Vtable,
    pub const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_device_access_information: *const anyopaque,
        request_access_async: *const anyopaque,
        get_gatt_services_async: *const fn (
            *IBluetoothLEDevice3,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEDevice6 = extern struct {
    vtable: *const Vtable,
    pub const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_connection_parameters: *const fn (
            *IBluetoothLEDevice6,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
        get_connection_phy: *const anyopaque,
        request_preferred_connection_parameters: *const fn (
            *IBluetoothLEDevice6,
            *IUnknown,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBluetoothLEConnectionParameters = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
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
    pub const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_balanced: *const anyopaque,
        get_throughput_optimized: *const fn (
            *IBluetoothLEPreferredConnectionParametersStatics,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IGattDeviceServicesResult = extern struct {
    vtable: *const Vtable,
    pub const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_status: *const anyopaque,
        get_protocol_error: *const anyopaque,
        get_services: *const fn (
            *IGattDeviceServicesResult,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IGattDeviceService = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
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
        add_reference: *const anyopaque,
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
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IGattCharacteristicsResult = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_status: *const anyopaque,
        get_protocol_error: *const anyopaque,
        get_characteristics: *const fn (
            *IGattCharacteristicsResult,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IGattCharacteristic = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
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
            ?*IUnknown,
            i32,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
        read_cccd_async: *const anyopaque,
        write_cccd_async: *const fn (
            *IGattCharacteristic,
            i32,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,

        add_value_changed: *const fn (
            *IGattCharacteristic,
            ?*IUnknown,
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
        add_reference: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        get_characteristic_value: *const fn (
            *IGattValueChangedEventArgs,
            *?*IUnknown,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IBuffer = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
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
        add_reference: *const anyopaque,
        release: *const anyopaque,
        get_iids: *const anyopaque,
        get_runtime_class_name: *const anyopaque,
        get_trust_level: *const anyopaque,
        create_buffer: *const fn (*IBufferFactory, u32, *?*IUnknown) callconv(.winapi) HRESULT,
    };
};

pub const IBufferByteAccess = extern struct {
    vtable: *const Vtable,
    const Vtable = extern struct {
        query_interface: *const anyopaque,
        add_reference: *const anyopaque,
        release: *const anyopaque,
        buffer: *const fn (*IBufferByteAccess, *?[*]u8) callconv(.winapi) HRESULT,
    };

    pub fn bytes(access: *IBufferByteAccess, length: u32) ?[]u8 {
        assert(length <= value_bytes_max);

        var data: ?[*]u8 = null;

        if (access.vtable.buffer(access, &data) != S_OK) return null;

        const start = data orelse return null;

        return start[0..length];
    }
};

pub const RO_INIT_SINGLETHREADED: c_int = 0;
pub const RO_INIT_MULTITHREADED: c_int = 1;
pub const S_OK: HRESULT = 0;

pub const GUID_NULL = GUID{
    .Data1 = 0,
    .Data2 = 0,
    .Data3 = 0,
    .Data4 = @splat(0),
};

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
) callconv(.winapi) ?windows.FARPROC;

pub extern "user32" fn PeekMessageW(
    message: *MSG,
    hwnd: ?HANDLE,
    filter_min: u32,
    filter_max: u32,
    remove: u32,
) callconv(.winapi) i32;

pub extern "user32" fn TranslateMessage(message: *const MSG) callconv(.winapi) i32;
pub extern "user32" fn DispatchMessageW(message: *const MSG) callconv(.winapi) windows.LPARAM;

fn load(
    module: HMODULE,
    comptime field: RuntimeField,
) LoadError!@FieldType(Runtime, @tagName(field)) {
    const procedure = GetProcAddress(module, @field(symbol_names, @tagName(field))) orelse {
        return error.SymbolMissing;
    };

    return @ptrCast(procedure);
}

const RuntimeField = std.meta.FieldEnum(Runtime);

const symbol_names = .{
    .activate_instance_function = "RoActivateInstance",
    .create_free_threaded_marshaler = "CoCreateFreeThreadedMarshaler",
    .create_string = "WindowsCreateString",
    .delete_string = "WindowsDeleteString",
    .get_activation_factory = "RoGetActivationFactory",
    .get_string_raw_buffer = "WindowsGetStringRawBuffer",
    .initialize = "RoInitialize",
    .uninitialize = "RoUninitialize",
};

pub fn as_unknown(comptime Interface: type, pointer: *Interface) *IUnknown {
    comptime assert(@hasField(Interface, "vtable"));
    comptime assert(@typeInfo(Interface).@"struct".layout == .@"extern");

    return @ptrCast(@alignCast(pointer));
}

pub fn messages_pump() void {
    var message: MSG = undefined;

    for (0..messages_pump_max) |_| {
        if (PeekMessageW(&message, null, 0, 0, message_remove) == 0) return;

        _ = TranslateMessage(&message);
        _ = DispatchMessageW(&message);
    }
}

pub fn await_operation(operation: *IUnknown) Error!*IUnknown {
    defer operation.release();

    const information = operation.query(&IID_IAsyncInfo) orelse return error.NoAsyncInformation;
    defer information.release();

    const async_information: *IAsyncInfo = @ptrCast(@alignCast(information));

    var status: i32 = async_status_started;

    for (0..operation_spins_max) |_| {
        if (async_information.vtable.get_status(async_information, &status) != S_OK) {
            return error.StatusFailed;
        }

        if (status != async_status_started) break;

        messages_pump();
        time.sleep_ms(operation_spin_sleep_ms);
    }

    if (status != async_status_completed) return error.AsyncNotCompleted;

    const typed: *IAsyncOperation = @ptrCast(@alignCast(operation));

    var result: ?*IUnknown = null;

    if (typed.vtable.get_results(typed, &result) != S_OK) return error.ResultsFailed;
    return result orelse error.NullResult;
}

pub fn await_completion(operation: *IUnknown) Error!void {
    defer operation.release();

    const information = operation.query(&IID_IAsyncInfo) orelse return error.NoAsyncInformation;
    defer information.release();

    const async_information: *IAsyncInfo = @ptrCast(@alignCast(information));
    const start = time.now_ms();

    var status: i32 = async_status_started;

    for (0..completion_timeout_ms) |_| {
        const now = time.now_ms();

        assert(now >= start);

        if (now - start >= completion_timeout_ms) break;

        if (async_information.vtable.get_status(async_information, &status) != S_OK) {
            return error.StatusFailed;
        }

        if (status != async_status_started) break;

        messages_pump();
        time.sleep_ms(0);
    }

    if (status != async_status_completed) return error.AsyncNotCompleted;
}

pub fn delegate_query_interface(
    object: *IUnknown,
    marshaler: ?*IUnknown,
    iid: *const GUID,
    out: *?*IUnknown,
) callconv(.winapi) HRESULT {
    assert(marshaler != object);

    if (std.meta.eql(iid.*, IID_IMarshal)) {
        if (marshaler) |free_threaded| {
            return free_threaded.vtable.query_interface(free_threaded, iid, out);
        }

        out.* = null;

        return E_NOINTERFACE;
    }

    const refused = [_]*const GUID{ &IID_INoMarshal, &IID_IStdMarshalInfo, &IID_IInspectable };

    for (refused) |candidate| {
        if (std.meta.eql(iid.*, candidate.*)) {
            out.* = null;

            return E_NOINTERFACE;
        }
    }

    out.* = object;

    return S_OK;
}

pub const ValueBuffer = struct {
    bytes: []u8,
    object: *IBuffer,

    pub fn init(runtime: *Runtime, capacity: u32) Error!ValueBuffer {
        assert(capacity > 0);
        assert(capacity <= value_bytes_max);

        const factory_object = try runtime.activation_factory(
            "Windows.Storage.Streams.Buffer",
            &IID_IBufferFactory,
        );

        defer factory_object.release();

        const factory: *IBufferFactory = @ptrCast(@alignCast(factory_object));

        var created: ?*IUnknown = null;

        if (factory.vtable.create_buffer(factory, capacity, &created) != S_OK) {
            return error.BufferCreateFailed;
        }

        const handle = created orelse return error.BufferCreateFailed;
        errdefer handle.release();

        const access_object = handle.query(&IID_IBufferByteAccess) orelse {
            return error.NoByteAccess;
        };

        defer access_object.release();

        const access: *IBufferByteAccess = @ptrCast(@alignCast(access_object));
        const bytes = access.bytes(capacity) orelse return error.BufferAccessFailed;

        assert(bytes.len == capacity);

        return .{ .bytes = bytes, .object = @ptrCast(@alignCast(handle)) };
    }

    pub fn deinit(buffer: *ValueBuffer) void {
        assert(buffer.bytes.len > 0);
        assert(buffer.bytes.len <= value_bytes_max);

        as_unknown(IBuffer, buffer.object).release();
    }

    pub fn write(
        buffer: *ValueBuffer,
        characteristic: *IGattCharacteristic,
        data: []const u8,
    ) Error!void {
        assert(data.len > 0);
        assert(data.len <= buffer.bytes.len);

        @memcpy(buffer.bytes[0..data.len], data);

        if (buffer.object.vtable.put_length(buffer.object, @intCast(data.len)) != S_OK) {
            return error.PutLengthFailed;
        }

        var operation: ?*IUnknown = null;

        const status = characteristic.vtable.write_value_with_option_async(
            characteristic,
            as_unknown(IBuffer, buffer.object),
            write_without_response,
            &operation,
        );

        if (status != S_OK) return error.ValueWriteFailed;

        try await_completion(operation orelse return error.ValueWriteFailed);
    }
};

const messages_pump_max: u32 = 4096;
const value_bytes_max: u32 = 512;
const write_without_response: i32 = 1;

const fake_com = @import("fake_com.zig");

test "the runtime names a string or factory failure and keeps a string it made" {
    var runtime = fake_com.runtime();

    const long: [string_bytes_max + 1]u8 = @splat('x');

    try std.testing.expectError(error.StringTooLong, runtime.string(&long));
    try std.testing.expectError(error.StringInvalid, runtime.string("\xff"));

    const text = try runtime.string("Windows");
    defer runtime.delete(&text);

    try std.testing.expect(text.handle != null);
    try std.testing.expect(text.runtime == &runtime);

    const missing = runtime.activation_factory("Windows.Storage.Streams.Buffer", &IID_IAsyncInfo);

    try std.testing.expectError(error.ActivationFactoryMissing, missing);

    try std.testing.expectError(
        error.StringTooLong,
        runtime.activation_factory(&long, &IID_IUnknown),
    );

    const class = "Windows.Devices.Bluetooth.BluetoothLEDevice";
    const first = try runtime.activation_factory(class, &IID_IBluetoothLEDeviceStatics2);
    const second = try runtime.activation_factory(class, &IID_IBluetoothLEDeviceStatics2);

    try std.testing.expectEqual(first, second);
}

test "a UTF-16 string converts when its exact UTF-8 length fits the buffer" {
    var buffer: [8]u8 = undefined;

    const ascii = std.unicode.utf8ToUtf16LeStringLiteral("abcdefgh");
    const accented = std.unicode.utf8ToUtf16LeStringLiteral("\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}");
    const pair = std.unicode.utf8ToUtf16LeStringLiteral("\u{1F600}");
    const lone = [_]u16{0xD83D};

    try std.testing.expectEqualStrings("abcdefgh", try Runtime.utf8_from_utf16(ascii, &buffer));
    try std.testing.expectEqualStrings("\u{1F600}", try Runtime.utf8_from_utf16(pair, &buffer));
    try std.testing.expectError(error.StringTooLong, Runtime.utf8_from_utf16(accented, &buffer));
    try std.testing.expectError(error.StringInvalid, Runtime.utf8_from_utf16(&lone, &buffer));
}

test GUID_NULL {
    @setEvalBranchQuota(100_000);

    const names = @typeInfo(@This()).@"struct".decl_names;

    try std.testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&GUID_NULL), 0));

    inline for (names, 0..) |name, index| {
        if (comptime !std.mem.startsWith(u8, name, "IID_")) continue;

        const identifier: GUID = @field(@This(), name);

        try std.testing.expect(!std.meta.eql(identifier, GUID_NULL));

        inline for (names[index + 1 ..]) |other| {
            if (comptime !std.mem.startsWith(u8, other, "IID_")) continue;

            try std.testing.expect(!std.meta.eql(identifier, @field(@This(), other)));
        }
    }
}

test delegate_query_interface {
    var object: IUnknown = undefined;
    var out: ?*IUnknown = undefined;

    const marshal = delegate_query_interface(&object, null, &IID_IMarshal, &out);

    try std.testing.expectEqual(E_NOINTERFACE, marshal);
    try std.testing.expectEqual(@as(?*IUnknown, null), out);

    const refused = delegate_query_interface(&object, null, &IID_INoMarshal, &out);
    const inspectable = delegate_query_interface(&object, null, &IID_IInspectable, &out);
    const information = delegate_query_interface(&object, null, &IID_IStdMarshalInfo, &out);

    try std.testing.expectEqual(E_NOINTERFACE, refused);
    try std.testing.expectEqual(E_NOINTERFACE, inspectable);
    try std.testing.expectEqual(E_NOINTERFACE, information);

    const accepted = delegate_query_interface(&object, null, &IID_IUnknown, &out);

    try std.testing.expectEqual(S_OK, accepted);
    try std.testing.expectEqual(@as(?*IUnknown, &object), out);
}
