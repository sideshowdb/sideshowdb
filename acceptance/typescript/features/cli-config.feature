@cli @config
Feature: CLI config commands

  # EARS:
  # - When a caller runs `sideshow config set --local <key> <value>`, the CLI shall update `.sideshowdb/config.toml`, creating parent directories as needed. (CONF-001)
  # - When a caller runs `sideshow config set --global <key> <value>`, the CLI shall update the user config file, creating parent directories as needed. (CONF-002)
  # - When a caller runs `sideshow config get <key>` without a scope, the CLI shall print the resolved value. (CONF-003)
  # - When `SIDESHOWDB_REFSTORE` is set, the CLI shall prefer it over local and global config. (CONF-004)
  # - If a caller supplies both `--local` and `--global`, then the CLI shall fail with a usage error and not write a config file. (CONF-005)
  # - When a caller supplies `--refstore <kind>`, the CLI shall prefer the flag over environment, local config, and global config. (CONF-006)
  # - When a caller runs `sideshow config list` without a scope, the CLI shall print the resolved flattened config view. (CONF-007)
  # - When a caller runs `sideshow --json config get <key>` without a scope, the CLI shall include the source that supplied the resolved value. (CONF-008)
  # - If a config file contains invalid TOML or an invalid value, then the CLI shall fail and surface an invalid config error. (CONF-009)
  # - When a caller runs `sideshow config unset --local <key>` for a missing key, the CLI shall leave the file unchanged and exit successfully. (CONF-010)
  # - When local or global config selects the GitHub refstore, document commands shall use GitHub refstore validation and fail before HTTP when required repo or credentials are missing. (CONF-011)
  # - If a caller attempts to persist a secret-shaped unsupported config key such as `github.token`, then the CLI shall reject the write as an unknown config key and not persist the secret. (CONF-012)

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

  Scenario: refstore flag overrides environment and config
    Given a temporary git-backed CLI repository
    And a fresh sideshow auth config directory
    When I invoke "config set --global refstore.kind github"
    Then the auth CLI command succeeds
    When I invoke "config set --local refstore.kind github"
    Then the auth CLI command succeeds
    Given the auth CLI environment variable "SIDESHOWDB_REFSTORE" is "github"
    When I invoke "--refstore subprocess config get refstore.kind"
    Then the auth CLI command succeeds
    And the auth CLI stdout equals "subprocess\n"

  Scenario: unscoped config list prints the resolved flattened view
    Given a temporary git-backed CLI repository
    And a fresh sideshow auth config directory
    When I invoke "config set --local refstore.kind github"
    Then the auth CLI command succeeds
    Given the auth CLI environment variable "SIDESHOWDB_REPO" is "env/repo"
    When I invoke "config list"
    Then the auth CLI command succeeds
    And the auth CLI stdout contains "refstore.kind=github"
    And the auth CLI stdout contains "refstore.repo=env/repo"
    And the auth CLI stdout contains "refstore.ref_name=refs/sideshowdb/documents"

  Scenario: JSON config get identifies the resolved source
    Given a temporary git-backed CLI repository
    And a fresh sideshow auth config directory
    When I invoke "config set --local refstore.kind github"
    Then the auth CLI command succeeds
    When I invoke "--json config get refstore.kind"
    Then the auth CLI command succeeds
    And the auth CLI JSON field "key" equals "refstore.kind"
    And the auth CLI JSON field "value" equals "github"
    And the auth CLI JSON field "source" equals "local"

  Scenario: invalid local config is surfaced
    Given a temporary git-backed CLI repository
    And an invalid local sideshow config file
    When I invoke "config get refstore.kind"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "invalid config"

  Scenario: invalid local config value is surfaced
    Given a temporary git-backed CLI repository
    And a local sideshow config file containing:
      """
      [refstore]
      kind = "banana"
      """
    When I invoke "config get refstore.kind"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "invalid config"

  Scenario: unsetting a missing local key is successful
    Given a temporary git-backed CLI repository
    When I invoke "config unset --local refstore.kind"
    Then the auth CLI command succeeds
    And the auth CLI stdout equals ""
    And the auth CLI did not write config files

  Scenario: local config can select GitHub refstore behavior
    Given a temporary git-backed CLI repository
    When I invoke "config set --local refstore.kind github"
    Then the auth CLI command succeeds
    When I invoke "doc list"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "--repo owner/name"

  Scenario: global config can select GitHub refstore behavior
    Given a temporary git-backed CLI repository
    And a fresh sideshow auth config directory
    When I invoke "config set --global refstore.kind github"
    Then the auth CLI command succeeds
    When I invoke "--repo owner/repo --credential-helper env doc list"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "no GitHub credentials configured"

  Scenario: literal credential-shaped config key is rejected
    Given a temporary git-backed CLI repository
    When I invoke "config set --local github.token ghp_secret_token"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "unknown config key: github.token"
    And the auth CLI did not write config files
