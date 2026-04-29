# As-built design: `doc put --data-file` (sideshowdb-pb5)

## Problem and goal

The native CLI should support reading the document put payload from a file via `--data-file <path>` so scripted and large-payload workflows do not depend on piping. This document records the **as-built** behavior aligned with Bead **sideshowdb-pb5** (EARS and acceptance criteria).

**EARS mapping (implemented):**

- With `--data-file`, payload bytes come from the referenced path (relative paths resolve from the process current working directory, consistent with `std.Io.Dir.cwd().readFileAlloc`).
- If the file is missing or unreadable, the CLI exits non-zero with a clear stderr message and does not call `DocumentStore.put` (no document mutation).
- When both stdin and `--data-file` carry data, **`--data-file` wins** so behavior is deterministic for scripts that accidentally leave stdin connected.
- With `--json`, successful puts use the same stdout envelope as stdin-based puts.

## CLI surface

- **Subcommand:** `sideshowdb [global options] doc put [put options]`
- **Global options:** `--json`, `--refstore ziggit|subprocess` (unchanged).
- **Put options (all two-token `--flag value` pairs):** `--namespace`, `--type`, `--id`, `--data-file`. When **both** `--type` and `--id` are supplied, `PutRequest.fromOverrides` uses **payload** mode (identity in flags, body is raw JSON). If either is omitted, **envelope** mode applies (identity may live inside the JSON). Bead acceptance examples use payload mode. `--namespace` remains optional in both cases.
- **Flag name:** exactly `--data-file` (not `--data_file`).

The one-line `usage_message` in `src/cli/app.zig` remains a high-level shape and does not enumerate `doc put` flags. Operators should use the repository README and the published [CLI Reference](https://sideshowdb.github.io/sideshowdb/docs/cli/) for the full option matrix and `--data-file` semantics.

## Data flow

1. **`src/cli/main.zig`** reads the entire stdin stream into `stdin_data` before invoking `cli.run`, then passes `stdin_data` into `app.run`.
2. **`src/cli/app.zig` (`doc put`)** parses `global.argv[3..]` with `parsePutArgs`, which recognizes `--data-file` and stores the path on `PutArgs.data_file`.
3. If `data_file` is set, the implementation reads the file into an allocated buffer; on success that buffer is the payload. If unset, `stdin_data` is the payload.
4. Payload bytes are passed to `sideshowdb.document.PutRequest.fromOverrides` and `DocumentStore.put` as today. JSON vs human-readable stdout for puts is unchanged.

## Errors

- **File read failures** (missing path, permission, I/O error): handled in the `readFileAlloc` catch block. The user sees stderr of the form `failed to read --data-file <path>: <error>\n` and exit code `1`. `store.put` is not reached.
- **Payload validation** (invalid JSON, schema rules, etc.): still occurs inside `store.put` after a successful read; those failures are unchanged from stdin-based puts and are not specific to `--data-file`.

## Precedence: stdin vs file

When `--data-file` is present and the file reads successfully, the payload is **always** the file contents; `stdin_data` is ignored for the put. Rationale: predictable behavior when a terminal or wrapper feeds unexpected stdin, and explicit file intent wins over incidental stdin.

When `--data-file` is absent, the payload is `stdin_data` (which may be empty).

## Testing

All tests live in `tests/cli_test.zig` and require a working `git` binary (they skip otherwise).

| Test | What it proves |
|------|----------------|
| `CLI doc put --data-file reads payload from file` | Happy path: `--json doc put --type … --id … --data-file` stores file bytes; `doc get` returns the expected `data` fields. |
| `CLI doc put --data-file fails non-zero on missing file without mutating state` | Exit `1`, stderr mentions `--data-file`, empty stdout; subsequent `doc get` reports document not found. |
| `CLI doc put precedence: --data-file overrides stdin payload` | Same invocation with non-empty `stdin_data` and a file: stored document matches **file** content, not stdin. |

## Documentation

- **README:** Section “Loading `doc put` payloads from a file” documents the flag, example command, precedence, and failure behavior before any state change.
- **Site:** The README quick reference links to the published CLI documentation for the full catalog.

## Scope note

This feature applies to the **native Zig CLI** only. WASM and TypeScript clients use other payload APIs and are out of scope for pb5.
