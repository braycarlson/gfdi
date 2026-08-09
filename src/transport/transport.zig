pub const TransferStatus = struct {
    ready: bool,
    closed: bool,
    overflow: bool,
    handle: u8,
    len: u32,
};

pub fn assert_transport(comptime T: type) void {
    comptime {
        for ([_][]const u8{
            "send",           "register_next_transfer_service", "start_transfer",
            "next_message",   "transfer_status",                "transfer_reset",
            "transfer_bytes", "transfer_capacity",              "poll",
        }) |name| {
            if (!@hasDecl(T, name)) {
                @compileError("Transport type " ++ @typeName(T) ++
                    " is missing method '" ++ name ++ "'");
            }

            if (@typeInfo(@TypeOf(@field(T, name))) != .@"fn") {
                @compileError("Transport type " ++ @typeName(T) ++
                    " declaration '" ++ name ++ "' is not a function");
            }
        }
    }
}
