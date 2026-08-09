const std = @import("std");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Param = std.builtin.Type.Fn.Param;
const Writer = std.Io.Writer;

const Command = struct {
    name: []const u8,
    params: []const type,
};

pub const command_count: u8 = 6;

const commands = [command_count]Command{
    .{ .name = "connect", .params = &.{ Allocator, *Writer, u64 } },
    .{ .name = "enumerate", .params = &.{ Allocator, *Writer } },
    .{ .name = "observe", .params = &.{ Allocator, std.Io, *Writer, u64 } },
    .{ .name = "pull", .params = &.{ Allocator, *Writer, u64 } },
    .{ .name = "scan", .params = &.{ Allocator, *Writer } },
    .{ .name = "smoke", .params = &.{ Allocator, *Writer } },
};

comptime {
    assert(command_count == 6);
    assert(commands.len == command_count);
}

pub fn assert_backend(comptime backend: type) void {
    comptime {
        for (commands) |command| require_command(backend, command);
    }
}

fn require_command(comptime backend: type, comptime command: Command) void {
    if (!@hasDecl(backend, command.name)) {
        @compileError("gfdi backend " ++ @typeName(backend) ++
            " is missing command '" ++ command.name ++ "'");
    }

    const info = @typeInfo(@TypeOf(@field(backend, command.name)));

    if (info != .@"fn") {
        @compileError("gfdi backend command '" ++ command.name ++ "' is not a function");
    }

    require_params(command, info.@"fn".params);
    require_return(command, info.@"fn".return_type);
}

fn require_params(comptime command: Command, comptime params: []const Param) void {
    if (params.len != command.params.len) {
        @compileError("gfdi backend command '" ++ command.name ++
            "' takes the wrong argument count");
    }

    for (params, command.params) |actual, expected| {
        const found = actual.type orelse @compileError("gfdi backend command '" ++
            command.name ++ "' has a generic parameter");

        if (found != expected) {
            @compileError("gfdi backend command '" ++ command.name ++ "' takes " ++
                @typeName(found) ++ " where " ++ @typeName(expected) ++ " is required");
        }
    }
}

fn require_return(comptime command: Command, comptime returned: ?type) void {
    const declared = returned orelse @compileError("gfdi backend command '" ++
        command.name ++ "' has no return type");

    const info = @typeInfo(declared);

    if (info != .error_union or info.error_union.payload != void) {
        @compileError("gfdi backend command '" ++ command.name ++ "' must return !void");
    }
}

const StubBackend = struct {
    pub fn connect(_: Allocator, _: *Writer, _: u64) !void {}

    pub fn enumerate(_: Allocator, _: *Writer) !void {}

    pub fn observe(_: Allocator, _: std.Io, _: *Writer, _: u64) !void {}

    pub fn pull(_: Allocator, _: *Writer, _: u64) !void {}

    pub fn scan(_: Allocator, _: *Writer) !void {}

    pub fn smoke(_: Allocator, _: *Writer) !void {}
};

const testing = std.testing;

test "the contract accepts a backend that exports every command" {
    assert_backend(StubBackend);

    try testing.expectEqual(@as(usize, command_count), commands.len);
}

test "every command the CLI dispatches is named in the contract" {
    const names = [_][]const u8{ "connect", "enumerate", "observe", "pull", "scan", "smoke" };

    inline for (names) |name| {
        comptime var found = false;

        inline for (commands) |command| {
            if (comptime std.mem.eql(u8, command.name, name)) found = true;
        }

        try testing.expect(found);
    }
}
