const std = @import("std");

const gfdi = @import("../protocol.zig").gfdi;
const reassembly = @import("../transport.zig").reassembly;
const session_module = @import("../session.zig");

const FakeClock = @import("../testing/fake_clock.zig").FakeClock;
const FakeTransport = @import("../testing/fake_transport.zig").FakeTransport;
const MemoryStore = @import("../testing/memory_store.zig").MemoryStore;

const assert = std.debug.assert;

const SessionType = session_module.SessionType;
const Writer = std.Io.Writer;

pub const NoHooks = struct {
    pub fn on_streaming(hooks: *const NoHooks) void {
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

pub fn RunnerType(comptime Environment: type, comptime Time: type) type {
    comptime assert_time(Time);

    return struct {
        pub const Session = SessionType(Environment);

        const Pump = struct {
            progress_last: u64,
            start: u64,
            streaming: bool,
        };

        pub fn attempts_run(
            comptime Attempt: type,
            attempt: *const Attempt,
            out: *Writer,
            time: *const Time,
        ) (Attempt.Error || Writer.Error)!void {
            comptime assert(@hasDecl(Attempt, "Error"));
            comptime assert(@hasDecl(Attempt, "once"));

            var index: u32 = 0;

            while (index < attempts_max) : (index += 1) {
                assert(index < attempts_max);

                if (index > 0) try settle(out, time, index);

                if (try attempt.once()) {
                    try out.print("archive fully pulled; nothing left to fetch.\n", .{});
                    try out.flush();

                    return;
                }
            }

            assert(index == attempts_max);

            try out.print(
                "stopped after {d} reconnects without a clean finish; re-run to keep going.\n",
                .{attempts_max},
            );

            try out.flush();
        }

        fn settle(out: *Writer, time: *const Time, index: u32) !void {
            assert(index > 0);
            assert(index < attempts_max);

            try out.print(
                "\nreconnect {d}/{d}: settling {d}s then resuming from disk...\n",
                .{ index + 1, attempts_max, @divFloor(reconnect_settle_ms, 1000) },
            );

            try out.flush();

            time.sleep_ms(reconnect_settle_ms);
        }

        pub fn pump_run(
            comptime Hooks: type,
            hooks: *const Hooks,
            session: *Session,
            time: *const Time,
        ) Writer.Error!void {
            comptime assert(@hasDecl(Hooks, "on_streaming"));
            assert(session.phase == .handshake);

            try session.out.print(
                "GFDI session: handshake + protobuf file sync (up to {d}h)...\n",
                .{@divFloor(session_ms, 3_600_000)},
            );

            try session.out.flush();

            const now = time.now_ms();

            var pump = Pump{ .progress_last = now, .start = now, .streaming = false };
            var tick: u64 = 0;

            while (tick < session_ms) : (tick += 1) {
                if (time.now_ms() - pump.start >= session_ms) break;
                if (session.finished) break;

                const going = try pump_tick(Hooks, hooks, session, &pump, time);
                if (!going) break;

                time.sleep_ms(tick_sleep_ms);
            }

            try report(session);
        }

        fn report(session: *const Session) !void {
            const dropped = session.transport.dropped();
            const out = session.out;

            if (dropped > 0) {
                try out.print("note: {d} fragment(s)/message(s) dropped\n", .{dropped});
            }

            if (!session.finished) try out.print("session timed out before sync completed.\n", .{});

            try out.print(
                "done. {d} file(s) saved.\n",
                .{session.transfer.files_saved + session.archive.saved},
            );

            try out.flush();
        }

        fn pump_tick(
            comptime Hooks: type,
            hooks: *const Hooks,
            session: *Session,
            pump: *Pump,
            time: *const Time,
        ) !bool {
            assert(pump.progress_last >= pump.start);

            session.transport.poll();

            var scratch: [gfdi.message_length_max]u8 = undefined;
            var progressed = false;

            for (0..reassembly.ring_slots) |_| {
                const length = session.transport.next_message(&scratch) orelse break;

                assert(length <= scratch.len);

                progressed = true;

                session.process_message(scratch[0..length]) catch |err| {
                    try session.out.print("process error: {s}\n", .{@errorName(err)});
                };
            }

            session.poll_transfer() catch |err| {
                try session.out.print("transfer error: {s}\n", .{@errorName(err)});
            };

            if (!progressed) return stalled_tick(session, pump, time);

            pump.progress_last = time.now_ms();
            session.archive.stalls = 0;

            if (!pump.streaming) {
                if (session.phase == .archive) {
                    pump.streaming = true;

                    hooks.on_streaming();
                }
            }

            return true;
        }

        fn stalled_tick(session: *Session, pump: *Pump, time: *const Time) !bool {
            assert(pump.progress_last >= pump.start);

            const now = time.now_ms();

            assert(now >= pump.progress_last);

            if (session.phase == .archive) {
                if (now - pump.progress_last > session_module.archive_stall_ms) {
                    session.archive_on_stall() catch |err| {
                        try session.out.print("stall handler error: {s}\n", .{@errorName(err)});
                    };

                    pump.progress_last = time.now_ms();

                    return true;
                }
            }

            if (session.phase == .handshake) {
                if (now - pump.start > handshake_timeout_ms) {
                    try session.out.print(
                        "no device-info within {d}s; GFDI wedged at handshake, reconnecting.\n",
                        .{@divFloor(handshake_timeout_ms, 1000)},
                    );

                    return false;
                }
            }

            return true;
        }
    };
}

pub fn SystemTimeType(comptime System: type) type {
    comptime assert(@hasDecl(System, "now_ms"));
    comptime assert(@hasDecl(System, "sleep_ms"));

    return struct {
        const SystemTime = @This();

        pub fn now_ms(time: SystemTime) u64 {
            _ = time;

            const result = System.now_ms();

            assert(result < std.math.maxInt(u64) - session_ms);

            return result;
        }

        pub fn sleep_ms(time: SystemTime, milliseconds: u32) void {
            assert(milliseconds <= session_ms);

            _ = time;

            System.sleep_ms(milliseconds);
        }
    };
}

pub const FakeTime = struct {
    elapsed_ms: *u64,

    pub fn now_ms(time: FakeTime) u64 {
        assert(time.elapsed_ms.* < std.math.maxInt(u64) - session_ms);

        return time.elapsed_ms.*;
    }

    pub fn sleep_ms(time: FakeTime, milliseconds: u32) void {
        assert(milliseconds <= session_ms);
        assert(time.elapsed_ms.* < std.math.maxInt(u64) - session_ms);

        time.elapsed_ms.* += milliseconds;
    }
};

fn assert_time(comptime Time: type) void {
    comptime {
        assert(@sizeOf(Time) <= @sizeOf(u64));

        require(Time, "now_ms", fn (Time) u64);
        require(Time, "sleep_ms", fn (Time, u32) void);
    }
}

fn require(comptime Time: type, comptime name: []const u8, comptime Signature: type) void {
    comptime assert(name.len > 0);

    if (!@hasDecl(Time, name)) {
        @compileError("gfdi: the runner time " ++ @typeName(Time) ++ " declares no '" ++
            name ++ "'");
    }

    const Actual = @TypeOf(@field(Time, name));

    if (Actual != Signature) {
        @compileError("gfdi: the runner time " ++ @typeName(Time) ++ "." ++ name ++
            " has type " ++ @typeName(Actual) ++ ", expected " ++ @typeName(Signature));
    }
}

const FakeEnvironment = struct {
    pub const Clock = FakeClock;
    pub const FileStore = MemoryStore;
    pub const Transport = FakeTransport;
};

const CountingAttempt = struct {
    calls: *u32,
    success_at: u32,

    pub const Error = error{};

    pub fn once(attempt: *const CountingAttempt) Error!bool {
        assert(attempt.calls.* < attempts_max);

        attempt.calls.* += 1;

        return attempt.calls.* == attempt.success_at;
    }
};

const TestRunner = RunnerType(FakeEnvironment, FakeTime);
const TestStorage = session_module.StorageType(.{
    .inflate_bytes_max = 1024,
    .legacy_bytes_max = 1024,
    .protobuf_bytes_max = 1024,
    .transfer_bytes_max = 1024,
});

const testing = std.testing;

fn test_session(fixture: *Fixture, out: *Writer) void {
    assert(out.buffer.len > 0);

    fixture.transport = .empty;

    const storage = fixture.storage.slices();

    fixture.session.init(&storage, &fixture.transport, out, .zero, .empty);
}

test "attempts_run stops at the first attempt that completes the archive" {
    var buffer: [4096]u8 = undefined;
    var out = Writer.fixed(&buffer);
    var calls: u32 = 0;
    var elapsed_ms: u64 = 0;

    const attempt = CountingAttempt{ .calls = &calls, .success_at = 3 };

    try TestRunner.attempts_run(CountingAttempt, &attempt, &out, &.{ .elapsed_ms = &elapsed_ms });

    try testing.expectEqual(@as(u32, 3), calls);
    try testing.expectEqual(2 * @as(u64, reconnect_settle_ms), elapsed_ms);
    try testing.expect(std.mem.find(u8, out.buffered(), "archive fully pulled") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "reconnect 3/20") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "reconnect 4/20") == null);
}

