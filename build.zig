const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library — exposed under the import name "sideshowdb".
    const core_mod = b.addModule("sideshowdb", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
    });

    buildNativeCli(b, target, optimize, core_mod);
    buildWasmClient(b, optimize);
    buildTests(b, target, optimize, core_mod);
}

fn buildNativeCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
) void {
    const exe = b.addExecutable(.{
        .name = "sideshowdb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sideshowdb", .module = core_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the sideshowdb CLI");
    run_step.dependOn(&run_cmd.step);
}

fn buildWasmClient(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // Core compiled for the wasm target — separate instance so it shares the
    // wasm32-freestanding target with the wasm client root.
    const wasm_core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const wasm_exe = b.addExecutable(.{
        .name = "sideshowdb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm/root.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sideshowdb", .module = wasm_core_mod },
            },
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;

    const wasm_install = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });

    const wasm_step = b.step("wasm", "Build the wasm32-freestanding browser client");
    wasm_step.dependOn(&wasm_install.step);
}

fn buildTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
) void {
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const run_core_tests = b.addRunArtifact(core_tests);

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/core_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
        },
    });
    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const git_ref_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/git_ref_store_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
        },
    });
    const git_ref_tests = b.addTest(.{ .root_module = git_ref_test_mod });
    const run_git_ref_tests = b.addRunArtifact(git_ref_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_git_ref_tests.step);
}
