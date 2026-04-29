# ADR — TypeScript WASM `hostCapabilities.store` and host store naming

- **Date:** 2026-04-29
- **Status:** Accepted
- **PR:** [sideshowdb#24](https://github.com/sideshowdb/sideshowdb/pull/24)
- **Supersedes:** Flat `hostBridge` / `hostConnector` options and file names
  using `*bridge*` for the ref persistence adapter in `@sideshowdb/core`.

## 1. Context

The browser WASM client needs the host (JavaScript) to supply a **ref
store** implementation when the module is configured for imported ref
storage. Early bindings exposed that dependency as a **top-level option**
with names like `hostBridge` and types like `IndexedDbRefHostBridge`.

That naming carried two problems:

1. **Metaphor mismatch.** The object is not a “bridge” in the network sense; it
   is a **store** implementing the same conceptual contract as other ref
   stores (put/get/list/history/delete). Calling it a bridge obscures the
   mental model and drifts from Zig-side vocabulary (`RefStore`).
2. **Extension shape.** We expect additional **host-provided capabilities**
   over time (for example sync helpers, telemetry hooks, or platform file
   access). A flat `hostBridge` option does not compose: every new concern
   would force another top-level rename or ambiguous overload.

We therefore needed a **stable container** for host-side capabilities and a
**honest name** for the ref persistence implementation.

## 2. Options considered

### 2.1 Keep `hostBridge` and add parallel top-level options

**Pros.** No breaking change for early adopters.

**Cons.** Does not scale; option bag becomes a flat grab bag; names stay
misleading.

### 2.2 Rename to `hostConnector` only

**Pros.** Slightly more generic.

**Cons.** Still a flat option; “connector” is equally vague; does not reserve
space for future capabilities.

### 2.3 Introduce `hostCapabilities: { store?: SideshowdbHostStore }`

**Pros.**

- **Accurate language:** `SideshowdbHostStore` matches behavior — a ref store
  supplied by the host.
- **Forward compatible:** New capabilities nest under `hostCapabilities`
  without breaking existing callers that only pass `store`.
- **Aligns with errors:** A dedicated `host-store` error kind mirrors the
  capability name.

**Cons.** Breaking rename for TypeScript callers and file/module names
(`indexeddb-bridge` → `indexeddb-store`, demo and acceptance helpers).

## 3. Decision

Adopt **2.3**:

- `LoadSideshowdbClientOptions.hostCapabilities?: { store?: SideshowdbHostStore }`
- Public types and factories use **store** language (`IndexedDbHostStore`,
  `createIndexedDbHostStore`, `createIndexedDbHostStoreEffect`).
- IndexedDB persistence ships as `indexeddb-store` (module/file naming).
  Acceptance coverage for IndexedDB-backed host stores lives in
  `indexeddb-host-store.feature` with EARS in `indexeddb-host-store-ears.md`.

Default wiring when IndexedDB exists and the caller did not supply
`hostCapabilities.store` remains **automatic**; the change is naming and
option shape, not persistence semantics.

## 4. Consequences

- **Callers** pass `hostCapabilities: { store: myStore }` instead of a flat
  bridge/connector property.
- **Documentation** points here and to PR #24 for the full diff and
  validation notes.
- **Beads:** Chore `sideshowdb-ywt` (`external_ref: gh-pr-24`) embeds this ADR
  in `design` notes so agents searching “host capabilities” find the trace.
- **EARS** documents under `docs/development/specs/` should use the same
  vocabulary (`hostCapabilities.store`, host store) when describing
  user-visible behavior.

## 5. References

- TypeScript EARS: `docs/development/specs/typescript-bindings-and-wasm-browser-bridge-ears.md`
- IndexedDB EARS: `docs/development/specs/indexeddb-host-store-ears.md`
- Core package README: `bindings/typescript/sideshowdb-core/README.md`
