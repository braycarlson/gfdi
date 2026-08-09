const builtin = @import("builtin");

const contract = @import("platform/contract.zig");

pub const backend = switch (builtin.os.tag) {
    .linux => @import("platform/linux/linux.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("gfdi: unsupported target OS"),
};

comptime {
    contract.assert_backend(backend);
}