test "attempts_run settles between attempts and gives up after the cap" {
    var buffer: [8192]u8 = undefined;
    var out = Writer.fixed(&buffer);
    var calls: u32 = 0;
    var elapsed_ms: u64 = 0;

    const attempt = CountingAttempt{ .calls = &calls, .success_at = 0 };

    try TestRunner.attempts_run(CountingAttempt, &attempt, &out, &.{ .elapsed_ms = &elapsed_ms });

    const settles: u64 = attempts_max - 1;

    try testing.expectEqual(attempts_max, calls);
    try testing.expectEqual(settles * reconnect_settle_ms, elapsed_ms);
    try testing.expect(std.mem.find(u8, out.buffered(), "stopped after") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "reconnect 20/20") != null);
}

test "pump_run abandons a handshake that never receives device information" {
    var buffer: [8192]u8 = undefined;
    var out = Writer.fixed(&buffer);
    var elapsed_ms: u64 = 0;

    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    test_session(fixture, &out);

    try TestRunner.pump_run(NoHooks, &.{}, &fixture.session, &.{ .elapsed_ms = &elapsed_ms });

    try testing.expect(!fixture.session.finished);
    try testing.expect(elapsed_ms > handshake_timeout_ms);
    try testing.expect(elapsed_ms < session_ms);
    try testing.expect(std.mem.find(u8, out.buffered(), "wedged at handshake") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "GFDI session: handshake") != null);
}

test "pump_run reports dropped fragments once the session ends" {
    var buffer: [8192]u8 = undefined;
    var out = Writer.fixed(&buffer);
    var elapsed_ms: u64 = 0;

    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    test_session(fixture, &out);

    fixture.transport.dropped_count = 7;

    fixture.session.finished = true;

    try TestRunner.pump_run(NoHooks, &.{}, &fixture.session, &.{ .elapsed_ms = &elapsed_ms });

    try testing.expect(std.mem.find(u8, out.buffered(), "7 fragment(s)") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "0 file(s) saved") != null);
    try testing.expectEqual(@as(u64, 0), elapsed_ms);
}

const Fixture = struct {
    session: TestRunner.Session,
    storage: TestStorage,
    transport: FakeTransport,
};
