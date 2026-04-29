Feature: WASM document lifecycle

  # EARS:
  # - When a caller uses the shipped WASM binding with a host bridge, the WASM client shall expose put/get/list/history/delete through the public TypeScript API.
  # - When a caller loads the WASM binding without a host bridge, the WASM client shall use the in-WASM MemoryRefStore so document operations succeed without any host wiring.

  @wasm
  Scenario: Put a document through the WASM binding with an in-memory host bridge
    Given an in-memory WASM host bridge
    And the WASM client is loaded
    When I put the first document version through the WASM binding
    And I put the second document version through the WASM binding
    And I get the document through the WASM binding
    Then the WASM get result title is "second"
    When I list documents through the WASM binding
    Then the WASM list result kind is "summary"
    When I request detailed history through the WASM binding
    Then the WASM history result contains 2 entries
    When I delete the document through the WASM binding
    Then the WASM delete result is true

  @wasm
  Scenario: Standalone WASM client round-trips documents through the in-WASM MemoryRefStore
    Given no WASM host bridge
    And the WASM client is loaded
    When I put the first document version through the WASM binding
    Then the WASM operation succeeds
    When I put the second document version through the WASM binding
    And I get the document through the WASM binding
    Then the WASM get result title is "second"
    When I request detailed history through the WASM binding
    Then the WASM history result contains 2 entries
    When I delete the document through the WASM binding
    Then the WASM delete result is true
