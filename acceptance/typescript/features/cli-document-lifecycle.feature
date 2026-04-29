@cli
Feature: CLI document lifecycle

  # EARS:
  # - When a caller manages a document lifecycle through the CLI in a git-backed repository, the CLI shall allow put/get/list/history/delete operations and emit observable JSON results for each command.
  # - If a caller invokes the CLI put command with invalid arguments, then the CLI shall fail with exit code 1 and emit usage information on stderr.
  # - When a caller invokes 'doc put' with --data-file <path>, the CLI shall read the payload bytes from that file and store them as the document body.
  # - If --data-file points to a missing or unreadable path, then the CLI shall fail with exit code 1 and a "--data-file" error on stderr without mutating any document.
  # - When both stdin and --data-file are supplied, the CLI shall use the file contents and ignore the stdin payload.

  Scenario: Manage a document lifecycle through the CLI in a temporary git-backed repository
    Given a temporary git-backed CLI repository
    When I put the first document version through the CLI
    Then the CLI command succeeds
    When I put the second document version through the CLI
    Then the CLI command succeeds
    When I get the document through the CLI
    Then the CLI JSON data title is "second"
    When I list documents through the CLI in summary mode
    Then the CLI JSON kind is "summary"
    And the first listed document id is "cli-1"
    When I request document history through the CLI in detailed mode
    Then the CLI JSON kind is "detailed"
    And the CLI JSON items length is 2
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
