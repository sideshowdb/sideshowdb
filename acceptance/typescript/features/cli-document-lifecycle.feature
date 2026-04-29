@cli
Feature: CLI document lifecycle

  # EARS:
  # - When a caller manages a document lifecycle through the CLI in a git-backed repository, the CLI shall allow put/get/list/history/delete operations and emit observable JSON results for each command.
  # - If a caller invokes the CLI put command with invalid arguments, then the CLI shall fail with exit code 1 and emit usage information on stderr.
  # - When a caller invokes 'doc put' with --data-file <path>, the CLI shall read the payload bytes from that file and store them as the document body.
  # - If --data-file points to a missing or unreadable path, then the CLI shall fail with exit code 1 and a "--data-file" error on stderr without mutating any document.
  # - When both stdin and --data-file are supplied, the CLI shall use the file contents and ignore the stdin payload.
  # - When acceptance coverage expands for the CLI, the suite shall cover namespace-aware document flows through the public CLI contract.
  # - When acceptance coverage expands for the CLI, the suite shall cover version-targeted document reads through the public CLI contract.

  Scenario: Manage a document lifecycle through the CLI in a temporary git-backed repository
    Given a temporary git-backed CLI repository
    When I put document "cli-1" of type "issue" in namespace "default" through the CLI with JSON body:
      """
      {
        "title": "First issue draft",
        "status": "draft"
      }
      """
    Then the CLI command succeeds
    And I remember the CLI JSON version as "cli-v1"
    When I put document "cli-1" of type "issue" in namespace "default" through the CLI with JSON body:
      """
      {
        "title": "Second issue draft",
        "status": "review"
      }
      """
    Then the CLI command succeeds
    And I remember the CLI JSON version as "cli-v2"
    When I get document "cli-1" of type "issue" in namespace "default" through the CLI
    Then the CLI JSON body equals:
      """
      {
        "title": "Second issue draft",
        "status": "review"
      }
      """
    When I list documents through the CLI in summary mode for namespace "default" and type "issue"
    Then the CLI JSON summary items are:
      | namespace | type  | id    |
      | default   | issue | cli-1 |
    When I request document history for "cli-1" of type "issue" in namespace "default" through the CLI in detailed mode
    Then the CLI JSON history items match:
      | remembered_version | title              | namespace | type  | id    |
      | cli-v2             | Second issue draft | default   | issue | cli-1 |
      | cli-v1             | First issue draft  | default   | issue | cli-1 |
    When I delete the document through the CLI
    Then the CLI JSON deleted flag is true

  Scenario: Invalid CLI put arguments return usage information
    Given a temporary git-backed CLI repository
    When I run the CLI with invalid put arguments
    Then the CLI command fails with exit code 1
    And the CLI stderr contains "usage: sideshowdb"

  Scenario: doc put --data-file reads payload from a file
    Given a temporary git-backed CLI repository
    And a payload file "payload.json" containing data title "from file"
    When I put the document through the CLI with --data-file "payload.json"
    Then the CLI command succeeds
    When I get the document through the CLI
    Then the CLI JSON data title is "from file"

  Scenario: doc put --data-file fails non-zero on a missing path without mutating state
    Given a temporary git-backed CLI repository
    When I put the document through the CLI with --data-file "does-not-exist.json"
    Then the CLI command fails with exit code 1
    And the CLI stderr contains "--data-file"
    When I get the document through the CLI
    Then the CLI command fails with exit code 1
    And the CLI stderr contains "document not found"

  Scenario: doc put --data-file overrides stdin payload when both are present
    Given a temporary git-backed CLI repository
    And a payload file "payload.json" containing data title "file wins"
    When I put the document through the CLI with --data-file "payload.json" and stdin payload data title "stdin loses"
    Then the CLI command succeeds
    When I get the document through the CLI
    Then the CLI JSON data title is "file wins"

  Scenario: Namespace-aware CLI listing uses rich document examples
    Given a temporary git-backed CLI repository
    When I put document "roadmap-q3" of type "issue" in namespace "catalog" through the CLI with JSON body:
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
    Then the CLI command succeeds
    When I put document "launch-checklist" of type "issue" in namespace "catalog" through the CLI with JSON body:
      """
      {
        "title": "Launch checklist",
        "status": "ready",
        "owner": "release",
        "tags": ["launch", "ops"],
        "steps": ["freeze", "verify", "announce"]
      }
      """
    Then the CLI command succeeds
    When I put document "incident-442" of type "issue" in namespace "support" through the CLI with JSON body:
      """
      {
        "title": "Incident 442",
        "status": "monitoring",
        "owner": "support",
        "severity": "high"
      }
      """
    Then the CLI command succeeds
    When I list documents through the CLI in summary mode for namespace "catalog" and type "issue"
    Then the CLI JSON summary items are:
      | namespace | type  | id               |
      | catalog   | issue | launch-checklist |
      | catalog   | issue | roadmap-q3       |

  Scenario: CLI reads a remembered earlier version from rich history
    Given a temporary git-backed CLI repository
    When I put document "release-notes" of type "note" in namespace "product" through the CLI with JSON body:
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
    Then the CLI command succeeds
    And I remember the CLI JSON version as "launch-v1"
    When I put document "release-notes" of type "note" in namespace "product" through the CLI with JSON body:
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
    Then the CLI command succeeds
    And I remember the CLI JSON version as "launch-v2"
    When I request document history for "release-notes" of type "note" in namespace "product" through the CLI in detailed mode
    Then the CLI JSON history items match:
      | remembered_version | title               | namespace | type | id            |
      | launch-v2          | Launch prep updated | product   | note | release-notes |
      | launch-v1          | Launch prep         | product   | note | release-notes |
    When I get document "release-notes" of type "note" in namespace "product" at remembered version "launch-v1" through the CLI
    Then the CLI JSON body equals:
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
