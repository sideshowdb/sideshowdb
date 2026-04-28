# Native RefStore Backend Design

Date: 2026-04-28
Status: Proposed
Issue: `sideshowdb-w1i`

## Summary

Sideshowdb currently uses a subprocess-backed Git implementation for native
`RefStore` operations and a host-import-backed `RefStore` bridge for the
`wasm32-freestanding` module. This design explores a zero-subprocess native
backend that preserves current `RefStore` behavior while evaluating whether the
same backend can also unlock a second WASM packaging mode where Git behavior is
implemented inside the module rather than provided by the host.

The work proceeds in two phases:

1. attempt full `RefStore` parity with `ziggit`
2. if `ziggit` is not viable for full parity, record the findings and repeat
   the exercise with `libgit2`

The chosen direction must remain zero-subprocess. A hybrid backend that keeps
subprocess Git for writes is explicitly out of scope as a final outcome for
this work.

## Goals

- Preserve the existing `RefStore` contract for all callers.
- Prototype a zero-subprocess native Git backend with full `RefStore` parity:
  `put`, `get`, `delete`, `list`, and `history`.
- Preserve current `VersionId` behavior as Git commit SHA strings.
- Preserve existing latest-read and historical-read semantics used by
  `DocumentStore`, CLI transport, and the WASM bridge.
- Evaluate whether the chosen native backend could support an alternate WASM
  artifact where Git behavior is implemented in-module rather than via host
  imports.
- Produce durable findings if `ziggit` is not viable before continuing to the
  `libgit2` exercise.

## Non-Goals

- Replacing the public `RefStore` API with a backend-specific contract.
- Shipping a hybrid subprocess/native backend as the intended solution.
- Productizing a second native-Git WASM artifact unless feasibility is clearly
  demonstrated by the spike.
- Changing document JSON transport shapes or document EARS behavior.
- Removing the existing subprocess backend during the evaluation phase.

## Product Decisions

### Stable Caller Contract

`RefStore` remains the only storage abstraction visible to callers. Native CLI,
`DocumentStore`, transport adapters, and host-backed WASM code continue to
depend on `RefStore` rather than backend-specific repository handles or object
types.

### Viability Ordering

`ziggit` gets the first implementation exercise because it may support a
zero-subprocess, pure-Zig dependency story. If it fails any required parity
gate, sideshowdb will document the findings in-repo and continue with a
`libgit2`-backed exercise using the same parity checklist.

### Zero-Subprocess Requirement

The final recommended backend for this work must not rely on subprocess Git for
any `RefStore` operation. If `ziggit` cannot support writes, tree updates,
commit creation, or ref movement, it is not viable as the chosen backend for
this issue.

### WASM Mode Evaluation

The existing host-backed WASM model remains supported during evaluation. If the
native backend proves WASM-friendly, the spike should also evaluate whether an
additional WASM artifact with native Git behavior in-module is worth pursuing.
This is an evaluation target, not an unconditional implementation promise.

## Architecture

### Native Backend Shape

Add a second concrete `RefStore` implementation alongside the existing
subprocess-backed `GitRefStore`. The new implementation should:

- own backend-specific repository state internally
- expose a `refStore()` method returning the standard type-erased `RefStore`
- preserve commit-SHA `VersionId` values for reads and writes
- hide any backend-specific object IDs, repo handles, caches, or allocators
  from callers

This allows the rest of the system to exercise the new backend without
rewriting product-facing layers first.

### Viability Gates

The native backend is viable only if it can support all of the following:

- resolve the current ref tip for latest reads
- read an exact historical version by commit SHA
- write blobs, trees, and commits needed for `put`
- delete keys by producing an updated tree and commit
- move refs safely enough to preserve current logical semantics
- enumerate keys for `list`
- traverse reachable readable versions newest-first for `history`
- preserve the observable behavior already covered by document-level tests

Failure at any gate should be recorded explicitly, including which operation
failed, whether the failure is architectural or just incomplete implementation,
and why that blocks full parity.

### Behavior Preservation

Observable behavior must remain the same regardless of backend:

