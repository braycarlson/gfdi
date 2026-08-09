const std = @import("std");

const file_sync = @import("../protocol/file_sync.zig");
const fit = @import("../protocol/fit.zig");
const gfdi = @import("../protocol/gfdi.zig");
const naming = @import("../transport/naming.zig");
const transport_contract = @import("../transport/transport.zig");

const FakeClock = @import("../testing/fake_clock.zig").FakeClock;
const FakeTransport = @import("../testing/fake_transport.zig").FakeTransport;
const MemStore = @import("../testing/mem_store.zig").MemStore;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Phase = enum { handshake, directory, archive, listing, downloading, done };

const QueuedFile = struct {
    id1: u64 = 0,
    id2: u64 = 0,
    type_code: u32 = 0,
    size: u32 = 0,
    name_len: u8 = 0,
    name: [type_name_max]u8 = undefined,
    raw_len: u16 = 0,
    raw: [file_raw_max]u8 = undefined,
};

const LegacyTransfer = struct {
    index: u16 = 0,
    size: u32 = 0,
    received: u32 = 0,
    crc: u16 = 0,
    buffer: []u8 = &.{},
};

const ArchiveSweep = struct {
    offered: u32 = 0,
    refusals: u32 = 0,
    stalls: u32 = 0,
    saved: u32 = 0,
    complete: bool = false,
};

const ProtobufReassembly = struct {
    buffer: []u8 = &.{},
    inflate_buffer: []u8 = &.{},
    len: u32 = 0,
    total: u32 = 0,
    last_page_id: u32 = 0xFFFFFFFF,
};

const TypeNameTable = struct {
    codes: [type_code_max]u32 = undefined,
    names: [type_code_max][type_name_max]u8 = undefined,
    name_lengths: [type_code_max]u8 = undefined,
    count: u32 = 0,

    fn record(table: *TypeNameTable, code: u32, name: []const u8) void {
        assert(table.count <= type_code_max);

        var index: u32 = 0;

        while (index < table.count) : (index += 1) {
            if (table.codes[index] == code) return;
        }

        if (table.count >= type_code_max) return;

        const slot = table.count;
        assert(slot < type_code_max);

        table.codes[slot] = code;

        const length = @min(name.len, type_name_max);
        assert(length <= type_name_max);

        @memcpy(table.names[slot][0..length], name[0..length]);
        table.name_lengths[slot] = @intCast(length);
        table.count += 1;

        assert(table.count <= type_code_max);
    }

    fn resolve(table: *const TypeNameTable, code: u32) []const u8 {
        assert(table.count <= type_code_max);

        var index: u32 = 0;

        while (index < table.count) : (index += 1) {
            if (table.codes[index] == code) {
                assert(table.name_lengths[index] <= type_name_max);
                return table.names[index][0..table.name_lengths[index]];
            }
        }

        return &.{};
    }
};

const DownloadQueue = struct {
    items: [download_queue_max]QueuedFile = undefined,
    len: u32 = 0,
    position: u32 = 0,

    fn push(queue: *DownloadQueue, file: *const file_sync.File, name: []const u8) void {
        assert(queue.len <= download_queue_max);

        if (queue.len >= download_queue_max) return;
        if (file.raw.len > file_raw_max) return;
        if (file.size == 0) return;

        assert(file.raw.len <= file_raw_max);

        const slot = &queue.items[queue.len];

        slot.* = .{
            .id1 = file.id1,
            .id2 = file.id2,
            .type_code = file.type_code,
            .size = file.size,
            .raw_len = @intCast(file.raw.len),
        };

        const name_length = @min(name.len, type_name_max);

        assert(name_length <= type_name_max);
        @memcpy(slot.name[0..name_length], name[0..name_length]);

        slot.name_len = @intCast(name_length);
        @memcpy(slot.raw[0..file.raw.len], file.raw);

        queue.len += 1;

        assert(queue.len <= download_queue_max);
    }
};

const Transfer = struct {
    in_progress: bool = false,
    start_sent: bool = false,
    current_index: u32 = 0,
    current_file_handle: u32 = 0,
    files_saved: u32 = 0,
};

