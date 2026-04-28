# Ziggit Viability Report

Date: 2026-04-28

Decision: Viable for full `RefStore` parity on non-freestanding targets

## Scope evaluated

This spike evaluated whether a native backend built from `ziggit` primitives
could replace the current subprocess Git path for `RefStore` behavior without
changing caller-visible semantics. The exercised scope covered `put`, `get`,
`delete`, `list`, and `history`, including latest reads, explicit historical
reads by commit SHA, and commit-SHA `VersionId` behavior.

The downstream checks also confirmed that `DocumentStore`,
document-transport JSON behavior, and the existing host-backed WASM bridge
continue to behave the same when the native backend is present in the build.

## Confirmed capabilities

- Native commits can be written for `put` and `delete`.
- Native ref updates can move `refs/sideshowdb/test` without subprocess Git.
- Latest reads resolve from the current ref tip.
- Historical reads resolve from an explicit commit SHA.
- `history` returns reachable readable versions newest-first.
- Literal key handling is preserved for metacharacters such as `[` and `]`.

## Implementation notes

The working prototype lives in
`src/core/storage/ziggit_ref_store.zig` and is verified by
`tests/ziggit_ref_store_test.zig` plus the shared parity harness in
`tests/ref_store_parity.zig`.

The branch also carries a tracked compatibility subset under
`src/core/storage/ziggit_pkg/`. That subset was copied into the repository so
the spike would not depend on uncommitted edits inside the fetched package
cache. The copied files adapt the exercised `ziggit` surface to the Zig 0.16
toolchain used by this repository.

## Verification

- `zig test tests/ziggit_ref_store_test.zig` passed
- `zig build test --summary all` passed with `35/35` tests green

Those results cover the parity suite and the build-backed downstream tests for
document storage, transport JSON, and the current WASM result/version buffer
behavior.

## WASM host integration status

The existing host-backed WASM path remains intact. The build-backed test suite
continued to pass after introducing `ZiggitRefStore`, which confirms that the
current host import contract still preserves latest-read and version-buffer
behavior for the shipped freestanding artifact.

## Native-Git WASM status

This spike did not produce a second WASM artifact with Git behavior implemented
inside the module. The current `ZiggitRefStore` remains gated to
non-freestanding targets, and the compatibility subset was only proven against
native filesystem-backed execution in tests.

That means native-Git WASM is still an open follow-up question, not a proven
delivery mode. The next evaluation should measure:

- whether the required `ziggit` surface can compile for freestanding WASM
- binary size and memory cost
- browser-side repository storage requirements
- whether the added artifact is preferable to the current host-provided bridge

## Recommendation

Accept the native `ziggit` backend spike as a viable zero-subprocess
`RefStore` implementation for non-freestanding targets.

Treat native-Git WASM as separate follow-up work. Keep the current host-backed
WASM integration as the default path until a dedicated feasibility pass proves
that a second artifact is worth the operational cost.
