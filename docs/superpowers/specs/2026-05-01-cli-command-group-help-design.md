# CLI Command Group Help Design

## Goal

Make SideshowDB command groups behave like the GitHub CLI: invoking an existing
non-leaf command path without a required subcommand prints that command group's
help to stdout and exits 0.

Tracked by beads issue `sideshowdb-5hy`.

## Requirements

- When a caller invokes an existing command group without a required subcommand,
  the CLI shall print that command group's help to stdout and exit 0.
- When a caller includes `--json` on a command-group help shortcut, the CLI
  shall still print human-readable help and exit 0.
- If a caller invokes an unknown nested command under an existing command group,
  then the CLI shall fail with exit code 1, write a scoped unknown-command
  diagnostic to stderr, and include the nearest valid command group's usage.
- When a caller uses existing help forms such as `sideshow help doc` or
  `sideshow doc --help`, the CLI shall continue to print command-specific help
  to stdout and exit 0.

## Current Behavior

`sideshow doc`, `sideshow auth`, `sideshow gh`, and `sideshow gh auth` fail with
generic root usage. Users expect these command groups to be discoverable pages,
as in `gh auth`.

Unknown nested commands such as `sideshow doc nope` fail, but the stderr falls
back to root usage. That hides the relevant command group and makes the fix
harder to discover.

## Design

The usage runtime parser should keep walking valid command path segments. If the
argument list ends on a command with required subcommands, the parser should
return a generated `help` invocation whose topic is the command path. The app
already renders help invocations as human-readable stdout with exit 0, so this
keeps behavior consistent with `sideshow help doc` and `sideshow doc --help`.

Invalid nested command diagnostics should use the nearest valid command group as
context. For `sideshow doc nope`, stderr should start with `unknown command:
nope` and include `Usage:\n  sideshow doc <put|get|list|delete|history>` rather
than the root usage string. Root-level unknown commands keep the existing root
diagnostic and suggestion behavior.

`--json` remains ignored for help output. The flag may still be parsed into
global options, but command-group help must remain plain text.

## Testing

Use TDD:

- Unit-test parser behavior for bare non-leaf commands returning `help` topics.
- Unit-test app behavior for command-group help shortcuts and scoped nested
  unknown-command diagnostics.
- Add Cucumber scenarios for `sideshow doc`, `sideshow --json doc`, and
  `sideshow doc nope`.
- Re-run existing help scenarios to prove `help <topic>` and `<topic> --help`
  still work.
