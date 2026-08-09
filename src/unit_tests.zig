test {
    _ = @import("cli.zig");
    _ = @import("fuzz_tests.zig");
    _ = @import("platform/contract.zig");
    _ = @import("platform/linux/dbus/variant.zig");
    _ = @import("platform/linux/dbus/wire.zig");
    _ = @import("platform/linux/dbus/wire_fuzz.zig");
    _ = @import("protocol/file_sync.zig");
    _ = @import("protocol/fit.zig");
    _ = @import("protocol/fit_fuzz.zig");
    _ = @import("protocol/gfdi.zig");
    _ = @import("protocol/gfdi_fuzz.zig");
    _ = @import("protocol/multi_link.zig");
    _ = @import("protocol/protobuf.zig");
    _ = @import("protocol/protobuf_fuzz.zig");
    _ = @import("session/runner.zig");
    _ = @import("session/session.zig");
    _ = @import("session/session_fuzz.zig");
    _ = @import("testing/fake_clock.zig");
    _ = @import("testing/fuzz.zig");
    _ = @import("tidy.zig");
    _ = @import("transport/link.zig");
    _ = @import("transport/link_fuzz.zig");
    _ = @import("transport/naming.zig");
    _ = @import("transport/reassembly.zig");
    _ = @import("transport/reassembly_fuzz.zig");
}
