const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const assert = std.debug.assert;

const source_directories = [_][]const u8{"src"};
const extra_files = [_][]const u8{ "build.zig", "build.zig.zon" };

const test_registries = [_][]const u8{
    "src/linux_tests.zig",
    "src/unit_tests.zig",
};

const fuzz_registry_path = "src/fuzz_tests.zig";
const platform_selector_path = "src/plat" ++ "form.zig";

const entry_points = [_][]const u8{
    "fuzz_tests.zig",
    "linux_tests.zig",
    "main.zig",
    "root.zig",
    "unit_tests.zig",
};

const boundary_exempt = [_][]const u8{
    "fuzz_tests.zig",
    "linux_tests.zig",
    "main.zig",
    "root.zig",
    "unit_tests.zig",
};

const Ban = struct {
    needle: []const u8,
    replacement: []const u8,
};

const Mention = struct {
    count: u32,
    offset: u32,
};

const Span = struct {
    exempt: bool,
    first: usize,
    last: usize,
};

const SourceFile = struct {
    basename: []const u8,
    path: []const u8,
    text: []const u8,
};

const line_columns_max: usize = 100;
const line_count_max: usize = 8192;
const file_bytes_max: usize = 16 * 1024 * 1024;
const file_count_max: usize = 1024;
const functions_per_file_max: usize = 1024;
const imports_per_file_max: usize = 1024;
const function_lines_max: usize = 70;

const fuzz_suffix = "_fuzz.zig";
const function_marker = "fn ";
const import_marker = "@import(\"";
const type_suffix = "Type";
const assert_alias = "const assert = std.debug." ++ "assert;";
const assert_call = "assert(";
const catch_opener = "catch " ++ "{";

const banned = [_]Ban{
    .{ .needle = "== " ++ "error.", .replacement = "a switch, to avoid a silent anyerror upcast" },
    .{ .needle = "!= " ++ "error.", .replacement = "a switch, to avoid a silent anyerror upcast" },
    .{ .needle = "debug." ++ "assert(", .replacement = "an unqualified assert" },
    .{ .needle = "Self = " ++ "@This()", .replacement = "the type's own name" },
    .{ .needle = "!comp" ++ "time", .replacement = "! inside comptime" },
    .{ .needle = "using" ++ "namespace", .replacement = "an explicit declaration" },
    .{ .needle = "@c" ++ "Import", .replacement = "an explicit extern declaration" },
    .{ .needle = "catch " ++ "unreachable", .replacement = "an explicit error handler" },
    .{ .needle = "catch " ++ "{}", .replacement = "an explicit error handler" },
};

const leftover_markers = [_][]const u8{
    "FIX" ++ "ME",
    "db" ++ "g(",
};

const platform_marker = "plat" ++ "form/";
const platform_directory = "src/" ++ platform_marker;
const linux_directory = platform_directory ++ "linux/";
const windows_directory = platform_directory ++ "windows/";
const builtin_marker = "@import(\"buil" ++ "tin\")";

const linux_markers = [_][]const u8{
    "std.po" ++ "six",
    "std.os." ++ "linux",
};

const windows_markers = [_][]const u8{
    "extern \"kernel" ++ "32\"",
    "extern \"user" ++ "32\"",
    "extern \"win" ++ "mm\"",
    "std.os." ++ "windows",
};

const guard_keywords = [_][]const u8{
    "defer ",
    "errdefer ",
};

const breathing_keywords = [_][]const u8{
    "return",
    "if ",
    "while ",
    "for ",
    "switch ",
    "try ",
};

const statement_openers = "({[";
const statement_closers = ")}]";
const prong_marker = "=>";

const block_keywords = [_][]const u8{
    ".",
    "comptime",
    "defer",
    "else",
    "errdefer",
    "export",
    "extern",
    "fn ",
    "for ",
    "if ",
    "inline",
    "pub ",
    "switch ",
    "test ",
    "while ",
};

const container_openers = [_][]const u8{
    "enum {",
    "error {",
    "opaque {",
    "struct {",
    "union {",
};

