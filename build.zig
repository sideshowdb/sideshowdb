const std = @import("std");

const CliUsageBuild = struct {
    runtime_mod: *std.Build.Module,
    generated_mod: *std.Build.Module,
    generate_step: *std.Build.Step,
    sync_docs_step: *std.Build.Step,
    artifacts_step: *std.Build.Step,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const package_version = loadPackageVersion(b);

    const native_build_options = b.addOptions();
    native_build_options.addOption(std.SemanticVersion, "package_version", package_version);

    // Core library — exposed under the import name "sideshowdb".
    const core_mod = b.addModule("sideshowdb", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
    });
    core_mod.addOptions("build_options", native_build_options);

    const cli_usage = buildCliUsage(b, target, optimize);
    const cli_exe = buildNativeCli(b, target, optimize, core_mod, cli_usage.runtime_mod, cli_usage.generated_mod);
    const wasm_step = buildWasmClient(b, optimize);
    const reference_docs_step = buildSiteReferenceDocs(b, core_mod);
    const site_assets_step = buildSiteAssets(b, wasm_step, reference_docs_step);
    const js_install_step = buildJsInstall(b);
    const js_bindings_build_step = buildJsScriptStep(
        b,
        "js:build-bindings",
        "Build the TypeScript binding packages from the repo root",
        "build:bindings",
        js_install_step,
    );
    const js_acceptance_build_step = buildJsScriptStep(
        b,
        "js:build-acceptance",
        "Build the TypeScript acceptance workspace from the repo root",
        "build:acceptance",
        js_install_step,
    );
    js_acceptance_build_step.dependOn(js_bindings_build_step);
    _ = buildJsReleasePrepareStep(
        b,
        js_install_step,
        js_bindings_build_step,
    );
    _ = buildJsTestStep(
        b,
        js_install_step,
        wasm_step,
        js_bindings_build_step,
    );
    _ = buildJsAcceptanceStep(
        b,
        js_install_step,
        wasm_step,
        js_bindings_build_step,
        js_acceptance_build_step,
    );
    _ = buildJsScriptStep(
        b,
        "js:check",
        "Run the Bun workspace typecheck suite from the repo root",
        "check",
        js_install_step,
    );
    buildTests(b, target, optimize, core_mod, wasm_step, cli_exe, cli_usage.runtime_mod, cli_usage.generated_mod);
    buildCheckCoreDocs(b);
    const site_only_step = buildSiteOnly(b, site_assets_step, js_install_step, js_bindings_build_step);
    _ = buildSiteDev(b, site_assets_step, js_install_step, js_bindings_build_step);
    _ = buildSitePreview(b, site_only_step, js_install_step);

    const site_step = b.step("site", "Build the full site pipeline");
    site_step.dependOn(site_only_step);
    _ = cli_usage.generate_step;
    _ = cli_usage.sync_docs_step;
    _ = cli_usage.artifacts_step;
}

