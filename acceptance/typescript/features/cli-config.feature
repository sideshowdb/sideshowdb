@cli @config
Feature: CLI config commands

  # EARS:
  # - When a caller runs `sideshow config set --local <key> <value>`, the CLI shall update `.sideshowdb/config.toml`, creating parent directories as needed. (CONF-001)
  # - When a caller runs `sideshow config set --global <key> <value>`, the CLI shall update the user config file, creating parent directories as needed. (CONF-002)
  # - When a caller runs `sideshow config get <key>` without a scope, the CLI shall print the resolved value. (CONF-003)
  # - When `SIDESHOWDB_REFSTORE` is set, the CLI shall prefer it over local and global config. (CONF-004)
  # - If a caller supplies both `--local` and `--global`, then the CLI shall fail with a usage error and not write a config file. (CONF-005)

  Scenario: local config set and get round trip
    Given a temporary git-backed CLI repository
    When I invoke "config set --local refstore.kind github"
    Then the auth CLI command succeeds
    When I invoke "config get --local refstore.kind"
    Then the auth CLI command succeeds
    And the auth CLI stdout equals "github\n"

  Scenario: global config uses the configured user config directory
    Given a fresh sideshow auth config directory
    When I invoke "config set --global refstore.repo sideshowdb/sideshowdb"
    Then the auth CLI command succeeds
    When I invoke "config get --global refstore.repo"
    Then the auth CLI command succeeds
    And the auth CLI stdout equals "sideshowdb/sideshowdb\n"

  Scenario: environment refstore overrides config
    Given a temporary git-backed CLI repository
    And a fresh sideshow auth config directory
    When I invoke "config set --global refstore.kind github"
    Then the auth CLI command succeeds
    When I invoke "config set --local refstore.kind github"
    Then the auth CLI command succeeds
    Given the auth CLI environment variable "SIDESHOWDB_REFSTORE" is "subprocess"
    When I invoke "config get refstore.kind"
    Then the auth CLI command succeeds
    And the auth CLI stdout equals "subprocess\n"

  Scenario: conflicting scopes fail
    Given a temporary git-backed CLI repository
    And a fresh sideshow auth config directory
    When I invoke "config set --local --global refstore.kind github"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "choose only one"
    And the auth CLI did not write config files
