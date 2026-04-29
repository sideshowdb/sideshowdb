Feature: WASM document lifecycle

  Scenario: Put a document through the WASM binding with an in-memory host bridge
    Given an in-memory WASM host bridge
    When I put one document through the WASM binding
    Then the WASM operation succeeds
