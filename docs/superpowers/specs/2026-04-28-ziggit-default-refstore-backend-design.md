# Ziggit Default RefStore Backend Design

Date: 2026-04-28
Status: Proposed
Issue: `sideshowdb-cnm`

## Summary

SideshowDB will promote the ziggit-backed `RefStore` work from exploration
into the production native storage path. The future-facing native default is a
zero-subprocess Git backend built with ziggit. The existing subprocess-backed
implementation remains available as an explicit compatibility and debugging
fallback.

The public storage contract does not change. Callers still speak through
`RefStore`, document operations still return commit-SHA `VersionId` values,
and CLI/document/WASM-facing transport shapes stay stable.

## Context

The closed `sideshowdb-w1i` exploration proved that a ziggit-backed backend can
reach full `RefStore` parity on non-freestanding targets for `put`, `get`,
`delete`, `list`, and `history`. The prototype also confirmed that existing
document-level and host-backed WASM behavior can continue to pass when the
native backend is present in the build.

The exploration branch will not be merged as-is. It contains copied ziggit
compatibility files, parity-test experiments, and documentation artifacts that
need to be turned into a maintained production shape on current `main`.

## Goals

- Make the native ziggit backend the default `GitRefStore` on non-freestanding
  targets.
- Keep the subprocess-backed backend available as an explicitly named fallback.
- Preserve the existing `RefStore` contract and all document-facing behavior.
- Let CLI users select the backend through command-line flag, environment
  variable, or repo-local config.
- Cover ziggit and subprocess backends with the same parity suite.
- Document backend selection and the subprocess fallback clearly.

## Non-Goals

- Remove the subprocess backend in this change.
- Change document JSON output shapes, CLI document command behavior, or
  `VersionId` semantics.
- Productize a native-Git WASM artifact in this change.
- Add a general-purpose configuration system beyond the storage backend
  selector needed here.

## Architecture

### Storage Types

`RefStore` remains the sole abstraction used by product layers. Concrete
backends expose `refStore()` methods returning the type-erased `RefStore` view.

The native target exports become:

- `ZiggitRefStore`: zero-subprocess Git implementation using ziggit primitives.
- `SubprocessGitRefStore`: existing subprocess-backed implementation, renamed
  from the current internal `GitRefStore` code.
- `GitRefStore`: default alias to `ZiggitRefStore` on non-freestanding targets.

On `wasm32-freestanding`, concrete native Git backends continue to resolve to
unavailable types because the shipped browser artifact still uses the host
import bridge.

### Backend Selection

The CLI resolves the document backend in this precedence order:

1. command-line flag: `--refstore ziggit|subprocess`
2. environment variable: `SIDESHOWDB_REFSTORE=ziggit|subprocess`
3. repo-local config: `.sideshowdb/config.toml`
4. built-in default: `ziggit`

The config file format is intentionally small:

```toml
[storage]
refstore = "ziggit"
```

Unknown backend names fail before document mutation. The failure must make it
clear which selector was invalid and which names are accepted.

### CLI Surface

The global CLI usage becomes:

```text
usage: sideshowdb [--json] [--refstore ziggit|subprocess] <version|doc <put|get|list|delete|history>>
```

`--refstore` is a global option, so it may appear anywhere the current `--json`
global option is accepted. It affects document commands only. `version` must
not require a repository or backend.

### Compatibility

The subprocess backend remains tested and selectable. This is important for:

- diagnosing ziggit-specific failures
- supporting environments where the native backend exposes an unexpected bug
- providing a behavior reference while ziggit becomes the default

Compatibility is not a second product direction. New development will treat
ziggit as the primary native path unless a regression proves otherwise.

### Ziggit Dependency Shape

The implementation will prefer a maintainable dependency integration over a
large copied package subset. If upstream ziggit cannot be consumed directly
with Zig 0.16, the implementation may carry a scoped compatibility subset, but
that subset must live under a clearly named internal path and must be explained
in code comments and docs.

Vendored compatibility code is acceptable only for the exercised surface needed
by `ZiggitRefStore`.

## Behavior Preservation

Both backends must expose the same observable behavior through `RefStore`:

- `put` writes a value and returns the new commit SHA.
- `get` with no version reads from the current configured ref tip.
- `get` with a version reads from that commit SHA.
- absent latest and historical reads return not-found semantics.
- `delete` removes a key through a new reachable commit when the key exists.
- `delete` is idempotent for absent keys.
- `list` returns keys reachable from the current ref tip.
- `history` returns reachable readable versions newest-first.
- literal key handling remains safe for metacharacters.

Backend-specific internal errors may differ, but product-facing behavior must
continue to map through the same document and CLI boundaries.

## EARS

- The SideshowDB native storage layer shall default to a ziggit-backed
  `GitRefStore` on non-freestanding targets.
- The SideshowDB native storage layer shall keep the subprocess-backed Git
  implementation available as an explicit fallback backend.
- When a CLI user passes `--refstore ziggit` or `--refstore subprocess`, the
  SideshowDB CLI shall use the requested backend for document operations.
- When no `--refstore` flag is passed and `SIDESHOWDB_REFSTORE` is set, the
  SideshowDB CLI shall use the backend named by that environment variable.
- When no `--refstore` flag or environment override is provided and
  `.sideshowdb/config.toml` contains `[storage] refstore`, the SideshowDB CLI
  shall use the configured backend.
- The SideshowDB CLI shall resolve backend selection in this precedence order:
  command-line flag, environment variable, config file, built-in default.
- If a backend selector names an unsupported backend, then the SideshowDB CLI
  shall fail with a clear usage or configuration error and shall not mutate
  document refs.
- The ziggit-backed backend shall preserve the existing `RefStore` `put`,
  `get`, `delete`, `list`, and `history` behavior, including commit-SHA
  `VersionId` values.
- The subprocess-backed fallback shall remain covered by the same `RefStore`
  parity suite as the ziggit-backed backend.
- The host-backed WASM path shall preserve current result-buffer and
  version-buffer behavior while native storage defaults change.

## Testing Strategy

### RefStore Parity

Create or keep a shared parity harness that can run against both concrete
backends. The harness covers:

- empty store reads, lists, and history
- `put` and latest `get`
- overwrite and history ordering
- explicit historical reads by commit SHA
- second-key insertion and list membership
- delete and idempotent delete
- invalid key rejection
- literal metacharacter key handling

### CLI Backend Selection

CLI tests cover:

- default backend is ziggit
- `--refstore subprocess` selects the subprocess fallback
- `--refstore` beats `SIDESHOWDB_REFSTORE`
- `SIDESHOWDB_REFSTORE` beats `.sideshowdb/config.toml`
- `.sideshowdb/config.toml` beats the built-in default
- invalid flag, environment, or config backend names fail before mutation

### Regression Coverage

Run existing suites after each implementation slice:

- native Zig tests
- direct backend tests where useful
- document transport tests
- host-backed WASM export tests
- JS/TS check and test suites when public bindings could be affected

## Rollout

The implementation will land as one focused feature branch. It may use the
closed `sideshowdb-w1i` branch as source material, but the production change
must be rebased onto current `main` and shaped around `sideshowdb-cnm`.

The PR description must call out:

- `sideshowdb-cnm` as the implemented bead
- `sideshowdb-w1i` as the source exploration
- the default-backend change
- the subprocess fallback and selection mechanisms
- verification commands for both backend parity and full regression coverage

## Follow-Up Work

Native-Git WASM remains a separate decision. After ziggit is the default native
backend, a follow-up can evaluate whether a second WASM artifact with in-module
Git behavior is worth its binary-size, memory, and browser-storage costs.