const FakeEnv = struct {
    pub const Transport = FakeTransport;
    pub const Clock = FakeClock;
    pub const FileStore = MemStore;
};

pub const protobuf_buffer_max: u32 = 256 * 1024;
pub const legacy_buffer_max: u32 = 8 * 1024 * 1024;
pub const inflate_output_max: u32 = 8 * 1024 * 1024;

const download_queue_max: u32 = 512;
const type_code_max: u32 = 64;
const type_name_max: u32 = 32;
const file_raw_max: u32 = 192;
const file_suffix_max: u32 = 1000;

const archive_pull: bool = true;
const archive_index_first: u16 = 1;
const archive_index_last: u16 = 1024;
const archive_refusals_max: u32 = 16;

pub const archive_stall_ms: u32 = 15_000;
const archive_stalls_max: u32 = 4;

comptime {
    assert(archive_index_first <= archive_index_last);
    assert(type_name_max <= std.math.maxInt(u8));
    assert(file_raw_max <= std.math.maxInt(u16));
}

const TestSession = SessionType(FakeEnv);

pub fn SessionType(comptime Env: type) type {
    transport_contract.assert_transport(Env.Transport);

    return struct {
        transport: *Env.Transport,
        out: *std.Io.Writer,
        clock: Env.Clock,
        store: Env.FileStore,
        phase: Phase = .handshake,
        sync_started: bool = false,
        request_id: u16 = 1,
        finished: bool = false,
        legacy: LegacyTransfer = .{},
        archive: ArchiveSweep = .{},
        protobuf: ProtobufReassembly = .{},
        types: TypeNameTable = .{},
        queue: DownloadQueue = .{},
        transfer: Transfer = .{},

        const Session = @This();

        pub fn process_message(session: *Session, message: []const u8) !void {
            assert(message.len <= gfdi.message_len_max);

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
                    "GFDI msg type={d} len={d} crc=BAD (dropped)\n",
                    .{ parsed.type, message.len },
                );

                return;
            }

            switch (parsed.type) {
                .device_information => try session.handle_device_info(parsed.payload),
                .protobuf_request, .protobuf_response => try session.handle_protobuf(
                    parsed.type,
                    parsed.payload,
                ),
                .response => try session.handle_status(parsed.payload),
                .file_transfer_data => try session.handle_legacy_chunk(parsed.payload),
                .current_time_request => {
                    var buffer: [40]u8 = undefined;

                    const length = gfdi.build_time_response(
                        &buffer,
                        session.clock.now_garmin(),
                        session.clock.utc_offset_seconds(),
                    );

                    try session.send(buffer[0..length]);
                    try session.out.print("GFDI 5052 time-request -> sent time response\n", .{});
                },
                else => {
                    var buffer: [16]u8 = undefined;
                    const length = gfdi.build_ack(&buffer, parsed.type);

                    try session.send(buffer[0..length]);
                },
            }
        }

        pub fn poll_transfer(session: *Session) !void {
            if (!session.transfer.in_progress) return;
            assert(session.transfer.in_progress);

            const status = session.transport.transfer_status();

            if (status.ready and !session.transfer.start_sent) {
                session.transfer.start_sent = true;
                try session.transport.start_transfer(session.transfer.current_file_handle);
                try session.out.print("transfer started (handle 0x{x:0>2})\n", .{status.handle});
                try session.out.flush();
            }

            if (status.closed) try session.finish_transfer(status.len, status.overflow);
        }

        pub fn archive_on_stall(session: *Session) !void {
            assert(session.phase == .archive);

            session.archive.stalls += 1;
            assert(session.archive.stalls > 0);

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
            assert(message.len <= gfdi.message_len_max);

            try session.transport.send(message);
        }

        fn handle_device_info(session: *Session, payload: []const u8) !void {
            try session.out.print("GFDI 5024 device-info: ", .{});

            for (payload) |byte| {
                if (byte >= 0x20 and byte < 0x7F) try session.out.print("{c}", .{byte});
            }

            try session.out.print("\n", .{});

            const protocol_version = gfdi.device_info_protocol_version(payload) orelse 0;

            var buffer: [128]u8 = undefined;

            const length = gfdi.build_device_info_response(
                &buffer,
                gfdi.device_info_protocol_flags(protocol_version),
            );

            assert(length <= buffer.len);

            try session.send(buffer[0..length]);

            if (!session.sync_started) {
                session.sync_started = true;
                try session.start_sync();
            }
        }

        fn start_sync(session: *Session) !void {
            assert(session.sync_started);

            var buffer: [64]u8 = undefined;

            try session.send(buffer[0..gfdi.build_supported_file_types_request(&buffer)]);
            try session.send(buffer[0..gfdi.build_system_event(&buffer, .sync_ready, 0)]);

            session.phase = .directory;

            try session.out.print(
                "sync: device-info + SupportedFileTypes + SYNC_READY; requesting directory...\n",
                .{},
            );

            try session.out.flush();
            try session.legacy_download(0);
        }

        fn legacy_download(session: *Session, file_index: u16) !void {
            session.legacy.index = file_index;
            session.legacy.size = 0;
            session.legacy.received = 0;
            session.legacy.crc = 0;

            var buffer: [32]u8 = undefined;
            const length = gfdi.build_download_request(&buffer, .{ .file_index = file_index });

            assert(length <= buffer.len);
            assert(session.legacy.received == 0);

            try session.send(buffer[0..length]);
        }

        fn handle_status(session: *Session, payload: []const u8) !void {
            const reference = gfdi.status_reference_type(payload) orelse return;

            if (reference != .download_request) return;
            if (session.phase != .directory and session.phase != .archive) return;

            const status = gfdi.parse_download_status(payload) orelse return;
            const can_take = status.can_proceed and status.file_size_max > 0 and
                status.file_size_max <= session.legacy.buffer.len;

            if (can_take) {
                session.legacy.size = status.file_size_max;
                session.legacy.received = 0;
                session.legacy.crc = 0;

                assert(session.legacy.size > 0);
                assert(session.legacy.size <= session.legacy.buffer.len);

                if (session.phase == .archive) {
                    session.archive.offered += 1;
                    session.archive.refusals = 0;

                    try session.out.print(
                        "index {d}: downloading {d} bytes...\n",
                        .{ session.legacy.index, status.file_size_max },
                    );

                    try session.out.flush();
                } else {
                    try session.out.print("directory: {d} bytes\n", .{status.file_size_max});
                }

                return;
            }

            if (session.phase == .archive) {
                session.archive.refusals += 1;

                try session.out.print(
                    "index {d}: refused (end-of-table run {d}/{d})\n",
                    .{ session.legacy.index, session.archive.refusals, archive_refusals_max },
                );

                try session.out.flush();

                if (session.archive.refusals >= archive_refusals_max) {
                    try session.finish_archive();
                } else {
                    try session.archive_next();
                }
            } else {
                try session.out.print(
                    "directory unavailable (size={d}); ",
                    .{status.file_size_max},
                );

                try session.begin_after_directory();
            }
        }

        fn handle_legacy_chunk(session: *Session, payload: []const u8) !void {
            if (session.phase != .directory and session.phase != .archive) return;
            const chunk = gfdi.parse_file_transfer_data(payload) orelse return;

            if (chunk.offset != session.legacy.received) {
                @branchHint(.cold);

                var resync: [16]u8 = undefined;

                try session.send(
                    resync[0..gfdi.build_file_transfer_data_status(
                        &resync,
                        session.legacy.received,
                    )],
                );

                return;
            }
            assert(chunk.offset == session.legacy.received);

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
            const data = session.legacy.buffer[0..session.legacy.received];
            const count: u32 = @intCast(@divFloor(data.len, gfdi.directory_entry_len));

            try session.out.print(
                "directory complete: {d} bytes, {d} entries\n",
                .{ data.len, count },
            );

            var index: u32 = 0;

            while (index < count) : (index += 1) {
                assert((index + 1) * gfdi.directory_entry_len <= data.len);

                const record =
                    data[index * gfdi.directory_entry_len ..][0..gfdi.directory_entry_len];
                const entry = gfdi.parse_directory_entry(record);

                try session.out.print(
                    "  entry: index={d} type={d}/{d} number={d} " ++
                        "flags={x:0>2}/{x:0>2} size={d} ts={d}\n",
                    .{
                        entry.file_index,  entry.data_type,      entry.sub_type,
                        entry.file_number, entry.specific_flags, entry.file_flags,
                        entry.file_size,   entry.timestamp,
                    },
                );
            }

            try session.out.flush();
        }

        fn begin_after_directory(session: *Session) !void {
            if (archive_pull) {
                session.phase = .archive;
                session.legacy.index = archive_index_first - 1;
                session.archive.refusals = 0;

                assert(session.phase == .archive);
                assert(archive_index_first <= archive_index_last);

                try session.out.print(
                    "legacy archive sweep: indices {d}..{d} " ++
                        "(resuming; skips files already on disk)...\n",
                    .{ archive_index_first, archive_index_last },
                );

                try session.out.flush();
                try session.archive_next();
            } else {
                try session.out.print("requesting protobuf file list...\n", .{});
                session.phase = .listing;
                try session.send_file_list_request(null);
            }
        }

        fn archive_next(session: *Session) !void {
            assert(session.phase == .archive);

            var next_index = session.legacy.index;
            var iterations: u32 = 0;

            while (next_index < archive_index_last) {
                iterations += 1;
                assert(iterations <= archive_index_last);

                next_index += 1;
                assert(next_index <= archive_index_last);

                if (session.index_done(next_index)) {
                    session.legacy.index = next_index;
                    session.archive.refusals = 0;
                    continue;
                }

                try session.legacy_download(next_index);
                return;
            }

            try session.finish_archive();
        }

        fn finish_archive(session: *Session) !void {
            session.phase = .done;
            session.finished = true;
            session.archive.complete = true;
            assert(session.phase == .done);
            assert(session.finished);

            try session.out.print(
                "archive sweep complete: {d} offered, {d} saved this run (last index {d}).\n",
                .{ session.archive.offered, session.archive.saved, session.legacy.index },
            );

            try session.out.flush();
        }

        fn index_done(session: *Session, index: u16) bool {
            var buffer: [64]u8 = undefined;

            return session.store.exists(naming.marker_path(&buffer, index));
        }

        fn mark_index_done(session: *Session, index: u16) void {
            session.store.make_path(naming.state_dir);
            var buffer: [64]u8 = undefined;
            session.store.write(naming.marker_path(&buffer, index), "") catch return;
        }

        fn save_legacy_file(session: *Session) !void {
            const data = session.legacy.buffer[0..session.legacy.received];
            const info = fit.scan(data);

            var dir_buffer: [96]u8 = undefined;
            const dir = naming.dir_path(&dir_buffer, info.file_type) orelse return;
            session.store.make_path(dir);

            var stamp_buffer: [32]u8 = undefined;
            const stamp: ?[]const u8 = if (info.name_timestamp()) |timestamp|
                session.clock.format_local_time(&stamp_buffer, timestamp)
            else
                null;

            var path_buffer: [160]u8 = undefined;
            const path = session.legacy_save_path(&path_buffer, dir, stamp) orelse return;

            session.store.write(path, data) catch |err| {
                @branchHint(.cold);
                try session.out.print(
                    "  index {d}: save failed ({s})\n",
                    .{ session.legacy.index, @errorName(err) },
                );
                return;
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
            dir: []const u8,
            stamp: ?[]const u8,
        ) ?[]const u8 {
            assert(buffer.len > 0);
            assert(dir.len > 0);

            if (stamp) |text| {
                var suffix: u32 = 1;

                while (suffix <= file_suffix_max) : (suffix += 1) {
                    const path = naming.activity_path(buffer, dir, text, suffix) orelse
                        return null;

                    if (!session.store.exists(path)) return path;
                }
            }

            return naming.index_path(buffer, dir, session.legacy.index);
        }

        fn send_file_list_request(session: *Session, start_page_id: ?u32) !void {
            var request_buffer: [256]u8 = undefined;

            const request_len = file_sync.build_file_list_request(&request_buffer, start_page_id);
            assert(request_len <= request_buffer.len);

            var message_buffer: [512]u8 = undefined;

            const message_len = gfdi.build_protobuf_request(
                &message_buffer,
                session.request_id,
                request_buffer[0..request_len],
            );

            assert(message_len <= message_buffer.len);

            session.request_id +%= 1;
            try session.send(message_buffer[0..message_len]);
        }

        fn handle_protobuf(
            session: *Session,
            message_type: gfdi.MessageType,
            payload: []const u8,
        ) !void {
            const parsed = gfdi.parse_protobuf_message(payload) orelse return;

            var ack: [24]u8 = undefined;

            const ack_len = gfdi.build_protobuf_ack(
                &ack,
                message_type,
                parsed.request_id,
                parsed.data_offset,
            );

            assert(ack_len <= ack.len);

            try session.send(ack[0..ack_len]);

            if (parsed.data_offset == 0) {
                if (parsed.total_size > session.protobuf.buffer.len) {
                    @branchHint(.cold);

                    session.protobuf.len = 0;
                    session.protobuf.total = 0;

                    try session.out.print(
                        "protobuf message too large ({d}B > {d}B), dropped\n",
                        .{ parsed.total_size, session.protobuf.buffer.len },
                    );

                    return;
                }

                session.protobuf.len = 0;
                session.protobuf.total = parsed.total_size;
            } else if (parsed.data_offset != session.protobuf.len) {
                @branchHint(.cold);

                return;
            }

            if (session.protobuf.len + parsed.payload.len > session.protobuf.buffer.len) {
                @branchHint(.cold);

                return;
            }

            @memcpy(
                session.protobuf.buffer[session.protobuf.len..][0..parsed.payload.len],
                parsed.payload,
            );

            session.protobuf.len += @intCast(parsed.payload.len);
            assert(session.protobuf.len <= session.protobuf.buffer.len);

            if (session.protobuf.total == 0) return;
            if (session.protobuf.len < session.protobuf.total) return;
            assert(session.protobuf.total <= session.protobuf.buffer.len);
            try session.dispatch_filesync(session.protobuf.buffer[0..session.protobuf.total]);
            session.protobuf.len = 0;
            session.protobuf.total = 0;
        }

        fn dispatch_filesync(session: *Session, smart: []const u8) !void {
            const message = file_sync.parse_smart(smart) orelse return;

            switch (message) {
                .file_list_response => |bytes| try session.handle_file_list(bytes),
                .file_response => |bytes| try session.handle_file_response(bytes),
                .new_file_notification => |bytes| {
                    const file = file_sync.parse_file(bytes);
                    const name = session.resolve_type_name(&file);

                    if (name.len > 0 and file_sync.is_wanted_type(name)) {
                        session.queue.push(&file, name);
                        try session.out.print("new-file notification queued ({s})\n", .{name});
                    }
                },
                .other => {},
            }
        }

        fn resolve_type_name(session: *Session, file: *const file_sync.File) []const u8 {
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

            const list = file_sync.parse_file_list_response(bytes);

            const file_list_page_max: u32 = protobuf_buffer_max;
            var iterator = file_sync.file_iterator(bytes);
            var seen: u32 = 0;

            while (iterator.next()) |file| {
                seen += 1;

                assert(seen <= file_list_page_max);
                const name = session.resolve_type_name(&file);

                if (name.len > 0 and file_sync.is_wanted_type(name)) {
                    session.queue.push(&file, name);
                }
            }

            try session.out.print(
                "file list page: {d} entries, {d} queued (next_page={d})\n",
                .{ seen, session.queue.len, list.next_page_id },
            );

            try session.out.flush();

            if (list.next_page_id != 0 and list.next_page_id != session.protobuf.last_page_id) {
                session.protobuf.last_page_id = list.next_page_id;
                try session.send_file_list_request(list.next_page_id);
            } else {
                try session.out.print(
                    "file list complete: {d} file(s) to pull\n",
                    .{session.queue.len},
                );

                session.phase = .downloading;
                try session.request_next_file();
            }
        }

        fn request_next_file(session: *Session) !void {
            if (session.queue.position >= session.queue.len) {
                session.phase = .done;
                session.finished = true;
                session.archive.complete = true;

                var buffer: [16]u8 = undefined;

                try session.transport.send(buffer[0..gfdi.build_system_event(
                    &buffer,
                    .sync_complete,
                    0,
                )]);

                try session.out.print(
                    "sync complete: {d} file(s) saved.\n",
                    .{session.transfer.files_saved},
                );

                try session.out.flush();

                return;
            }

            session.transfer.current_index = session.queue.position;
            session.queue.position += 1;

            assert(session.transfer.current_index < session.queue.len);
            const file = &session.queue.items[session.transfer.current_index];
            assert(file.name_len <= type_name_max);
            assert(file.raw_len <= file_raw_max);

            try session.out.print(
                "requesting file {d}/{d}: {s} ({d} bytes)\n",
                .{
                    session.transfer.current_index + 1,
                    session.queue.len,
                    file.name[0..file.name_len],
                    file.size,
                },
            );

            try session.out.flush();

            var request_buffer: [384]u8 = undefined;

            const request_len = file_sync.build_file_request(
                &request_buffer,
                file.raw[0..file.raw_len],
            );

            assert(request_len <= request_buffer.len);

            var message_buffer: [512]u8 = undefined;

            const message_len = gfdi.build_protobuf_request(
                &message_buffer,
                session.request_id,
                request_buffer[0..request_len],
            );

            assert(message_len <= message_buffer.len);
            session.request_id +%= 1;
            try session.send(message_buffer[0..message_len]);
        }

        fn handle_file_response(session: *Session, bytes: []const u8) !void {
            if (session.phase != .downloading) return;

            const response = file_sync.parse_file_response(bytes);

            if (response.status != 0) {
                @branchHint(.cold);

                try session.out.print(
                    "file refused (status {d}), skipping\n",
                    .{response.status},
                );

                try session.request_next_file();

                return;
            }

            session.transfer.current_file_handle = response.handle;
            session.transport.transfer_reset();
            session.transfer.start_sent = false;
            session.transfer.in_progress = true;
            assert(session.transfer.in_progress);

            try session.transport.register_next_transfer_service();

            try session.out.print(
                "file handle {d}; registering transfer service\n",
                .{response.handle},
            );

            try session.out.flush();
        }

        fn finish_transfer(session: *Session, length: u32, overflow: bool) !void {
            assert(session.transfer.current_index < session.queue.len);

            session.transfer.in_progress = false;

            const file = &session.queue.items[session.transfer.current_index];
            assert(file.name_len <= type_name_max);

            if (overflow) {
                @branchHint(.cold);

                try session.out.print(
                    "transfer overflow (> {d}B), skipping {s}\n",
                    .{ session.transport.transfer_capacity(), file.name[0..file.name_len] },
                );
            } else if (length == 0) {
                @branchHint(.cold);

                try session.out.print(
                    "transfer closed with 0 bytes, skipping {s}\n",
                    .{file.name[0..file.name_len]},
                );
            } else {
                const compressed = session.transport.transfer_bytes(length);

                if (inflate_zlib(session.protobuf.inflate_buffer, compressed)) |inflated| {
                    try session.save_file(file, inflated);
                    session.transfer.files_saved += 1;
                } else |err| {
                    @branchHint(.cold);

                    try session.out.print(
                        "inflate failed ({s}) for {s}\n",
                        .{ @errorName(err), file.name[0..file.name_len] },
                    );
                }
            }

            session.transport.transfer_reset();
            session.transfer.start_sent = false;

            try session.request_next_file();
        }

        fn save_file(session: *Session, file: *const QueuedFile, data: []const u8) !void {
            assert(file.name_len <= type_name_max);

            var name_buffer: [96]u8 = undefined;

            const name = std.fmt.bufPrint(
                &name_buffer,
                "{s}_{x}_{x}.fit",
                .{ file.name[0..file.name_len], file.id1, file.id2 },
            ) catch return;

            session.store.write(name, data) catch |err| {
                @branchHint(.cold);
                try session.out.print("save failed ({s}) for {s}\n", .{ @errorName(err), name });
                return;
            };

            try session.out.print("saved {s} ({d} bytes)\n", .{ name, data.len });
            try session.out.flush();
        }
    };
}

