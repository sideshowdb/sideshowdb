# CLI Help Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `sideshowdb help`, `sideshowdb --help`, command `--help`, and `sideshowdb help <command path>` to the native CLI.

**Architecture:** Keep `src/cli/usage/sideshowdb.usage.kdl` as the canonical command metadata source. Extend the usage runtime to detect help intent before complete command validation, render help from `usage.SpecView`, and return a generated help invocation that `src/cli/app.zig` can short-circuit before refstore setup.

**Tech Stack:** Zig 0.16, generated CLI usage module, KDL usage spec, TypeScript Cucumber acceptance, beads issue `sideshowdb-qns`.

---

## File Structure

- Create: `docs/development/specs/cli-help-ears.md` for user-facing EARS requirements.
- Create: `acceptance/typescript/features/cli-help.feature` for Cucumber acceptance coverage.
- Modify: `acceptance/typescript/src/steps/cli.steps.ts` to add generic help invocation and stdout assertions.
- Modify: `tests/cli_usage_spec_test.zig` to add red tests for parser/rendering and generated module output.
- Modify: `tests/cli_test.zig` to add red tests for app-level help stdout/stderr/exit behavior.
- Modify: `src/cli/usage/runtime.zig` to add `HelpRequest`, `ParsedCli` support, help detection, topic resolution, and text rendering.
- Modify: `src/cli/usage/root.zig` to mirror runtime types in the hand-written test module and generated module.
- Modify: `src/cli/usage/sideshowdb.usage.kdl` to add the global `--help` flag and `help` command metadata.
- Modify: `src/cli/app.zig` to return help success/failure before mutable command handlers.

## Task 1: EARS And Acceptance Red

**Files:**
- Create: `docs/development/specs/cli-help-ears.md`
- Create: `acceptance/typescript/features/cli-help.feature`
- Modify: `acceptance/typescript/src/steps/cli.steps.ts`

- [ ] **Step 1: Write the EARS doc**

Create `docs/development/specs/cli-help-ears.md`:

```markdown
# CLI Help EARS

Tracked by beads issue `sideshowdb-qns`.

- CLI-HELP-001: When a caller invokes `sideshowdb help`, the CLI shall print top-level help to stdout and exit `0`.
- CLI-HELP-002: When a caller invokes `sideshowdb --help`, the CLI shall print top-level help to stdout and exit `0`.
- CLI-HELP-003: When a caller invokes an existing command path followed by `--help`, the CLI shall print help for that command path to stdout and exit `0`.
- CLI-HELP-004: When a caller invokes `sideshowdb help` followed by an existing command path, the CLI shall print help for that command path to stdout and exit `0`.
- CLI-HELP-005: If a caller invokes `sideshowdb help` followed by an unknown command path, then the CLI shall fail with exit code `1`, write an unknown help topic error to stderr, and not mutate state.
- CLI-HELP-006: When a caller includes `--json` on a help request, the CLI shall still emit human-readable help text rather than JSON.
- CLI-HELP-007: The CLI help renderer shall derive command names, flags, summaries, long help, and examples from the canonical usage metadata.
```

- [ ] **Step 2: Write failing acceptance scenarios**

Create `acceptance/typescript/features/cli-help.feature`:

