# Serde Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a serde.zig-backed SideshowDB configuration module and git-like `sideshow config` CLI with local/global scopes.

**Architecture:** Start with a shared `sideshowdb.config` module that owns typed persisted config, local/global file paths, dotted-key mutation, and precedence resolution. Then wire the CLI to that module, replacing the old CLI-only RefStore selector while preserving existing flag/env behavior. Wire-format JSON migration is deliberately deferred to linked follow-up work.

**Tech Stack:** Zig 0.16, `serde.zig` for TOML config serialization, existing KDL usage spec generator, Zig unit/CLI tests, TypeScript Cucumber acceptance.

---

## File Structure

- Create `src/core/config.zig`: persisted config structs, serde TOML load/render, local/global path helpers, dotted-key get/set/unset/list, precedence resolver.
- Modify `src/core/root.zig`: re-export `config`.
- Modify `build.zig.zon`: add `serde.zig` dependency.
- Modify `build.zig`: import serde into `core_mod` and every module that compiles `src/core/root.zig` through `core_mod`.
- Modify `src/cli/app.zig`: route RefStore selection and `config` commands through `sideshowdb.config`.
- Modify `src/cli/usage/sideshow.usage.kdl`: add `config get|set|unset|list` command metadata and scope flags.
- Modify `tests/cli_usage_spec_test.zig`: assert the new command parses.
- Modify `tests/cli_test.zig`: add local/global config CLI tests and precedence regression tests.
- Add `acceptance/typescript/features/cli-config.feature`: user-facing scenarios mapped to EARS comments.
- Modify `acceptance/typescript/src/steps/auth.steps.ts` only if existing generic CLI invocation steps cannot express config scenarios.
- Keep `src/cli/usage/*` out of the serde migration. A minimal positional-argument extension is allowed so `sideshow config get <key>` and `set <key> <value>` work.

## Task 1: Add serde dependency and config module scaffold

**Files:**
- Modify: `build.zig.zon`
- Modify: `build.zig`
- Create: `src/core/config.zig`
- Modify: `src/core/root.zig`

- [x] **Step 1: Write the failing core export test**

Add this to `src/core/root.zig` near the existing `test { ... }` block:

```zig
test {
    _ = config;
    _ = event;
    _ = snapshot;
    _ = document;
    _ = document_transport;
    _ = storage;
}

test "config module exposes built-in defaults" {
    try std.testing.expectEqual(config.RefStoreKind.subprocess, config.defaults.refstore.kind);
    try std.testing.expectEqualStrings("refs/sideshowdb/documents", config.defaults.refstore.ref_name);
}
```

Expected compile failure before implementation: `use of undeclared identifier 'config'`.

- [x] **Step 2: Run the focused failing test**

Run:

```bash
zig build test --summary all
```

Expected: FAIL because `src/core/root.zig` does not export `config`.

- [x] **Step 3: Add the dependency**

Run:

```bash
zig fetch --save https://github.com/orlovevgeny/serde.zig/archive/refs/tags/v0.4.0.tar.gz
```

Expected: `build.zig.zon` gains a `.serde` dependency entry. If a newer compatible tag is available and `zig fetch` suggests a different canonical hash, use the generated entry from `zig fetch --save`; do not hand-edit the hash.

- [x] **Step 4: Wire serde into the core module**

In `build.zig`, after `const package_version = loadPackageVersion(b);`, add:

```zig
const serde_dep = b.dependency("serde", .{
    .target = target,
    .optimize = optimize,
});
const serde_mod = serde_dep.module("serde");
```

After creating `core_mod`, add:

```zig
core_mod.addImport("serde", serde_mod);
```

If `serde.zig` exposes a different module name, inspect the fetched dependency's `build.zig` and use the exported module name from that file.

- [x] **Step 5: Create the config scaffold**

Create `src/core/config.zig`:

```zig
//! Unified SideshowDB configuration model.

const std = @import("std");
const serde = @import("serde");

pub const RefStoreKind = enum {
    subprocess,
    github,
};

pub const CredentialHelper = enum {
    auto,
    env,
    gh,
    git,
};

pub const Config = struct {
    refstore: RefStoreConfig = .{},
    credentials: CredentialConfig = .{},
};

pub const RefStoreConfig = struct {
    kind: ?RefStoreKind = null,
    repo: ?[]const u8 = null,
    ref_name: ?[]const u8 = null,
    api_base: ?[]const u8 = null,
    credential_helper: ?CredentialHelper = null,
};

pub const CredentialConfig = struct {
    helper: ?CredentialHelper = null,
};

pub const ResolvedRefStoreConfig = struct {
    kind: RefStoreKind,
    repo: ?[]const u8,
    ref_name: []const u8,
    api_base: []const u8,
    credential_helper: CredentialHelper,
};

pub const ResolvedConfig = struct {
    refstore: ResolvedRefStoreConfig,
};

pub const defaults: ResolvedConfig = .{
    .refstore = .{
        .kind = .subprocess,
        .repo = null,
        .ref_name = "refs/sideshowdb/documents",
        .api_base = "https://api.github.com",
        .credential_helper = .auto,
    },
};

test "defaults are stable" {
    try std.testing.expectEqual(RefStoreKind.subprocess, defaults.refstore.kind);
    try std.testing.expectEqualStrings("refs/sideshowdb/documents", defaults.refstore.ref_name);
    _ = serde;
}
```

Modify `src/core/root.zig`:

```zig
/// Unified configuration types and serde-backed TOML helpers. See `config.zig`.
pub const config = @import("config.zig");
```

- [x] **Step 6: Run the test to verify green**

Run:

```bash
zig build test --summary all
```

Expected: PASS for the newly added config export/default tests. Other pre-existing unrelated failures should be investigated before proceeding.

- [x] **Step 7: Commit**

```bash
git add build.zig build.zig.zon src/core/config.zig src/core/root.zig
git commit -m "feat(config): add serde-backed config module scaffold"
```

## Task 2: Implement serde TOML load/render and config paths

**Files:**
- Modify: `src/core/config.zig`
- Test: `src/core/config.zig`

- [x] **Step 1: Write failing tests for TOML and paths**

Append to `src/core/config.zig`:

```zig
test "parseToml reads refstore fields" {
    const gpa = std.testing.allocator;
    const source =
        \\[refstore]
        \\kind = "github"
        \\repo = "sideshowdb/sideshowdb"
        \\ref_name = "refs/sideshowdb/test"
        \\api_base = "https://github.example.com/api/v3"
        \\credential_helper = "gh"
        \\
    ;

    var parsed = try parseToml(gpa, source);
    defer parsed.deinit(gpa);

    try std.testing.expectEqual(RefStoreKind.github, parsed.value.refstore.kind.?);
    try std.testing.expectEqualStrings("sideshowdb/sideshowdb", parsed.value.refstore.repo.?);
    try std.testing.expectEqualStrings("refs/sideshowdb/test", parsed.value.refstore.ref_name.?);
    try std.testing.expectEqualStrings("https://github.example.com/api/v3", parsed.value.refstore.api_base.?);
    try std.testing.expectEqual(CredentialHelper.gh, parsed.value.refstore.credential_helper.?);
}

test "renderToml emits parseable config" {
    const gpa = std.testing.allocator;
    const bytes = try renderToml(gpa, .{
        .refstore = .{
            .kind = .github,
            .repo = "owner/repo",
            .ref_name = "refs/sideshowdb/docs",
            .credential_helper = .env,
        },
    });
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "[refstore]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "kind") != null);

    var parsed = try parseToml(gpa, bytes);
    defer parsed.deinit(gpa);
    try std.testing.expectEqual(RefStoreKind.github, parsed.value.refstore.kind.?);
    try std.testing.expectEqual(CredentialHelper.env, parsed.value.refstore.credential_helper.?);
}

test "local and global paths follow project conventions" {
    const gpa = std.testing.allocator;
    const local = try localConfigPath(gpa, "/tmp/repo");
    defer gpa.free(local);
    try std.testing.expectEqualStrings("/tmp/repo/.sideshowdb/config.toml", local);

    var env = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();
    try env.put("SIDESHOWDB_CONFIG_DIR", "/tmp/sideshow-config");
    const global = try globalConfigPath(gpa, &env);
    defer gpa.free(global);
    try std.testing.expectEqualStrings("/tmp/sideshow-config/config.toml", global);
}
```

Expected failure: `parseToml`, `renderToml`, `localConfigPath`, and `globalConfigPath` are undefined.

- [x] **Step 2: Run failing tests**

Run:

```bash
zig build test --summary all
```

Expected: FAIL on undefined config functions.

- [x] **Step 3: Implement owned parsed config and serde helpers**

In `src/core/config.zig`, add:

```zig
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const ParsedConfig = struct {
    value: Config,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ParsedConfig, gpa: Allocator) void {
        _ = gpa;
        self.arena.deinit();
    }
};

pub fn parseToml(gpa: Allocator, bytes: []const u8) !ParsedConfig {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const value = try serde.toml.fromSlice(Config, aa, bytes, .{
        .ignore_unknown_fields = false,
    });
    return .{ .value = value, .arena = arena };
}

pub fn renderToml(gpa: Allocator, config: Config) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try serde.toml.toWriter(config, &out.writer, .{});
    return out.toOwnedSlice();
}

pub fn localConfigPath(gpa: Allocator, repo_path: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ repo_path, ".sideshowdb", "config.toml" });
}

pub fn globalConfigPath(gpa: Allocator, env: *const Environ.Map) ![]u8 {
    if (env.get("SIDESHOWDB_CONFIG_DIR")) |dir| {
        return std.fs.path.join(gpa, &.{ dir, "config.toml" });
    }
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len != 0) return std.fs.path.join(gpa, &.{ xdg, "sideshowdb", "config.toml" });
    }
    if (env.get("HOME")) |home| {
        return std.fs.path.join(gpa, &.{ home, ".config", "sideshowdb", "config.toml" });
    }
    return error.NoHomeDir;
}
```

If the fetched serde API uses different names than `serde.toml.fromSlice` or `serde.toml.toWriter`, adapt only these two functions to the dependency's documented API and keep the public SideshowDB functions unchanged.

- [x] **Step 4: Run tests**

Run:

```bash
zig build test --summary all
```

Expected: PASS for TOML and path tests.

- [x] **Step 5: Commit**

```bash
git add src/core/config.zig
git commit -m "feat(config): parse and render TOML config"
```

## Task 3: Add dotted keys and precedence resolution

**Files:**
- Modify: `src/core/config.zig`
- Modify: `src/cli/refstore_selector.zig` later in Task 5, not here

- [x] **Step 1: Write failing dotted-key tests**

Add to `src/core/config.zig`:

```zig
test "setPath getPath unsetPath operate on supported keys" {
    const gpa = std.testing.allocator;
    var cfg: Config = .{};

    try setPath(gpa, &cfg, "refstore.kind", "github");
    try setPath(gpa, &cfg, "refstore.repo", "owner/repo");
    try setPath(gpa, &cfg, "refstore.ref_name", "refs/sideshowdb/demo");
    try setPath(gpa, &cfg, "refstore.api_base", "https://api.github.com");
    try setPath(gpa, &cfg, "refstore.credential_helper", "git");

    try std.testing.expectEqualStrings("github", (try getPath(gpa, cfg, "refstore.kind")).?);
    try std.testing.expectEqualStrings("owner/repo", (try getPath(gpa, cfg, "refstore.repo")).?);
    try std.testing.expectEqualStrings("refs/sideshowdb/demo", (try getPath(gpa, cfg, "refstore.ref_name")).?);
    try std.testing.expectEqualStrings("https://api.github.com", (try getPath(gpa, cfg, "refstore.api_base")).?);
    try std.testing.expectEqualStrings("git", (try getPath(gpa, cfg, "refstore.credential_helper")).?);

    try unsetPath(&cfg, "refstore.repo");
    try std.testing.expectEqual(@as(?[]const u8, null), try getPath(gpa, cfg, "refstore.repo"));
}

test "setPath rejects unknown keys and invalid values" {
    var cfg: Config = .{};
    try std.testing.expectError(error.UnknownConfigKey, setPath(std.testing.allocator, &cfg, "github.token", "secret"));
    try std.testing.expectError(error.InvalidConfigValue, setPath(std.testing.allocator, &cfg, "refstore.kind", "banana"));
    try std.testing.expectError(error.InvalidConfigValue, setPath(std.testing.allocator, &cfg, "refstore.credential_helper", "keychain"));
}
```

Expected failure: dotted-key functions are undefined.

- [x] **Step 2: Write failing precedence test**

Add to `src/core/config.zig`:

```zig
test "resolveLayers applies flag env local global default precedence" {
    const gpa = std.testing.allocator;
    var env = try std.process.Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const global: Config = .{ .refstore = .{ .kind = .github, .repo = "global/repo" } };
    const local: Config = .{ .refstore = .{ .kind = .subprocess, .repo = "local/repo" } };

    var resolved = try resolveLayers(gpa, .{
        .global = global,
        .local = local,
        .env = &env,
        .cli_refstore = null,
        .cli_repo = null,
        .cli_ref_name = null,
        .cli_api_base = null,
        .cli_credential_helper = null,
    });
    try std.testing.expectEqual(RefStoreKind.subprocess, resolved.refstore.kind);
    try std.testing.expectEqualStrings("local/repo", resolved.refstore.repo.?);

    try env.put("SIDESHOWDB_REFSTORE", "github");
    resolved = try resolveLayers(gpa, .{
        .global = global,
        .local = local,
        .env = &env,
        .cli_refstore = null,
        .cli_repo = null,
        .cli_ref_name = null,
        .cli_api_base = null,
        .cli_credential_helper = null,
    });
    try std.testing.expectEqual(RefStoreKind.github, resolved.refstore.kind);

    resolved = try resolveLayers(gpa, .{
        .global = global,
        .local = local,
        .env = &env,
        .cli_refstore = .subprocess,
        .cli_repo = null,
        .cli_ref_name = null,
        .cli_api_base = null,
        .cli_credential_helper = null,
    });
    try std.testing.expectEqual(RefStoreKind.subprocess, resolved.refstore.kind);
}
```

Expected failure: `resolveLayers` is undefined.

- [x] **Step 3: Run failing tests**

Run:

```bash
zig build test --summary all
```

Expected: FAIL on undefined dotted-key and resolve functions.

- [x] **Step 4: Implement dotted-key functions**

Add:

```zig
pub const ConfigError = error{
    UnknownConfigKey,
    InvalidConfigValue,
} || Allocator.Error;

fn parseRefStoreKind(value: []const u8) ?RefStoreKind {
    if (std.mem.eql(u8, value, "subprocess")) return .subprocess;
    if (std.mem.eql(u8, value, "github")) return .github;
    return null;
}

pub fn parseRefStoreKindPublic(value: []const u8) ?RefStoreKind {
    return parseRefStoreKind(value);
}

fn parseCredentialHelper(value: []const u8) ?CredentialHelper {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "env")) return .env;
    if (std.mem.eql(u8, value, "gh")) return .gh;
    if (std.mem.eql(u8, value, "git")) return .git;
    return null;
}

pub fn parseCredentialHelperPublic(value: []const u8) ?CredentialHelper {
    return parseCredentialHelper(value);
}

fn refStoreKindName(value: RefStoreKind) []const u8 {
    return switch (value) {
        .subprocess => "subprocess",
        .github => "github",
    };
}

fn credentialHelperName(value: CredentialHelper) []const u8 {
    return switch (value) {
        .auto => "auto",
        .env => "env",
        .gh => "gh",
        .git => "git",
    };
}

pub fn setPath(gpa: Allocator, cfg: *Config, key: []const u8, value: []const u8) ConfigError!void {
    if (std.mem.eql(u8, key, "refstore.kind")) {
        cfg.refstore.kind = parseRefStoreKind(value) orelse return error.InvalidConfigValue;
    } else if (std.mem.eql(u8, key, "refstore.repo")) {
        cfg.refstore.repo = try gpa.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "refstore.ref_name")) {
        cfg.refstore.ref_name = try gpa.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "refstore.api_base")) {
        cfg.refstore.api_base = try gpa.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "refstore.credential_helper")) {
        cfg.refstore.credential_helper = parseCredentialHelper(value) orelse return error.InvalidConfigValue;
    } else {
        return error.UnknownConfigKey;
    }
}

pub fn getPath(gpa: Allocator, cfg: Config, key: []const u8) ConfigError!?[]const u8 {
    _ = gpa;
    if (std.mem.eql(u8, key, "refstore.kind")) return if (cfg.refstore.kind) |v| refStoreKindName(v) else null;
    if (std.mem.eql(u8, key, "refstore.repo")) return cfg.refstore.repo;
    if (std.mem.eql(u8, key, "refstore.ref_name")) return cfg.refstore.ref_name;
    if (std.mem.eql(u8, key, "refstore.api_base")) return cfg.refstore.api_base;
    if (std.mem.eql(u8, key, "refstore.credential_helper")) return if (cfg.refstore.credential_helper) |v| credentialHelperName(v) else null;
    return error.UnknownConfigKey;
}

pub fn unsetPath(cfg: *Config, key: []const u8) ConfigError!void {
    if (std.mem.eql(u8, key, "refstore.kind")) cfg.refstore.kind = null else
    if (std.mem.eql(u8, key, "refstore.repo")) cfg.refstore.repo = null else
    if (std.mem.eql(u8, key, "refstore.ref_name")) cfg.refstore.ref_name = null else
    if (std.mem.eql(u8, key, "refstore.api_base")) cfg.refstore.api_base = null else
    if (std.mem.eql(u8, key, "refstore.credential_helper")) cfg.refstore.credential_helper = null else
        return error.UnknownConfigKey;
}
```

