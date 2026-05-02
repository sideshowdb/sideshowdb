# CLI Command Group Help Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make bare SideshowDB command groups print contextual help like GitHub CLI command groups.

**Architecture:** The usage runtime parser will convert valid non-leaf command paths into generated help invocations when the argument list ends there. The app-level unknown-command diagnostic will use the nearest valid command group to render scoped usage for invalid nested commands while preserving root diagnostics and suggestions for root-level typos.

**Tech Stack:** Zig CLI usage parser/generator, Zig CLI app tests, TypeScript Cucumber acceptance tests.

---

### Task 1: Parser Help Shortcut

**Files:**
- Modify: `tests/cli_usage_spec_test.zig`
- Modify: `src/cli/usage/runtime.zig`

- [ ] **Step 1: Write the failing parser test**

  Add this test after `runtime parser resolves version into a typed invocation case`:

  ```zig
  test "runtime parser resolves bare command groups as help topics" {
      const gpa = std.testing.allocator;
      const source =
          \\bin "sideshow"
          \\usage "usage: sideshow <doc <put>|gh <auth <login>>>"
          \\flag "--json" global=#true
          \\cmd "doc" subcommand_required=#true {
          \\  cmd "put"
          \\}
          \\cmd "gh" subcommand_required=#true {
          \\  cmd "auth" subcommand_required=#true {
          \\    cmd "login"
          \\  }
          \\}
      ;

      var spec = try usage.parseSpec(gpa, source);
      defer spec.deinit(gpa);

      var doc_help = try usage.parseArgv(gpa, &spec, &.{ "sideshow", "doc" });
      defer doc_help.deinit(gpa);
      try std.testing.expect(doc_help.command == .help);
      try std.testing.expectEqual(@as(usize, 1), doc_help.command.help.topic.len);
      try std.testing.expectEqualStrings("doc", doc_help.command.help.topic[0]);

      var gh_auth_help = try usage.parseArgv(gpa, &spec, &.{ "sideshow", "--json", "gh", "auth" });
      defer gh_auth_help.deinit(gpa);
      try std.testing.expect(gh_auth_help.global.json);
      try std.testing.expect(gh_auth_help.command == .help);
      try std.testing.expectEqual(@as(usize, 2), gh_auth_help.command.help.topic.len);
      try std.testing.expectEqualStrings("gh", gh_auth_help.command.help.topic[0]);
      try std.testing.expectEqualStrings("auth", gh_auth_help.command.help.topic[1]);
  }
  ```

- [ ] **Step 2: Verify the parser test fails**

  Run:

  ```bash
  zig build test --summary all
  ```

  Expected: FAIL in the new test with `InvalidArguments`.

- [ ] **Step 3: Implement parser shortcut**

  In `src/cli/usage/runtime.zig`, replace:

  ```zig
      const final_command = current_command orelse return error.InvalidArguments;
      if (final_command.subcommand_required and final_command.subcommands.len > 0) return error.InvalidArguments;
  ```

  with:

  ```zig
      const final_command = current_command orelse return error.InvalidArguments;
      if (final_command.subcommand_required and final_command.subcommands.len > 0) {
          return Generated.buildHelp(gpa, parsed_flags.items, command_path.items);
      }
  ```

- [ ] **Step 4: Verify the parser test passes**

  Run:

  ```bash
  zig build test --summary all
  ```

  Expected: PASS.

- [ ] **Step 5: Commit parser shortcut**

  ```bash
  git add tests/cli_usage_spec_test.zig src/cli/usage/runtime.zig
  git commit -m "fix(cli): treat command groups as help topics"
  ```

### Task 2: Scoped Nested Unknown-Command Diagnostics

**Files:**
- Modify: `tests/cli_test.zig`
- Modify: `src/cli/app.zig`

- [ ] **Step 1: Write failing app tests**

  Add tests near the existing CLI usage/unknown-command tests:

  ```zig
  test "CLI command groups print contextual help on stdout" {
      const gpa = std.testing.allocator;
      const io = std.testing.io;

      var env = try Environ.createMap(std.testing.environ, gpa);
      defer env.deinit();

      const doc = try cli.run(gpa, io, &env, ".", &.{ "sideshow", "doc" }, "");
      defer doc.deinit(gpa);
      try std.testing.expectEqual(@as(u8, 0), doc.exit_code);
      try std.testing.expectEqualStrings("", doc.stderr);
      try std.testing.expect(std.mem.indexOf(u8, doc.stdout, "sideshow doc") != null);
      try std.testing.expect(std.mem.indexOf(u8, doc.stdout, "Usage:\n  sideshow doc <put|get|list|delete|history>") != null);

      const gh_auth = try cli.run(gpa, io, &env, ".", &.{ "sideshow", "--json", "gh", "auth" }, "");
      defer gh_auth.deinit(gpa);
      try std.testing.expectEqual(@as(u8, 0), gh_auth.exit_code);
      try std.testing.expectEqualStrings("", gh_auth.stderr);
      try std.testing.expect(std.mem.indexOf(u8, gh_auth.stdout, "sideshow gh auth") != null);
      try std.testing.expect(std.mem.indexOf(u8, gh_auth.stdout, "\"") == null or std.mem.indexOf(u8, gh_auth.stdout, "Usage:") != null);
  }

  test "CLI nested unknown commands show nearest command group usage" {
      const gpa = std.testing.allocator;
      const io = std.testing.io;

      var env = try Environ.createMap(std.testing.environ, gpa);
      defer env.deinit();

      const nested = try cli.run(gpa, io, &env, ".", &.{ "sideshow", "doc", "nope" }, "");
      defer nested.deinit(gpa);
      try std.testing.expectEqual(@as(u8, 1), nested.exit_code);
      try std.testing.expectEqualStrings("", nested.stdout);
      try std.testing.expect(std.mem.startsWith(u8, nested.stderr, "unknown command: nope\n"));
      try std.testing.expect(std.mem.indexOf(u8, nested.stderr, "Usage:\n  sideshow doc <put|get|list|delete|history>") != null);
      try std.testing.expect(std.mem.indexOf(u8, nested.stderr, "usage: sideshow [--help]") == null);
  }
  ```

