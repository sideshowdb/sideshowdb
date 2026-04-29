Feature: IndexedDB host bridge acceptance

  # EARS:
  # - When createIndexedDbRefHostBridgeEffect is run with indexedDB available, the Effect binding shall produce a usable host bridge.
  # - If indexedDB is unavailable, then createIndexedDbRefHostBridgeEffect shall fail in the Effect error channel with runtime-load signaling.
  # - When a bridge opens an existing database with a missing storeName, the bridge shall upgrade schema and operate through the new store.
  # - If schema upgrade is blocked while adding a missing storeName, then createIndexedDbRefHostBridge shall invoke onPersistenceError and fail bridge creation.
  # - When values are written through an IndexedDB host bridge, a newly opened bridge with the same database and store shall read the persisted value.
  # - When loadSideshowdbClient runs without an explicit host bridge and indexedDB is available, the client shall persist document writes through the default IndexedDB bridge across reloads.

  @wasm @indexeddb
  Scenario: Effect binding creates an IndexedDB host bridge when IndexedDB exists
    Given IndexedDB is available for acceptance tests
    When I create an IndexedDB host bridge through the Effect binding
    Then the IndexedDB host bridge is created
    When I put key "effect-key" with value "effect-value" through the IndexedDB host bridge
    Then getting key "effect-key" through the IndexedDB host bridge returns value "effect-value"

  @wasm @indexeddb
  Scenario: Effect binding reports runtime-load failure when IndexedDB is unavailable
    Given IndexedDB is unavailable for acceptance tests
    When I create an IndexedDB host bridge through the Effect binding
    Then IndexedDB host bridge creation fails with error kind "runtime-load"
    And IndexedDB availability is restored for acceptance tests

  @wasm @indexeddb
  Scenario: Bridge upgrades schema when storeName is missing from an existing DB
    Given IndexedDB is available for acceptance tests
    And an IndexedDB host bridge database "acceptance-upgrade-db" exists with store "refs-a"
    When I open an IndexedDB host bridge on database "acceptance-upgrade-db" with store "refs-b"
    And I put key "upgrade-key" with value "upgrade-value" through the IndexedDB host bridge
    Then getting key "upgrade-key" through the IndexedDB host bridge returns value "upgrade-value"

  @wasm @indexeddb
  Scenario: Bridge reports persistence errors when schema upgrade is blocked
    Given IndexedDB is available for acceptance tests
    And an IndexedDB host bridge database "acceptance-blocked-upgrade-db" exists with store "refs-a"
    And an external IndexedDB connection blocks upgrades for database "acceptance-blocked-upgrade-db"
    When I open an IndexedDB host bridge on database "acceptance-blocked-upgrade-db" with store "refs-b" and persistence error hook
    Then IndexedDB host bridge creation fails
    And the IndexedDB persistence error hook was called
    And I release the external IndexedDB blocker

  @indexeddb
  Scenario: Values persist across host bridge reload with the same database and store
    Given IndexedDB is available for acceptance tests
    And an IndexedDB host bridge on database "acceptance-durability-db" with store "refs-durable"
    When I put key "durability-key" with value "durability-value" through the IndexedDB host bridge
    And I close the IndexedDB host bridge
    And I reopen the IndexedDB host bridge on database "acceptance-durability-db" with store "refs-durable"
    Then getting key "durability-key" through the reopened IndexedDB host bridge returns value "durability-value"

  @wasm @indexeddb
  Scenario: Default client persists documents through IndexedDB across reload
    Given IndexedDB is available for acceptance tests
    When I load the default IndexedDB-backed client for database "acceptance-client-default-db"
    And I put document "default-indexeddb-doc" of type "issue" with JSON body through the default IndexedDB client:
      """
      {
        "title": "Persisted through default client",
        "status": "durable",
        "owner": "browser-demo",
        "tags": ["indexeddb", "reload"],
        "checkpoints": {
          "bridge": "default",
          "reload": "verified"
        }
      }
      """
    And I reload the default IndexedDB-backed client for database "acceptance-client-default-db"
    Then getting document "default-indexeddb-doc" of type "issue" through the default IndexedDB client returns JSON body:
      """
      {
        "title": "Persisted through default client",
        "status": "durable",
        "owner": "browser-demo",
        "tags": ["indexeddb", "reload"],
        "checkpoints": {
          "bridge": "default",
          "reload": "verified"
        }
      }
      """