fn inflate_zlib(buffer: []u8, compressed: []const u8) ![]u8 {
    assert(buffer.len > 0);
    assert(buffer.len <= inflate_output_max);

    var input = std.Io.Reader.fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, .zlib, &window);
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(buffer);

    return decompress.reader.allocRemaining(
        fixed_buffer_allocator.allocator(),
        std.Io.Limit.limited(inflate_output_max),
    );
}

fn make_session(
    gpa: Allocator,
    transport: *FakeTransport,
    out: *std.Io.Writer,
    protobuf_buffer: []u8,
    legacy_buffer: []u8,
) !*TestSession {
    const session = try gpa.create(TestSession);

    session.* = .{
        .transport = transport,
        .out = out,
        .clock = .{},
        .store = .{},
        .protobuf = .{ .buffer = protobuf_buffer },
        .legacy = .{ .buffer = legacy_buffer },
    };

    return session;
}

test "device-info drives the session from handshake to directory request" {
    var transport = FakeTransport{};
    var out_buffer: [64 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);
    var protobuf_buffer: [1024]u8 = undefined;
    var legacy_buffer: [1024]u8 = undefined;

    const session = try make_session(
        std.testing.allocator,
        &transport,
        &out,
        &protobuf_buffer,
        &legacy_buffer,
    );

    defer std.testing.allocator.destroy(session);

    var frame: [64]u8 = undefined;
    const payload = [_]u8{ 0x01, 0x02 };
    transport.queue_inbound(frame[0..gfdi.build_frame(&frame, .device_information, &payload)]);

    var scratch: [gfdi.message_len_max]u8 = undefined;

    while (transport.next_message(&scratch)) |len| {
        try session.process_message(scratch[0..len]);
    }

    try std.testing.expect(session.sync_started);
    try std.testing.expectEqual(Phase.directory, session.phase);
    try std.testing.expect(transport.sent_count >= 1);
}

