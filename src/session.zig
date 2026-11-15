const std = @import("std");

const bounded = @import("bounded");

const protocol = @import("protocol.zig");
const transport_module = @import("transport.zig");

const FakeClock = @import("testing/fake_clock.zig").FakeClock;
const FakeTransport = @import("testing/fake_transport.zig").FakeTransport;
const MemoryStore = @import("testing/memory_store.zig").MemoryStore;

pub const runner = @import("session/runner.zig");

const file_synchronization = protocol.file_synchronization;
const fit = protocol.fit;
const gfdi = protocol.gfdi;
const naming = transport_module.naming;

const assert = std.debug.assert;
const assert_transport = transport_module.assert_transport;

const Writer = std.Io.Writer;

pub const Phase = enum {
    archive,
    directory,
    done,
    downloading,
    handshake,
    listing,
};

pub const Capacity = struct {
    inflate_bytes_max: u32,
    legacy_bytes_max: u32,
    protobuf_bytes_max: u32,
    transfer_bytes_max: u32,
};

pub const Storage = struct {
    inflate: []u8,
    legacy: []u8,
    protobuf: []u8,
    transfer: []u8,
};

const QueuedFile = struct {
    id1: u64,
    id2: u64,
    name: bounded.BufferType(type_name_max),
    raw: bounded.BufferType(file_raw_max),
    size: u32,
    type_code: u32,
};

const LegacyTransfer = struct {
    buffer: []u8,
    crc: u16,
    index: u16,
    received: u32,
    size: u32,
};

const ArchiveSweep = struct {
    complete: bool,
    offered: u32,
    refusals: u32,
    saved: u32,
    stalls: u32,
};

const ProtobufReassembly = struct {
    buffer: []u8,
    inflate_buffer: []u8,
    length: u32,
    page_id_last: u32,
    total: u32,
};

const TypeName = struct {
    code: u32,
    name: bounded.BufferType(type_name_max),
};

const TypeNames = struct {
    entries: bounded.ArrayType(TypeName, type_code_max),

    const empty: TypeNames = .{ .entries = .empty };

    fn record(table: *TypeNames, code: u32, name: []const u8) void {
        assert(code != 0);
        assert(name.len > 0);

        if (table.resolve(code).len > 0) return;
        if (table.entries.full()) return;

        const slot = table.entries.push_slot_assume_capacity();
        const length = @min(name.len, type_name_max);

        slot.* = .{ .code = code, .name = .empty };
        slot.name.array.push_slice_assume_capacity(name[0..length]);

        assert(table.entries.count <= type_code_max);
    }

    fn resolve(table: *const TypeNames, code: u32) []const u8 {
        assert(code != 0);
        assert(table.entries.count <= type_code_max);

        for (table.entries.slice()) |*entry| {
            if (entry.code == code) return entry.name.slice();
        }

        return &.{};
    }
};

const DownloadQueue = struct {
    files: bounded.ArrayType(QueuedFile, download_queue_max),
    position: u32,

    const empty: DownloadQueue = .{ .files = .empty, .position = 0 };

    fn push(queue: *DownloadQueue, file: *const file_synchronization.File, name: []const u8) void {
        assert(name.len > 0);
        assert(queue.position <= queue.files.count);

        if (queue.files.full()) return;
        if (file.raw.len > file_raw_max) return;
        if (file.size == 0) return;

        const slot = queue.files.push_slot_assume_capacity();
        const name_length = @min(name.len, type_name_max);

        slot.* = .{
            .id1 = file.id1,
            .id2 = file.id2,
            .name = .empty,
            .raw = .empty,
            .size = file.size,
            .type_code = file.type_code,
        };

        slot.name.array.push_slice_assume_capacity(name[0..name_length]);
        slot.raw.array.push_slice_assume_capacity(file.raw);

        assert(queue.files.count <= download_queue_max);
    }
};

const Transfer = struct {
    file_handle_current: u32,
    files_saved: u32,
    in_progress: bool,
    index_current: u32,
    start_sent: bool,
};

pub const protobuf_buffer_max: u32 = 256 * 1024;
pub const legacy_buffer_max: u32 = 8 * 1024 * 1024;
pub const inflate_output_max: u32 = 8 * 1024 * 1024;
pub const archive_stall_ms: u32 = 15_000;
pub const archive_index_first: u16 = 1;
pub const archive_index_last: u16 = 1024;
const download_queue_max: u32 = 512;
const type_code_max: u32 = 64;
const type_name_max: u32 = 32;
const file_raw_max: u32 = 192;
const file_suffix_max: u32 = 1000;
const file_list_page_entries_max: u32 = protobuf_buffer_max;
const archive_pull: bool = true;
pub const archive_refusals_max: u32 = 16;
const archive_stalls_max: u32 = 4;
const page_id_none: u32 = 0xFFFFFFFF;

