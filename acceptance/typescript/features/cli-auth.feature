@cli @auth
Feature: CLI auth subcommands

  # EARS:
  # - When `sideshowdb auth status` is invoked and no hosts are configured, the CLI shall exit with code 0 and print "No authenticated hosts." (CLIA-010).
  # - When `sideshowdb gh auth login --with-token` is invoked, the CLI shall persist the token under hosts.toml and exit 0 (CLIA-030).
  # - If `--with-token` is supplied and stdin is empty after trimming, then the CLI shall exit 1 with "empty token" on stderr and not modify hosts.toml (CLIA-031).
  # - When the prompt or stdin produces a token containing whitespace, the CLI shall reject it without modifying hosts.toml (CLIA-034).
  # - When `sideshowdb --json auth status` runs against a configured host, the CLI shall emit a JSON object with a token_preview but no full token (CLIA-012).
  # - When `sideshowdb auth logout --host <h>` is invoked for a known host, the CLI shall remove the entry and exit 0 (CLIA-020).
  # - When `sideshowdb auth logout --host <h>` is invoked for an unknown host, the CLI shall exit 1 with "not logged in" (CLIA-021).
  # - When `sideshowdb --refstore github` is invoked without `--repo`, the CLI shall exit 1 before any HTTP request (CLIA-050).

  Scenario: auth status reports no hosts when hosts.toml is absent
    Given a fresh sideshowdb auth config directory
    When I invoke "auth status"
    Then the auth CLI command succeeds
    And the auth CLI stdout equals "No authenticated hosts.\n"

  Scenario: gh auth login with --with-token persists the PAT and never echoes it
    Given a fresh sideshowdb auth config directory
    When I invoke "gh auth login --with-token --skip-verify" with stdin "ghp_acceptance_login_xyz12\n"
    Then the auth CLI command succeeds
    And the auth CLI stdout contains "Logged in to github.com"
    And the auth CLI stdout does not contain "ghp_acceptance_login_xyz12"
    When I invoke "--json auth status"
    Then the auth CLI command succeeds
    And the auth CLI stdout contains "github.com"
    And the auth CLI stdout contains "hosts-file"
    And the auth CLI stdout does not contain "ghp_acceptance_login_xyz12"

  Scenario: gh auth login --with-token rejects empty stdin without writing hosts.toml
    Given a fresh sideshowdb auth config directory
    When I invoke "gh auth login --with-token --skip-verify" with stdin "\n"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "empty token"
    When I invoke "auth status"
    Then the auth CLI stdout equals "No authenticated hosts.\n"

  Scenario: gh auth login rejects tokens that contain whitespace
    Given a fresh sideshowdb auth config directory
    When I invoke "gh auth login --with-token --skip-verify" with stdin "ghp_with space\n"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "whitespace"

  Scenario: auth logout removes the named host and is loud about unknown hosts
    Given a fresh sideshowdb auth config directory
    When I invoke "gh auth login --with-token --skip-verify" with stdin "ghp_logout_acceptance_qwert\n"
    Then the auth CLI command succeeds
    When I invoke "auth logout --host ghe.example.com"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "not logged in to ghe.example.com"
    When I invoke "auth logout --host github.com"
    Then the auth CLI command succeeds
    When I invoke "auth status"
    Then the auth CLI stdout equals "No authenticated hosts.\n"

  Scenario: --refstore github without --repo fails before any HTTP request
    When I invoke "--refstore github doc list"
    Then the auth CLI exit code is 1
    And the auth CLI stderr contains "--repo owner/name"
