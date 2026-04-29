Feature: WASM document lifecycle

  # EARS:
  # - When a caller uses the shipped WASM binding with a host store, the WASM client shall expose put/get/list/history/delete through the public TypeScript API.
  # - When a caller loads the WASM binding without a host store, the WASM client shall use the in-WASM MemoryRefStore so document operations succeed without any host wiring.
  # - When acceptance coverage expands for the WASM binding, the suite shall cover namespace-aware document flows through the public TypeScript API.
  # - When acceptance coverage expands for the WASM binding, the suite shall cover version-targeted document reads through the public TypeScript API.

  @wasm
  Scenario: Put a document through the WASM binding with an in-memory host store
    Given an in-memory WASM host store
    And the WASM client is loaded
    When I put document "doc-1" of type "summary" in namespace "default" through the WASM binding with JSON body:
      """
      {
        "title": "First issue draft",
        "status": "draft"
      }
      """
    Then the WASM operation succeeds
    And I remember the WASM envelope version as "wasm-v1"
    When I put document "doc-1" of type "summary" in namespace "default" through the WASM binding with JSON body:
      """
      {
        "title": "Second issue draft",
        "status": "review"
      }
      """
    Then the WASM operation succeeds
    And I remember the WASM envelope version as "wasm-v2"
    When I get document "doc-1" of type "summary" in namespace "default" through the WASM binding
    Then the WASM document body equals:
      """
      {
        "title": "Second issue draft",
        "status": "review"
      }
      """
    When I list documents of type "summary" in namespace "default" through the WASM binding in summary mode
    Then the WASM summary items are:
      | namespace | type    | id    |
      | default   | summary | doc-1 |
    When I request document history for "doc-1" of type "summary" in namespace "default" through the WASM binding in detailed mode
    Then the WASM history items match:
      | remembered_version | title              | namespace | type    | id    |
      | wasm-v2            | Second issue draft | default   | summary | doc-1 |
      | wasm-v1            | First issue draft  | default   | summary | doc-1 |
    When I delete the document through the WASM binding
    Then the WASM delete result is true

  @wasm
  Scenario: Standalone WASM client round-trips documents through the in-WASM MemoryRefStore
    Given no WASM host store
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

  @wasm
  Scenario: WASM binding lists namespace-scoped rich documents
    Given an in-memory WASM host store
    And the WASM client is loaded
    When I put document "roadmap-q3" of type "issue" in namespace "catalog" through the WASM binding with JSON body:
      """
      {
        "title": "Q3 roadmap",
        "status": "draft",
        "owner": "platform",
        "tags": ["planning", "quarterly"],
        "milestones": [
          { "name": "alpha", "date": "2026-07-15" },
          { "name": "ga", "date": "2026-09-30" }
        ]
      }
      """
    Then the WASM operation succeeds
    When I put document "launch-checklist" of type "issue" in namespace "catalog" through the WASM binding with JSON body:
      """
      {
        "title": "Launch checklist",
        "status": "ready",
        "owner": "release",
        "tags": ["launch", "ops"],
        "steps": ["freeze", "verify", "announce"]
      }
      """
    Then the WASM operation succeeds
    When I put document "incident-442" of type "issue" in namespace "support" through the WASM binding with JSON body:
      """
      {
        "title": "Incident 442",
        "status": "monitoring",
        "owner": "support",
        "severity": "high"
      }
      """
    Then the WASM operation succeeds
    When I list documents of type "issue" in namespace "catalog" through the WASM binding in summary mode
    Then the WASM summary items are:
      | namespace | type  | id               |
      | catalog   | issue | launch-checklist |
      | catalog   | issue | roadmap-q3       |

  @wasm
  Scenario: WASM binding reads a remembered earlier version from rich history
    Given an in-memory WASM host store
    And the WASM client is loaded
    When I put document "release-notes" of type "note" in namespace "product" through the WASM binding with JSON body:
      """
      {
        "title": "Launch prep",
        "body": "Coordinate final launch readiness across docs, support, and release.",
        "owners": ["dana", "kai"],
        "checkpoints": {
          "docs": "ready",
          "support": "pending",
          "release": "ready"
        }
      }
      """
    Then the WASM operation succeeds
    And I remember the WASM envelope version as "launch-v1"
    When I put document "release-notes" of type "note" in namespace "product" through the WASM binding with JSON body:
      """
      {
        "title": "Launch prep updated",
        "body": "Support is now staffed and the launch review is complete.",
        "owners": ["dana", "kai"],
        "checkpoints": {
          "docs": "ready",
          "support": "ready",
          "release": "ready"
        }
      }
      """
    Then the WASM operation succeeds
    And I remember the WASM envelope version as "launch-v2"
    When I request document history for "release-notes" of type "note" in namespace "product" through the WASM binding in detailed mode
    Then the WASM history items match:
      | remembered_version | title               | namespace | type | id            |
      | launch-v2          | Launch prep updated | product   | note | release-notes |
      | launch-v1          | Launch prep         | product   | note | release-notes |
    When I get document "release-notes" of type "note" in namespace "product" at remembered version "launch-v1" through the WASM binding
    Then the WASM document body equals:
      """
      {
        "title": "Launch prep",
        "body": "Coordinate final launch readiness across docs, support, and release.",
        "owners": ["dana", "kai"],
        "checkpoints": {
          "docs": "ready",
          "support": "pending",
          "release": "ready"
        }
      }
      """
