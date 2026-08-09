const std = @import("std");

const gfdi = @import("../protocol/gfdi.zig");
const session_module = @import("session.zig");

const FakeClock = @import("../testing/fake_clock.zig").FakeClock;
const FakeTransport = @import("../testing/fake_transport.zig").FakeTransport;
const MemStore = @import("../testing/mem_store.zig").MemStore;

const assert = std.debug.assert;

pub const Buffers = struct {
    inflate: []u8,
    legacy: []u8,
    protobuf: []u8,
    transfer: []u8,
};

pub const NoHooks = struct {
    pub fn on_streaming(hooks: NoHooks) void {
        _ = hooks;
    }
};

pub const attempts_max: u32 = 20;
pub const reconnect_settle_ms: u32 = 10_000;
pub const handshake_timeout_ms: u64 = 30_000;
pub const session_ms: u64 = 4 * 60 * 60 * 1000;
pub const tick_sleep_ms: u32 = 2;

comptime {
    assert(attempts_max > 1);
    assert(reconnect_settle_ms > 0);
    assert(handshake_timeout_ms > 0);
    assert(session_ms > handshake_timeout_ms);
    assert(session_ms % 3_600_000 == 0);
}

pub fn RunnerType(comptime Env: type, comptime Time: type) type {
    assert_time(Time);

    return struct {
        pub const Session = session_module.SessionType(Env);

        const Pump = struct {
            start: u64,
            last_progress: u64,
            streaming: bool = false,
        };

        pub fn init_session(
            session: *Session,
            transport: *Env.Transport,
            out: *std.Io.Writer,
            clock: Env.Clock,
            store: Env.FileStore,
            buffers: *const Buffers,
        ) void {
            assert(buffers.protobuf.len > 0);
            assert(buffers.legacy.len > 0);

            session.* = .{
                .transport = transport,
                .out = out,
                .clock = clock,
                .store = store,

                .protobuf = .{
                    .buffer = buffers.protobuf,
                    .inflate_buffer = buffers.inflate,
                },

                .legacy = .{ .buffer = buffers.legacy },
            };
        }

        pub fn run_attempts(out: *std.Io.Writer, attempts: anytype) !void {
            var attempt: u32 = 0;

            while (attempt < attempts_max) : (attempt += 1) {
                assert(attempt < attempts_max);

                if (attempt > 0) try settle(out, attempt);

                if (try attempts.once()) {
                    try out.print("archive fully pulled; nothing left to fetch.\n", .{});
                    try out.flush();

                    return;
                }
            }

            try out.print(
                "stopped after {d} reconnects without a clean finish; re-run to keep going.\n",
                .{attempts_max},
            );

            try out.flush();
        }

        fn settle(out: *std.Io.Writer, attempt: u32) !void {
            assert(attempt > 0);

            try out.print(
                "\nreconnect {d}/{d}: settling {d}s then resuming from disk...\n",
                .{ attempt + 1, attempts_max, @divFloor(reconnect_settle_ms, 1000) },
            );

            try out.flush();

            Time.sleep_ms(reconnect_settle_ms);
        }

        pub fn run_pump(
            out: *std.Io.Writer,
            session: *Session,
            state: anytype,
            hooks: anytype,
        ) !void {
            try out.print(
                "GFDI session: handshake + protobuf file sync (up to {d}h)...\n",
                .{@divFloor(session_ms, 3_600_000)},
            );

            try out.flush();

            const now = Time.now_ms();

            var pump = Pump{ .start = now, .last_progress = now };

            while (!session.finished and Time.now_ms() - pump.start < session_ms) {
                const keep_going = try pump_tick(out, session, &pump, hooks);

                if (!keep_going) break;

                Time.sleep_ms(tick_sleep_ms);
            }

            try report(out, session, state.dropped);
        }

        fn report(out: *std.Io.Writer, session: *const Session, dropped: u32) !void {
            if (dropped > 0) try out.print(
                "note: {d} fragment(s)/message(s) dropped\n",
                .{dropped},
            );

            if (!session.finished) try out.print("session timed out before sync completed.\n", .{});

            try out.print(
                "done. {d} file(s) saved.\n",
                .{session.transfer.files_saved + session.archive.saved},
            );

            try out.flush();
        }

        fn pump_tick(
            out: *std.Io.Writer,
            session: *Session,
            pump: *Pump,
            hooks: anytype,
        ) !bool {
            session.transport.poll();

            var scratch: [gfdi.message_len_max]u8 = undefined;
            var progressed = false;

            while (session.transport.next_message(&scratch)) |message_len| {
                progressed = true;

                session.process_message(scratch[0..message_len]) catch |err| {
                    try out.print("process error: {s}\n", .{@errorName(err)});
                };
            }

            session.poll_transfer() catch |err| {
                try out.print("transfer error: {s}\n", .{@errorName(err)});
            };

            if (progressed) {
                pump.last_progress = Time.now_ms();
                session.archive.stalls = 0;

                if (!pump.streaming and session.phase == .archive) {
                    pump.streaming = true;

                    hooks.on_streaming();
                }

                return true;
            }

            return stalled_tick(out, session, pump);
        }

        fn stalled_tick(out: *std.Io.Writer, session: *Session, pump: *Pump) !bool {
            const now = Time.now_ms();

            if (session.phase == .archive and
                now - pump.last_progress > session_module.archive_stall_ms)
            {
                session.archive_on_stall() catch |err| {
                    try out.print("stall handler error: {s}\n", .{@errorName(err)});
                };

                pump.last_progress = Time.now_ms();

                return true;
            }

            if (session.phase == .handshake and now - pump.start > handshake_timeout_ms) {
                try out.print(
                    "no device-info within {d}s; GFDI wedged at handshake, reconnecting.\n",
                    .{@divFloor(handshake_timeout_ms, 1000)},
                );

                return false;
            }

            return true;
        }
    };
}