```gherkin
@cli
Feature: CLI help

  # EARS:
  # - CLI-HELP-001 maps to: Top-level help command prints root help
  # - CLI-HELP-002 maps to: Global --help prints root help
  # - CLI-HELP-003 maps to: Command --help prints command help
  # - CLI-HELP-004 maps to: Help command prints nested command help
  # - CLI-HELP-005 maps to: Unknown help topic fails without stdout
  # - CLI-HELP-006 maps to: JSON flag does not make help JSON
  # - CLI-HELP-007 maps to: Top-level and nested scenarios assert KDL-derived commands, flags, summaries, and examples

  Scenario: Top-level help command prints root help
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg  |
      | help |
    Then the CLI command succeeds
    And the CLI stdout contains "usage: sideshowdb"
    And the CLI stdout contains "doc"
    And the CLI stdout contains "--refstore"
    And the CLI stderr is empty

  Scenario: Global --help prints root help
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg    |
      | --help |
    Then the CLI command succeeds
    And the CLI stdout contains "usage: sideshowdb"
    And the CLI stdout contains "version"
    And the CLI stderr is empty

  Scenario: Command --help prints command help
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg    |
      | doc    |
      | put    |
      | --help |
    Then the CLI command succeeds
    And the CLI stdout contains "Create or replace a document version."
    And the CLI stdout contains "--data-file"
    And the CLI stdout contains "$ sideshowdb --json doc put"
    And the CLI stderr is empty

  Scenario: Help command prints nested command help
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg  |
      | help |
      | doc  |
      | put  |
    Then the CLI command succeeds
    And the CLI stdout contains "Create or replace a document version."
    And the CLI stdout contains "--type"
    And the CLI stderr is empty

  Scenario: Unknown help topic fails without stdout
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg  |
      | help |
      | nope |
    Then the CLI command fails with exit code 1
    And the CLI stdout is empty
    And the CLI stderr contains "unknown help topic: nope"

  Scenario: JSON flag does not make help JSON
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg    |
      | --json |
      | help   |
    Then the CLI command succeeds
    And the CLI stdout contains "usage: sideshowdb"
    And the CLI stdout is not JSON
    And the CLI stderr is empty
```

- [ ] **Step 3: Add failing step definitions**

Append to `acceptance/typescript/src/steps/cli.steps.ts` near the existing CLI step definitions:

```typescript
When("I run the CLI with arguments:", async function (this: AcceptanceWorld, dataTable: DataTable) {
  const args = dataTable.hashes().map((row) => row.arg);
  await executeCli(this, args);
});

Then("the CLI stdout contains {string}", function (this: AcceptanceWorld, text: string) {
  assert.match(this.cliStdout, new RegExp(escapeRegExp(text)));
});

Then("the CLI stdout is empty", function (this: AcceptanceWorld) {
  assert.equal(this.cliStdout, "");
});

Then("the CLI stderr is empty", function (this: AcceptanceWorld) {
  assert.equal(this.cliStderr, "");
});

Then("the CLI stdout is not JSON", function (this: AcceptanceWorld) {
  assert.equal(this.cliJson, null, `expected non-JSON stdout, got:\n${this.cliStdout}`);
});
```

- [ ] **Step 4: Run acceptance to verify RED**

Run: `zig build js:acceptance -- --tags "@cli"` is not supported by the Zig step, so use the project script:

```bash
bash scripts/run-js-acceptance.sh -- --tags "@cli"
```

Expected: fails because `sideshowdb help` and `--help` are not recognized yet.

- [ ] **Step 5: Commit acceptance red**

```bash
git add docs/development/specs/cli-help-ears.md acceptance/typescript/features/cli-help.feature acceptance/typescript/src/steps/cli.steps.ts
git commit -m "test: cover CLI help contract"
```

## Task 2: Zig Unit Red For Help Parsing And App Behavior

**Files:**
- Modify: `tests/cli_usage_spec_test.zig`
- Modify: `tests/cli_test.zig`

- [ ] **Step 1: Add parser and renderer tests**

Append to `tests/cli_usage_spec_test.zig`:

```zig
test "runtime parser resolves top-level help and command help before required command validation" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb [--help] <help|doc <put>>"
        \\flag "--help" global=#true help="Print help information."
        \\cmd "help" help="Print help information." {
        \\  arg "[command...]"
        \\}
        \\cmd "doc" help="Manage documents." subcommand_required=#true {
        \\  cmd "put" help="Create or replace a document version." {
        \\    flag "--type <type>" help="Document type."
        \\    example "$ sideshowdb doc put --type note"
        \\  }
        \\}
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);

    var top_help = try usage.parseArgv(gpa, &spec, &.{ "sideshowdb", "--help" });
    defer top_help.deinit(gpa);
    try std.testing.expect(top_help.command == .help);
    try std.testing.expectEqual(@as(usize, 0), top_help.command.help.topic.len);

    var command_help = try usage.parseArgv(gpa, &spec, &.{ "sideshowdb", "doc", "--help" });
    defer command_help.deinit(gpa);
    try std.testing.expect(command_help.command == .help);
    try std.testing.expectEqualStrings("doc", command_help.command.help.topic[0]);

    var nested_help = try usage.parseArgv(gpa, &spec, &.{ "sideshowdb", "help", "doc", "put" });
    defer nested_help.deinit(gpa);
    try std.testing.expect(nested_help.command == .help);
    try std.testing.expectEqualStrings("doc", nested_help.command.help.topic[0]);
    try std.testing.expectEqualStrings("put", nested_help.command.help.topic[1]);
}

test "help renderer prints root and nested command metadata from the spec" {
    const gpa = std.testing.allocator;
    const source =
        \\bin "sideshowdb"
        \\usage "usage: sideshowdb [--help] <help|doc <put>>"
        \\flag "--help" global=#true help="Print help information."
        \\cmd "help" help="Print help information."
        \\cmd "doc" help="Manage documents." subcommand_required=#true {
        \\  cmd "put" help="Create or replace a document version." {
        \\    long_help "Writes one document version."
        \\    flag "--type <type>" help="Document type."
        \\    example "$ sideshowdb doc put --type note"
        \\  }
        \\}
    ;

    var spec = try usage.parseSpec(gpa, source);
    defer spec.deinit(gpa);
    const view = try spec.view(gpa);
    defer usage.freeSpecViewForTests(gpa, &view);

    const root_help = try usage.renderHelp(gpa, &view, &.{});
    defer gpa.free(root_help);
    try std.testing.expect(std.mem.indexOf(u8, root_help, "usage: sideshowdb") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_help, "doc") != null);

    const put_help = try usage.renderHelp(gpa, &view, &.{ "doc", "put" });
    defer gpa.free(put_help);
    try std.testing.expect(std.mem.indexOf(u8, put_help, "Create or replace a document version.") != null);
    try std.testing.expect(std.mem.indexOf(u8, put_help, "Writes one document version.") != null);
    try std.testing.expect(std.mem.indexOf(u8, put_help, "--type <type>") != null);
    try std.testing.expect(std.mem.indexOf(u8, put_help, "$ sideshowdb doc put --type note") != null);

    try std.testing.expectError(error.UnknownHelpTopic, usage.renderHelp(gpa, &view, &.{"nope"}));
}
```

- [ ] **Step 2: Add app-level help tests**

Append to `tests/cli_test.zig`:

```zig
test "CLI help requests print help to stdout without stderr" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = try cli.run(gpa, io, &env, ".", &.{ "sideshowdb", "help", "doc", "put" }, "");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Create or replace a document version.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "--data-file") != null);
}

test "CLI unknown help topic fails before backend setup" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var env = try Environ.createMap(std.testing.environ, gpa);
    defer env.deinit();

    const result = try cli.run(gpa, io, &env, ".", &.{ "sideshowdb", "help", "nope" }, "");
    defer result.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unknown help topic: nope") != null);
}
```

- [ ] **Step 3: Run Zig tests to verify RED**

```bash
zig build test
```

Expected: fails to compile because `help`, `renderHelp`, and `UnknownHelpTopic` do not exist yet.

- [ ] **Step 4: Commit Zig red tests**

```bash
git add tests/cli_usage_spec_test.zig tests/cli_test.zig
git commit -m "test: cover CLI help parsing"
```

## Task 3: Implement Help Parsing And Rendering

**Files:**
- Modify: `src/cli/usage/runtime.zig`
- Modify: `src/cli/usage/root.zig`

- [ ] **Step 1: Add help runtime types**

In `src/cli/usage/runtime.zig`, add `UnknownHelpTopic` to `ParseError`. Add:

```zig
pub const HelpRequest = struct {
    topic: []const []const u8 = &.{},
};
```

