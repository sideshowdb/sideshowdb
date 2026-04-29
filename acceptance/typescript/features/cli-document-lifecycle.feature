@cli
Feature: CLI document lifecycle

  # EARS:
  # - When a caller manages a document lifecycle through the CLI in a git-backed repository, the CLI shall allow put/get/list/history/delete operations and emit observable JSON results for each command.
  # - If a caller invokes the CLI put command with invalid arguments, then the CLI shall fail with exit code 1 and emit usage information on stderr.

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