comptime {
    assert(line_columns_max == 100);
    assert(line_count_max > line_columns_max);
    assert(file_bytes_max > 0);
    assert(file_count_max > 0);
    assert(functions_per_file_max > 0);
    assert(imports_per_file_max > 0);
    assert(function_lines_max > 0);
    assert(source_directories.len > 0);
    assert(test_registries.len > 0);
    assert(entry_points.len > 0);
    assert(banned.len > 0);
    assert(leftover_markers.len > 0);
    assert(guard_keywords.len > 0);
    assert(breathing_keywords.len > 0);
    assert(block_keywords.len > 0);
    assert(container_openers.len > 0);
    assert(linux_markers.len > 0);
    assert(windows_markers.len > 0);
    assert(assert_alias.len > 0);
    assert(builtin_marker.len > 0);
    assert(function_marker.len == 3);
    assert(import_marker.len > 0);
    assert(type_suffix.len > 0);
    assert(prong_marker.len == 2);
    assert(statement_openers.len == statement_closers.len);
    assert(std.mem.startsWith(u8, linux_directory, platform_directory));
    assert(std.mem.startsWith(u8, windows_directory, platform_directory));
}

const Errors = struct {
    count: u32 = 0,

    fn add(errors: *Errors, path: []const u8, line: usize, message: []const u8) void {
        errors.count += 1;

        std.debug.print("{s}:{d}: error: {s}\n", .{ path, line, message });
    }

    fn add_fmt(
        errors: *Errors,
        path: []const u8,
        line: usize,
        comptime format: []const u8,
        args: anytype,
    ) void {
        errors.count += 1;

        std.debug.print("{s}:{d}: error: " ++ format ++ "\n", .{ path, line } ++ args);
    }
};

const Lines = struct {
    items: [line_count_max][]const u8,
    count: usize,

    fn fill(self: *Lines, text: []const u8) void {
        self.count = 0;

        var iterator = std.mem.splitScalar(u8, text, '\n');

        while (iterator.next()) |line| {
            if (self.count >= line_count_max) break;

            self.items[self.count] = line;
            self.count += 1;
        }

        assert(self.count <= line_count_max);
    }

    fn get(self: *const Lines, index: usize) []const u8 {
        assert(index < self.count);

        return self.items[index];
    }
};

fn line_of(text: []const u8, offset: usize) usize {
    assert(offset <= text.len);

    return std.mem.count(u8, text[0..offset], "\n") + 1;
}

fn line_columns(line: []const u8) usize {
    return std.unicode.utf8CountCodepoints(line) catch line.len;
}

fn indent_of(line: []const u8) []const u8 {
    var index: usize = 0;

    while (index < line.len) : (index += 1) {
        const byte = line[index];

        if (byte != ' ' and byte != '\t') {
            break;
        }
    }

    return line[0..index];
}