fn buildCliUsage(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) CliUsageBuild {
    const ckdl_dep = b.dependency("ckdl", .{});
    const spec_path = b.path("src/cli/usage/sideshowdb.usage.kdl");
    const runtime_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/usage/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    const generator = b.addExecutable(.{
        .name = "sideshowdb-cli-usage-generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/usage/generate.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    addCkdlToCompile(generator, ckdl_dep);

    const generate_run = b.addRunArtifact(generator);
    generate_run.addFileArg(spec_path);
    const generated_usage_file = generate_run.addOutputFileArg("sideshowdb_cli_generated_usage.zig");

    const generated_mod = b.createModule(.{
        .root_source_file = generated_usage_file,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb_cli_usage_runtime", .module = runtime_mod },
        },
    });

    const cli_generate_step = b.step(
        "cli:generate",
        "Generate the static Zig CLI usage module from src/cli/usage/sideshowdb.usage.kdl",
    );
    cli_generate_step.dependOn(&generate_run.step);

    const sync_docs = b.addSystemCommand(&.{
        "sh",
        "-c",
        "set -eu; spec=\"$1\"; out=\"$2\"; tmp=$(mktemp); trap 'rm -f \"$tmp\"' EXIT; usage generate markdown --file \"$spec\" --out-file \"$tmp\" --replace-pre-with-code-fences; { printf -- '---\\ntitle: CLI Reference\\norder: 2\\n---\\n\\n'; cat \"$tmp\"; } > \"$out\"",
        "sh",
        "src/cli/usage/sideshowdb.usage.kdl",
        "site/src/routes/docs/cli/+page.md",
    });
    sync_docs.setCwd(b.path("."));
    const cli_sync_docs_step = b.step(
        "cli:sync-docs",
        "Generate site/src/routes/docs/cli/+page.md from the canonical usage spec",
    );
    cli_sync_docs_step.dependOn(&sync_docs.step);

    const make_artifact_dirs = b.addSystemCommand(&.{
        "mkdir",
        "-p",
        "zig-out/share/man/man1",
        "zig-out/share/completions",
    });
    make_artifact_dirs.setCwd(b.path("."));

    const manpage = b.addSystemCommand(&.{
        "usage",
        "generate",
        "manpage",
        "--file",
        "src/cli/usage/sideshowdb.usage.kdl",
        "--out-file",
        "zig-out/share/man/man1/sideshowdb.1",
    });
    manpage.setCwd(b.path("."));
    manpage.step.dependOn(&make_artifact_dirs.step);

    const bash_completion = b.addSystemCommand(&.{
        "usage",
        "generate",
        "completion",
        "bash",
        "sideshowdb",
        "--file",
        "src/cli/usage/sideshowdb.usage.kdl",
    });
    bash_completion.setCwd(b.path("."));
    const bash_completion_file = bash_completion.captureStdOut(.{ .basename = "sideshowdb.bash" });
    const install_bash_completion = b.addInstallFile(
        bash_completion_file,
        "share/completions/sideshowdb.bash",
    );
    install_bash_completion.step.dependOn(&make_artifact_dirs.step);

    const fish_completion = b.addSystemCommand(&.{
        "usage",
        "generate",
        "completion",
        "fish",
        "sideshowdb",
        "--file",
        "src/cli/usage/sideshowdb.usage.kdl",
    });
    fish_completion.setCwd(b.path("."));
    const fish_completion_file = fish_completion.captureStdOut(.{ .basename = "sideshowdb.fish" });
    const install_fish_completion = b.addInstallFile(
        fish_completion_file,
        "share/completions/sideshowdb.fish",
    );
    install_fish_completion.step.dependOn(&make_artifact_dirs.step);

    const zsh_completion = b.addSystemCommand(&.{
        "usage",
        "generate",
        "completion",
        "zsh",
        "sideshowdb",
        "--file",
        "src/cli/usage/sideshowdb.usage.kdl",
    });
    zsh_completion.setCwd(b.path("."));
    const zsh_completion_file = zsh_completion.captureStdOut(.{ .basename = "_sideshowdb" });
    const install_zsh_completion = b.addInstallFile(
        zsh_completion_file,
        "share/completions/_sideshowdb",
    );
    install_zsh_completion.step.dependOn(&make_artifact_dirs.step);

    const cli_artifacts_step = b.step(
        "cli:artifacts",
        "Generate the CLI manpage and shell completion artifacts from the canonical usage spec",
    );
    cli_artifacts_step.dependOn(&manpage.step);
    cli_artifacts_step.dependOn(&install_bash_completion.step);
    cli_artifacts_step.dependOn(&install_fish_completion.step);
    cli_artifacts_step.dependOn(&install_zsh_completion.step);

    return .{
        .runtime_mod = runtime_mod,
        .generated_mod = generated_mod,
        .generate_step = cli_generate_step,
        .sync_docs_step = cli_sync_docs_step,
        .artifacts_step = cli_artifacts_step,
    };
}

fn buildJsInstall(b: *std.Build) *std.Build.Step {
    const step = b.step(
        "js:install",
        "Install Bun workspace dependencies from the repo root",
    );
    const bun = b.addSystemCommand(&.{ "bun", "install" });
    bun.setCwd(b.path("."));
    bun.has_side_effects = true;
    step.dependOn(&bun.step);
    return step;
}

fn buildJsScriptStep(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    script: []const u8,
    js_install_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step(name, description);
    const bun = b.addSystemCommand(&.{ "bun", "run", script });
    bun.setCwd(b.path("."));
    bun.step.dependOn(js_install_step);
    step.dependOn(&bun.step);
    return step;
}

fn buildJsTestStep(
    b: *std.Build,
    js_install_step: *std.Build.Step,
    wasm_step: *std.Build.Step,
    js_bindings_build_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step(
        "js:test",
        "Run the Bun workspace test suite from the repo root",
    );
    const bun = b.addSystemCommand(&.{ "bun", "run", "test:raw" });
    bun.setCwd(b.path("."));
    bun.step.dependOn(js_install_step);
    bun.step.dependOn(wasm_step);
    bun.step.dependOn(js_bindings_build_step);
    step.dependOn(&bun.step);
    return step;
}

fn buildJsAcceptanceStep(
    b: *std.Build,
    js_install_step: *std.Build.Step,
    wasm_step: *std.Build.Step,
    js_bindings_build_step: *std.Build.Step,
    js_acceptance_build_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step(
        "js:acceptance",
        "Run the TypeScript acceptance suite from the repo root",
    );
    const bun = b.addSystemCommand(&.{ "bun", "run", "acceptance:raw" });
    bun.setCwd(b.path("."));
    bun.step.dependOn(js_install_step);
    bun.step.dependOn(wasm_step);
    bun.step.dependOn(js_bindings_build_step);
    bun.step.dependOn(js_acceptance_build_step);
    bun.step.dependOn(b.getInstallStep());
    step.dependOn(&bun.step);
    return step;
}

fn buildJsReleasePrepareStep(
    b: *std.Build,
    js_install_step: *std.Build.Step,
    js_bindings_build_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step(
        "js:release-prepare",
        "Validate and stage publishable TypeScript binding packages",
    );
    const bun = b.addSystemCommand(&.{ "bun", "run", "release:bindings:prepare" });
    bun.setCwd(b.path("."));
    bun.step.dependOn(js_install_step);
    bun.step.dependOn(js_bindings_build_step);
    step.dependOn(&bun.step);
    return step;
}

fn buildNativeCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    cli_usage_runtime_mod: *std.Build.Module,
    cli_generated_usage_mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "sideshowdb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sideshowdb", .module = core_mod },
                .{ .name = "sideshowdb_cli_usage_runtime", .module = cli_usage_runtime_mod },
                .{ .name = "sideshowdb_cli_generated_usage", .module = cli_generated_usage_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the sideshowdb CLI");
    run_step.dependOn(&run_cmd.step);
    return exe;
}

