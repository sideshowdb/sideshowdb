# SideshowDB TypeScript Bindings And WASM Browser Bridge Design

Date: 2026-04-28
Status: Proposed
Issue: `sideshowdb-3da`

## Summary

The current browser-side WASM wrapper only loads the shipped
`sideshowdb.wasm` artifact far enough to read banner and version metadata.
That is useful for smoke coverage, but it is not the right public interface
for real browser usage, and it does not expose the full document surface
already available in the Zig WASM module.

This slice introduces first-class TypeScript bindings for the browser/WASM
integration and makes the docs site consume those bindings as a public client.
The new structure should support:

- a root Bun workspace spanning all JavaScript and TypeScript projects
- a canonical TypeScript client package for WASM-backed document operations
- an Effect-flavored TypeScript package built on the same core contract
- a site that consumes the public client rather than a private ad hoc wrapper
- continued repo-wide orchestration through `build.zig`

The bindings should expose first-class `put`, `get`, `list`, `history`, and
`delete` operations, preserve explicit request/result memory handling at the
WASM boundary, and improve browser-facing error signaling.

## Goals

- Create a top-level Bun workspace that brings together:
  - `site`
  - `bindings/typescript/sideshowdb-core`
  - `bindings/typescript/sideshowdb-effect`
- Define a public TypeScript binding contract for the existing WASM document
  exports.
- Expose `put`, `get`, `list`, `history`, and `delete` at the TypeScript API
  level.
- Keep the low-level WASM pointer/length contract encapsulated inside the
  bindings rather than in the site.
- Make the docs site and playground consume the public TypeScript binding
  package.
- Preserve `build.zig` as the top-level build and orchestration system for the
  repo.
- Improve runtime error reporting for missing host support, transport failure,
  and not-found reads.

## Non-Goals

- Replacing `build.zig` with Bun scripts, Make, or an external task runner
- Shipping a full projection engine in this slice
- Designing non-TypeScript bindings in this change
- Adding the repo-wide Cucumber acceptance layer in this slice
- Changing the Zig WASM export ABI unless implementation work proves that a
  targeted ABI addition is necessary
- Replacing the site with an SDK demo app or changing the docs site visual
  direction

## Product Decisions

### Package Layout

The repo should treat TypeScript bindings as first-class public packages under a
language-specific root:

- `bindings/typescript/sideshowdb-core`
- `bindings/typescript/sideshowdb-effect`

This keeps the package layout explicit, leaves room for future bindings in
other languages, and prevents the site from becoming the accidental home of the
public client surface.

### Root Bun Workspace

The repo root should gain a Bun workspace that includes exactly these three
projects:

- `site`
- `bindings/typescript/sideshowdb-core`
- `bindings/typescript/sideshowdb-effect`

The workspace owns JavaScript and TypeScript dependency management,
cross-package linking, and package-level test/check/build commands. It does not
replace Zig as the repo’s top-level orchestrator.

### `build.zig` Remains The Orchestrator

`build.zig` stays the source of truth for bringing the repo together. Bun is a
subordinate toolchain used for the JS/TS projects.

That means:

- Zig remains the top-level entrypoint for repo builds
- Zig stages the WASM artifact and drives JS/TS steps through named build steps
- Bun owns package management and workspace-local scripts
- future acceptance testing should also plug into `build.zig`, even if the
  runner is TypeScript-based

This preserves the benefits of the Zig build graph over a plain Make-style
shell orchestration layer.

### Public Package Roles

`bindings/typescript/sideshowdb-core` is the canonical public TypeScript client
package.

Its responsibilities:

- load and instantiate the shipped `sideshowdb.wasm` module
- manage guest request memory and result reads
- provide host-bridge integration for ref operations
- expose typed document operations
- distinguish operational failures in a browser-friendly way

`bindings/typescript/sideshowdb-effect` is a second public package built around
the same underlying contract, but surfaced through the Effect library. It
should not fork the underlying protocol or data model.

### Site Consumption Model

The docs site should consume the public `sideshowdb-core` binding package
instead of owning an app-local WASM helper as the canonical runtime.

A small site-local convenience layer is acceptable for presentation concerns,
but WASM instantiation, request encoding, host bridge semantics, and document
operation APIs belong in the binding package.

### First-Class Document Surface

The public TypeScript bindings should expose all existing document operations:

- `put`
- `get`
- `list`
- `history`
- `delete`

This should mirror the document capabilities already available in the Zig
module and make the bindings suitable for real application use rather than just
metadata inspection.

### Error Model

The TypeScript bindings should distinguish at least these cases:

- runtime load failure
- host bridge unavailable
- WASM export failure
- malformed or unreadable result payload
- not-found document reads

`get` should preserve a distinct not-found outcome instead of collapsing it
into the same shape as operational failure.

### Future Acceptance Testing

Another body of work will add a repo-wide Cucumber acceptance layer in
TypeScript. That future suite should be treated as the formal external
acceptance harness for:

- the CLI
- the WASM module boundary
- the public TypeScript bindings

This slice should therefore define stable public operations and error semantics
that the later acceptance tests can exercise directly without test-only seams.

## User-Facing Contract

### Root Workspace