Add `examples: []const []const u8 = &.{}` to `CommandView`.

- [ ] **Step 2: Detect help before full invocation validation**

In `src/cli/usage/runtime.zig`, update `parseArgv` so:

```zig
if (std.mem.eql(u8, token, "--help")) {
    try appendParsedFlag(gpa, &parsed_flags, &.{ .long_name = "--help" }, argv, &i);
    return Generated.buildHelp(gpa, parsed_flags.items, command_path.items);
}
```

At the start of argument scanning, detect `help` as a command with the remainder as the help topic:

```zig
if (std.mem.eql(u8, token, "help")) {
    i += 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.startsWith(u8, argv[i], "-")) return error.InvalidArguments;
        try command_path.append(gpa, try gpa.dupe(u8, argv[i]));
    }
    return Generated.buildHelp(gpa, parsed_flags.items, command_path.items);
}
```

After normal scanning, return help when `usage.hasFlag(parsed_flags.items, "--help")` is true.

- [ ] **Step 3: Add renderHelp**

In `src/cli/usage/runtime.zig`, add:

```zig
pub fn renderHelp(gpa: std.mem.Allocator, spec: *const SpecView, topic: []const []const u8) ParseError![]u8 {
    const command = if (topic.len == 0) null else findCommandPath(spec.root_commands, topic) orelse return error.UnknownHelpTopic;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    if (command) |cmd| {
        try out.writer.print("{s} {s}\n\n", .{ spec.bin, topic[0] });
        if (cmd.help) |help| try out.writer.print("{s}\n\n", .{help});
        if (cmd.long_help) |long_help| try out.writer.print("{s}\n\n", .{long_help});
        try writeUsageForCommand(&out.writer, spec.bin, topic, cmd);
        try writeFlags(&out.writer, cmd.flags);
        try writeCommands(&out.writer, cmd.subcommands);
        try writeExamples(&out.writer, cmd.examples);
    } else {
        if (spec.version) |version| try out.writer.print("{s} {s}\n", .{ spec.bin, version }) else try out.writer.print("{s}\n", .{spec.bin});
        try out.writer.print("{s}\n\n", .{spec.usage});
        try writeFlags(&out.writer, spec.global_flags);
        try writeCommands(&out.writer, spec.root_commands);
    }

    return out.toOwnedSlice();
}
```

Implement helpers `findCommandPath`, `writeUsageForCommand`, `writeFlags`, `writeCommands`, `writeExamples`, and `writeFlagName`. Use simple text:

```text
Flags:
  --type <type>  Document type.

Commands:
  put  Create or replace a document version.

Examples:
  $ sideshowdb doc put --type note
```

- [ ] **Step 4: Mirror types and examples in root/generator**

In `src/cli/usage/root.zig`:

- Add `examples: [][]const u8 = &.{}` to `Command` and deinit it.
- Parse `example` child nodes into `Command.examples`.
- Add `examples` to `cloneCommandView`, `freeCommandViews`, and `renderCommand`.
- Export `pub const HelpRequest = usage_runtime.HelpRequest;`.
- Add `.help: HelpRequest` to the handwritten `Invocation` union and deinit the topic slice.
- Add `buildHelp` returning `ParsedCli` with `.command = .{ .help = .{ .topic = cloned_topic } }`.
- Add `pub fn renderHelp(gpa, spec, topic)` wrapper around `usage_runtime.renderHelp`.
- Add `pub fn freeSpecViewForTests(gpa, spec)` wrapper for tests.
- Update generator output to include `help: usage.HelpRequest` in generated `Invocation`, generated deinit, and generated `buildHelp`.

- [ ] **Step 5: Run Zig tests to verify GREEN**

```bash
zig build test
```

Expected: all Zig tests pass.

- [ ] **Step 6: Commit parser/rendering implementation**

```bash
git add src/cli/usage/runtime.zig src/cli/usage/root.zig
git commit -m "feat(cli): render help from usage metadata"
```

## Task 4: Wire CLI Metadata And App Behavior