fn buildSiteAssets(
    b: *std.Build,
    wasm_step: *std.Build.Step,
    reference_docs_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step("site:assets", "Stage the site wasm and reference assets");

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
        "site:reference",
        "Generate Zig autodoc into site/static/reference/api",
    );
    step.dependOn(&copy.step);
    return step;
}

fn buildSiteOnly(
    b: *std.Build,
    site_assets_step: *std.Build.Step,
    js_install_step: *std.Build.Step,
    js_bindings_build_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step("site:build", "Build the GitHub Pages site");
    const bun = b.addSystemCommand(&.{ "bun", "run", "build" });
    bun.setCwd(b.path("site"));
    bun.step.dependOn(js_install_step);
    bun.step.dependOn(js_bindings_build_step);
    bun.step.dependOn(site_assets_step);
    step.dependOn(&bun.step);
    return step;
}

fn buildSiteDev(
    b: *std.Build,
    site_assets_step: *std.Build.Step,
    js_install_step: *std.Build.Step,
    js_bindings_build_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step(
        "site:dev",
        "Run the SvelteKit dev server with staged wasm and reference assets",
    );
    const bun = b.addSystemCommand(&.{ "bun", "run", "dev" });
    bun.setCwd(b.path("site"));
    bun.has_side_effects = true;
    bun.stdio = .inherit;
    if (b.args) |args| bun.addArgs(args);
    bun.step.dependOn(js_install_step);
    bun.step.dependOn(js_bindings_build_step);
    bun.step.dependOn(site_assets_step);
    step.dependOn(&bun.step);
    return step;
}

