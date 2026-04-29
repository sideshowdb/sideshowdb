# SideshowDB WASM Boundary Test Depth And Mainline Sync Design

Date: 2026-04-27
Status: Proposed
Issue: `sideshowdb-psy`

## Summary

The document traversal slice now spans the Git-backed store, JSON transport,
CLI, and exported WASM entrypoints. The remaining confidence gap is at the WASM
request/result boundary itself: current tests cover the store and transport
layers well, but do not directly execute the compiled `wasm32-freestanding`
artifact or verify that the exported document operations behave correctly when
instantiated with real host imports.

This follow-up has two goals:

- bring `sideshowdb-psy` up to date with the latest commits from `origin/main`
- add real runtime tests that execute the compiled WASM artifact through
  `zwasm`

## Goals

- Merge the latest `origin/main` into `sideshowdb-psy` before adding new tests.
- Increase confidence in `sideshowdb_document_list`,
  `sideshowdb_document_delete`, and `sideshowdb_document_history`.
- Verify result-buffer replacement semantics across repeated WASM-style calls.
- Keep the exported API contract unchanged.

## Non-Goals

- Rebase or rewrite the published branch history.
- Add a browser-side harness or end-to-end UI automation.
- Change the request or response JSON shapes for document traversal.
- Expand the document feature set beyond test coverage and sync work.

## Product Decisions

### Merge Strategy

`sideshowdb-psy` should merge `origin/main` rather than rebase onto it.

Reasons:

- the branch already exists on `origin`
- merge preserves the reviewable history of the traversal work
- the update goal is compatibility and confidence, not history cleanup

### Runtime Harness

The tests should execute the real `src/wasm/root.zig` artifact through
`zwasm`. The harness should instantiate the compiled module, provide the
required `sideshowdb_host_ref_*` and result/version host imports, and invoke
the exported document functions exactly as a browser host would.

This is preferred over a native seam because the goal is confidence in the
compiled module's import/export contract, not just in the logic that happens to
sit behind the exports.

### Boundary Behaviors To Verify

The new tests should verify:

- `list`, `delete`, and `history` return success status when transport handling
  succeeds
- repeated successful calls replace the previous result payload rather than
  appending to or leaking the prior logical value
- `history` and `list` preserve the JSON emitted by the transport layer
- the compiled WASM module can resolve and use the host traversal imports
- missing-document `get` behavior remains unchanged while new traversal
  operations continue to use success-on-result semantics

## EARS

- When `sideshowdb_document_list` handles a valid request, the WASM boundary
  shall return success and expose the encoded JSON result through the shared
  result buffer.
- When `sideshowdb_document_delete` handles a valid request, the WASM boundary
  shall return success and expose the encoded JSON result through the shared
  result buffer.
- When `sideshowdb_document_history` handles a valid request, the WASM boundary
  shall return success and expose the encoded JSON result through the shared
  result buffer.
- When a second successful WASM document request completes, the WASM boundary
  shall replace the previously exposed result-buffer contents with the newer
  encoded result.
- If a WASM document request fails during transport handling, then the WASM
  boundary shall return failure and shall not claim success for the result.

## Architecture

### Sync First

Before touching implementation, merge `origin/main` into the feature branch and
resolve any conflicts in the traversal files and tests. Verification should run
immediately after the merge to make sure the branch is stable before the new
TDD cycle begins.

### Shared Dispatch Helper

The runtime harness should live in a dedicated Zig test module and use `zwasm`
to:

- load the compiled `sideshowdb.wasm` artifact
- register host imports for document storage operations
- write request bytes into module memory
- invoke exports such as `sideshowdb_document_list`
- read response bytes back through `sideshowdb_result_ptr` /
  `sideshowdb_result_len`

### Runtime Test Strategy

Add a dedicated Zig test module that builds a real temporary Git-backed
`DocumentStore`, adapts it into `zwasm` host functions, and asserts on:

- returned status code
- exact result-buffer contents
- result replacement after sequential calls

This gives coverage of the actual compiled module boundary the browser-facing
host depends on, including memory ABI and import resolution.

## Testing

The work should follow TDD:

1. write the new failing WASM-boundary tests first
2. confirm they fail for the missing runtime harness or missing traversal
   imports
3. implement the smallest host-import/runtime integration needed
4. rerun the focused tests
5. rerun the full `zig build test` suite after the merge and after the final
   implementation

## Risks

- Merging `origin/main` may surface unrelated conflicts in docs or build files.
- Adding a new Zig dependency may introduce build-graph or cache churn.
- The runtime harness must match the module's pointer/length ABI exactly or the
  tests may fail for harness bugs rather than product bugs.
- The current host-backed ref store inside WASM only supports `put`/`get`, so
  traversal exports will need matching host import support before the runtime
  tests can pass.

The design addresses this by keeping the harness focused on the existing
imports/exports, using a real `DocumentStore` behind the host functions, and
leaving the public export surface unchanged.