fn trimmed_of(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn is_blank(line: []const u8) bool {
    return trimmed_of(line).len == 0;
}

fn is_guard(line: []const u8) bool {
    const trimmed = trimmed_of(line);

    for (guard_keywords) |keyword| {
        if (std.mem.startsWith(u8, trimmed, keyword)) return true;
    }

    return false;
}

fn is_declaration(line: []const u8) bool {
    const trimmed = trimmed_of(line);
    const opens = std.mem.startsWith(u8, trimmed, "const ") or
        std.mem.startsWith(u8, trimmed, "var ");

    if (!opens) {
        return false;
    }

    return std.mem.endsWith(u8, trimmed, ";");
}

fn is_control_flow(line: []const u8) bool {
    const trimmed = trimmed_of(line);

    for (breathing_keywords) |keyword| {
        if (std.mem.startsWith(u8, trimmed, keyword)) return true;
    }

    return false;
}

fn opens_scope(line: []const u8) bool {
    const trimmed = trimmed_of(line);

    if (trimmed.len == 0) {
        return false;
    }

    return std.mem.indexOfScalar(u8, statement_openers, trimmed[trimmed.len - 1]) != null;
}

fn closes_scope(line: []const u8) bool {
    const trimmed = trimmed_of(line);

    if (trimmed.len == 0) {
        return false;
    }

    return std.mem.indexOfScalar(u8, statement_closers, trimmed[0]) != null;
}

fn opens_statement(line: []const u8) bool {
    const trimmed = trimmed_of(line);

    if (trimmed.len == 0) return false;
    if (indent_of(line).len == 0) return false;
    if (!opens_scope(line)) return false;
    if (closes_scope(line)) return false;
    if (std.mem.indexOf(u8, trimmed, prong_marker) != null) return false;

    for (block_keywords) |keyword| {
        if (std.mem.startsWith(u8, trimmed, keyword)) return false;
    }

    for (container_openers) |opener| {
        if (std.mem.endsWith(u8, trimmed, opener)) return false;
    }

    return true;
}

fn statement_end(lines: *const Lines, start: usize) ?usize {
    assert(start < lines.count);

    const indent = indent_of(lines.get(start));

    var index = start + 1;

    while (index < lines.count) : (index += 1) {
        const line = lines.get(index);

        if (is_blank(line)) continue;

        const current = indent_of(line);

        if (current.len > indent.len) continue;
        if (current.len < indent.len) return null;
        if (!closes_scope(line)) return null;
        if (std.mem.endsWith(u8, trimmed_of(line), ";")) return index;
    }

    return null;
}

fn guard_is_crowded(lines: *const Lines, index: usize) bool {
    const line = lines.get(index);

    if (!std.mem.endsWith(u8, trimmed_of(line), ";")) return false;
    if (index + 1 >= lines.count) return false;

    const next = lines.get(index + 1);

    if (is_blank(next)) return false;
    if (is_guard(next)) return false;
    if (closes_scope(next)) return false;

    return std.mem.eql(u8, indent_of(next), indent_of(line));
}

fn statement_is_crowded_above(lines: *const Lines, start: usize) bool {
    if (start == 0) return false;

    const above = lines.get(start - 1);

    return !(is_blank(above) or opens_scope(above) or is_guard(above));
}

fn statement_is_crowded_below(lines: *const Lines, end: usize) bool {
    if (end + 1 >= lines.count) return false;

    const below = lines.get(end + 1);

    return !(is_blank(below) or closes_scope(below));
}

fn tidy_guards(errors: *Errors, path: []const u8, lines: *const Lines) void {
    var index: usize = 0;

    while (index < lines.count) : (index += 1) {
        if (!is_guard(lines.get(index))) continue;

        if (guard_is_crowded(lines, index)) {
            errors.add(path, index + 1, "guard needs a blank line before the next step");
        }
    }
}

fn tidy_isolation(errors: *Errors, path: []const u8, lines: *const Lines) void {
    var index: usize = 0;

    while (index < lines.count) {
        if (!opens_statement(lines.get(index))) {
            index += 1;

            continue;
        }

        const end = statement_end(lines, index) orelse {
            index += 1;

            continue;
        };

        if (statement_is_crowded_above(lines, index)) {
            errors.add(path, index + 1, "multi-line expression needs a blank line above");
        }

        if (statement_is_crowded_below(lines, end)) {
            errors.add(path, end + 2, "multi-line expression needs a blank line below");
        }

        index = end + 1;
    }
}

fn tidy_breathing(errors: *Errors, path: []const u8, lines: *const Lines) void {
    var index: usize = 1;

    while (index < lines.count) : (index += 1) {
        const previous = lines.get(index - 1);
        const line = lines.get(index);

        if (!is_declaration(previous)) continue;
        if (!is_control_flow(line)) continue;
        if (!std.mem.eql(u8, indent_of(previous), indent_of(line))) continue;

        errors.add(path, index + 1, "declaration needs a blank line before the next step");
    }
}

fn tidy_control_characters(errors: *Errors, file: *const SourceFile) void {
    const offset = std.mem.indexOfAny(u8, file.text, "\r\t") orelse return;

    const name = if (file.text[offset] == '\r') "carriage return" else "tab";

    errors.add_fmt(file.path, line_of(file.text, offset), "control character: {s}", .{name});
}

fn tidy_banned(errors: *Errors, file: *const SourceFile) void {
    for (banned) |ban| {
        const offset = std.mem.indexOf(u8, file.text, ban.needle) orelse continue;

        errors.add_fmt(file.path, line_of(file.text, offset), "'{s}' is banned, use {s}", .{
            ban.needle,
            ban.replacement,
        });
    }

    for (leftover_markers) |marker| {
        const offset = std.mem.indexOf(u8, file.text, marker) orelse continue;

        errors.add_fmt(file.path, line_of(file.text, offset), "leftover '{s}', remove it", .{
            marker,
        });
    }

    if (std.mem.indexOf(u8, file.text, assert_call) == null) return;
    if (std.mem.indexOf(u8, file.text, assert_alias) != null) return;

    errors.add_fmt(file.path, 1, "uses assert without declaring '{s}'", .{assert_alias});
}

fn tidy_catch_blocks(errors: *Errors, file: *const SourceFile) void {
    var index: usize = 0;

    while (std.mem.indexOfPos(u8, file.text, index, catch_opener)) |found| {
        const opened = found + catch_opener.len;

        index = opened;

        const closed = std.mem.indexOfScalarPos(u8, file.text, opened, '}') orelse continue;
        const body = std.mem.trim(u8, file.text[opened..closed], " \t\r\n");

        if (body.len > 0) continue;

        errors.add(file.path, line_of(file.text, found), "empty catch block swallows the error");
    }
}

fn raw_literal_fits(line: []const u8) bool {
    const marker = std.mem.indexOf(u8, line, "\\\\") orelse return false;

    for (line[0..marker]) |byte| {
        if (byte != ' ') return false;
    }

    return line_columns(line[marker + 2 ..]) <= line_columns_max;
}

fn tidy_lines(errors: *Errors, file: *const SourceFile) void {
    var lines = std.mem.splitScalar(u8, file.text, '\n');
    var index: usize = 0;

    while (lines.next()) |raw| : (index += 1) {
        const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;

        if (line.len > 0 and line[line.len - 1] == ' ') {
            errors.add(file.path, index + 1, "trailing whitespace");
        }

        if (index == line_count_max) {
            errors.add_fmt(file.path, index + 1, "file exceeds {d} lines", .{line_count_max});
        }

        if (line_columns(line) <= line_columns_max) continue;
        if (std.mem.indexOf(u8, line, "https://") != null) continue;
        if (raw_literal_fits(line)) continue;

        errors.add_fmt(file.path, index + 1, "line exceeds {d} columns", .{line_columns_max});
    }
}

fn tidy_type_functions(errors: *Errors, file: *const SourceFile) void {
    var lines = std.mem.splitScalar(u8, file.text, '\n');
    var index: usize = 0;

    while (lines.next()) |line| : (index += 1) {
        const found = std.mem.indexOf(u8, line, function_marker) orelse continue;

        if (found > 0 and line[found - 1] != ' ') continue;
        if (std.mem.indexOf(u8, line, "extern \"") != null) continue;

        const rest = line[found + function_marker.len ..];
        const open = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        const name = rest[0..open];

        if (name.len == 0) continue;
        if (!std.ascii.isUpper(name[0])) continue;
        if (std.mem.endsWith(u8, name, type_suffix)) continue;

        errors.add_fmt(file.path, index + 1, "type function '{s}' must end in '{s}'", .{
            name,
            type_suffix,
        });
    }
}

fn tidy_file_name(errors: *Errors, file: *const SourceFile) void {
    if (!std.mem.endsWith(u8, file.basename, ".zig")) {
        errors.add(file.path, 1, "source file must end in .zig");

        return;
    }

    const stem = file.basename[0 .. file.basename.len - ".zig".len];

    if (stem.len == 0) {
        errors.add(file.path, 1, "empty file name stem");

        return;
    }

    for (stem) |byte| {
        const lower = std.ascii.isLower(byte);
        const digit = std.ascii.isDigit(byte);

        if (lower or digit or byte == '_') continue;

        errors.add(file.path, 1, "file name must be snake_case");

        return;
    }
}

fn is_boundary_exempt(basename: []const u8) bool {
    for (boundary_exempt) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }

    return false;
}

