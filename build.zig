const std = @import("std");

const assert = std.debug.assert;

const Artifact = struct {
    name: []const u8,
    root: []const u8,
};

const Context = struct {
    bounded: *std.Build.Module,
    builder: *std.Build,
    filters: []const []const u8,
    optimize: std.lang.Optimize,
    steps: Steps,
    target: std.Build.ResolvedTarget,
};

const Steps = struct {
    check: *std.Build.Step,
    continuous_integration: *std.Build.Step,
    example: *std.Build.Step,
    fuzz: *std.Build.Step,
    fuzz_build: *std.Build.Step,
    fuzz_smoke: *std.Build.Step,
    run: *std.Build.Step,
    test_all: *std.Build.Step,
    test_format: *std.Build.Step,
    test_unit: *std.Build.Step,
};

const artifact_example: Artifact = .{ .name = "observe", .root = "examples/observe.zig" };
const artifact_fuzz: Artifact = .{ .name = "fuzz", .root = "src/fuzz_tests.zig" };
const artifact_main: Artifact = .{ .name = "gfdi", .root = "src/main.zig" };
const format_paths = [_][]const u8{ "build.zig", "examples", "src" };
const module_root = "src/gfdi.zig";
const unit_tests_root = "src/unit_tests.zig";

const supported_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

comptime {
    assert(format_paths.len == 3);
    assert(supported_targets.len == 2);
}

pub fn build(builder: *std.Build) void {
    assert(builder.graph.host.result.ptrBitWidth() == 64);

    const filters = builder.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const context = Context{
        .bounded = builder.dependency("bounded", .{}).module("bounded"),
        .builder = builder,
        .filters = filters,
        .optimize = builder.standardOptimizeOption(.{ .preferred_optimize_mode = null }),
        .steps = steps_declare(builder),
        .target = builder.standardTargetOptions(.{ .whitelist = null, .default_target = .{} }),
    };

    _ = builder.addModule("gfdi", .{
        .root_source_file = builder.path(module_root),
        .imports = &.{
            .{ .name = "bounded", .module = context.bounded },
            .{ .name = "fit", .module = fit(&context, context.target) },
        },
    });

    add_check(&context);
    add_example(&context);
    add_format(&context);
    add_fuzz(&context);
    add_run(&context);
    add_unit_tests(&context);

    context.steps.continuous_integration.dependOn(context.steps.check);
    context.steps.continuous_integration.dependOn(context.steps.example);
    context.steps.continuous_integration.dependOn(context.steps.fuzz_smoke);
    context.steps.continuous_integration.dependOn(context.steps.test_all);
}

fn steps_declare(builder: *std.Build) Steps {
    assert(builder.graph.host.result.ptrBitWidth() == 64);

    const result = Steps{
        .check = builder.step("check", "Compile every artifact for Linux and Windows"),
        .continuous_integration = builder.step("ci", "Run every check, test, and fuzz smoke"),
        .example = builder.step("example", "Build and run the example against the module"),
        .fuzz = builder.step("fuzz", "Run a fuzzer: zig build fuzz -- <fuzzer> [seed] [events]"),
        .fuzz_build = builder.step("fuzz:build", "Compile the fuzzers without running them"),
        .fuzz_smoke = builder.step("fuzz:smoke", "Run every fuzzer briefly with a fixed seed"),
        .run = builder.step("run", "Run the archive puller: zig build run -- <command>"),
        .test_all = builder.step("test", "Run every test suite and the format check"),
        .test_format = builder.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = builder.step("test:unit", "Run the unit tests and the tidy check"),
    };

    assert(result.check != result.test_all);
    assert(result.fuzz != result.fuzz_smoke);

    return result;
}

fn fit(context: *const Context, target: std.Build.ResolvedTarget) *std.Build.Module {
    assert(target.result.ptrBitWidth() == 64);
    assert(context.steps.check != context.steps.test_all);

    const dependency = context.builder.dependency("fit", .{
        .optimize = context.optimize,
        .target = target,
    });

    return dependency.module("fit");
}

fn library(context: *const Context, target: std.Build.ResolvedTarget) *std.Build.Module {
    assert(target.result.ptrBitWidth() == 64);
    assert(std.mem.endsWith(u8, module_root, ".zig"));

    return context.builder.createModule(.{
        .root_source_file = context.builder.path(module_root),
        .target = target,
        .optimize = context.optimize,
        .imports = &.{
            .{ .name = "bounded", .module = context.bounded },
            .{ .name = "fit", .module = fit(context, target) },
        },
    });
}