- `get(..., null)` reads from the current tip of the backing ref
- `get(..., version)` reads from the supplied historical commit SHA
- `put(...)` returns the newly created commit SHA
- `history(...)` returns reachable readable versions newest-first
- absent latest or historical reads return not-found semantics rather than
  mutating storage

Backend-specific error categories may exist internally, but CLI, document, and
WASM-facing behavior should continue to map back to the current boundaries.

### WASM Packaging Modes

The design intentionally keeps two WASM deployment models in play:

1. host-backed WASM
   - the current model
   - host provides ref operations through imports
   - smaller guest surface and simpler browser integration

2. native-Git WASM
   - only considered if the chosen backend can realistically operate in WASM
   - Git behavior lives inside the module instead of being host-provided
   - may reduce host integration burden at the cost of binary size, memory
     pressure, and repository-access complexity

The spike should gather evidence on whether native-Git WASM is realistic enough
to justify a second artifact. The current host-backed artifact remains the
baseline unless the evidence clearly favors a broader shift.

## EARS

- The `RefStore` native backend shall preserve `put`, `get`, `delete`, `list`,
  and `history` behavior exposed by the existing `RefStore` contract.
- When a caller reads without an explicit version, the native backend shall
  return the value reachable from the current tip of the configured ref.
- When a caller reads with an explicit version, the native backend shall return
  the value reachable from that Git commit SHA or not-found if the key is not
  present there.
- When a caller writes a value, the native backend shall create a new reachable
  Git commit and return that commit SHA as the `VersionId`.
- When a caller deletes an existing key, the native backend shall produce a new
  reachable Git commit reflecting the removal.
- If the candidate backend cannot satisfy any full-parity `RefStore`
  requirement, then sideshowdb shall record the findings in repo documentation
  before beginning the `libgit2` fallback exercise.
- Where a native Git backend can operate inside WASM, sideshowdb shall evaluate
  whether an additional native-Git WASM artifact is preferable to the existing
  host-backed model.
- The host-backed WASM path shall preserve current result-buffer and
  version-buffer behavior while the native backend exercise is in progress.

## Testing Strategy

Testing should proceed in layers so failures are attributable:

### RefStore Parity

Add backend-focused tests for:

- `put/get/delete/list/history`
- latest reads versus explicit-version reads
- commit-SHA `VersionId` values
- key deletion and not-found behavior
- literal handling of keys containing metacharacters
- newest-first history ordering

### Document Regression

Run existing document-level tests against the new backend to prove that the
document EARS remain unchanged after the storage engine swap.

### WASM Boundary Confirmation

Confirm that the host-backed WASM bridge still preserves result-buffer and
version-buffer behavior when the host-side implementation is backed by the new
native `RefStore`.

### Native-Git WASM Feasibility

If the chosen backend appears WASM-compatible, perform only enough work to
establish feasibility and tradeoffs:

- binary size implications
- storage/repository access assumptions
- host integration complexity avoided or added
- memory and runtime constraints

## Deliverables

- a design-backed native `RefStore` spike in an isolated worktree
- supporting EARS for backend parity and fallback behavior
- a written `ziggit` viability report if `ziggit` fails parity
- a follow-on `libgit2` exercise if `ziggit` is not viable
- a recommendation on whether to keep only host-backed WASM or also pursue a
  native-Git WASM artifact

## Risks

- `ziggit` may be read-focused and unable to support full write parity.
- `libgit2` may introduce packaging, build, or allocator complexity.
- Preserving exact commit-SHA semantics across backends may require careful
  translation between internal identifiers and public `VersionId` values.
- A native-Git WASM artifact may be technically possible but operationally too
  heavy in binary size or browser storage complexity.

## Open Decision Boundaries

The spike is expected to answer these questions with evidence:

- Is `ziggit` viable for full `RefStore` parity, including writes and ref
  updates?
- If not, is `libgit2` the practical zero-subprocess fallback?
- Does a native-Git backend make an additional WASM artifact worth supporting,
  or is host-backed WASM still the better default integration story?