pub const capacity_native: Capacity = .{
    .inflate_bytes_max = inflate_output_max,
    .legacy_bytes_max = legacy_buffer_max,
    .protobuf_bytes_max = protobuf_buffer_max,
    .transfer_bytes_max = transport_module.reassembly.transfer_buffer_max,
};

comptime {
    assert(archive_index_first <= archive_index_last);
    assert(type_name_max <= std.math.maxInt(u8));
    assert(file_raw_max <= std.math.maxInt(u16));
    assert(archive_refusals_max > 0);
    assert(archive_stalls_max > 0);
}

pub fn StorageType(comptime capacity: Capacity) type {
    comptime assert(capacity.inflate_bytes_max > 0);
    comptime assert(capacity.legacy_bytes_max > 0);
    comptime assert(capacity.protobuf_bytes_max > 0);
    comptime assert(capacity.transfer_bytes_max > 0);

    return struct {
        inflate: [capacity.inflate_bytes_max]u8,
        legacy: [capacity.legacy_bytes_max]u8,
        protobuf: [capacity.protobuf_bytes_max]u8,
        transfer: [capacity.transfer_bytes_max]u8,

        const Fixed = @This();

        pub fn slices(fixed: *Fixed) Storage {
            assert(fixed.legacy.len == capacity.legacy_bytes_max);
            assert(fixed.transfer.len == capacity.transfer_bytes_max);

            return .{
                .inflate = &fixed.inflate,
                .legacy = &fixed.legacy,
                .protobuf = &fixed.protobuf,
                .transfer = &fixed.transfer,
            };
        }
    };
}

