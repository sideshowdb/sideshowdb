Feature: CLI document lifecycle

  Scenario: Put a document through the CLI in a temporary git-backed repository
    Given a temporary git-backed CLI repository
    When I put one document through the CLI
    Then the CLI command succeeds
