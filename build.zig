const std = @import("std");

const assert = std.debug.assert;

const Steps = struct {
    check: *std.Build.Step,
    ci: *std.Build.Step,
    fuzz: *std.Build.Step,
    fuzz_build: *std.Build.Step,
    fuzz_smoke: *std.Build.Step,
    run: *std.Build.Step,
    test_all: *std.Build.Step,
    test_fmt: *std.Build.Step,
    test_unit: *std.Build.Step,
};

const format_paths = [_][]const u8{ "build.zig", "src" };

const root_path = "src/root.zig";
const cli_path = "src/main.zig";
const fuzz_path = "src/fuzz_tests.zig";
const linux_path = "src/linux_tests.zig";
const unit_path = "src/unit_tests.zig";

const windows_query = std.Target.Query{
    .cpu_arch = .x86_64,
    .os_tag = .windows,
    .abi = .gnu,
};

comptime {
    assert(format_paths.len > 0);
    assert(std.mem.endsWith(u8, root_path, ".zig"));
    assert(std.mem.endsWith(u8, cli_path, ".zig"));
    assert(std.mem.endsWith(u8, fuzz_path, ".zig"));
    assert(std.mem.endsWith(u8, linux_path, ".zig"));
    assert(std.mem.endsWith(u8, unit_path, ".zig"));
    assert(!std.mem.eql(u8, root_path, cli_path));
    assert(!std.mem.eql(u8, linux_path, unit_path));
    assert(windows_query.os_tag == .windows);
}

fn is_hosted(tag: std.Target.Os.Tag) bool {
    return tag == .linux or tag == .windows;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const steps = Steps{
        .check = b.step("check", "Compile every artifact without running it"),
        .ci = b.step("ci", "Run formatting, compilation, unit tests, and fuzzer smoke"),
        .fuzz = b.step("fuzz", "Run a fuzzer: -- <fuzzer> [seed] [events]"),
        .fuzz_build = b.step("fuzz:build", "Compile the fuzzer without running it"),
        .fuzz_smoke = b.step("fuzz:smoke", "Run every fuzzer briefly with a fixed seed"),
        .run = b.step("run", "Run the GFDI archive puller"),
        .test_all = b.step("test", "Run every test suite and the formatting check"),
        .test_fmt = b.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = b.step("test:unit", "Run the colocated unit tests and the tidy law"),
    };

    const module = b.addModule("gfdi", .{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfit", .module = zfit_module(b, target, optimize) }},
    });

    add_format(b, &steps);
    add_cli(b, &steps, module, target, optimize);
    add_unit_tests(b, &steps, target, optimize);
    add_linux_tests(b, &steps, optimize);
    add_fuzz(b, &steps, target, optimize);

    steps.ci.dependOn(steps.test_fmt);
    steps.ci.dependOn(steps.check);
    steps.ci.dependOn(steps.test_unit);
    steps.ci.dependOn(steps.fuzz_smoke);

    b.default_step.dependOn(steps.check);
}

fn add_format(b: *std.Build, steps: *const Steps) void {
    const fmt = b.addFmt(.{
        .paths = &format_paths,
        .check = true,
    });

    steps.test_fmt.dependOn(&fmt.step);
    steps.test_all.dependOn(&fmt.step);
}

fn add_cli(
    b: *std.Build,
    steps: *const Steps,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const hosted = is_hosted(target.result.os.tag);

    const resolved = if (hosted)
        target
    else
        b.resolveTargetQuery(windows_query);

    const linked = if (hosted) module else cross_module(b, resolved, optimize);

    const exe = b.addExecutable(.{
        .name = "gfdi",
        .root_module = b.createModule(.{
            .root_source_file = b.path(cli_path),
            .target = resolved,
            .optimize = optimize,
            .imports = &.{.{ .name = "gfdi", .module = linked }},
        }),
    });

    steps.check.dependOn(&exe.step);

    if (!hosted) {
        return;
    }

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    run.step.dependOn(b.getInstallStep());

    if (b.args) |args| run.addArgs(args);

    steps.run.dependOn(&run.step);
}

fn add_unit_tests(
    b: *std.Build,
    steps: *const Steps,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(unit_path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zfit", .module = zfit_module(b, target, optimize) }},
        }),
        .filters = b.args orelse &.{},
    });

    const run = b.addRunArtifact(unit);

    run.setCwd(b.path("."));

    steps.test_unit.dependOn(&run.step);
    steps.test_all.dependOn(&run.step);
    steps.check.dependOn(&unit.step);
}

fn add_linux_tests(
    b: *std.Build,
    steps: *const Steps,
    optimize: std.builtin.OptimizeMode,
) void {
    if (b.graph.host.result.os.tag != .linux) {
        return;
    }

    const suite = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(linux_path),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{
                .name = "zfit",
                .module = zfit_module(b, b.graph.host, optimize),
            }},
        }),
        .filters = b.args orelse &.{},
    });

    const run = b.addRunArtifact(suite);

    run.setCwd(b.path("."));

    steps.test_unit.dependOn(&run.step);
    steps.test_all.dependOn(&run.step);
    steps.check.dependOn(&suite.step);
}

fn add_fuzz(
    b: *std.Build,
    steps: *const Steps,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path(fuzz_path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zfit", .module = zfit_module(b, target, optimize) }},
        }),
    });

    const run = b.addRunArtifact(exe);

    if (b.args) |args| run.addArgs(args);

    const smoke = b.addRunArtifact(exe);

    smoke.addArg("smoke");

    steps.fuzz.dependOn(&run.step);
    steps.fuzz_build.dependOn(&exe.step);
    steps.fuzz_smoke.dependOn(&smoke.step);
    steps.check.dependOn(&exe.step);
}

fn cross_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfit", .module = zfit_module(b, target, optimize) }},
    });
}

fn zfit_module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const dependency = b.dependency("zfit", .{
        .target = target,
        .optimize = optimize,
    });

    return dependency.module("zfit");
}
