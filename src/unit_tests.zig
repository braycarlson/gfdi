const std = @import("std");

const assert = std.debug.assert;

comptime {
    _ = @import("fuzz_tests.zig");
    _ = @import("gfdi.zig");
    _ = @import("platform.zig");
    _ = @import("platform.zig").Native;
    _ = @import("platform/fake.zig");
    _ = @import("platform/interface.zig");
    _ = @import("platform/linux/dbus/variant.zig");
    _ = @import("platform/linux/dbus/wire.zig");
    _ = @import("platform/linux/dbus/wire_fuzz.zig");
    _ = @import("protocol.zig");
    _ = @import("protocol/file_synchronization.zig");
    _ = @import("protocol/fit.zig");
    _ = @import("protocol/fit_fuzz.zig");
    _ = @import("protocol/gfdi.zig");
    _ = @import("protocol/gfdi_fuzz.zig");
    _ = @import("protocol/multi_link.zig");
    _ = @import("protocol/protobuf.zig");
    _ = @import("protocol/protobuf_fuzz.zig");
    _ = @import("session.zig");
    _ = @import("session/runner.zig");
    _ = @import("session_fuzz.zig");
    _ = @import("store.zig");
    _ = @import("testing/fake_clock.zig");
    _ = @import("testing/fake_transport.zig");
    _ = @import("testing/fuzz.zig");
    _ = @import("testing/memory_store.zig");
    _ = @import("tidy.zig");
    _ = @import("transport.zig");
    _ = @import("transport/link.zig");
    _ = @import("transport/link_fuzz.zig");
    _ = @import("transport/naming.zig");
    _ = @import("transport/reassembly.zig");
    _ = @import("transport/reassembly_fuzz.zig");
}

test "every public declaration compiles" {
    const gfdi = @import("gfdi.zig");

    comptime assert(@hasDecl(gfdi, "Native"));
    comptime assert(@hasDecl(gfdi, "Fake"));

    std.testing.refAllDecls(gfdi);
    std.testing.refAllDecls(gfdi.Fake);
    std.testing.refAllDecls(gfdi.Native);
    std.testing.refAllDecls(gfdi.limits);
}
