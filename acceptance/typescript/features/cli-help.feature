@cli
Feature: CLI help

  # EARS:
  # - CLI-HELP-001 maps to: Top-level help command prints root help
  # - CLI-HELP-002 maps to: Global --help prints root help
  # - CLI-HELP-003 maps to: Command --help prints command help
  # - CLI-HELP-004 maps to: Help command prints nested command help
  # - CLI-HELP-005 maps to: Unknown help topic fails without stdout
  # - CLI-HELP-006 maps to: JSON flag does not make help JSON
  # - CLI-HELP-007 maps to: Top-level and nested scenarios assert KDL-derived commands, flags, summaries, and examples
  # - CLI-HELP-008 maps to: Invocation with no arguments prints root help on stdout
  # - CLI-HELP-009 maps to: Unknown command prints diagnostic with usage on stderr
  # - CLI-HELP-010 maps to: Unknown command suggests close match when one exists

  Scenario: No arguments prints root help on stdout
    Given a temporary git-backed CLI repository
    When I run the CLI with no arguments
    Then the CLI command succeeds
    And the CLI stdout contains "usage: sideshow"
    And the CLI stdout contains "version"
    And the CLI stderr is empty

  Scenario: Top-level help command prints root help
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg  |
      | help |
    Then the CLI command succeeds
    And the CLI stdout contains "usage: sideshow"
    And the CLI stdout contains "doc"
    And the CLI stdout contains "--refstore"
    And the CLI stderr is empty

  Scenario: Global --help prints root help
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg    |
      | --help |
    Then the CLI command succeeds
    And the CLI stdout contains "usage: sideshow"
    And the CLI stdout contains "version"
    And the CLI stderr is empty

  Scenario: Command --help prints command help
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg    |
      | doc    |
      | put    |
      | --help |
    Then the CLI command succeeds
    And the CLI stdout contains "Create or replace a document version."
    And the CLI stdout contains "--data-file"
    And the CLI stdout contains "$ sideshow --json doc put"
    And the CLI stderr is empty

  Scenario: Help command prints nested command help
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg  |
      | help |
      | doc  |
      | put  |
    Then the CLI command succeeds
    And the CLI stdout contains "Create or replace a document version."
    And the CLI stdout contains "--type"
    And the CLI stderr is empty

  Scenario: Unknown help topic fails without stdout
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg  |
      | help |
      | nope |
    Then the CLI command fails with exit code 1
    And the CLI stdout is empty
    And the CLI stderr contains "unknown help topic: nope"

  Scenario: JSON flag does not make help JSON
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg    |
      | --json |
      | help   |
    Then the CLI command succeeds
    And the CLI stdout contains "usage: sideshow"
    And the CLI stdout is not JSON
    And the CLI stderr is empty

  Scenario: Unknown command prints diagnostic with usage on stderr
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg   |
      | bogus |
    Then the CLI command fails with exit code 1
    And the CLI stdout is empty
    And the CLI stderr contains "unknown command: bogus"
    And the CLI stderr contains "usage: sideshow"

  Scenario: Unknown command suggests close match when one exists
    Given a temporary git-backed CLI repository
    When I run the CLI with arguments:
      | arg    |
      | vesion |
    Then the CLI command fails with exit code 1
    And the CLI stderr contains "unknown command: vesion"
    And the CLI stderr contains "did you mean: version?"