- [ ] **Step 2: Verify app tests fail**

  Run:

  ```bash
  zig build test --summary all
  ```

  Expected: FAIL because nested unknown commands still render root usage.

- [ ] **Step 3: Implement scoped diagnostics**

  In `src/cli/app.zig`, update the invalid-arguments branch to call a helper that returns scoped diagnostics when possible. Add helpers that walk `generated_usage.spec.root_commands`, collect the valid prefix, and render `generated_usage.renderHelp` for that prefix.

  The stderr format for nested unknown commands should be:

  ```text
  unknown command: nope

  sideshow doc
  ...
  Usage:
    sideshow doc <put|get|list|delete|history>
  ```

- [ ] **Step 4: Verify app tests pass**

  Run:

  ```bash
  zig build test --summary all
  ```

  Expected: PASS.

- [ ] **Step 5: Commit scoped diagnostics**

  ```bash
  git add tests/cli_test.zig src/cli/app.zig
  git commit -m "fix(cli): scope nested unknown-command help"
  ```

### Task 3: EARS and Acceptance Coverage

**Files:**
- Modify: `docs/development/specs/cli-help-ears.md`
- Modify: `acceptance/typescript/features/cli-help.feature`

- [ ] **Step 1: Add EARS statements**

  Add:

  ```markdown
  - CLI-HELP-014: When a caller invokes an existing command group without a required subcommand, the CLI shall print that command group's help to stdout and exit `0`.
  - CLI-HELP-015: When a caller includes `--json` on a command-group help shortcut, the CLI shall still emit human-readable help text rather than JSON.
  - CLI-HELP-016: If a caller invokes an unknown nested command under an existing command group, then the CLI shall fail with exit code `1`, write a scoped unknown-command diagnostic to stderr, and include the nearest valid command group's usage.
  ```

- [ ] **Step 2: Add acceptance scenarios**

  In `acceptance/typescript/features/cli-help.feature`, extend the comment mapping and add scenarios for:

  ```gherkin
  Scenario: Command group invocation prints contextual help
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg |
      | doc |
    Then the CLI command succeeds
    And the CLI stdout contains "sideshow doc"
    And the CLI stdout contains "Usage:"
    And the CLI stdout contains "sideshow doc <put|get|list|delete|history>"
    And the CLI stderr is empty

  Scenario: JSON flag does not make command group help JSON
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg    |
      | --json |
      | doc    |
    Then the CLI command succeeds
    And the CLI stdout contains "sideshow doc"
    And the CLI stdout is not JSON
    And the CLI stderr is empty

  Scenario: Unknown nested command prints scoped command group usage
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg  |
      | doc  |
      | nope |
    Then the CLI command fails with exit code 1
    And the CLI stdout is empty
    And the CLI stderr contains "unknown command: nope"
    And the CLI stderr contains "sideshow doc <put|get|list|delete|history>"
  ```

- [ ] **Step 3: Run acceptance**

  Run:

  ```bash
  zig build js:acceptance
  ```

  Expected: PASS.

- [ ] **Step 4: Commit EARS and acceptance**

  ```bash
  git add docs/development/specs/cli-help-ears.md acceptance/typescript/features/cli-help.feature
  git commit -m "test(cli): cover command group help acceptance"
  ```

### Task 4: Final Verification and Bead Close

**Files:**
- Modify: `.beads/issues.jsonl`

- [ ] **Step 1: Run full verification**

  Run:

  ```bash
  zig build test
  zig build js:acceptance
  ```

  Expected: both PASS.

- [ ] **Step 2: Close bead and export**

  Run:

  ```bash
  bd close sideshowdb-5hy --reason "Command groups now print contextual help and nested unknown commands show scoped usage." --json
  bd export -o .beads/issues.jsonl
  ```

- [ ] **Step 3: Commit bead export**

  ```bash
  git add .beads/issues.jsonl
  git commit -m "chore(beads): close cli group help fix"
  ```
