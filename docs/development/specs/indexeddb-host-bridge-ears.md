# IndexedDB Host Bridge EARS

This document defines user-facing EARS requirements for IndexedDB host bridge
behavior in `@sideshowdb/core` and `@sideshowdb/effect`, with explicit mapping
to TypeScript Cucumber acceptance scenarios.

## EARS

- **IDB-BRIDGE-001**  
  When `createIndexedDbRefHostBridgeEffect` is run with indexedDB available,
  the Effect binding shall produce a usable host bridge value.

- **IDB-BRIDGE-002**  
  If indexedDB is unavailable, then `createIndexedDbRefHostBridgeEffect` shall
  fail in the Effect error channel with runtime-load signaling.

- **IDB-BRIDGE-003**  
  When `createIndexedDbRefHostBridge` opens an existing database whose requested
  `storeName` is missing, the bridge shall upgrade schema and support operations
  through the new store.

- **IDB-BRIDGE-004**  
  If schema upgrade is blocked while opening a missing `storeName`, then
  `createIndexedDbRefHostBridge` shall invoke `onPersistenceError` and fail
  bridge creation.

- **IDB-BRIDGE-005**  
  When values are written through an IndexedDB host bridge, a newly opened
  bridge using the same database and store shall read the persisted value.

- **IDB-BRIDGE-006**  
  When `loadSideshowdbClient` is run in a browser-like runtime without an
  explicit `hostBridge` and indexedDB is available, the client shall persist
  document writes through the default IndexedDB-backed host bridge so a newly
  loaded client can read the stored value.

## Acceptance Mapping

- **IDB-BRIDGE-001** -> `indexeddb-host-bridge.feature` / "Effect binding creates an IndexedDB host bridge when IndexedDB exists"
- **IDB-BRIDGE-002** -> `indexeddb-host-bridge.feature` / "Effect binding reports runtime-load failure when IndexedDB is unavailable"
- **IDB-BRIDGE-003** -> `indexeddb-host-bridge.feature` / "Bridge upgrades schema when storeName is missing from an existing DB"
- **IDB-BRIDGE-004** -> `indexeddb-host-bridge.feature` / "Bridge reports persistence errors when schema upgrade is blocked"
- **IDB-BRIDGE-005** -> `indexeddb-host-bridge.feature` / "Values persist across host bridge reload with the same database and store"
- **IDB-BRIDGE-006** -> `indexeddb-host-bridge.feature` / "Default client persists documents through IndexedDB across reload"