Before finalizing this implementation, replace any leaked old string allocations in `setPath` if the config already owns a previous value. The simplest safe implementation for this phase is to use an arena-owned `Config` in CLI mutation paths and avoid repeated `setPath` calls on the same in-memory value outside tests.

- [x] **Step 5: Implement precedence resolution**

Add:

```zig
pub const ResolveInputs = struct {
    global: Config = .{},
    local: Config = .{},
    env: *const Environ.Map,
    cli_refstore: ?RefStoreKind = null,
    cli_repo: ?[]const u8 = null,
    cli_ref_name: ?[]const u8 = null,
    cli_api_base: ?[]const u8 = null,
    cli_credential_helper: ?CredentialHelper = null,
};

pub fn resolveLayers(gpa: Allocator, inputs: ResolveInputs) !ResolvedConfig {
    _ = gpa;
    var result = defaults;

    if (inputs.global.refstore.kind) |v| result.refstore.kind = v;
    if (inputs.global.refstore.repo) |v| result.refstore.repo = v;
    if (inputs.global.refstore.ref_name) |v| result.refstore.ref_name = v;
    if (inputs.global.refstore.api_base) |v| result.refstore.api_base = v;
    if (inputs.global.refstore.credential_helper) |v| result.refstore.credential_helper = v;

    if (inputs.local.refstore.kind) |v| result.refstore.kind = v;
    if (inputs.local.refstore.repo) |v| result.refstore.repo = v;
    if (inputs.local.refstore.ref_name) |v| result.refstore.ref_name = v;
    if (inputs.local.refstore.api_base) |v| result.refstore.api_base = v;
    if (inputs.local.refstore.credential_helper) |v| result.refstore.credential_helper = v;

    if (inputs.env.get("SIDESHOWDB_REFSTORE")) |v| result.refstore.kind = parseRefStoreKind(v) orelse return error.InvalidConfigValue;
    if (inputs.env.get("SIDESHOWDB_REPO")) |v| result.refstore.repo = v;
    if (inputs.env.get("SIDESHOWDB_REF")) |v| result.refstore.ref_name = v;
    if (inputs.env.get("SIDESHOWDB_API_BASE")) |v| result.refstore.api_base = v;
    if (inputs.env.get("SIDESHOWDB_CREDENTIAL_HELPER")) |v| result.refstore.credential_helper = parseCredentialHelper(v) orelse return error.InvalidConfigValue;

    if (inputs.cli_refstore) |v| result.refstore.kind = v;
    if (inputs.cli_repo) |v| result.refstore.repo = v;
    if (inputs.cli_ref_name) |v| result.refstore.ref_name = v;
    if (inputs.cli_api_base) |v| result.refstore.api_base = v;
    if (inputs.cli_credential_helper) |v| result.refstore.credential_helper = v;

    return result;
}
```

- [x] **Step 6: Run tests**

Run:

```bash
zig build test --summary all
```

Expected: PASS for config tests.

- [x] **Step 7: Commit**

```bash
git add src/core/config.zig
git commit -m "feat(config): resolve local global env flag layers"
```

## Task 4: Add positional usage support and config command metadata

**Files:**
- Modify: `src/cli/usage/runtime.zig`
- Modify: `src/cli/usage/root.zig`
- Modify: `src/cli/usage/sideshow.usage.kdl`
- Modify: `tests/cli_usage_spec_test.zig`

- [x] **Step 1: Add failing positional-argument tests**

Add to `tests/cli_usage_spec_test.zig`:

```zig
test "usage runtime passes positional command args to generated invocations" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshow"
        \\usage "usage: sideshow <config <get|set>>"
        \\cmd "config" help="Read and write config." subcommand_required=#true {
        \\  cmd "get" help="Get value." {
        \\    flag "--global" help="Read global config."
        \\    arg "<key>"
        \\  }
        \\  cmd "set" help="Set value." {
        \\    flag "--local" help="Write local config."
        \\    arg "<key>"
        \\    arg "<value>"
        \\  }
        \\}
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    var get = try usage.parseArgv(gpa, &spec, &.{ "sideshow", "config", "get", "--global", "refstore.kind" });
    defer get.deinit(gpa);
    try std.testing.expect(get.command == .config_get);
    try std.testing.expect(get.command.config_get.global);
    try std.testing.expectEqualStrings("refstore.kind", get.command.config_get.key);

    var set = try usage.parseArgv(gpa, &spec, &.{ "sideshow", "config", "set", "--local", "refstore.kind", "github" });
    defer set.deinit(gpa);
    try std.testing.expect(set.command == .config_set);
    try std.testing.expect(set.command.config_set.local);
    try std.testing.expectEqualStrings("refstore.kind", set.command.config_set.key);
    try std.testing.expectEqualStrings("github", set.command.config_set.value);
}
```

Expected failure: the runtime treats `refstore.kind` as another command segment and returns `InvalidArguments`, or generated payload structs do not include arg fields.

- [x] **Step 2: Run failing usage tests**

Run:

```bash
zig build test --summary all
```

Expected: FAIL on positional argument parsing/building.

- [x] **Step 3: Extend runtime parse state with args**

In `src/cli/usage/runtime.zig`, add `parsed_args` beside `parsed_flags` in `parseArgv`:

```zig
var parsed_args = std.ArrayList([]u8).empty;
defer {
    for (parsed_args.items) |arg| gpa.free(arg);
    parsed_args.deinit(gpa);
}
```

When a non-flag token does not match a child command but `current_command` is set, append it and continue:

```zig
if (findCommand(current_children, token)) |matched| {
    try command_path.append(gpa, try gpa.dupe(u8, matched.name));
    current_command = matched;
    current_children = matched.subcommands;
    i += 1;
    continue;
}

if (current_command != null) {
    try parsed_args.append(gpa, try gpa.dupe(u8, token));
    i += 1;
    continue;
}

return error.InvalidArguments;
```

Then call:

```zig
var command = try Generated.buildInvocation(gpa, command_path.items, parsed_flags.items, parsed_args.items);
```

instead of the old three-argument call.

- [x] **Step 4: Extend root/generator invocation signatures**

In `src/cli/usage/root.zig`, change both hand-written and generated `buildInvocation` signatures to include:

```zig
args: []const []const u8,
```

Add hand-written payload structs and union arms near the existing `Doc*Args` declarations so parser unit tests that use `parseSpec` compile:

```zig
pub const ConfigGetArgs = struct {
    local: bool = false,
    global: bool = false,
    key: []const u8,

    pub fn deinit(self: *ConfigGetArgs, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
    }
};

pub const ConfigSetArgs = struct {
    local: bool = false,
    global: bool = false,
    key: []const u8,
    value: []const u8,

    pub fn deinit(self: *ConfigSetArgs, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
        gpa.free(self.value);
    }
};
```

Add `config_get: ConfigGetArgs` and `config_set: ConfigSetArgs` to `Invocation`, with matching deinit cases. Add `ConfigUnsetArgs` and `ConfigListArgs` in the same style when adding the full KDL command metadata.

For existing non-config commands, reject unexpected args:

```zig
if (args.len != 0) return error.InvalidArguments;
```

Add hand-written config cases for parser unit tests that use `parseSpec` directly:

```zig
if (commandPathMatches(command_path, &.{ "config", "get" })) {
    if (args.len != 1) return error.InvalidArguments;
    return .{ .config_get = .{
        .local = usage_runtime.hasFlag(flags, "--local"),
        .global = usage_runtime.hasFlag(flags, "--global"),
        .key = try gpa.dupe(u8, args[0]),
    } };
}

if (commandPathMatches(command_path, &.{ "config", "set" })) {
    if (args.len != 2) return error.InvalidArguments;
    return .{ .config_set = .{
        .local = usage_runtime.hasFlag(flags, "--local"),
        .global = usage_runtime.hasFlag(flags, "--global"),
        .key = try gpa.dupe(u8, args[0]),
        .value = try gpa.dupe(u8, args[1]),
    } };
}
```

Update `renderGeneratedBuildInvocation` so generated modules emit the same four-argument signature. Update generated call sites in `usage_runtime.parseArgv` only once via the runtime change above.

- [x] **Step 5: Generate arg fields in payload structs**

In `renderGeneratedPayloadStructForCommand`, after flag fields, emit one required `[]const u8` field for each `command.args.items`. Normalize `<key>` to `key` and `<value>` to `value` with the same identifier helper style used for flags.

Generated struct shape for config get should become:

```zig
pub const ConfigGetArgs = struct {
    global: bool = false,
    local: bool = false,
    key: []const u8,

    pub fn deinit(self: *ConfigGetArgs, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
        _ = self;
    }
};
```

In `renderGeneratedBuildInvocationCase`, before returning the payload, enforce arity:

```zig
if (args.len != expected_arg_count) return error.InvalidArguments;
```

and populate generated arg fields with duplicated positional values:

```zig
.key = try gpa.dupe(u8, args[0]),
.value = try gpa.dupe(u8, args[1]),
```

Also update deinit generation so arg fields are freed just like required flag-value fields.

- [x] **Step 6: Add config command metadata**

