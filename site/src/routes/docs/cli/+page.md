---
title: CLI Reference
order: 2
---

This page is the command reference for the native `sideshowdb` CLI.
It documents the current MVP command surface, options, examples, and
failure behavior.

## Usage

```bash
sideshowdb [--json] [--refstore ziggit|subprocess] <command>
```

Global options may appear before the command. Document commands run
against the current working directory's Git repository unless the
embedding test harness passes a repository path directly.

## Global Options

| Option | Description |
| ------ | ----------- |
| `--json` | Emit machine-readable JSON for document commands. |
| `--refstore ziggit|subprocess` | Select the native document backend for this invocation. |

Backend selection applies to native document commands. The browser WASM
runtime has its own in-WASM `MemoryRefStore` default and optional
TypeScript host store.

## Backend Selection

Native document commands resolve the refstore in this precedence order:

1. `--refstore ziggit|subprocess`
2. `SIDESHOWDB_REFSTORE=ziggit|subprocess`
3. `.sideshowdb/config.toml`
4. built-in default: `ziggit`

Config file example:

```toml
[storage]
refstore = "ziggit"
```

Invalid backend names fail before document state is mutated.

## Commands

### `sideshowdb version`

Print the product banner and package version.

```bash
sideshowdb version
```

Example output:

```text
sideshowdb — git-backed event-sourced db v0.1.0-alpha.1
```

### `sideshowdb doc put`

Create or replace a document version.

```bash
sideshowdb [--json] doc put --type <type> --id <id> [--namespace <namespace>] [--data-file <path>]
```

Options:

| Option | Required | Description |
| ------ | -------- | ----------- |
| `--type <type>` | No | Document type. If omitted, the JSON payload may provide it. |
| `--id <id>` | No | Document id. If omitted, the JSON payload may provide it. |
| `--namespace <namespace>` | No | Logical namespace. Defaults to `default`. |
| `--data-file <path>` | No | Read payload bytes from a file instead of stdin. |

Examples:

```bash
echo '{"title":"From stdin"}' \
  | sideshowdb --json doc put --type note --id stdin-demo
```

```bash
echo '{"title":"From file"}' > payload.json
sideshowdb --json doc put --type note --id file-demo --data-file payload.json
```

`--data-file wins` when both stdin and `--data-file` are present. A
missing or unreadable `--data-file <path>` returns exit code `1`, writes
a `--data-file` error to stderr, and does not mutate document state.

### `sideshowdb doc get`

Read the current document value, or a specific historical version.

```bash
sideshowdb [--json] doc get --type <type> --id <id> [--namespace <namespace>] [--version <version>]
```

Options:

| Option | Required | Description |
| ------ | -------- | ----------- |
| `--type <type>` | Yes | Document type. |
| `--id <id>` | Yes | Document id. |
| `--namespace <namespace>` | No | Logical namespace. Defaults to `default`. |
| `--version <version>` | No | Version id returned by a prior put or history call. |

Example:

```bash
sideshowdb --json doc get --type note --id file-demo
```

If the document cannot be found, the command exits with code `1` and
prints `document not found` to stderr.

### `sideshowdb doc list`

List documents in the document section.

```bash
sideshowdb [--json] doc list [--namespace <namespace>] [--type <type>] [--limit <count>] [--cursor <cursor>] [--mode summary|detailed]
```

Options:

| Option | Required | Description |
| ------ | -------- | ----------- |
| `--namespace <namespace>` | No | Filter to one namespace. |
| `--type <type>` | No | Filter to one document type. |
| `--limit <count>` | No | Maximum number of items to return. |
| `--cursor <cursor>` | No | Cursor returned by a previous paged response. |
| `--mode summary|detailed` | No | `summary` returns identity/version metadata; `detailed` includes document data. Defaults to `summary`. |

Example:

```bash
sideshowdb --json doc list --type note --mode summary
```

### `sideshowdb doc delete`

Delete the latest reachable document value.

```bash
sideshowdb [--json] doc delete --type <type> --id <id> [--namespace <namespace>]
```

Options:

| Option | Required | Description |
| ------ | -------- | ----------- |
| `--type <type>` | Yes | Document type. |
| `--id <id>` | Yes | Document id. |
| `--namespace <namespace>` | No | Logical namespace. Defaults to `default`. |

Example:

```bash
sideshowdb --json doc delete --type note --id file-demo
```

### `sideshowdb doc history`

List historical document versions newest-first.

```bash
sideshowdb [--json] doc history --type <type> --id <id> [--namespace <namespace>] [--limit <count>] [--cursor <cursor>] [--mode summary|detailed]
```

Options:

| Option | Required | Description |
| ------ | -------- | ----------- |
| `--type <type>` | Yes | Document type. |
| `--id <id>` | Yes | Document id. |
| `--namespace <namespace>` | No | Logical namespace. Defaults to `default`. |
| `--limit <count>` | No | Maximum number of versions to return. |
| `--cursor <cursor>` | No | Cursor returned by a previous paged response. |
| `--mode summary|detailed` | No | `summary` returns identity/version metadata; `detailed` includes historical document data. Defaults to `summary`. |

Example:

```bash
sideshowdb --json doc history --type note --id file-demo --mode detailed
```

## Exit Codes

| Code | Meaning |
| ---- | ------- |
| `0` | Command succeeded. |
| `1` | Usage error, invalid backend, missing data file, missing document, or another command-level failure. |

## Related Docs

- [Getting Started](/docs/getting-started/) for the first end-to-end CLI walkthrough.
- [Architecture](/docs/architecture/) for the Git-backed storage model.
- [Concepts](/docs/concepts/) for document identities, refs, and versions.
