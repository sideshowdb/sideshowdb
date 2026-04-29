# IndexedDB Host Store EARS

This document defines user-facing EARS requirements for IndexedDB-backed **host
store** behavior in `@sideshowdb/core` and `@sideshowdb/effect`, with explicit
mapping to TypeScript Cucumber acceptance scenarios.

API symbols: `createIndexedDbHostStore`, `createIndexedDbHostStoreEffect`, and
`hostCapabilities.store`. **Design rationale:**
`docs/design/adrs/2026-04-29-host-capabilities-store-api.md`.

## EARS

- **IDB-STORE-001**  
  When `createIndexedDbHostStoreEffect` is run with indexedDB available,
  the Effect binding shall produce a usable host store value.

- **IDB-STORE-002**  
  If indexedDB is unavailable, then `createIndexedDbHostStoreEffect` shall
  fail in the Effect error channel with runtime-load signaling.

- **IDB-STORE-003**  
  When `createIndexedDbHostStore` opens an existing database whose requested
  `storeName` is missing, the store shall upgrade schema and support operations
  through the new object store.

- **IDB-STORE-004**  
  If schema upgrade is blocked while opening a missing `storeName`, then
  `createIndexedDbHostStore` shall invoke `onPersistenceError` and fail
  store creation.

- **IDB-STORE-005**  
  When values are written through an IndexedDB host store, a newly opened
  store using the same database and object store shall read the persisted value.

- **IDB-STORE-006**  
  When `loadSideshowDBClient` is run in a browser-like runtime without an
  explicit `hostCapabilities.store` and indexedDB is available, the client shall
  persist document writes through the default IndexedDB-backed host store so a
  newly loaded client can read the stored value.

## Acceptance Mapping

- **IDB-STORE-001** -> `indexeddb-host-store.feature` / "Effect binding creates an IndexedDB host store when IndexedDB exists"
- **IDB-STORE-002** -> `indexeddb-host-store.feature` / "Effect binding reports runtime-load failure when IndexedDB is unavailable"
- **IDB-STORE-003** -> `indexeddb-host-store.feature` / "Host store upgrades schema when storeName is missing from an existing DB"
- **IDB-STORE-004** -> `indexeddb-host-store.feature` / "Host store reports persistence errors when schema upgrade is blocked"
- **IDB-STORE-005** -> `indexeddb-host-store.feature` / "Values persist across host store reopen with the same database and store"
- **IDB-STORE-006** -> `indexeddb-host-store.feature` / "Default client persists documents through IndexedDB across reload"

## Historic identifiers

Earlier revisions used requirement ids **`IDB-BRIDGE-*`** and the feature file
`indexeddb-host-bridge.feature`. Those identifiers map one-to-one to
**`IDB-STORE-*`** and `indexeddb-host-store.feature` in the same order above.