Add this command group to `src/cli/usage/sideshow.usage.kdl` before `cmd "doc"`:

```kdl
cmd "config" help="Read and write SideshowDB configuration." subcommand_required=#true {
  long_help "Read and write local or global SideshowDB configuration values."

  cmd "get" help="Print one resolved or scoped config value." {
    arg "<key>" help="Dotted config key, such as refstore.kind."
    flag "--local" help="Read only .sideshowdb/config.toml."
    flag "--global" help="Read only the user config file."
    example "$ sideshow config get refstore.kind"
  }

  cmd "set" help="Set one config value." {
    arg "<key>" help="Dotted config key, such as refstore.kind."
    arg "<value>" help="Value to write."
    flag "--local" help="Write .sideshowdb/config.toml."
    flag "--global" help="Write the user config file."
    example "$ sideshow config set --local refstore.kind github"
  }

  cmd "unset" help="Remove one config value." {
    arg "<key>" help="Dotted config key, such as refstore.kind."
    flag "--local" help="Remove from .sideshowdb/config.toml."
    flag "--global" help="Remove from the user config file."
    example "$ sideshow config unset --global refstore.kind"
  }

  cmd "list" help="List config values." {
    flag "--local" help="List only .sideshowdb/config.toml."
    flag "--global" help="List only the user config file."
    example "$ sideshow config list"
  }
}
```

Also update the root usage line to include `config`:

```kdl
usage "usage: sideshow [--help] [--json] [--refstore subprocess|github] [--repo owner/name] [--ref refname] <help|version|config|doc|event|snapshot|auth|gh>"
```

- [x] **Step 7: Run usage tests**

Run:

```bash
zig build test --summary all
```

Expected: PASS for usage tests and generated CLI compile.

- [x] **Step 8: Commit**

```bash
git add src/cli/usage/runtime.zig src/cli/usage/root.zig src/cli/usage/sideshow.usage.kdl tests/cli_usage_spec_test.zig
git commit -m "feat(cli): add config command usage"
```

## Task 5: Implement config CLI commands and RefStore resolution

**Files:**
- Modify: `src/cli/app.zig`
- Modify: `src/core/config.zig`
- Modify: `tests/cli_test.zig`
- Eventually remove or stop using: `src/cli/refstore_selector.zig`

- [x] **Step 1: Write failing CLI tests for local/global commands**

Add to `tests/cli_test.zig`:

```zig
test "CLI config set get list unset support local scope" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(repo_path);

    const set = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "set", "--local", "refstore.kind", "github" }, "");
    defer set.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), set.exit_code);
    try std.testing.expectEqualStrings("", set.stderr);

    const get = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "get", "--local", "refstore.kind" }, "");
    defer get.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), get.exit_code);
    try std.testing.expectEqualStrings("github\n", get.stdout);

    const list = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "list", "--local" }, "");
    defer list.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), list.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, list.stdout, "refstore.kind=github") != null);

    const unset = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "unset", "--local", "refstore.kind" }, "");
    defer unset.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), unset.exit_code);

    const get_after = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "get", "--local", "refstore.kind" }, "");
    defer get_after.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), get_after.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, get_after.stderr, "not set") != null);
}

test "CLI config global scope uses SIDESHOWDB_CONFIG_DIR" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "config" });
    defer gpa.free(config_dir);
    try env.put("SIDESHOWDB_CONFIG_DIR", config_dir);

    const set = try cli.run(gpa, io, &env, ".", &.{ "sideshow", "config", "set", "--global", "refstore.repo", "owner/repo" }, "");
    defer set.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), set.exit_code);

    const get = try cli.run(gpa, io, &env, ".", &.{ "sideshow", "config", "get", "--global", "refstore.repo" }, "");
    defer get.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), get.exit_code);
    try std.testing.expectEqualStrings("owner/repo\n", get.stdout);
}
```

Expected failure: config command cases are unimplemented in `src/cli/app.zig`.

- [x] **Step 2: Write failing precedence regression test**

Add to `tests/cli_test.zig`:

```zig
test "CLI refstore flag and env override local and global config" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const repo_path = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "repo" });
    defer gpa.free(repo_path);
    const config_dir = try std.fs.path.join(gpa, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "global" });
    defer gpa.free(config_dir);
    try env.put("SIDESHOWDB_CONFIG_DIR", config_dir);

    _ = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "set", "--global", "refstore.kind", "github" }, "");
    _ = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "config", "set", "--local", "refstore.kind", "subprocess" }, "");

    try env.put("SIDESHOWDB_REFSTORE", "github");
    const env_result = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "doc", "list" }, "");
    defer env_result.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 1), env_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, env_result.stderr, "--repo owner/name") != null);

    const flag_result = try cli.run(gpa, io, &env, repo_path, &.{ "sideshow", "--refstore", "subprocess", "doc", "list" }, "");
    defer flag_result.deinit(gpa);
    try std.testing.expect(flag_result.exit_code != 1 or std.mem.indexOf(u8, flag_result.stderr, "--repo owner/name") == null);
}
```

Expected failure until app resolution moves to config.

- [x] **Step 3: Run failing CLI tests**

Run:

```bash
zig build test --summary all
```

Expected: FAIL on unimplemented config command handling.

- [x] **Step 4: Add file load/save helpers**

In `src/core/config.zig`, add:

```zig
pub fn loadFile(gpa: Allocator, io: std.Io, path: []const u8) !ParsedConfig {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .value = .{}, .arena = std.heap.ArenaAllocator.init(gpa) },
        else => |e| return e,
    };
    defer gpa.free(bytes);
    return parseToml(gpa, bytes);
}

pub fn loadLocal(gpa: Allocator, io: std.Io, repo_path: []const u8) !ParsedConfig {
    const path = try localConfigPath(gpa, repo_path);
    defer gpa.free(path);
    return loadFile(gpa, io, path);
}

pub fn loadGlobal(gpa: Allocator, io: std.Io, env: *const Environ.Map) !ParsedConfig {
    const path = try globalConfigPath(gpa, env);
    defer gpa.free(path);
    return loadFile(gpa, io, path);
}

pub fn saveFile(gpa: Allocator, io: std.Io, path: []const u8, cfg: Config) !void {
    const bytes = try renderToml(gpa, cfg);
    defer gpa.free(bytes);
    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
    _ = io;
}
```

Adjust `std.Io.Dir` vs `std.fs.cwd()` calls to match Zig 0.16 APIs already used in the repo. Keep the public signatures stable for CLI use.

Add a small flattened row type used by `config list`:

```zig
pub const ConfigRow = struct {
    key: []const u8,
    value: []const u8,
    source: []const u8 = "file",
};

pub fn listFlattened(gpa: Allocator, cfg: Config) ![]ConfigRow {
    var rows: std.ArrayList(ConfigRow) = .empty;
    errdefer rows.deinit(gpa);
    if (cfg.refstore.kind) |value| try rows.append(gpa, .{ .key = "refstore.kind", .value = refStoreKindName(value) });
    if (cfg.refstore.repo) |value| try rows.append(gpa, .{ .key = "refstore.repo", .value = value });
    if (cfg.refstore.ref_name) |value| try rows.append(gpa, .{ .key = "refstore.ref_name", .value = value });
    if (cfg.refstore.api_base) |value| try rows.append(gpa, .{ .key = "refstore.api_base", .value = value });
    if (cfg.refstore.credential_helper) |value| try rows.append(gpa, .{ .key = "refstore.credential_helper", .value = credentialHelperName(value) });
    return rows.toOwnedSlice(gpa);
}
```

- [x] **Step 5: Implement app command cases**

In `src/cli/app.zig`, handle config commands immediately after help/version/auth command handling and before RefStore initialization:

```zig
        .config_get => |args| return runConfigGet(gpa, io, env, repo_path, json, args),
        .config_set => |args| return runConfigSet(gpa, io, env, repo_path, json, args),
        .config_unset => |args| return runConfigUnset(gpa, io, env, repo_path, json, args),
        .config_list => |args| return runConfigList(gpa, io, env, repo_path, json, args),
```

Add helpers:

```zig
fn rejectConflictingScopes(gpa: Allocator, local: bool, global: bool) !?Result {
    if (local and global) return try failure(gpa, "choose only one of --local or --global\n");
    return null;
}

fn configScopePath(gpa: Allocator, env: *const Environ.Map, repo_path: []const u8, local: bool, global: bool) ![]u8 {
    if (global) return sideshowdb.config.globalConfigPath(gpa, env);
    if (local) return sideshowdb.config.localConfigPath(gpa, repo_path);
    return sideshowdb.config.localConfigPath(gpa, repo_path);
}
```

Implement `runConfigSet`, `runConfigUnset`, `runConfigGet`, and `runConfigList` by loading the chosen file, applying `setPath`/`unsetPath`/`getPath`/`listFlattened`, saving for writes, and formatting plain or JSON output. Map `UnknownConfigKey` to `unknown config key: <key>\n`, `InvalidConfigValue` to `invalid value for config key: <key>\n`, and missing get to `config key not set: <key>\n`.

- [x] **Step 6: Replace RefStore selector usage**

In `src/cli/app.zig`, replace:

```zig
const refstore = if (parsed.global.refstore) |value|
    refstore_selector.RefStoreBackend.parse(value) orelse return failure(gpa, refstore_invalid_message)
else
    null;
const selection = refstore_selector.resolve(gpa, repo_path, env, refstore) catch |err| switch (err) {
```

with config resolution:

```zig
const cli_refstore = if (parsed.global.refstore) |value|
    sideshowdb.config.parseRefStoreKindPublic(value) orelse return failure(gpa, refstore_invalid_message)
else
    null;
var global_cfg = try sideshowdb.config.loadGlobal(gpa, io, env);
defer global_cfg.deinit(gpa);
var local_cfg = try sideshowdb.config.loadLocal(gpa, io, repo_path);
defer local_cfg.deinit(gpa);
const resolved = sideshowdb.config.resolveLayers(gpa, .{
    .global = global_cfg.value,
    .local = local_cfg.value,
    .env = env,
    .cli_refstore = cli_refstore,
    .cli_repo = parsed.global.repo,
    .cli_ref_name = parsed.global.ref,
    .cli_api_base = parsed.global.api_base,
    .cli_credential_helper = if (parsed.global.credential_helper) |value|
        sideshowdb.config.parseCredentialHelperPublic(value) orelse return failure(gpa, refstore_invalid_message)
    else
        null,
}) catch |err| switch (err) {
    error.InvalidConfigValue => return failure(gpa, refstore_invalid_message),
    else => |e| return e,
};
```

Then switch on `resolved.refstore.kind` instead of `selection.backend`, and pass `resolved.refstore.repo`, `resolved.refstore.ref_name`, `resolved.refstore.api_base`, and `resolved.refstore.credential_helper` to GitHub initialization.