fn assert_time(comptime Time: type) void {
    comptime {
        require_fn(Time, "now_ms", fn () u64);
        require_fn(Time, "sleep_ms", fn (u32) void);
    }
}

fn require_fn(comptime Time: type, comptime name: []const u8, comptime Signature: type) void {
    if (!@hasDecl(Time, name)) {
        @compileError("Runner time " ++ @typeName(Time) ++ " is missing '" ++ name ++ "'");
    }

    const Actual = @TypeOf(@field(Time, name));

    if (Actual != Signature) {
        @compileError("Runner time " ++ @typeName(Time) ++ "." ++ name ++ " has type " ++
            @typeName(Actual) ++ ", expected " ++ @typeName(Signature));
    }
}

const FakeEnv = struct {
    pub const Transport = FakeTransport;
    pub const Clock = FakeClock;
    pub const FileStore = MemStore;
};

const FakeTime = struct {
    var elapsed_ms: u64 = 0;

    pub fn now_ms() u64 {
        return elapsed_ms;
    }

    pub fn sleep_ms(milliseconds: u32) void {
        elapsed_ms += milliseconds;
    }
};

const FakeState = struct {
    dropped: u32 = 0,
};

const CountingAttempts = struct {
    calls: *u32,
    succeed_at: u32,

    pub fn once(attempts: CountingAttempts) !bool {
        attempts.calls.* += 1;

        return attempts.calls.* == attempts.succeed_at;
    }
};

const TestRunner = RunnerType(FakeEnv, FakeTime);

const testing = std.testing;

test "run_attempts stops at the first attempt that completes the archive" {
    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);
    var calls: u32 = 0;

    FakeTime.elapsed_ms = 0;

    try TestRunner.run_attempts(&out, CountingAttempts{ .calls = &calls, .succeed_at = 3 });

    try testing.expectEqual(@as(u32, 3), calls);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "archive fully pulled") != null);
}

test "run_attempts settles between attempts and gives up after the cap" {
    var out_buffer: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);
    var calls: u32 = 0;

    FakeTime.elapsed_ms = 0;

    try TestRunner.run_attempts(&out, CountingAttempts{ .calls = &calls, .succeed_at = 0 });

    const settles: u64 = attempts_max - 1;

    try testing.expectEqual(attempts_max, calls);
    try testing.expectEqual(settles * reconnect_settle_ms, FakeTime.elapsed_ms);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "stopped after") != null);
}

test "run_pump abandons a handshake that never receives device-info" {
    var transport = FakeTransport{};
    var out_buffer: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);

    var protobuf_buffer: [1024]u8 = undefined;
    var legacy_buffer: [1024]u8 = undefined;
    var inflate_buffer: [1024]u8 = undefined;
    var transfer_buffer: [1024]u8 = undefined;

    const buffers = Buffers{
        .inflate = &inflate_buffer,
        .legacy = &legacy_buffer,
        .protobuf = &protobuf_buffer,
        .transfer = &transfer_buffer,
    };

    const session = try testing.allocator.create(TestRunner.Session);
    defer testing.allocator.destroy(session);

    TestRunner.init_session(session, &transport, &out, .{}, .{}, &buffers);

    FakeTime.elapsed_ms = 0;

    try TestRunner.run_pump(&out, session, FakeState{}, NoHooks{});

    try testing.expect(!session.finished);
    try testing.expect(FakeTime.elapsed_ms > handshake_timeout_ms);
    try testing.expect(FakeTime.elapsed_ms < session_ms);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "wedged at handshake") != null);
}

test "run_pump reports dropped fragments once the session ends" {
    var transport = FakeTransport{};
    var out_buffer: [8192]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);

    var protobuf_buffer: [1024]u8 = undefined;
    var legacy_buffer: [1024]u8 = undefined;
    var inflate_buffer: [1024]u8 = undefined;
    var transfer_buffer: [1024]u8 = undefined;

    const buffers = Buffers{
        .inflate = &inflate_buffer,
        .legacy = &legacy_buffer,
        .protobuf = &protobuf_buffer,
        .transfer = &transfer_buffer,
    };

    const session = try testing.allocator.create(TestRunner.Session);
    defer testing.allocator.destroy(session);

    TestRunner.init_session(session, &transport, &out, .{}, .{}, &buffers);

    session.finished = true;
    FakeTime.elapsed_ms = 0;

    try TestRunner.run_pump(&out, session, FakeState{ .dropped = 7 }, NoHooks{});

    try testing.expect(std.mem.indexOf(u8, out.buffered(), "7 fragment(s)") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "0 file(s) saved") != null);
}