fn is_entry_point(basename: []const u8) bool {
    for (entry_points) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }

    return false;
}

fn report_marker(errors: *Errors, file: *const SourceFile, marker: []const u8) void {
    const offset = std.mem.indexOf(u8, file.text, marker) orelse return;

    errors.add_fmt(file.path, line_of(file.text, offset), "'{s}' does not belong here", .{marker});
}

fn tidy_boundary(errors: *Errors, file: *const SourceFile) void {
    if (is_boundary_exempt(file.basename)) return;

    const is_selector = std.mem.eql(u8, file.path, platform_selector_path);

    if (!std.mem.startsWith(u8, file.path, linux_directory)) {
        for (linux_markers) |marker| report_marker(errors, file, marker);
    }

    if (!std.mem.startsWith(u8, file.path, windows_directory)) {
        for (windows_markers) |marker| report_marker(errors, file, marker);
    }

    if (!is_selector) {
        report_marker(errors, file, builtin_marker);
    }

    if (!is_selector and !std.mem.startsWith(u8, file.path, platform_directory)) {
        report_marker(errors, file, platform_marker);
    }
}

fn nested(spans: []const Span, index: usize) bool {
    const target = spans[index];

    for (spans, 0..) |span, other| {
        if (other == index) continue;
        if (span.first <= target.first and span.last >= target.last) return true;
    }

    return false;
}

