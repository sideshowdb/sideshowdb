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
    const wasm_step = buildWasmClient(b, optimize);
    const reference_docs_step = buildSiteReferenceDocs(b, core_mod);
    const site_assets_step = buildSiteAssets(b, wasm_step, reference_docs_step);
    buildTests(b, target, optimize, core_mod);
    const site_only_step = buildSiteOnly(b, site_assets_step);
    _ = buildSiteDev(b, site_assets_step);
    _ = buildSitePreview(b, site_only_step);

    const site_step = b.step("site", "Build the full site pipeline");
    site_step.dependOn(site_only_step);
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

fn buildSiteAssets(
    b: *std.Build,
    wasm_step: *std.Build.Step,
    reference_docs_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step("siteAssets", "Stage the site wasm and reference assets");

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "site/static/wasm" });
    mkdir.step.dependOn(wasm_step);

    const copy = b.addSystemCommand(&.{
        "cp",
        "-f",
        "zig-out/wasm/sideshowdb.wasm",
        "site/static/wasm/sideshowdb.wasm",
    });
    copy.step.dependOn(&mkdir.step);

    step.dependOn(&copy.step);
    step.dependOn(reference_docs_step);
    return step;
}

fn buildSiteReferenceDocs(
    b: *std.Build,
    core_mod: *std.Build.Module,
) *std.Build.Step {
    const docs_compile = b.addTest(.{ .root_module = core_mod });
    const emit_docs = docs_compile.getEmittedDocs();

    const copy = b.addSystemCommand(&.{
        "sh",
        "-c",
        "set -eu; dest=\"$1\"; src=\"$2\"; rm -rf \"$dest\"; mkdir -p \"$dest\"; cp -rf \"$src\"/. \"$dest\"/",
        "sh",
        "site/static/reference/api",
    });
    copy.addDirectoryArg(emit_docs);

    const step = b.step(
        "siteReferenceDocs",
        "Generate Zig autodoc into site/static/reference/api",
    );
    step.dependOn(&copy.step);
    return step;
}

fn buildSiteOnly(
    b: *std.Build,
    site_assets_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step("siteOnly", "Build the GitHub Pages site");
    const bun = b.addSystemCommand(&.{ "bun", "run", "build" });
    bun.setCwd(b.path("site"));
    bun.step.dependOn(site_assets_step);
    step.dependOn(&bun.step);
    return step;
}

fn buildSiteDev(
    b: *std.Build,
    site_assets_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step(
        "siteDev",
        "Run the SvelteKit dev server with staged wasm and reference assets",
    );
    const bun = b.addSystemCommand(&.{ "bun", "run", "dev" });
    bun.setCwd(b.path("site"));
    bun.has_side_effects = true;
    bun.stdio = .inherit;
    if (b.args) |args| bun.addArgs(args);
    bun.step.dependOn(site_assets_step);
    step.dependOn(&bun.step);
    return step;
}

fn buildSitePreview(
    b: *std.Build,
    site_only_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step(
        "sitePreview",
        "Preview the built site (Vite preview server)",
    );
    const bun = b.addSystemCommand(&.{ "bun", "run", "preview" });
    bun.setCwd(b.path("site"));
    bun.has_side_effects = true;
    bun.stdio = .inherit;
    if (b.args) |args| bun.addArgs(args);
    bun.step.dependOn(site_only_step);
    step.dependOn(&bun.step);
    return step;
}

fn buildWasmClient(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
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
    return wasm_step;
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

    const document_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/document_store_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
        },
    });
    const document_tests = b.addTest(.{ .root_module = document_test_mod });
    const run_document_tests = b.addRunArtifact(document_tests);

    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/cli_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
            .{ .name = "sideshowdb_cli_app", .module = b.createModule(.{
                .root_source_file = b.path("src/cli/app.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sideshowdb", .module = core_mod },
                },
            }) },
        },
    });
    const cli_tests = b.addTest(.{ .root_module = cli_test_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const transport_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/document_transport_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
        },
    });
    const transport_tests = b.addTest(.{ .root_module = transport_test_mod });
    const run_transport_tests = b.addRunArtifact(transport_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_git_ref_tests.step);
    test_step.dependOn(&run_document_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_transport_tests.step);
}
