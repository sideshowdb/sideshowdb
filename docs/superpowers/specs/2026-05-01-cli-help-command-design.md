# CLI Help Command Design

## Summary

SideshowDB will expose first-class CLI help through three user-facing paths:

- `sideshowdb help`
- `sideshowdb --help`
- Command-specific help such as `sideshowdb doc --help`, `sideshowdb doc put --help`, and `sideshowdb help doc put`

Help output will be generated from the same canonical CLI usage metadata that already drives parsing, docs generation, manpages, and completions. That keeps runtime help aligned with the command reference instead of introducing a second set of hand-written strings.

Tracked by beads issue `sideshowdb-qns`.

## Goals

- Help requests exit `0` and write human-readable reference text to stdout.
- Invalid help topics fail with exit code `1` and a clear stderr message.
- Help output remains text even when `--json` is present.
- Top-level help summarizes global flags and root commands.
- Command help summarizes the selected command path, flags, subcommands, long help, and examples when metadata exists.
- The implementation uses the existing KDL usage spec and generated Zig module as the source of truth.

## Non-Goals

- Do not add machine-readable JSON help in this slice.
- Do not change command behavior beyond recognizing help requests.
- Do not require the external `usage` binary at runtime.
- Do not redesign generated docs, manpage, or completion output.

## EARS Requirements

- When a caller invokes `sideshowdb help`, the CLI shall print top-level help to stdout and exit `0`.
- When a caller invokes `sideshowdb --help`, the CLI shall print top-level help to stdout and exit `0`.
- When a caller invokes an existing command path followed by `--help`, the CLI shall print help for that command path to stdout and exit `0`.
- When a caller invokes `sideshowdb help` followed by an existing command path, the CLI shall print help for that command path to stdout and exit `0`.
- If a caller invokes `sideshowdb help` followed by an unknown command path, then the CLI shall fail with exit code `1`, write an unknown help topic error to stderr, and not mutate state.
- When a caller includes `--json` on a help request, the CLI shall still emit human-readable help text rather than JSON.
- The CLI help renderer shall derive command names, flags, summaries, long help, and examples from the canonical usage metadata.

## Architecture

The existing `src/cli/usage/sideshowdb.usage.kdl` file remains the canonical declaration of CLI metadata. The generated Zig module will grow enough static metadata for runtime help rendering, including command summaries, long help, flags, subcommands, examples, and the top-level usage line.

The runtime parser will detect help intent before it requires a complete executable command. This matters for commands that require subcommands: `sideshowdb doc --help` succeeds even though `sideshowdb doc` alone remains invalid.

`src/cli/app.zig` will receive either a normal invocation or a help invocation from the generated parser. Help invocations short-circuit before refstore resolution and before any document, event, snapshot, or auth handler can run.

## User-Facing Output

Top-level help will include:

- Product/CLI name and short description.
- Usage line.
- Global flags.
- Root commands.

Command help will include:

- Command path and summary.
- Usage for that path.
- Long help where present.
- Command flags.
- Subcommands when present.
- Examples when present.

The exact spacing can be simple and stable. Tests will assert key content and stream/exit behavior rather than every column of formatting.

## Error Handling

Unknown help topics fail before any mutable command path is evaluated. The error message will name the unknown topic, for example `unknown help topic: nope`.

Malformed regular command invocations keep the existing behavior: exit code `1` with shared usage on stderr.

## Testing

Zig tests will cover:

- `sideshowdb help`
- `sideshowdb --help`
- `sideshowdb doc --help`
- `sideshowdb doc put --help`
- `sideshowdb help doc put`
- `sideshowdb --json help`
- Unknown help topics

Acceptance coverage will add a CLI help feature that maps each user-facing EARS statement to at least one Gherkin scenario. The scenarios will invoke the built CLI binary, assert stdout/stderr/exit behavior, and assert representative help content.

Quality gates for implementation:

- `zig build test`
- `zig build js:acceptance`

## Implementation Notes

Prefer small additions around the generated usage/runtime boundary:

1. Extend the KDL parser/generator only enough to preserve help metadata already present in the spec.
2. Add a generated help invocation shape or equivalent parser result.
3. Add a renderer in the CLI usage layer or app layer that consumes generated metadata.
4. Keep `app.zig` command handlers focused on behavior by short-circuiting help before backend setup.

This avoids hand-written command lists in `app.zig` and keeps future commands automatically visible in help when their KDL metadata is complete.