pub fn SessionType(comptime Environment: type) type {
    comptime assert_transport(Environment.Transport);

    return struct {
        archive: ArchiveSweep,
        clock: Environment.Clock,
        finished: bool,
        legacy: LegacyTransfer,
        out: *Writer,
        phase: Phase,
        protobuf: ProtobufReassembly,
        queue: DownloadQueue,
        request_id: u16,
        store: Environment.FileStore,
        synchronization_started: bool,
        transfer: Transfer,
        transport: *Environment.Transport,
        types: TypeNames,

        const Session = @This();

        pub const Error = Environment.Transport.Error || Writer.Error;

        pub fn init(
            session: *Session,
            storage: *const Storage,
            transport: *Environment.Transport,
            out: *Writer,
            clock: Environment.Clock,
            store: Environment.FileStore,
        ) void {
            assert(storage.legacy.len > 0);
            assert(storage.protobuf.len > 0);
            assert(storage.inflate.len > 0);

            session.* = .{
                .archive = .{
                    .complete = false,
                    .offered = 0,
                    .refusals = 0,
                    .saved = 0,
                    .stalls = 0,
                },

                .clock = clock,
                .finished = false,
                .legacy = .{
                    .buffer = storage.legacy,
                    .crc = 0,
                    .index = 0,
                    .received = 0,
                    .size = 0,
                },

                .out = out,
                .phase = .handshake,

                .protobuf = .{
                    .buffer = storage.protobuf,
                    .inflate_buffer = storage.inflate,
                    .length = 0,
                    .page_id_last = page_id_none,
                    .total = 0,
                },

                .queue = .empty,
                .request_id = 1,
                .store = store,
                .synchronization_started = false,

                .transfer = .{
                    .file_handle_current = 0,
                    .files_saved = 0,
                    .in_progress = false,
                    .index_current = 0,
                    .start_sent = false,
                },

                .transport = transport,
                .types = .empty,
            };

            assert(session.phase == .handshake);
            assert(!session.finished);
        }

        pub fn process_message(session: *Session, message: []const u8) Error!void {
            assert(message.len <= gfdi.message_length_max);
            assert(session.legacy.received <= session.legacy.buffer.len);

            const parsed = gfdi.parse(message) orelse {
                @branchHint(.cold);

                try session.out.print(
                    "GFDI: runt/oversize message ({d}B), dropped\n",
                    .{message.len},
                );

                return;
            };

            if (!parsed.crc_ok) {
                @branchHint(.cold);

                try session.out.print(
                    "GFDI message type={d} length={d} crc=BAD (dropped)\n",
                    .{ parsed.type, message.len },
                );

                return;
            }

            switch (parsed.type) {
                .device_information => try session.handle_device_information(parsed.payload),
                .protobuf_request, .protobuf_response => try session.handle_protobuf(
                    parsed.type,
                    parsed.payload,
                ),
                .response => try session.handle_status(parsed.payload),
                .file_transfer_data => try session.handle_legacy_chunk(parsed.payload),
                .current_time_request => try session.handle_time_request(),
                else => {
                    var buffer: [16]u8 = undefined;
                    const length = gfdi.build_ack(&buffer, parsed.type);

                    try session.send(buffer[0..length]);
                },
            }
        }

        pub fn poll_transfer(session: *Session) Error!void {
            assert(session.queue.position <= session.queue.files.count);

            if (!session.transfer.in_progress) return;

            const status = session.transport.transfer_status();

            if (status.ready) {
                if (!session.transfer.start_sent) {
                    session.transfer.start_sent = true;

                    try session.transport.start_transfer(session.transfer.file_handle_current);

                    try session.out.print(
                        "transfer started (handle 0x{x:0>2})\n",
                        .{status.handle},
                    );

                    try session.out.flush();
                }
            }

            if (status.closed) try session.finish_transfer(status.length, status.overflow);
        }

        pub fn archive_on_stall(session: *Session) Error!void {
            assert(session.phase == .archive);
            assert(session.archive.stalls < archive_stalls_max);

            session.archive.stalls += 1;

            try session.out.print(
                "stall at index {d}: no data for {d}s (stall {d}/{d})\n",
                .{
                    session.legacy.index,
                    @divFloor(archive_stall_ms, 1000),
                    session.archive.stalls,
                    archive_stalls_max,
                },
            );

            try session.out.flush();

            if (session.archive.stalls >= archive_stalls_max) {
                @branchHint(.cold);

                try session.out.print(
                    "archive link stalled; exiting to allow resume (re-run to continue).\n",
                    .{},
                );

                session.phase = .done;
                session.finished = true;

                return;
            }

            try session.archive_next();
        }

        fn send(session: *Session, message: []const u8) !void {
            assert(message.len > 0);
            assert(message.len <= gfdi.message_length_max);

            try session.transport.send(message);
        }

        fn handle_time_request(session: *Session) !void {
            assert(session.request_id > 0);

            var buffer: [40]u8 = undefined;

            const length = gfdi.build_time_response(&buffer, .{
                .garmin_timestamp = session.clock.now_garmin(),
                .utc_offset_seconds = session.clock.utc_offset_seconds(),
            });

            assert(length <= buffer.len);

            try session.send(buffer[0..length]);
            try session.out.print("GFDI 5052 time-request -> sent time response\n", .{});
        }

        fn handle_device_information(session: *Session, payload: []const u8) !void {
            assert(payload.len <= gfdi.message_length_max);

            try session.out.print("GFDI 5024 device-information: ", .{});

            for (payload) |byte| {
                if (std.ascii.isPrint(byte)) try session.out.print("{c}", .{byte});
            }

            try session.out.print("\n", .{});

            const protocol_version = gfdi.device_information_protocol_version(payload) orelse 0;

            var buffer: [128]u8 = undefined;

            const length = gfdi.build_device_information_response(
                &buffer,
                gfdi.device_information_protocol_flags(protocol_version),
            );

            assert(length <= buffer.len);

            try session.send(buffer[0..length]);

            if (session.synchronization_started) return;

            session.synchronization_started = true;

            try session.synchronization_start();
        }

        fn synchronization_start(session: *Session) !void {
            assert(session.synchronization_started);
            assert(session.phase == .handshake);

            var buffer: [64]u8 = undefined;

            const request_length = gfdi.build_supported_file_types_request(&buffer);

            try session.send(buffer[0..request_length]);

            const event_length = gfdi.build_system_event(&buffer, .synchronization_ready);

            try session.send(buffer[0..event_length]);

            session.phase = .directory;

            try session.out.print(
                "synchronization: device-information + SupportedFileTypes + SYNC_READY; " ++
                    "requesting directory...\n",
                .{},
            );

            try session.out.flush();
            try session.legacy_download(0);
        }

        fn legacy_download(session: *Session, file_index: u16) !void {
            assert(file_index <= archive_index_last);

            session.legacy.index = file_index;
            session.legacy.size = 0;
            session.legacy.received = 0;
            session.legacy.crc = 0;

            var buffer: [32]u8 = undefined;
            const length = gfdi.build_download_request(&buffer, .{ .file_index = file_index });

            assert(length <= buffer.len);

            try session.send(buffer[0..length]);
        }

        fn handle_status(session: *Session, payload: []const u8) !void {
            assert(payload.len <= gfdi.message_length_max);

            const reference = gfdi.status_reference_type(payload) orelse return;
            if (reference != .download_request) return;

            switch (session.phase) {
                .directory, .archive => {},
                .handshake, .listing, .downloading, .done => return,
            }

            const status = gfdi.parse_download_status(payload) orelse return;

            if (status.can_proceed) {
                if (status.file_size_max > 0) {
                    if (status.file_size_max <= session.legacy.buffer.len) {
                        return session.legacy_accept(status.file_size_max);
                    }
                }
            }

            if (session.phase != .archive) {
                try session.out.print(
                    "directory unavailable (size={d}); ",
                    .{status.file_size_max},
                );

                return session.begin_after_directory();
            }

            session.archive.refusals += 1;

            try session.out.print(
                "index {d}: refused (end-of-table run {d}/{d})\n",
                .{ session.legacy.index, session.archive.refusals, archive_refusals_max },
            );

            try session.out.flush();

            if (session.archive.refusals >= archive_refusals_max) return session.finish_archive();
            return session.archive_next();
        }

        fn legacy_accept(session: *Session, size: u32) !void {
            assert(size > 0);
            assert(size <= session.legacy.buffer.len);

            session.legacy.size = size;
            session.legacy.received = 0;
            session.legacy.crc = 0;

            if (session.phase != .archive) {
                try session.out.print("directory: {d} bytes\n", .{size});

                return;
            }

            session.archive.offered += 1;
            session.archive.refusals = 0;

            try session.out.print(
                "index {d}: downloading {d} bytes...\n",
                .{ session.legacy.index, size },
            );

            try session.out.flush();
        }

        fn handle_legacy_chunk(session: *Session, payload: []const u8) !void {
            assert(payload.len <= gfdi.message_length_max);
            assert(session.legacy.received <= session.legacy.buffer.len);

            switch (session.phase) {
                .directory, .archive => {},
                .handshake, .listing, .downloading, .done => return,
            }

            const chunk = gfdi.parse_file_transfer_data(payload) orelse return;

            if (chunk.offset != session.legacy.received) {
                @branchHint(.cold);

                var resynchronization: [16]u8 = undefined;

                const length = gfdi.build_file_transfer_data_status(
                    &resynchronization,
                    session.legacy.received,
                );

                return session.send(resynchronization[0..length]);
            }

            if (session.legacy.received + chunk.data.len > session.legacy.buffer.len) {
                @branchHint(.cold);

                return;
            }

            session.legacy.crc = gfdi.crc16_seeded(session.legacy.crc, chunk.data);

            @memcpy(
                session.legacy.buffer[session.legacy.received..][0..chunk.data.len],
                chunk.data,
            );

            session.legacy.received += @intCast(chunk.data.len);

            assert(session.legacy.received <= session.legacy.buffer.len);

            var ack: [16]u8 = undefined;

            try session.send(
                ack[0..gfdi.build_file_transfer_data_status(&ack, session.legacy.received)],
            );

            if (session.legacy.received < session.legacy.size) return;

            if (session.phase == .directory) {
                try session.dump_directory();
                try session.begin_after_directory();
            } else {
                try session.save_legacy_file();
                try session.archive_next();
            }
        }

        fn dump_directory(session: *Session) !void {
            assert(session.phase == .directory);
            assert(session.legacy.received <= session.legacy.buffer.len);

            const data = session.legacy.buffer[0..session.legacy.received];
            const count: u32 = @intCast(@divFloor(data.len, gfdi.directory_entry_length));

            try session.out.print(
                "directory complete: {d} bytes, {d} entries\n",
                .{ data.len, count },
            );

            for (0..count) |index| {
                assert((index + 1) * gfdi.directory_entry_length <= data.len);

                const start = index * gfdi.directory_entry_length;
                const record = data[start..][0..gfdi.directory_entry_length];
                const entry = gfdi.parse_directory_entry(record);

                try session.out.print(
                    "  entry: index={d} type={d}/{d} number={d} " ++
                        "flags={x:0>2}/{x:0>2} size={d} timestamp={d}\n",
                    .{
                        entry.file_index,
                        entry.data_type,
                        entry.sub_type,
                        entry.file_number,
                        entry.specific_flags,
                        entry.file_flags,
                        entry.file_size,
                        entry.timestamp,
                    },
                );
            }

            try session.out.flush();
        }

        fn begin_after_directory(session: *Session) !void {
            assert(session.phase == .directory);
            assert(archive_index_first <= archive_index_last);

            if (!archive_pull) {
                try session.out.print("requesting protobuf file list...\n", .{});

                session.phase = .listing;

                return session.send_file_list_request(null);
            }

            session.phase = .archive;
            session.legacy.index = archive_index_first - 1;
            session.archive.refusals = 0;

            try session.out.print(
                "legacy archive sweep: indices {d}..{d} " ++
                    "(resuming; skips files already on disk)...\n",
                .{ archive_index_first, archive_index_last },
            );

            try session.out.flush();
            try session.archive_next();
        }

        fn archive_next(session: *Session) !void {
            assert(session.phase == .archive);
            assert(session.legacy.index <= archive_index_last);

            var index_next = session.legacy.index;

            for (0..archive_index_last) |_| {
                if (index_next >= archive_index_last) break;

                index_next += 1;

                assert(index_next <= archive_index_last);

                if (!session.index_done(index_next)) return session.legacy_download(index_next);

                session.legacy.index = index_next;
                session.archive.refusals = 0;
            }

            try session.finish_archive();
        }

        fn finish_archive(session: *Session) !void {
            assert(session.phase == .archive);
            assert(!session.finished);

            session.phase = .done;
            session.finished = true;
            session.archive.complete = true;

            try session.out.print(
                "archive sweep complete: {d} offered, {d} saved this run (last index {d}).\n",
                .{ session.archive.offered, session.archive.saved, session.legacy.index },
            );

            try session.out.flush();
        }

        fn index_done(session: *Session, index: u16) bool {
            assert(index >= archive_index_first);
            assert(index <= archive_index_last);

            var buffer: [64]u8 = undefined;

            return session.store.exists(naming.marker_path(&buffer, index));
        }

        fn mark_index_done(session: *Session, index: u16) void {
            assert(index >= archive_index_first);
            assert(index <= archive_index_last);

            var buffer: [64]u8 = undefined;

            session.store.make_path(naming.state_directory);
            const marker = naming.marker_path(&buffer, index);

            session.store.write(&.{ .data = "", .path = marker }) catch return;
        }

        fn save_legacy_file(session: *Session) !void {
            assert(session.phase == .archive);
            assert(session.legacy.received >= session.legacy.size);

            const data = session.legacy.buffer[0..session.legacy.received];
            const information = fit.scan(data);

            var directory_buffer: [96]u8 = undefined;

            const directory = naming.directory_path(&directory_buffer, information.file_type) orelse
                return;

            session.store.make_path(directory);

            var stamp_buffer: [32]u8 = undefined;

            const stamp: ?[]const u8 = if (information.name_timestamp()) |timestamp|
                session.clock.format_local_time(&stamp_buffer, fit.unix_seconds(timestamp))
            else
                null;

            var path_buffer: [160]u8 = undefined;
            const path = session.legacy_save_path(&path_buffer, directory, stamp) orelse return;

            session.store.write(&.{ .data = data, .path = path }) catch |err| {
                @branchHint(.cold);

                return session.out.print(
                    "  index {d}: save failed ({s})\n",
                    .{ session.legacy.index, @errorName(err) },
                );
            };

            session.mark_index_done(session.legacy.index);
            session.archive.saved += 1;

            try session.out.print(
                "  index {d}: saved {s} ({d} bytes)\n",
                .{ session.legacy.index, path, data.len },
            );

            try session.out.flush();
        }

        fn legacy_save_path(
            session: *Session,
            buffer: []u8,
            directory: []const u8,
            stamp: ?[]const u8,
        ) ?[]const u8 {
            if (stamp) |text| assert(text.len == naming.stamp_bytes);
            assert(buffer.len > 0);
            assert(directory.len > 0);

            if (stamp) |text| {
                for (1..file_suffix_max + 1) |suffix| {
                    const path = naming.activity_path(buffer, .{
                        .directory = directory,
                        .stamp = text,
                        .suffix = @intCast(suffix),
                    }) orelse return null;

                    if (!session.store.exists(path)) return path;
                }
            }

            return naming.index_path(buffer, directory, session.legacy.index);
        }

        fn send_file_list_request(session: *Session, start_page_id: ?u32) !void {
            assert((start_page_id orelse 1) != 0);
            assert(session.phase == .listing);

            var request_buffer: [256]u8 = undefined;

            const request_length = file_synchronization.build_file_list_request(
                &request_buffer,
                start_page_id,
            );

            assert(request_length <= request_buffer.len);

            var message_buffer: [512]u8 = undefined;

            const message_length = gfdi.build_protobuf_request(
                &message_buffer,
                session.request_id,
                request_buffer[0..request_length],
            );

            assert(message_length <= message_buffer.len);

            session.request_id +%= 1;

            try session.send(message_buffer[0..message_length]);
        }

        fn handle_protobuf(
            session: *Session,
            message_type: gfdi.MessageType,
            payload: []const u8,
        ) !void {
            assert(payload.len <= gfdi.message_length_max);

            const parsed = gfdi.parse_protobuf_message(payload) orelse return;

            var ack: [24]u8 = undefined;

            const ack_length = gfdi.build_protobuf_ack(
                &ack,
                message_type,
                parsed.request_id,
                parsed.data_offset,
            );

            assert(ack_length <= ack.len);

            try session.send(ack[0..ack_length]);

            if (parsed.data_offset == 0) {
                if (parsed.size_total > session.protobuf.buffer.len) {
                    @branchHint(.cold);

                    session.protobuf.length = 0;
                    session.protobuf.total = 0;

                    return session.out.print(
                        "protobuf message too large ({d}B > {d}B), dropped\n",
                        .{ parsed.size_total, session.protobuf.buffer.len },
                    );
                }

                session.protobuf.length = 0;
                session.protobuf.total = parsed.size_total;
            } else {
                if (parsed.data_offset != session.protobuf.length) return;
            }

            try session.protobuf_append(parsed.payload);
        }

        fn protobuf_append(session: *Session, payload: []const u8) !void {
            assert(payload.len <= gfdi.message_length_max);
            assert(session.protobuf.length <= session.protobuf.buffer.len);

            if (session.protobuf.length + payload.len > session.protobuf.buffer.len) {
                @branchHint(.cold);

                return;
            }

            @memcpy(session.protobuf.buffer[session.protobuf.length..][0..payload.len], payload);

            session.protobuf.length += @intCast(payload.len);

            assert(session.protobuf.length <= session.protobuf.buffer.len);

            if (session.protobuf.total == 0) return;
            if (session.protobuf.length < session.protobuf.total) return;

            assert(session.protobuf.total <= session.protobuf.buffer.len);

            try session.dispatch_file_synchronization(
                session.protobuf.buffer[0..session.protobuf.total],
            );

            session.protobuf.length = 0;
            session.protobuf.total = 0;
        }

        fn dispatch_file_synchronization(session: *Session, smart: []const u8) !void {
            assert(smart.len > 0);
            assert(smart.len <= session.protobuf.buffer.len);

            const message = file_synchronization.parse_smart(smart) orelse return;

            switch (message) {
                .file_list_response => |bytes| try session.handle_file_list(bytes),
                .file_response => |bytes| try session.handle_file_response(bytes),
                .file_notification_new => |bytes| try session.handle_file_notification(bytes),
                .other => {},
            }
        }

        fn handle_file_notification(session: *Session, bytes: []const u8) !void {
            assert(bytes.len <= protobuf_buffer_max);

            const file = file_synchronization.parse_file(bytes);
            const name = session.resolve_type_name(&file);

            if (name.len == 0) return;
            if (!file_synchronization.is_wanted_type(name)) return;

            session.queue.push(&file, name);

            try session.out.print("new-file notification queued ({s})\n", .{name});
        }

        fn resolve_type_name(session: *Session, file: *const file_synchronization.File) []const u8 {
            assert(file.raw.len <= protobuf_buffer_max);

            if (file.type_name.len > 0) {
                if (file.type_code != 0) session.types.record(file.type_code, file.type_name);

                return file.type_name;
            }

            if (file.type_code == 0) return &.{};
            return session.types.resolve(file.type_code);
        }

        fn handle_file_list(session: *Session, bytes: []const u8) !void {
            assert(bytes.len <= protobuf_buffer_max);

            if (session.phase != .listing) return;

            const list = file_synchronization.parse_file_list_response(bytes);

            var iterator = file_synchronization.file_iterator(bytes);
            var seen: u32 = 0;

            for (0..file_list_page_entries_max) |_| {
                const file = iterator.next() orelse break;

                seen += 1;

                const name = session.resolve_type_name(&file);
                if (name.len == 0) continue;
                if (!file_synchronization.is_wanted_type(name)) continue;

                session.queue.push(&file, name);
            }

            try session.out.print(
                "file list page: {d} entries, {d} queued (next_page={d})\n",
                .{ seen, session.queue.files.count, list.page_id_next },
            );

            try session.out.flush();

            if (list.page_id_next != 0) {
                if (list.page_id_next != session.protobuf.page_id_last) {
                    session.protobuf.page_id_last = list.page_id_next;

                    return session.send_file_list_request(list.page_id_next);
                }
            }

            try session.out.print(
                "file list complete: {d} file(s) to pull\n",
                .{session.queue.files.count},
            );

            session.phase = .downloading;

            try session.request_next_file();
        }

        fn request_next_file(session: *Session) !void {
            assert(session.queue.position <= session.queue.files.count);

            if (session.queue.position == session.queue.files.count) return session.finish_queue();

            session.transfer.index_current = session.queue.position;
            session.queue.position += 1;

            const file = session.queue.files.get(session.transfer.index_current);

            try session.out.print(
                "requesting file {d}/{d}: {s} ({d} bytes)\n",
                .{
                    session.transfer.index_current + 1,
                    session.queue.files.count,
                    file.name.slice(),
                    file.size,
                },
            );

            try session.out.flush();

            var request_buffer: [384]u8 = undefined;

            const request_length = file_synchronization.build_file_request(
                &request_buffer,
                file.raw.slice(),
            );

            assert(request_length <= request_buffer.len);

            var message_buffer: [512]u8 = undefined;

            const message_length = gfdi.build_protobuf_request(
                &message_buffer,
                session.request_id,
                request_buffer[0..request_length],
            );

            assert(message_length <= message_buffer.len);

            session.request_id +%= 1;

            try session.send(message_buffer[0..message_length]);
        }

        fn finish_queue(session: *Session) !void {
            assert(session.queue.position == session.queue.files.count);
            assert(!session.transfer.in_progress);

            session.phase = .done;
            session.finished = true;
            session.archive.complete = true;

            var buffer: [16]u8 = undefined;

            const length = gfdi.build_system_event(&buffer, .synchronization_complete);

            try session.transport.send(buffer[0..length]);

            try session.out.print(
                "synchronization complete: {d} file(s) saved.\n",
                .{session.transfer.files_saved},
            );

            try session.out.flush();
        }

        fn handle_file_response(session: *Session, bytes: []const u8) !void {
            assert(bytes.len <= protobuf_buffer_max);

            if (session.phase != .downloading) return;

            const response = file_synchronization.parse_file_response(bytes);

            if (response.status != 0) {
                @branchHint(.cold);

                try session.out.print(
                    "file refused (status {d}), skipping\n",
                    .{response.status},
                );

                return session.request_next_file();
            }

            session.transfer.file_handle_current = response.handle;

            session.transport.transfer_reset();
            session.transfer.start_sent = false;
            session.transfer.in_progress = true;

            try session.transport.register_next_transfer_service();

            try session.out.print(
                "file handle {d}; registering transfer service\n",
                .{response.handle},
            );

            try session.out.flush();
        }

        fn finish_transfer(session: *Session, length: u32, overflow: bool) !void {
            assert(length <= session.transport.transfer_capacity());
            assert(session.transfer.index_current < session.queue.files.count);
            assert(session.transfer.in_progress);

            session.transfer.in_progress = false;

            const file = session.queue.files.get(session.transfer.index_current);

            if (overflow) {
                @branchHint(.cold);

                try session.out.print(
                    "transfer overflow (> {d}B), skipping {s}\n",
                    .{ session.transport.transfer_capacity(), file.name.slice() },
                );
            } else if (length == 0) {
                @branchHint(.cold);

                try session.out.print(
                    "transfer closed with 0 bytes, skipping {s}\n",
                    .{file.name.slice()},
                );
            } else {
                try session.inflate_and_save(file, length);
            }

            session.transport.transfer_reset();
            session.transfer.start_sent = false;

            try session.request_next_file();
        }

        fn inflate_and_save(session: *Session, file: *const QueuedFile, length: u32) !void {
            assert(length > 0);
            assert(length <= session.transport.transfer_capacity());

            const compressed = session.transport.transfer_bytes(length);

            const inflated = inflate_zlib(session.protobuf.inflate_buffer, compressed) catch |err| {
                @branchHint(.cold);

                return session.out.print(
                    "inflate failed ({s}) for {s}\n",
                    .{ @errorName(err), file.name.slice() },
                );
            };

            try session.save_file(file, inflated);

            session.transfer.files_saved += 1;
        }

        fn save_file(session: *Session, file: *const QueuedFile, data: []const u8) !void {
            assert(file.name.count() <= type_name_max);
            assert(data.len > 0);

            var name_buffer: [96]u8 = undefined;

            const name = std.mem.print(
                &name_buffer,
                "{s}_{x}_{x}.fit",
                .{ file.name.slice(), file.id1, file.id2 },
            ) catch return;

            session.store.write(&.{ .data = data, .path = name }) catch |err| {
                @branchHint(.cold);

                return session.out.print(
                    "save failed ({s}) for {s}\n",
                    .{ @errorName(err), name },
                );
            };

            try session.out.print("saved {s} ({d} bytes)\n", .{ name, data.len });
            try session.out.flush();
        }
    };
}

