const std = @import("std");

const com = @import("windows/com.zig");
const interface = @import("interface.zig");
const lock = @import("windows/lock.zig");
const session_module = @import("../session.zig");
const winrt = @import("windows/winrt.zig");

const assert = std.debug.assert;

const Windows = @This();

failure: interface.Diagnostic,
io: std.Io,
session: winrt.Runner.Session,
state: lock.GFDIState,
storage: session_module.StorageType(session_module.capacity_native),

pub const Options = struct {};

pub const capabilities: interface.Capabilities = .{ .dbus = false };

const address_bits: u6 = 48;

comptime {
    interface.assert_backend(Windows);
}

pub fn init(windows: *Windows, io: std.Io, options: Options) void {
    _ = options;

    windows.failure = .none;
    windows.io = io;
    windows.state = .{};
}

pub fn deinit(windows: *Windows) void {
    assert(windows.failure.cause.len <= std.math.maxInt(u16));
}

pub fn diagnostic(windows: *const Windows) interface.Diagnostic {
    assert(windows.failure.cause.len <= std.math.maxInt(u16));

    return windows.failure;
}

pub fn observe(windows: *Windows, out: *std.Io.Writer, address: u64) interface.Error!void {
    assert(address >> address_bits == 0);
    assert(out.buffer.len > 0);

    const observation = winrt.Observation{
        .address = address,
        .io = windows.io,
        .out = out,
        .session = &windows.session,
        .state = &windows.state,
        .storage = windows.storage.slices(),
    };

    winrt.observe(&observation) catch |err| return windows.failed(err);
}

pub fn enumerate(windows: *Windows, out: *std.Io.Writer) interface.Error!void {
    assert(out.buffer.len > 0);

    var runtime = com.Runtime.init() catch |err| return windows.failed(err);
    defer runtime.deinit();

    winrt.enumerate(&runtime, out) catch |err| return windows.failed(err);
}

pub fn scan(windows: *Windows, out: *std.Io.Writer) interface.Error!void {
    assert(out.buffer.len > 0);

    var runtime = com.Runtime.init() catch |err| return windows.failed(err);
    defer runtime.deinit();

    winrt.scan(&runtime, out) catch |err| return windows.failed(err);
}

pub fn connect(windows: *Windows, out: *std.Io.Writer, address: u64) interface.Error!void {
    assert(address >> address_bits == 0);
    assert(out.buffer.len > 0);

    var runtime = com.Runtime.init() catch |err| return windows.failed(err);
    defer runtime.deinit();

    winrt.connect(&runtime, out, address) catch |err| return windows.failed(err);
}

pub fn pull(windows: *Windows, out: *std.Io.Writer, address: u64) interface.Error!void {
    assert(address >> address_bits == 0);
    assert(out.buffer.len > 0);

    var runtime = com.Runtime.init() catch |err| return windows.failed(err);
    defer runtime.deinit();

    winrt.pull(&runtime, out, address) catch |err| return windows.failed(err);
}

pub fn smoke(windows: *Windows, out: *std.Io.Writer) interface.Error!void {
    assert(out.buffer.len > 0);

    var runtime = com.Runtime.init() catch |err| return windows.failed(err);
    defer runtime.deinit();

    winrt.smoke(&runtime, out) catch |err| return windows.failed(err);
}

fn failed(windows: *Windows, err: winrt.Error) interface.Error {
    windows.failure = .{ .cause = @errorName(err) };

    const result: interface.Error = switch (err) {
        error.WriteFailed => error.WriteFailed,
        error.InitializeFailed,
        error.LibraryMissing,
        error.SymbolMissing,
        => error.RuntimeUnavailable,
        else => error.BluetoothFailed,
    };

    assert((result == error.WriteFailed) == (err == error.WriteFailed));
    assert(result != error.AdapterMissing);

    return result;
}

test {
    _ = @import("windows/ble_transport.zig");
    _ = @import("windows/clock.zig");
    _ = @import("windows/com.zig");
    _ = @import("windows/fake_com.zig");
    _ = @import("windows/lock.zig");
    _ = @import("windows/notify.zig");
    _ = @import("windows/time.zig");
    _ = @import("windows/winrt.zig");
}

const testing = std.testing;

test "a failure maps to the error a caller can act on and keeps its cause" {
    const windows = try testing.allocator.create(Windows);
    defer testing.allocator.destroy(windows);

    windows.failure = .none;

    try testing.expectEqual(error.RuntimeUnavailable, windows.failed(error.LibraryMissing));
    try testing.expectEqualStrings("LibraryMissing", windows.diagnostic().cause);
    try testing.expectEqual(error.RuntimeUnavailable, windows.failed(error.SymbolMissing));
    try testing.expectEqual(error.RuntimeUnavailable, windows.failed(error.InitializeFailed));
    try testing.expectEqual(error.WriteFailed, windows.failed(error.WriteFailed));
    try testing.expectEqualStrings("WriteFailed", windows.diagnostic().cause);
    try testing.expectEqual(error.BluetoothFailed, windows.failed(error.NoWatcher));
    try testing.expectEqualStrings("NoWatcher", windows.diagnostic().cause);
    try testing.expectEqual(error.BluetoothFailed, windows.failed(error.StringTooLong));
    try testing.expectEqual(error.BluetoothFailed, windows.failed(error.ActivateFailed));
    try testing.expectEqual(error.BluetoothFailed, windows.failed(error.DeviceSelectorFailed));
    try testing.expectEqualStrings("DeviceSelectorFailed", windows.diagnostic().cause);
}