fn buildSitePreview(
    b: *std.Build,
    site_only_step: *std.Build.Step,
    js_install_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step(
        "site:preview",
        "Preview the built site (Vite preview server)",
    );
    const bun = b.addSystemCommand(&.{ "bun", "run", "preview" });
    bun.setCwd(b.path("site"));
    bun.has_side_effects = true;
    bun.stdio = .inherit;
    if (b.args) |args| bun.addArgs(args);
    bun.step.dependOn(js_install_step);
    bun.step.dependOn(site_only_step);
    step.dependOn(&bun.step);
    return step;
}

fn buildWasmClient(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const freestanding_step = buildWasmArtifact(b, optimize, .{
        .os_tag = .freestanding,
        .artifact_name = "sideshowdb",
        .step_name = "wasm",
        .step_description = "Build the wasm32-freestanding browser client",
    });
    _ = buildWasmArtifact(b, optimize, .{
        .os_tag = .wasi,
        .artifact_name = "sideshowdb-wasi",
        .step_name = "wasm-wasi",
        .step_description = "Build the wasm32-wasi (preview1) browser client",
    });
    return freestanding_step;
}

const WasmArtifactOptions = struct {
    os_tag: std.Target.Os.Tag,
    artifact_name: []const u8,
    step_name: []const u8,
    step_description: []const u8,
};

fn buildWasmArtifact(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    opts: WasmArtifactOptions,
) *std.Build.Step {
    const package_version = loadPackageVersion(b);
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = opts.os_tag,
    });

    const wasm_build_options = b.addOptions();
    wasm_build_options.addOption(std.SemanticVersion, "package_version", package_version);

    const wasm_core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });
    wasm_core_mod.addOptions("build_options", wasm_build_options);

    const wasm_exe = b.addExecutable(.{
        .name = opts.artifact_name,
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

    const wasm_step = b.step(opts.step_name, opts.step_description);
    wasm_step.dependOn(&wasm_install.step);
    return wasm_step;
}

fn buildCheckCoreDocs(b: *std.Build) void {
    const run = b.addSystemCommand(&.{
        "bash",
        "scripts/check-core-docs.sh",
        "src/core",
    });
    run.has_side_effects = true;
    const step = b.step(
        "check:core-docs",
        "Fail if any pub declaration in src/core lacks a /// doc-comment",
    );
    step.dependOn(&run.step);
}

fn buildTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    wasm_step: *std.Build.Step,
    cli_exe: *std.Build.Step.Compile,
    cli_usage_runtime_mod: *std.Build.Module,
    cli_generated_usage_mod: *std.Build.Module,
) void {
    const ckdl_dep = b.dependency("ckdl", .{});
    const zwasm_dep = b.dependency("zwasm", .{
        .target = target,
        .optimize = optimize,
    });

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

    const ziggit_ref_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/ziggit_ref_store_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
        },
    });
    const ziggit_ref_tests = b.addTest(.{ .root_module = ziggit_ref_test_mod });
    const run_ziggit_ref_tests = b.addRunArtifact(ziggit_ref_tests);

    const memory_ref_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/memory_ref_store_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
        },
    });
    const memory_ref_tests = b.addTest(.{ .root_module = memory_ref_test_mod });
    const run_memory_ref_tests = b.addRunArtifact(memory_ref_tests);

    const write_through_ref_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/write_through_ref_store_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
        },
    });
    const write_through_ref_tests = b.addTest(.{ .root_module = write_through_ref_test_mod });
    const run_write_through_ref_tests = b.addRunArtifact(write_through_ref_tests);

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

    const cli_test_options = b.addOptions();
    cli_test_options.addOptionPath("cli_exe_path", cli_exe.getEmittedBin());

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
                    .{ .name = "sideshowdb_cli_usage_runtime", .module = cli_usage_runtime_mod },
                    .{ .name = "sideshowdb_cli_generated_usage", .module = cli_generated_usage_mod },
                },
            }) },
        },
    });
    cli_test_mod.addOptions("cli_test_options", cli_test_options);
    const cli_tests = b.addTest(.{ .root_module = cli_test_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    run_cli_tests.step.dependOn(&cli_exe.step);

    const cli_usage_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/usage/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_usage_mod.link_libc = true;
    cli_usage_mod.addIncludePath(ckdl_dep.path("include"));
    cli_usage_mod.addIncludePath(ckdl_dep.path("src"));

    const cli_usage_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/cli_usage_spec_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb_cli_usage", .module = cli_usage_mod },
        },
    });
    const cli_usage_tests = b.addTest(.{ .root_module = cli_usage_test_mod });
    addCkdlToCompile(cli_usage_tests, ckdl_dep);
    const run_cli_usage_tests = b.addRunArtifact(cli_usage_tests);

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

    const http_transport_mod = b.createModule(.{
        .root_source_file = b.path("src/core/storage/http_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    const std_http_transport_mod = b.createModule(.{
        .root_source_file = b.path("src/core/storage/std_http_transport.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_transport", .module = http_transport_mod },
        },
    });
    const http_transport_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/http_transport_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "http_transport", .module = http_transport_mod },
            .{ .name = "std_http_transport", .module = std_http_transport_mod },
        },
    });
    const http_transport_tests = b.addTest(.{ .root_module = http_transport_test_mod });
    const run_http_transport_tests = b.addRunArtifact(http_transport_tests);

    const credential_provider_mod = b.createModule(.{
        .root_source_file = b.path("src/core/storage/credential_provider.zig"),
        .target = target,
        .optimize = optimize,
    });
    const credential_source_explicit_mod = b.createModule(.{
        .root_source_file = b.path("src/core/storage/credential_sources/explicit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "credential_provider", .module = credential_provider_mod },
        },
    });
    credential_provider_mod.addImport("credential_source_explicit", credential_source_explicit_mod);
    const credential_provider_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/credential_provider_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "credential_provider", .module = credential_provider_mod },
            .{ .name = "credential_source_explicit", .module = credential_source_explicit_mod },
        },
    });
    const credential_provider_tests = b.addTest(.{ .root_module = credential_provider_test_mod });
    const run_credential_provider_tests = b.addRunArtifact(credential_provider_tests);

    const wasm_exports_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/wasm_exports_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sideshowdb", .module = core_mod },
            .{ .name = "zwasm", .module = zwasm_dep.module("zwasm") },
        },
    });
    const wasm_exports_tests = b.addTest(.{ .root_module = wasm_exports_test_mod });
    const run_wasm_exports_tests = b.addRunArtifact(wasm_exports_tests);
    run_wasm_exports_tests.step.dependOn(wasm_step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_git_ref_tests.step);
    test_step.dependOn(&run_ziggit_ref_tests.step);
    test_step.dependOn(&run_memory_ref_tests.step);
    test_step.dependOn(&run_write_through_ref_tests.step);
    test_step.dependOn(&run_document_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_cli_usage_tests.step);
    test_step.dependOn(&run_transport_tests.step);
    test_step.dependOn(&run_http_transport_tests.step);
    test_step.dependOn(&run_credential_provider_tests.step);
    test_step.dependOn(&run_wasm_exports_tests.step);
}