fn returns_type(tree: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [1]Ast.Node.Index = undefined;

    const proto = tree.fullFnProto(&buffer, node) orelse return false;
    const returned = proto.ast.return_type.unwrap() orelse return false;

    if (tree.nodeTag(returned) != .identifier) return false;

    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(returned)), "type");
}

fn tidy_function_lengths(errors: *Errors, tree: *const Ast, file: *const SourceFile) void {
    var spans: [functions_per_file_max]Span = undefined;
    var count: usize = 0;

    for (tree.nodes.items(.tag), 0..) |tag, index| {
        if (tag != .fn_decl) continue;
        if (count == spans.len) break;

        const node: Ast.Node.Index = @enumFromInt(index);
        const body = tree.nodeData(node).node_and_node[1];

        spans[count] = .{
            .exempt = returns_type(tree, node),
            .first = tree.tokenLocation(0, tree.firstToken(node)).line,
            .last = tree.tokenLocation(0, tree.lastToken(body)).line,
        };

        count += 1;
    }

    for (spans[0..count], 0..) |span, index| {
        if (span.exempt) continue;
        if (nested(spans[0..count], index)) continue;

        assert(span.last >= span.first);

        const length = span.last - span.first + 1;

        if (length <= function_lines_max) continue;

        errors.add_fmt(file.path, span.first + 1, "function spans {d} lines (max {d})", .{
            length,
            function_lines_max,
        });
    }
}

fn is_bin_op_bitwise(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .shl, .shl_sat, .shr => true,
        .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

fn is_bin_op_arithmetic(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .add, .add_sat, .add_wrap => true,
        .sub, .sub_sat, .sub_wrap => true,
        .mul, .mul_sat, .mul_wrap => true,
        .div, .mod => true,
        else => false,
    };
}

fn tidy_precedence(errors: *Errors, tree: *const Ast, file: *const SourceFile) void {
    for (tree.nodes.items(.tag), 0..) |tag, index| {
        const bitwise = is_bin_op_bitwise(tag);
        const arithmetic = is_bin_op_arithmetic(tag);

        if (!bitwise and !arithmetic) continue;

        const node: Ast.Node.Index = @enumFromInt(index);
        const left, const right = tree.nodeData(node).node_and_node;

        for ([_]Ast.Node.Index{ left, right }) |child| {
            const child_tag = tree.nodeTag(child);
            const mixed = (bitwise and is_bin_op_arithmetic(child_tag)) or
                (arithmetic and is_bin_op_bitwise(child_tag));

            if (!mixed) continue;

            const line = tree.tokenLocation(0, tree.firstToken(node)).line;

            errors.add(file.path, line + 1, "ambiguous operator precedence, add parentheses");
        }
    }
}