fn inflate_zlib(buffer: []u8, compressed: []const u8) ![]u8 {
    assert(buffer.len > 0);
    assert(compressed.len > 0);

    var input = std.Io.Reader.fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, .zlib, &window);
    var output = Writer.fixed(buffer);

    _ = try decompress.reader.streamRemaining(&output);

    const result = output.buffered();

    assert(result.len <= buffer.len);

    return result;
}

const FakeEnvironment = struct {
    pub const Clock = FakeClock;
    pub const FileStore = MemoryStore;
    pub const Transport = FakeTransport;
};

const TestSession = SessionType(FakeEnvironment);

const TestStorage = StorageType(.{
    .inflate_bytes_max = 1024,
    .legacy_bytes_max = 1024,
    .protobuf_bytes_max = 64,
    .transfer_bytes_max = 64,
});

const Fixture = struct {
    out: Writer,
    out_buffer: [64 * 1024]u8,
    session: TestSession,
    storage: TestStorage,
    transport: FakeTransport,

    fn init(fixture: *Fixture) void {
        fixture.out = Writer.fixed(&fixture.out_buffer);
        fixture.transport = .empty;

        const storage = fixture.storage.slices();

        fixture.session.init(&storage, &fixture.transport, &fixture.out, .zero, .empty);

        assert(fixture.session.phase == .handshake);
    }
};

