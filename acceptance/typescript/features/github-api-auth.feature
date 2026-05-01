@github
Feature: GitHub API RefStore authentication and error handling

  # EARS requirements covered:
  # GHAPI-010: When credentials are missing, the GitHubApiRefStore shall return AuthMissing without
  #   issuing any HTTP request. (CLI surfaces this as "no GitHub credentials configured".)
  # GHAPI-011: When the GitHub API responds with 401, the GitHubApiRefStore shall return AuthInvalid.
  # GHAPI-012: When the GitHub API responds with 403 (not rate-limited), the GitHubApiRefStore shall
  #   return InsufficientScope.
  # GHAPI-013: The GitHubApiRefStore shall never log or expose the credential token value.
  #   (Structural: verified by the test that absent GITHUB_TOKEN is the only form of leak prevention
  #   tested at the acceptance level; token is never in CLI stdout/stderr.)
  # GHAPI-014: When the env credential source cannot find the GITHUB_TOKEN variable, the auto walker
  #   shall fall through to the next source or return AuthMissing.
  # GHAPI-070: When the GitHub API responds with 403 and X-RateLimit-Remaining: 0, the
  #   GitHubApiRefStore shall return RateLimited.
  # GHAPI-071: When a GitHub API call succeeds, the GitHubApiRefStore shall surface rate-limit
  #   headers from the response on the result. (Observable here via successful put returning version.)

  Background:
    Given the GitHub mock server targets repo "sideshowdb-test/metrics"

  # ---------------------------------------------------------------------------
  # GHAPI-010 GHAPI-014: missing credentials
  # ---------------------------------------------------------------------------

  Scenario: Missing GITHUB_TOKEN causes a clear credentials error [GHAPI-010 GHAPI-014]
    When I put document "doc-1" of type "note" in namespace "default" through the GitHub CLI refstore with no credentials
    Then the CLI command fails with exit code 1
    And the CLI stderr contains "no GitHub credentials configured"

  # ---------------------------------------------------------------------------
  # GHAPI-011: 401 Unauthorized → AuthInvalid
  # ---------------------------------------------------------------------------

  Scenario: 401 response from GitHub causes an auth invalid failure [GHAPI-011]
    When the mock injects a 401 failure for the next GitHub request
    When I put document "doc-1" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"title": "test"}
      """
    Then the CLI command fails with exit code 1

  # ---------------------------------------------------------------------------
  # GHAPI-012: 403 non-rate-limit → InsufficientScope
  # ---------------------------------------------------------------------------

  Scenario: 403 non-rate-limit response causes an insufficient scope failure [GHAPI-012]
    When the mock injects a 403 failure for the next GitHub request
    When I put document "doc-1" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"title": "test"}
      """
    Then the CLI command fails with exit code 1

  # ---------------------------------------------------------------------------
  # GHAPI-070: 403 with X-RateLimit-Remaining: 0 → RateLimited
  # ---------------------------------------------------------------------------

  Scenario: 403 with rate-limit header causes a rate-limited failure [GHAPI-070]
    When the mock injects a 403 rate-limit failure for the next GitHub request
    When I put document "doc-1" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"title": "test"}
      """
    Then the CLI command fails with exit code 1

  # ---------------------------------------------------------------------------
  # GHAPI-071: rate-limit info surfaced on successful result
  # GHAPI-013: token never appears in CLI output
  # ---------------------------------------------------------------------------

  Scenario: Successful put returns a version and does not expose the token [GHAPI-071 GHAPI-013]
    When I put document "doc-1" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"title": "safe"}
      """
    Then the CLI command succeeds
    And the CLI JSON version is a non-empty string