test "archive_on_stall finishes the sweep after the consecutive-stall cap" {
    var transport = FakeTransport{};
    var out_buffer: [64 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);
    var protobuf_buffer: [1024]u8 = undefined;
    var legacy_buffer: [1024]u8 = undefined;

    const session = try make_session(
        std.testing.allocator,
        &transport,
        &out,
        &protobuf_buffer,
        &legacy_buffer,
    );

    defer std.testing.allocator.destroy(session);

    session.phase = .archive;

    var guard: u32 = 0;

    while (!session.finished and guard < 100) : (guard += 1) {
        try session.archive_on_stall();
    }
    try std.testing.expect(session.finished);
    try std.testing.expect(guard < 100);
}

test "archive sweep skips indices already marked done in the store" {
    var transport = FakeTransport{};
    var out_buffer: [64 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);
    var protobuf_buffer: [1024]u8 = undefined;
    var legacy_buffer: [1024]u8 = undefined;

    const session = try make_session(
        std.testing.allocator,
        &transport,
        &out,
        &protobuf_buffer,
        &legacy_buffer,
    );

    defer std.testing.allocator.destroy(session);

    session.phase = .archive;
    var marker: [64]u8 = undefined;
    var index: u16 = 1;

    while (index <= 3) : (index += 1) try session.store.write(
        naming.marker_path(&marker, index),
        "",
    );

    try session.archive_on_stall();
    try std.testing.expectEqual(@as(u16, 4), session.legacy.index);
}

test "oversized protobuf total is dropped instead of wedging the session" {
    var transport = FakeTransport{};
    var out_buffer: [64 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);
    var protobuf_buffer: [64]u8 = undefined;
    var legacy_buffer: [64]u8 = undefined;

    const session = try make_session(
        std.testing.allocator,
        &transport,
        &out,
        &protobuf_buffer,
        &legacy_buffer,
    );

    defer std.testing.allocator.destroy(session);

    var message: [64]u8 = undefined;
    const proto_bytes = [_]u8{ 0x08, 0x01 };
    const message_len = gfdi.build_protobuf_request(&message, 7, &proto_bytes);

    std.mem.writeInt(u32, message[10..14], 0xFFFF_0000, .little);
    const body_len = message_len - 2;
    const crc = gfdi.crc16(message[0..body_len]);

    std.mem.writeInt(u16, message[body_len..][0..2], crc, .little);
    try session.process_message(message[0..message_len]);

    try std.testing.expectEqual(@as(u32, 0), session.protobuf.total);
    try std.testing.expectEqual(@as(u32, 0), session.protobuf.len);
}
