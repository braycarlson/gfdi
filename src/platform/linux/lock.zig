const reassembly = @import("../../transport.zig").reassembly;

pub const GFDIState = reassembly.GFDIStateType(reassembly.SingleThreadedLock);