fn is_private_declaration(tree: *const Ast, token: Ast.TokenIndex) bool {
    if (token == 0) return false;

    const tags = tree.tokens.items(.tag);
    const keyword = tags[token - 1];

    if (keyword != .keyword_fn and keyword != .keyword_const) return false;

    var offset: Ast.TokenIndex = 2;

    while (offset <= 4) : (offset += 1) {
        if (token < offset) return true;

        switch (tags[token - offset]) {
            .keyword_inline, .keyword_extern, .string_literal => {},
            .keyword_pub, .keyword_export => return false,
            .r_bracket, .r_paren, .asterisk => return false,
            else => return true,
        }
    }

    return false;
}

fn record_mention(
    arena: Allocator,
    counts: *std.StringHashMapUnmanaged(Mention),
    tree: *const Ast,
    token: Ast.TokenIndex,
) !void {
    const name = tree.tokenSlice(token);
    const offset = tree.tokenStart(token);

    const entry = try counts.getOrPut(arena, name);

    if (!entry.found_existing) {
        entry.value_ptr.* = .{ .count = 1, .offset = offset };

        return;
    }

    const between = tree.source[entry.value_ptr.offset..offset];

    if (std.mem.indexOfScalar(u8, between, '\n') == null) return;

    entry.value_ptr.count += 1;
    entry.value_ptr.offset = offset;
}

fn tidy_dead_declarations(
    arena: Allocator,
    errors: *Errors,
    tree: *const Ast,
    file: *const SourceFile,
) !void {
    var counts: std.StringHashMapUnmanaged(Mention) = .empty;
    defer counts.deinit(arena);

    const tags = tree.tokens.items(.tag);

    for (tags, 0..) |tag, index| {
        if (tag != .identifier) continue;

        try record_mention(arena, &counts, tree, @intCast(index));
    }

    for (tags, 0..) |tag, index| {
        if (tag != .identifier) continue;

        const token: Ast.TokenIndex = @intCast(index);
        const name = tree.tokenSlice(token);
        const mention = counts.get(name) orelse continue;

        if (mention.count != 1) continue;
        if (!is_private_declaration(tree, token)) continue;

        const line = tree.tokenLocation(0, token).line;

        errors.add_fmt(file.path, line + 1, "unused private declaration '{s}'", .{name});
    }
}

fn tidy_ast(arena: Allocator, errors: *Errors, file: *const SourceFile) !void {
    const source = try arena.dupeZ(u8, file.text);

    var tree = try Ast.parse(arena, source, .zig);
    defer tree.deinit(arena);

    if (tree.errors.len > 0) {
        errors.add(file.path, 1, "file does not parse");

        return;
    }

    tidy_function_lengths(errors, &tree, file);
    tidy_precedence(errors, &tree, file);

    try tidy_dead_declarations(arena, errors, &tree, file);
}

fn tidy_text(arena: Allocator, errors: *Errors, file: *const SourceFile) !void {
    tidy_control_characters(errors, file);
    tidy_banned(errors, file);
    tidy_catch_blocks(errors, file);
    tidy_lines(errors, file);
    tidy_type_functions(errors, file);

    var buffer: Lines = undefined;

    buffer.fill(file.text);

    tidy_guards(errors, file.path, &buffer);
    tidy_isolation(errors, file.path, &buffer);
    tidy_breathing(errors, file.path, &buffer);

    try tidy_ast(arena, errors, file);
}

fn declares_tests(text: []const u8) bool {
    if (std.mem.startsWith(u8, text, "test ")) return true;

    return std.mem.indexOf(u8, text, "\ntest ") != null;
}

fn find_source(sources: []const SourceFile, path: []const u8) ?*const SourceFile {
    for (sources) |*source| {
        if (std.mem.eql(u8, source.path, path)) return source;
    }

    return null;
}

