const builtin = @import("builtin");

pub const Fake = @import("platform/fake.zig");
pub const interface = @import("platform/interface.zig");

pub const Native = switch (builtin.target.os.tag) {
    .linux => @import("platform/linux.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("gfdi: unsupported target OS"),
};
