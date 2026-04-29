# IndexedDB Host Store EARS

This document defines user-facing EARS requirements for IndexedDB-backed **host
store** behavior in `@sideshowdb/core` and `@sideshowdb/effect`, with explicit
mapping to TypeScript Cucumber acceptance scenarios.

**Note:** Requirement IDs keep the `IDB-BRIDGE-*` prefix and the feature file
name `indexeddb-host-bridge.feature` for stable traceability; API symbols use
`createIndexedDbHostStore`, `createIndexedDbHostStoreEffect`, and
`hostCapabilities.store`. **Design rationale:**
`docs/design/adrs/2026-04-29-host-capabilities-store-api.md`.

## EARS

- **IDB-BRIDGE-001**  
  When `createIndexedDbHostStoreEffect` is run with indexedDB available,
  the Effect binding shall produce a usable host store value.

- **IDB-BRIDGE-002**  
  If indexedDB is unavailable, then `createIndexedDbHostStoreEffect` shall
  fail in the Effect error channel with runtime-load signaling.

- **IDB-BRIDGE-003**  
  When `createIndexedDbHostStore` opens an existing database whose requested
  `storeName` is missing, the store shall upgrade schema and support operations
  through the new object store.

- **IDB-BRIDGE-004**  
  If schema upgrade is blocked while opening a missing `storeName`, then
  `createIndexedDbHostStore` shall invoke `onPersistenceError` and fail
  store creation.

- **IDB-BRIDGE-005**  
  When values are written through an IndexedDB host store, a newly opened
  store using the same database and object store shall read the persisted value.

- **IDB-BRIDGE-006**  
  When `loadSideshowdbClient` is run in a browser-like runtime without an
  explicit `hostCapabilities.store` and indexedDB is available, the client shall
  persist document writes through the default IndexedDB-backed host store so a
  newly loaded client can read the stored value.

## Acceptance Mapping

- **IDB-BRIDGE-001** -> `indexeddb-host-bridge.feature` / "Effect binding creates an IndexedDB host bridge when IndexedDB exists"
- **IDB-BRIDGE-002** -> `indexeddb-host-bridge.feature` / "Effect binding reports runtime-load failure when IndexedDB is unavailable"
- **IDB-BRIDGE-003** -> `indexeddb-host-bridge.feature` / "Bridge upgrades schema when storeName is missing from an existing DB"
- **IDB-BRIDGE-004** -> `indexeddb-host-bridge.feature` / "Bridge reports persistence errors when schema upgrade is blocked"
- **IDB-BRIDGE-005** -> `indexeddb-host-bridge.feature` / "Values persist across host bridge reload with the same database and store"
- **IDB-BRIDGE-006** -> `indexeddb-host-bridge.feature` / "Default client persists documents through IndexedDB across reload"
