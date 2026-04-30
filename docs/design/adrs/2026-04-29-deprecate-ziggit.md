# ADR — Deprecate and remove ziggit-based RefStore

- **Date:** 2026-04-29
- **Status:** Accepted
- **Companion ADR:** `2026-04-29-github-api-refstore.md`.

## 1. Context

`ZiggitRefStore` is an in-process Zig implementation of git plumbing —
loose object reads/writes, ref reads/writes, tree/commit construction —
backed by the local filesystem. It does **not** implement transport
(no fetch, push, clone, smart-HTTP, or pack negotiation), so it can
only operate on a pre-existing local repo. The vendored ziggit sources
under `src/core/storage/ziggit_pkg/` are several thousand lines of code
maintained alongside our own.

Two pending issues planned to extend ziggit toward browser use:

- `sideshowdb-an4` — run `ZiggitRefStore` unchanged inside a
  `wasm32-wasi` build with a browser-side WASI shim providing the
  filesystem.
- `sideshowdb-dgz` — fork ziggit's `Platform.fs` to a JS-backed virtual
  filesystem accessed via host capabilities.

Either path requires us to also build a complete smart-HTTP-v2 client
inside ziggit so the browser store can sync with GitHub. That alone is
a multi-quarter undertaking.

The companion ADR
(`2026-04-29-github-api-refstore.md`) replaces this entire trajectory
with a REST-based `GitHubApiRefStore`. With that decision in place,
the ziggit code path no longer earns its maintenance cost: it covers
no scenario that the new path does not cover better, and it blocks no
work that the new path needs.

The project is **pre-0.1.0** — there is no public API contract to
preserve and no deprecation cycle obligation.

## 2. Options considered

### 2.1 Keep ziggit, demote it behind a flag

**Pros.** Preserves the option to run native operations without
shelling out to git or relying on libgit2 at some future point.

**Cons.** Maintenance tax with no current consumer; unused code rots
fast; signals intent to evolve a path we have just decided not to evolve.

### 2.2 Soft-deprecate (mark deprecated, remove later)

**Pros.** Respects the impulse not to delete code that "might be
useful."

**Cons.** Pre-0.1.0 deprecation cycles serve no audience; the deferred
removal still has to happen, and meanwhile every reader has to ask
"why is this here?"

### 2.3 Remove ziggit and its tests in a single PR

**Pros.** Smallest residual footprint; clearest signal of the new
direction; aligns with the pre-0.1.0 freedom to delete; reclaims build
matrix complexity (no `freestanding`-vs-non gate inside `storage.zig`
for ziggit).

**Cons.** Future native users wanting in-process git plumbing must wait
for `Libgit2RefStore` (already a future ticket) or use
`SubprocessGitRefStore`.

## 3. Decision

Adopt **2.3**. Remove ziggit in a single focused PR that lands with
(or immediately after) the `GitHubApiRefStore` work.

In scope of removal:

- `src/core/storage/ziggit_pkg/` — entire vendored tree.
- `src/core/storage/ziggit_ref_store.zig` and its tests.
- `tests/ziggit_ref_store_test.zig`.
- `ZiggitRefStore` declaration in `src/core/storage.zig` and the
  `freestanding`-vs-other switch it required.
- `GitRefStore = ZiggitRefStore` alias in `src/core/storage.zig`. The
  alias is replaced with `pub const GitRefStore = GitHubApiRefStore`
  once the new store has landed; until then the alias is removed
  outright and callers reference the concrete store.
- Any `--refstore ziggit` CLI flag value and associated docs.
- References from the test runner in `build.zig`.

`SubprocessGitRefStore` is **not** removed; it stays as the explicit
escape hatch for environments without API access.

The closes for `sideshowdb-an4` and `sideshowdb-dgz` cite this ADR.

## 4. Consequences

- The codebase loses a substantial amount of code that nothing
  currently exercises end-to-end.
- Native callers wanting in-process git on a local repo must use
  `SubprocessGitRefStore` until `Libgit2RefStore` lands as a future
  enhancement.
- `wasm32-freestanding` no longer needs to special-case ziggit
  resolution to `void`; `storage.zig` simplifies.
- The `wasm32-wasi` build target introduced earlier in this branch
  loses its original justification (running ziggit in browser).
  The target itself is retained as an internal CI test artifact only,
  with a follow-up ticket to wire `wasmtime`-driven Zig tests; if that
  ticket does not land in a quarter we revisit and remove the target.