Keep `src/cli/refstore_selector.zig` until all references are gone; remove it in a later cleanup only if no test imports it.

- [x] **Step 7: Run tests**

Run:

```bash
zig build test --summary all
```

Expected: PASS for config CLI and refstore precedence tests.

- [x] **Step 8: Commit**

```bash
git add src/core/config.zig src/cli/app.zig tests/cli_test.zig
git commit -m "feat(cli): support local global config commands"
```

## Task 6: Add acceptance coverage and follow-up beads

**Files:**
- Add: `acceptance/typescript/features/cli-config.feature`
- Modify: `acceptance/typescript/src/steps/auth.steps.ts` only if needed
- Modify: `docs/superpowers/specs/2026-05-02-serde-config-design.md` only if implementation reveals a necessary correction

- [x] **Step 1: Add failing Cucumber feature**

Create `acceptance/typescript/features/cli-config.feature`:

```gherkin
@cli @config
Feature: CLI config commands

  # EARS:
  # - When a caller runs `sideshow config set --local <key> <value>`, the CLI shall update `.sideshowdb/config.toml`, creating parent directories as needed. (CONF-001)
  # - When a caller runs `sideshow config set --global <key> <value>`, the CLI shall update the user config file, creating parent directories as needed. (CONF-002)
  # - When a caller runs `sideshow config get <key>` without a scope, the CLI shall print the resolved value. (CONF-003)
  # - When `SIDESHOWDB_REFSTORE` is set, the CLI shall prefer it over local and global config. (CONF-004)
  # - If a caller supplies both `--local` and `--global`, then the CLI shall fail with a usage error and not write a config file. (CONF-005)

  Scenario: local config set and get round trip
    When I invoke "config set --local refstore.kind github"
    Then the auth CLI command succeeds
    When I invoke "config get --local refstore.kind"
    Then the auth CLI command succeeds
    And the auth CLI stdout equals "github\n"

  Scenario: global config uses the configured user config directory
    Given a fresh sideshow auth config directory
    When I invoke "config set --global refstore.repo sideshowdb/sideshowdb"
    Then the auth CLI command succeeds
    When I invoke "config get --global refstore.repo"
    Then the auth CLI command succeeds
    And the auth CLI stdout equals "sideshowdb/sideshowdb\n"

  Scenario: environment refstore overrides config
    Given a fresh sideshow auth config directory
    When I invoke "config set --global refstore.kind github"
    Then the auth CLI command succeeds
    When I invoke "--refstore subprocess config get refstore.kind"
    Then the auth CLI command succeeds
    And the auth CLI stdout equals "subprocess\n"

  Scenario: conflicting scopes fail
    When I invoke "config set --local --global refstore.kind github"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "choose only one"
```

Expected failure if existing steps do not set a stable repo cwd or if config commands are not wired.

- [x] **Step 2: Run acceptance**

Run:

```bash
zig build js:acceptance
```

Expected: FAIL until steps and CLI behavior are complete.

- [x] **Step 3: Adjust steps only if needed**

If `auth.steps.ts` cannot invoke config commands in a temp repo, add a config-specific Given step in a new `acceptance/typescript/src/steps/config.steps.ts`:

```ts
import { Given } from "@cucumber/cucumber";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AcceptanceWorld } from "../support/world";

Given("a fresh sideshow config repository", async function (this: AcceptanceWorld) {
  this.authConfigDir = await mkdtemp(join(tmpdir(), "sideshowdb-config-"));
});
```

Prefer reusing existing invocation steps when possible.

- [x] **Step 4: Create follow-up beads for wire formats**

Run:

```bash
bd create --title="Migrate document/event/snapshot Zig wire JSON to serde.zig" --description="Follow-up to sideshowdb-bum. After the config module lands, replace hand-written std.json parsing/rendering for document_transport.zig, event.zig, snapshot.zig, CLI event/snapshot output, and related tests with typed serde.zig helpers while preserving user-visible JSON contracts." --type=task --priority=2 --deps discovered-from:sideshowdb-bum --json
bd create --title="Migrate GitHub API and WASM Zig JSON helpers to serde.zig" --description="Follow-up to sideshowdb-bum. Replace std.json helpers in src/core/storage/github_api/json.zig and src/wasm/imported_ref_store.zig with typed serde.zig parsing/rendering, preserving GitHub API request/response contracts and WASM host bridge behavior." --type=task --priority=2 --deps discovered-from:sideshowdb-bum --json
```

- [x] **Step 5: Run quality gates**

Run:

```bash
zig build test
zig build js:acceptance
```

Expected: both PASS.

- [x] **Step 6: Commit**

```bash
git add acceptance/typescript/features/cli-config.feature acceptance/typescript/src/steps/config.steps.ts .beads/issues.jsonl
git commit -m "test(cli): cover config command acceptance"
```

If `.beads/issues.jsonl` is not present in this embedded-mode worktree, commit only files that exist and leave bead persistence to embedded beads.

## Final Verification

- [ ] Run:

```bash
git status --short --branch
zig build test
zig build js:acceptance
bd show sideshowdb-bum --json
```

- [ ] Update `sideshowdb-bum` with implementation notes and close it only after tests pass:

```bash
bd close sideshowdb-bum --reason "Implemented serde-backed config module and local/global config CLI with acceptance coverage" --json
```

- [ ] Because this worktree uses embedded beads/Dolt, do not require a separate `bd dolt push` remote. Follow the repository's current handoff/merge flow for the detached worktree.
