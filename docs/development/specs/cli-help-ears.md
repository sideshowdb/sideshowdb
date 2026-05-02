# CLI Help EARS

Tracked by beads issue `sideshowdb-qns`.

- CLI-HELP-001: When a caller invokes `sideshowdb help`, the CLI shall print top-level help to stdout and exit `0`.
- CLI-HELP-002: When a caller invokes `sideshowdb --help`, the CLI shall print top-level help to stdout and exit `0`.
- CLI-HELP-003: When a caller invokes an existing command path followed by `--help`, the CLI shall print help for that command path to stdout and exit `0`.
- CLI-HELP-004: When a caller invokes `sideshowdb help` followed by an existing command path, the CLI shall print help for that command path to stdout and exit `0`.
- CLI-HELP-005: If a caller invokes `sideshowdb help` followed by an unknown command path, then the CLI shall fail with exit code `1`, write an unknown help topic error to stderr, and not mutate state.
- CLI-HELP-006: When a caller includes `--json` on a help request, the CLI shall still emit human-readable help text rather than JSON.
- CLI-HELP-007: The CLI help renderer shall derive command names, flags, summaries, long help, and examples from the canonical usage metadata.
- CLI-HELP-008: When a caller invokes `sideshowdb` with no arguments, the CLI shall print top-level help to stdout and exit `0`.
- CLI-HELP-009: If a caller invokes an unknown root command, then the CLI shall fail with exit code `1`, write an unknown command diagnostic to stderr, and include root usage on stderr.
- CLI-HELP-010: If a caller invokes an unknown root command that closely matches a known root command, then the CLI shall include the closest command suggestion in stderr.
- CLI-HELP-011: When `sideshow version` is invoked while stdin remains open, the CLI shall print version output and exit `0` without waiting for stdin EOF.
- CLI-HELP-012: When `sideshow` is invoked with no subcommand while stdin remains open, the CLI shall print root help and exit `0` without waiting for stdin EOF.
- CLI-HELP-013: When a help invocation runs while stdin remains open, the CLI shall print the requested help and exit `0` without waiting for stdin EOF.
- CLI-HELP-014: When a caller invokes an existing command group without a required subcommand, the CLI shall print that command group's help to stdout and exit `0`.
- CLI-HELP-015: When a caller includes `--json` on a command-group help shortcut, the CLI shall still emit human-readable help text rather than JSON.
- CLI-HELP-016: If a caller invokes an unknown nested command under an existing command group, then the CLI shall fail with exit code `1`, write a scoped unknown-command diagnostic to stderr, and include the nearest valid command group's usage.
