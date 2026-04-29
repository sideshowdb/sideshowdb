Feature: IndexedDB host store acceptance

  # EARS:
  # - When createIndexedDbHostStoreEffect is run with indexedDB available, the Effect binding shall produce a usable host store value.
  # - If indexedDB is unavailable, then createIndexedDbHostStoreEffect shall fail in the Effect error channel with runtime-load signaling.
  # - When createIndexedDbHostStore opens an existing database with a missing storeName, the store shall upgrade schema and operate through the new object store.
  # - If schema upgrade is blocked while adding a missing storeName, then createIndexedDbHostStore shall invoke onPersistenceError and fail store creation.
  # - When values are written through an IndexedDB host store, a newly opened store with the same database and object store shall read the persisted value.
  # - When loadSideshowdbClient runs without an explicit hostCapabilities.store and indexedDB is available, the client shall persist document writes through the default IndexedDB-backed host store across reloads.

  @wasm @indexeddb
  Scenario: Effect binding creates an IndexedDB host store when IndexedDB exists
    Given IndexedDB is available for acceptance tests
    When I create an IndexedDB host store through the Effect binding
    Then the IndexedDB host store is created
    When I put key "effect-key" with value "effect-value" through the IndexedDB host store
    Then getting key "effect-key" through the IndexedDB host store returns value "effect-value"

  @wasm @indexeddb
  Scenario: Effect binding reports runtime-load failure when IndexedDB is unavailable
    Given IndexedDB is unavailable for acceptance tests
    When I create an IndexedDB host store through the Effect binding
    Then IndexedDB host store creation fails with error kind "runtime-load"
    And IndexedDB availability is restored for acceptance tests

  @wasm @indexeddb
  Scenario: Host store upgrades schema when storeName is missing from an existing DB
    Given IndexedDB is available for acceptance tests
    And an IndexedDB host store database "acceptance-upgrade-db" exists with store "refs-a"
    When I open an IndexedDB host store on database "acceptance-upgrade-db" with store "refs-b"
    And I put key "upgrade-key" with value "upgrade-value" through the IndexedDB host store
    Then getting key "upgrade-key" through the IndexedDB host store returns value "upgrade-value"

  @wasm @indexeddb
  Scenario: Host store reports persistence errors when schema upgrade is blocked
    Given IndexedDB is available for acceptance tests
    And an IndexedDB host store database "acceptance-blocked-upgrade-db" exists with store "refs-a"
    And an external IndexedDB connection blocks upgrades for database "acceptance-blocked-upgrade-db"
    When I open an IndexedDB host store on database "acceptance-blocked-upgrade-db" with store "refs-b" and persistence error hook
    Then IndexedDB host store creation fails
    And the IndexedDB persistence error hook was called
    And I release the external IndexedDB blocker

  @indexeddb
  Scenario: Values persist across host store reopen with the same database and store
    Given IndexedDB is available for acceptance tests
    And an IndexedDB host store on database "acceptance-durability-db" with store "refs-durable"
    When I put key "durability-key" with value "durability-value" through the IndexedDB host store
    And I close the IndexedDB host store
    And I reopen the IndexedDB host store on database "acceptance-durability-db" with store "refs-durable"
    Then getting key "durability-key" through the reopened IndexedDB host store returns value "durability-value"

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
          "store": "default",
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
          "store": "default",
          "reload": "verified"
        }
      }
      """
