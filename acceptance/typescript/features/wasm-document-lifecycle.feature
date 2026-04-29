Feature: WASM document lifecycle

  # EARS:
  # - When a caller uses the shipped WASM binding with a host bridge, the WASM client shall expose put/get/list/history/delete through the public TypeScript API.
  # - If a caller uses document operations without a host bridge, then the WASM client shall return a public host-bridge error.

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
  Scenario: Put fails without a host bridge
    Given no WASM host bridge
    And the WASM client is loaded
    When I put a document through the WASM binding without a host bridge
    Then the WASM operation fails with error kind "host-bridge"