const testing = std.testing;

test "device information drives the session from handshake to directory request" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    fixture.init();

    var frame: [64]u8 = undefined;
    const payload = [_]u8{ 0x01, 0x02 };

    try fixture.transport.queue_inbound(
        frame[0..gfdi.build_frame(&frame, .device_information, &payload)],
    );

    var scratch: [gfdi.message_length_max]u8 = undefined;

    for (0..fixture.transport.inbound.count + 1) |_| {
        const length = fixture.transport.next_message(&scratch) orelse break;

        try fixture.session.process_message(scratch[0..length]);
    }

    try testing.expect(fixture.session.synchronization_started);
    try testing.expectEqual(Phase.directory, fixture.session.phase);
    try testing.expect(fixture.transport.sent_count >= 1);
}

test "archive_on_stall finishes the sweep after the consecutive-stall cap" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    fixture.init();
    fixture.session.phase = .archive;

    var stalls: u32 = 0;

    while (stalls < 100) : (stalls += 1) {
        if (fixture.session.finished) break;

        try fixture.session.archive_on_stall();
    }

    try testing.expect(fixture.session.finished);
    try testing.expectEqual(archive_stalls_max, stalls);
}

test "archive sweep skips indices already marked done in the store" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    fixture.init();
    fixture.session.phase = .archive;

    var marker: [64]u8 = undefined;

    for (1..4) |index| {
        const path = naming.marker_path(&marker, @intCast(index));

        try fixture.session.store.write(&.{ .data = "", .path = path });
    }

    try fixture.session.archive_on_stall();
    try testing.expectEqual(@as(u16, 4), fixture.session.legacy.index);
}