fn addCkdlToCompile(
    compile: *std.Build.Step.Compile,
    ckdl_dep: *std.Build.Dependency,
) void {
    compile.root_module.link_libc = true;
    compile.root_module.addIncludePath(ckdl_dep.path("include"));
    compile.root_module.addIncludePath(ckdl_dep.path("src"));
    compile.root_module.addCSourceFiles(.{
        .root = ckdl_dep.path("."),
        .files = &.{
            "src/bigint.c",
            "src/compat.c",
            "src/parser.c",
            "src/str.c",
            "src/tokenizer.c",
            "src/utf8.c",
        },
        .flags = &.{"-std=c11"},
    });
}

fn loadPackageVersion(b: *std.Build) std.SemanticVersion {
    const Manifest = struct {
        version: []const u8,
    };

    const manifest_bytes = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .limited(16 * 1024),
    ) catch |err| std.debug.panic("failed to read build.zig.zon: {t}", .{err});
    const manifest_source = b.allocator.dupeZ(u8, manifest_bytes) catch @panic("out of memory");
    const manifest = std.zon.parse.fromSliceAlloc(Manifest, b.allocator, manifest_source, null, .{ .ignore_unknown_fields = true }) catch |err|
        std.debug.panic("failed to parse build.zig.zon: {t}", .{err});

    return std.SemanticVersion.parse(manifest.version) catch |err|
        std.debug.panic("invalid package version in build.zig.zon: {t}", .{err});
}
