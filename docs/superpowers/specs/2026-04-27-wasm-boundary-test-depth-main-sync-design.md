# Sideshowdb WASM Boundary Test Depth And Mainline Sync Design

Date: 2026-04-27
Status: Proposed
Issue: `sideshowdb-psy`

## Summary

The document traversal slice now spans the Git-backed store, JSON transport,
CLI, and exported WASM entrypoints. The remaining confidence gap is at the WASM
request/result boundary itself: current tests cover the store and transport
layers well, but do not directly verify that the exported document operations
set status codes and result buffers consistently.

This follow-up has two goals:

- bring `sideshowdb-psy` up to date with the latest commits from `origin/main`
- add native tests that exercise the same dispatch semantics used by the WASM
  exports without requiring a full freestanding runtime harness

## Goals

- Merge the latest `origin/main` into `sideshowdb-psy` before adding new tests.
- Increase confidence in `sideshowdb_document_list`,
  `sideshowdb_document_delete`, and `sideshowdb_document_history`.
- Verify result-buffer replacement semantics across repeated WASM-style calls.
- Keep the exported API contract unchanged.

## Non-Goals

- Rebase or rewrite the published branch history.
- Add a browser-side or true `wasm32-freestanding` execution harness.
- Change the request or response JSON shapes for document traversal.
- Expand the document feature set beyond test coverage and sync work.

## Product Decisions

### Merge Strategy

`sideshowdb-psy` should merge `origin/main` rather than rebase onto it.

Reasons:

- the branch already exists on `origin`
- merge preserves the reviewable history of the traversal work
- the update goal is compatibility and confidence, not history cleanup

### Test Seam

The exported WASM functions should stay as thin wrappers, but the request
dispatch and result-buffer update behavior should move behind a small helper
surface that native tests can call directly.

The helper should accept:

- the allocator used for result ownership
- a `DocumentStore`
- the request bytes
- a callback or mutable sink that receives the encoded result bytes

This keeps the actual exports unchanged while making the boundary behavior
testable without loading a freestanding module.

### Boundary Behaviors To Verify

The new tests should verify:

- `list`, `delete`, and `history` return success status when transport handling
  succeeds
- repeated successful calls replace the previous result payload rather than
  appending to or leaking the prior logical value
- `history` and `list` preserve the JSON emitted by the transport layer
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

Introduce a small internal WASM support unit, likely adjacent to
`src/wasm/root.zig`, that centralizes:

- invoking the appropriate `document_transport` handler
- mapping transport success/failure to the current `u32` status convention
- updating the result sink used by `sideshowdb_result_ptr` /
  `sideshowdb_result_len`

`root.zig` should continue exporting the public symbols, but each export should
delegate to this helper.

### Native Test Strategy

Add a dedicated Zig test module for the shared helper. The tests should build a
real temporary Git-backed `DocumentStore`, invoke the helper with serialized
requests, and assert on:

- returned status code
- exact result-buffer contents
- result replacement after sequential calls

This gives meaningful coverage at the boundary the browser-facing host actually
depends on, without introducing a heavyweight runtime harness.

## Testing

The work should follow TDD:

1. write the new failing WASM-boundary tests first
2. confirm they fail for the missing helper seam or missing assertions
3. implement the smallest helper/refactor needed
4. rerun the focused tests
5. rerun the full `zig build test` suite after the merge and after the final
   implementation

## Risks

- Merging `origin/main` may surface unrelated conflicts in docs or build files.
- A test seam that is too abstract could stop reflecting the real export
  behavior.
- A test seam that is too coupled to globals could be hard to run natively.

The design addresses this by keeping the helper narrowly scoped to request
dispatch and result-sink updates, with the public export wrappers still in
place.