test "an oversized protobuf total is dropped instead of wedging the session" {
    const fixture = try testing.allocator.create(Fixture);
    defer testing.allocator.destroy(fixture);

    fixture.init();

    var message: [64]u8 = undefined;
    const protobuf_bytes = [_]u8{ 0x08, 0x01 };
    const message_length = gfdi.build_protobuf_request(&message, 7, &protobuf_bytes);

    std.mem.writeInt(u32, message[10..14], 0xFFFF_0000, .little);

    const body_length = message_length - 2;
    const crc = gfdi.crc16(message[0..body_length]);

    std.mem.writeInt(u16, message[body_length..][0..2], crc, .little);

    try fixture.session.process_message(message[0..message_length]);

    try testing.expectEqual(@as(u32, 0), fixture.session.protobuf.total);
    try testing.expectEqual(@as(u32, 0), fixture.session.protobuf.length);
}

test "inflate_zlib round-trips data compressed by the standard library" {
    const text = "the archive holds FIT files; the archive holds FIT files; the archive holds";

    var compressed: [512]u8 = undefined;
    var sink = Writer.fixed(&compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&sink, &window, .zlib, .level_6);

    try compress.writer.writeAll(text);
    try compress.finish();

    var inflated: [256]u8 = undefined;

    try testing.expectEqualStrings(text, try inflate_zlib(&inflated, sink.buffered()));
}

test StorageType {
    var storage: TestStorage = undefined;

    const slices = storage.slices();

    try testing.expectEqual(@as(usize, 1024), slices.legacy.len);
    try testing.expectEqual(@as(usize, 64), slices.transfer.len);
    try testing.expect(slices.inflate.ptr == &storage.inflate);
}
