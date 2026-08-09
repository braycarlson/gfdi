const reassembly = @import("../../transport/reassembly.zig");

pub const GFDIState = reassembly.GFDIStateType(reassembly.SingleThreadedLock);
