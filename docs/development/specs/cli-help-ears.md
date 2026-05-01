# CLI Help EARS

Tracked by beads issue `sideshowdb-qns`.

- CLI-HELP-001: When a caller invokes `sideshowdb help`, the CLI shall print top-level help to stdout and exit `0`.
- CLI-HELP-002: When a caller invokes `sideshowdb --help`, the CLI shall print top-level help to stdout and exit `0`.
- CLI-HELP-003: When a caller invokes an existing command path followed by `--help`, the CLI shall print help for that command path to stdout and exit `0`.
- CLI-HELP-004: When a caller invokes `sideshowdb help` followed by an existing command path, the CLI shall print help for that command path to stdout and exit `0`.
- CLI-HELP-005: If a caller invokes `sideshowdb help` followed by an unknown command path, then the CLI shall fail with exit code `1`, write an unknown help topic error to stderr, and not mutate state.
- CLI-HELP-006: When a caller includes `--json` on a help request, the CLI shall still emit human-readable help text rather than JSON.
- CLI-HELP-007: The CLI help renderer shall derive command names, flags, summaries, long help, and examples from the canonical usage metadata.