fn is_registered(sources: []const SourceFile, basename: []const u8) bool {
    for (test_registries) |path| {
        const registry = find_source(sources, path) orelse continue;

        if (imports_basename(registry.text, basename)) return true;
    }

    return false;
}

fn imports_basename(text: []const u8, basename: []const u8) bool {
    assert(basename.len > 0);

    var index: usize = 0;
    var guard: usize = 0;

    while (std.mem.indexOfPos(u8, text, index, import_marker)) |found| {
        guard += 1;

        assert(guard <= imports_per_file_max);

        const start = found + import_marker.len;
        const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return false;
        const path = text[start..end];

        index = end;

        const tail = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash|
            path[slash + 1 ..]
        else
            path;

        if (std.mem.eql(u8, tail, basename)) return true;
    }

    return false;
}

fn imported_anywhere(sources: []const SourceFile, target: *const SourceFile) bool {
    for (sources) |*source| {
        if (std.mem.eql(u8, source.path, target.path)) continue;
        if (imports_basename(source.text, target.basename)) return true;
    }

    return false;
}

fn tidy_imports(errors: *Errors, sources: []const SourceFile, file: *const SourceFile) void {
    if (is_entry_point(file.basename)) return;

    if (!imported_anywhere(sources, file)) {
        errors.add(file.path, 1, "never imported by another file, dead file?");
    }

    if (declares_tests(file.text) and !is_registered(sources, file.basename)) {
        errors.add(file.path, 1, "declares tests but is missing from a test registry");
    }

    if (!std.mem.endsWith(u8, file.basename, fuzz_suffix)) return;

    const registry = find_source(sources, fuzz_registry_path) orelse {
        errors.add(fuzz_registry_path, 1, "fuzz registry is missing");

        return;
    };

    if (imports_basename(registry.text, file.basename)) return;

    errors.add(file.path, 1, "is a fuzzer but is missing from the fuzz registry");
}

fn normalize(path: []u8) []u8 {
    for (path) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }

    return path;
}

fn collect(
    arena: Allocator,
    io: std.Io,
    gpa: Allocator,
    storage: []SourceFile,
    directories: []const []const u8,
) !usize {
    assert(storage.len > 0);

    var count: usize = 0;

    for (directories) |directory| {
        var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
        defer dir.close(io);

        var walker = try dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            try std.testing.expect(count < storage.len);

            const relative = normalize(try arena.dupe(u8, entry.path));

            const text = try entry.dir.readFileAlloc(
                io,
                entry.basename,
                arena,
                .limited(file_bytes_max),
            );

            storage[count] = .{
                .basename = try arena.dupe(u8, entry.basename),
                .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ directory, relative }),
                .text = text,
            };

            count += 1;
        }
    }

    assert(count <= storage.len);

    return count;
}

fn tidy_extra_files(arena: Allocator, io: std.Io, errors: *Errors) !void {
    for (extra_files) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            arena,
            .limited(file_bytes_max),
        );

        const file: SourceFile = .{
            .basename = std.fs.path.basename(path),
            .path = path,
            .text = text,
        };

        if (std.mem.endsWith(u8, path, ".zig")) {
            try tidy_text(arena, errors, &file);

            continue;
        }

        tidy_control_characters(errors, &file);
        tidy_lines(errors, &file);
    }
}

test "tidy: sources obey the mechanical law" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    const storage = try arena.alloc(SourceFile, file_count_max);
    const count = try collect(arena, io, gpa, storage, &source_directories);

    try std.testing.expect(count > 0);

    const sources = storage[0..count];

    var errors: Errors = .{};

    for (test_registries) |path| {
        if (find_source(sources, path) != null) continue;

        errors.add(path, 1, "test registry is missing");
    }

    for (sources) |*source| {
        tidy_file_name(&errors, source);
        tidy_boundary(&errors, source);
        tidy_imports(&errors, sources, source);

        try tidy_text(arena, &errors, source);
    }

    try tidy_extra_files(arena, io, &errors);
    try std.testing.expectEqual(@as(u32, 0), errors.count);
}