fn executable(
    context: *const Context,
    target: std.Build.ResolvedTarget,
    artifact: Artifact,
) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() == 64);
    assert(artifact.name.len > 0);
    assert(std.mem.endsWith(u8, artifact.root, ".zig"));

    return context.builder.addExecutable(.{
        .name = artifact.name,
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(artifact.root),
            .target = target,
            .optimize = context.optimize,
            .omit_frame_pointer = false,
            .imports = &.{
                .{ .name = "bounded", .module = context.bounded },
                .{ .name = "fit", .module = fit(context, target) },
            },
        }),
    });
}

fn consumer(
    context: *const Context,
    target: std.Build.ResolvedTarget,
    artifact: Artifact,
) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() == 64);
    assert(std.mem.endsWith(u8, artifact.root, ".zig"));

    return context.builder.addExecutable(.{
        .name = artifact.name,
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(artifact.root),
            .target = target,
            .optimize = context.optimize,
            .imports = &.{.{ .name = "gfdi", .module = library(context, target) }},
        }),
    });
}

fn add_check(context: *const Context) void {
    assert(supported_targets.len > 0);
    assert(context.steps.check != context.steps.test_all);

    for (supported_targets) |query| {
        const resolved = context.builder.resolveTargetQuery(query);
        const fuzz = executable(context, resolved, artifact_fuzz);

        context.steps.check.dependOn(&fuzz.step);
        context.steps.check.dependOn(&consumer(context, resolved, artifact_example).step);
        context.steps.check.dependOn(&consumer(context, resolved, artifact_main).step);
        context.steps.check.dependOn(&unit_tests(context, resolved).step);
    }
}

fn add_example(context: *const Context) void {
    assert(context.steps.example != context.steps.check);
    assert(std.mem.startsWith(u8, artifact_example.root, "examples/"));

    const example = consumer(context, context.target, artifact_example);
    const run = context.builder.addRunArtifact(example);

    context.steps.example.dependOn(&run.step);
}

fn add_format(context: *const Context) void {
    assert(format_paths.len > 0);
    assert(context.steps.test_format != context.steps.test_all);

    const format = context.builder.addFmt(.{
        .paths = context.builder.pathList(&format_paths),
        .check = true,
    });

    context.steps.test_format.dependOn(&format.step);
    context.steps.test_all.dependOn(&format.step);
}

fn add_fuzz(context: *const Context) void {
    assert(context.steps.fuzz != context.steps.fuzz_smoke);
    assert(artifact_fuzz.root.len > 0);

    const fuzz = executable(context, context.target, artifact_fuzz);
    const fuzz_run = context.builder.addRunArtifact(fuzz);
    const fuzz_smoke = context.builder.addRunArtifact(fuzz);

    const fuzz_install = context.builder.addInstallArtifact(fuzz, .{
        .dest_dir = .default,
        .pdb_dir = .default,
        .compiler_rt_dyn_lib_dir = .default,
        .h_dir = .default,
        .implib_dir = .default,
        .dylib_symlinks = null,
        .dest_sub_path = null,
    });

    fuzz_run.addPassthruArgs();
    fuzz_smoke.addArg("smoke");

    context.steps.fuzz.dependOn(&fuzz_run.step);
    context.steps.fuzz_build.dependOn(&fuzz_install.step);
    context.steps.fuzz_smoke.dependOn(&fuzz_smoke.step);
}

fn add_run(context: *const Context) void {
    assert(context.steps.run != context.steps.check);
    assert(artifact_main.root.len > 0);

    const main = consumer(context, context.target, artifact_main);
    const run = context.builder.addRunArtifact(main);

    context.builder.installArtifact(main);
    run.addPassthruArgs();

    context.steps.run.dependOn(&run.step);
}

fn unit_tests(context: *const Context, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() == 64);
    assert(context.filters.len < 64);
    assert(unit_tests_root.len > 0);

    return context.builder.addTest(.{
        .name = "unit_tests",
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(unit_tests_root),
            .target = target,
            .optimize = context.optimize,
            .imports = &.{
                .{ .name = "bounded", .module = context.bounded },
                .{ .name = "fit", .module = fit(context, target) },
            },
        }),
        .filters = context.filters,
    });
}

fn add_unit_tests(context: *const Context) void {
    assert(context.steps.test_unit != context.steps.test_all);
    assert(unit_tests_root.len > 0);

    const suite = unit_tests(context, context.target);
    const run = context.builder.addRunArtifact(suite);

    run.setCwd(context.builder.path("."));
    run.has_side_effects = true;

    context.steps.test_unit.dependOn(&run.step);
    context.steps.test_all.dependOn(&run.step);
}