**Files:**
- Modify: `src/cli/usage/sideshowdb.usage.kdl`
- Modify: `src/cli/app.zig`

- [ ] **Step 1: Add help metadata to the KDL spec**

In `src/cli/usage/sideshowdb.usage.kdl`:

```kdl
usage "usage: sideshowdb [--help] [--json] [--refstore subprocess|github] [--repo owner/name] [--ref refname] <help|version|doc|event|snapshot|auth|gh>"
flag "--help" global=#true help="Print help information."

cmd "help" help="Print help information." {
  long_help "Print top-level help, or help for a command path such as 'sideshowdb help doc put'."
  example "$ sideshowdb help"
  example "$ sideshowdb help doc put"
}
```

Keep the existing product name spelling: `SideshowDB` in human-facing text.

- [ ] **Step 2: Short-circuit help in app.zig**

In `src/cli/app.zig`, after successful parse and before `const json = parsed.global.json;`, add:

```zig
if (parsed.command == .help) {
    const stdout = generated_usage.renderHelp(gpa, parsed.command.help.topic) catch |err| switch (err) {
        error.UnknownHelpTopic => {
            const topic = try joinHelpTopic(gpa, parsed.command.help.topic);
            defer gpa.free(topic);
            const message = try std.fmt.allocPrint(gpa, "unknown help topic: {s}\n", .{topic});
            defer gpa.free(message);
            return failure(gpa, message);
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => return usageFailure(gpa),
    };
    return success(gpa, stdout);
}
```

Add helper:

```zig
fn joinHelpTopic(gpa: Allocator, topic: []const []const u8) ![]u8 {
    if (topic.len == 0) return try gpa.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (topic, 0..) |segment, index| {
        if (index != 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(segment);
    }
    return out.toOwnedSlice();
}
```

Add `.help` to the later unreachable switch next to `.version`.

- [ ] **Step 3: Run Zig tests**

```bash
zig build test
```

Expected: all Zig tests pass.

- [ ] **Step 4: Commit CLI wiring**

```bash
git add src/cli/usage/sideshowdb.usage.kdl src/cli/app.zig
git commit -m "feat(cli): add help command"
```

## Task 5: Acceptance Green And Final Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run acceptance**

```bash
bash scripts/run-js-acceptance.sh -- --tags "@cli"
```

Expected: all `@cli` scenarios pass, including `cli-help.feature`.

- [ ] **Step 2: Run full required gates**

```bash
zig build test
zig build js:acceptance
```

Expected: both commands exit `0`.

- [ ] **Step 3: Review diff and beads status**

```bash
git status --short --branch
git diff --stat
bd show sideshowdb-qns --json
```

Expected: only intended files changed; issue remains `in_progress` until final commit/push workflow.

- [ ] **Step 4: Close beads issue after verification**

```bash
bd close sideshowdb-qns --reason "Implemented CLI help command, --help handling, EARS, and acceptance coverage." --json
```

- [ ] **Step 5: Commit final docs/acceptance state if needed**

If Task 5 changed files through generated exports or beads export, run:

```bash
git add .beads/issues.jsonl docs/development/specs/cli-help-ears.md acceptance/typescript/features/cli-help.feature acceptance/typescript/src/steps/cli.steps.ts
git commit -m "test(cli): add help acceptance coverage"
```

- [ ] **Step 6: Push session work**

```bash
git pull --rebase
bd dolt push
git push -u origin feature/cli-help-command
git status --short --branch
```

Expected: branch is up to date with `origin/feature/cli-help-command`.

## Self-Review

- Spec coverage: every EARS statement in `docs/superpowers/specs/2026-05-01-cli-help-command-design.md` maps to Task 1 acceptance and Tasks 2-4 Zig implementation.
- Placeholder scan: no deferred implementation placeholders remain in this plan.
- Type consistency: `HelpRequest.topic` is consistently `[]const []const u8`; `Invocation.help` is used by both hand-written and generated usage modules; app-level rendering calls `generated_usage.renderHelp`.