The repo root should expose a Bun workspace configuration that allows developers
to install and run the JavaScript/TypeScript projects together while still
using `build.zig` as the top-level orchestrator.

### `sideshowdb-core`

The core TypeScript package should expose a browser-oriented client API around
the shipped WASM artifact.

Suggested public concepts:

- `SideshowDBClient`
- `SideshowDBHostBridge`
- typed request/response models for document operations
- typed error/result discriminators

Suggested operation surface:

- `put(request)`
- `get(request)`
- `list(request)`
- `history(request)`
- `delete(request)`

The exact names can follow TypeScript package conventions, but the contract
should clearly separate:

- successful responses
- not-found reads
- operational failures

### `sideshowdb-effect`

The Effect-flavored package should expose equivalent document capabilities while
wrapping construction, invocation, and failures in Effect-native types and
combinators.

It should reuse the same operational model and request/response shapes as the
core package rather than inventing a second protocol.

## Architecture

### Binding Layers

The implementation should be layered like this:

1. Zig WASM module
   - remains the source of truth for exported document operations
2. TypeScript core binding package
   - owns WASM loading, guest memory writes, export calls, host bridge imports,
     and result decoding
3. TypeScript Effect package
   - wraps the core package contract in Effect-native APIs
4. Docs site
   - consumes the public core package

This keeps ABI-sensitive logic close to the binding and prevents the site from
reimplementing WASM details.

### WASM Boundary Ownership

The core package should encapsulate:

- locating the exported WASM functions
- encoding request JSON into guest memory
- invoking document exports
- decoding result buffers from `sideshowdb_result_ptr` /
  `sideshowdb_result_len`
- supplying host imports for ref operations and host result/version buffers

The site should not manipulate raw WebAssembly memory views or raw status codes
directly.

### Host Bridge Shape

The TypeScript bindings should accept an explicit host bridge object that
provides the repository-backed ref behavior required by the imported WASM
`RefStore`.

That bridge should be responsible for:

- `put`
- `get`
- `list`
- `history`
- `delete`
- owned host result buffers
- owned host version buffers

The binding package should translate between this host object and the raw import
functions expected by the module.

### Build Integration

`build.zig` should gain or update named steps that coordinate:

- Bun workspace installation
- package-level tests/checks
- site build
- binding package build/test/check steps
- future acceptance-test execution

The JS/TS workspace should feel like part of the Zig build graph rather than a
parallel toolchain the developer must discover separately.

## EARS

- When the repo’s JavaScript and TypeScript projects are installed, the repo
  shall provide a top-level Bun workspace that includes `site`,
  `bindings/typescript/sideshowdb-core`, and
  `bindings/typescript/sideshowdb-effect`.
- When a browser consumer uses the core TypeScript binding package, the package
  shall expose first-class document `put`, `get`, `list`, `history`, and
  `delete` operations backed by the shipped `sideshowdb.wasm` artifact.
- When the core TypeScript binding invokes a WASM document operation, the
  binding shall manage request-buffer writes and result-buffer reads internally
  rather than requiring application code to manipulate raw guest memory.
- When a WASM-backed `get` request does not resolve a document, the TypeScript
  binding shall report a distinct not-found outcome rather than a generic
  operational failure.
- If the WASM runtime cannot be loaded, then the TypeScript binding shall
  report a runtime-load failure with explicit error signaling.
- If the host bridge required by the WASM module is unavailable or incomplete,
  then the TypeScript binding shall report a host-bridge failure with explicit
  error signaling.
- When the docs site uses browser-side SideshowDB bindings, the site shall
  consume the public `bindings/typescript/sideshowdb-core` package rather than
  treating a site-local WASM wrapper as the canonical client.
- When repo-wide JS/TS build tasks run, the repo shall keep `build.zig` as the
  top-level orchestrator for those tasks.
- Where the Effect binding package is provided, the repo shall expose the same
  document operation capabilities through an Effect-native API without changing
  the underlying request/response contract.
- Where repo-wide acceptance tests are added later, the acceptance layer shall
  be able to exercise the CLI and WASM/module-facing document behaviors through
  stable public contracts defined by this slice.

## Testing

This slice should follow TDD and include tests at these levels:

- core binding unit tests for request encoding, result decoding, and typed error
  mapping
- core binding integration tests with mocked or controlled WASM imports/exports
- site tests proving the playground consumes the binding package rather than an
  app-local metadata-only helper
- build-graph verification that `build.zig` can drive the Bun workspace tasks

The future TypeScript Cucumber suite is explicitly out of scope here, but this
slice should avoid private-only contracts that would block that acceptance layer
later.

## Risks

- The current WASM artifact may need one or more small ABI additions if the
  existing exports are insufficient for safe browser-side request-buffer
  management.
- Public package boundaries can drift if site-specific concerns leak into the
  binding package.
- Workspace introduction can create dependency-management churn if not clearly
  integrated with `build.zig`.
- Supporting both vanilla TypeScript and Effect packages can cause duplicated
  logic if the shared core contract is not kept narrow and explicit.

The design addresses these risks by centralizing ABI-sensitive code in the core
binding package, keeping the Effect package as a wrapper over the same contract,
and treating `build.zig` as the orchestrator rather than an afterthought.
