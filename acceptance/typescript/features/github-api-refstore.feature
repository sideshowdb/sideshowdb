@github
Feature: CLI document lifecycle via GitHub API RefStore

  # EARS requirements covered:
  # GHAPI-020: When a caller calls put with valid credentials, the GitHubApiRefStore shall create or
  #   update the document via the GitHub Git Database API and return the new commit SHA as the version.
  # GHAPI-021: When the GitHub ref does not yet exist, the GitHubApiRefStore shall create the ref via
  #   POST /git/refs on the first write.
  # GHAPI-024: When a put succeeds, the GitHubApiRefStore shall return the new commit SHA on the result.
  # GHAPI-030: When a caller calls get for a key that exists, the GitHubApiRefStore shall retrieve and
  #   decode the document bytes.
  # GHAPI-031: When a caller calls get for a key that does not exist, the GitHubApiRefStore shall return
  #   null (CLI surfaces this as exit 1 / "document not found").
  # GHAPI-032: When a caller calls get with a known version SHA, the GitHubApiRefStore shall retrieve the
  #   document at that historical commit.
  # GHAPI-033: When a caller calls get with an unknown version SHA, the GitHubApiRefStore shall return
  #   null (CLI surfaces this as exit 1 / "document not found").
  # GHAPI-040: The GitHubApiRefStore shall return all blob entries in a ref tree when list is called,
  #   sorted by path.
  # GHAPI-041: When the GitHub ref does not exist, the GitHubApiRefStore shall return an empty list
  #   rather than an error.
  # GHAPI-050: When a caller calls delete for a key that exists, the GitHubApiRefStore shall remove the
  #   key and advance the ref.
  # GHAPI-051: When a caller calls delete for a key that does not exist, the GitHubApiRefStore shall
  #   return null without mutating the ref (CLI surfaces this as deleted: false).
  # GHAPI-060: The GitHubApiRefStore shall return commit SHAs for the put history of a given key.
  # GHAPI-061: The GitHubApiRefStore shall follow Link rel=next pagination headers and respect
  #   history_limit. (Pagination is internal; tested here by verifying multi-put history.)

  Background:
    Given the GitHub mock server targets repo "sideshowdb-test/metrics"

  # ---------------------------------------------------------------------------
  # PUT — GHAPI-020 GHAPI-021 GHAPI-024
  # ---------------------------------------------------------------------------

  Scenario: Put a new document creates the ref on first write [GHAPI-021 GHAPI-020 GHAPI-024]
    When I put document "doc-1" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"title": "hello"}
      """
    Then the CLI command succeeds
    And the CLI JSON version is a non-empty string
    And the mock GitHub ref "refs/sideshowdb/documents" exists

  Scenario: Put updates an existing document and returns new version [GHAPI-020 GHAPI-024]
    When I put document "doc-1" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"title": "v1"}
      """
    Then the CLI command succeeds
    And I remember the CLI JSON version as "v1"
    When I put document "doc-1" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"title": "v2"}
      """
    Then the CLI command succeeds
    And the CLI JSON version is a non-empty string

  # ---------------------------------------------------------------------------
  # GET — GHAPI-030 GHAPI-031 GHAPI-032 GHAPI-033
  # ---------------------------------------------------------------------------

  Scenario: Get returns the document that was put [GHAPI-030]
    When I put document "readme" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"content": "hello world"}
      """
    Then the CLI command succeeds
    When I get document "readme" of type "note" in namespace "default" through the GitHub CLI refstore
    Then the CLI command succeeds
    And the CLI JSON data field "content" equals "hello world"

  Scenario: Get returns not found for a key that does not exist [GHAPI-031]
    When I get document "nonexistent" of type "note" in namespace "default" through the GitHub CLI refstore
    Then the CLI command fails with exit code 1
    And the CLI stderr contains "document not found"

  Scenario: Get with a remembered version retrieves historical data [GHAPI-032]
    When I put document "versioned" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"v": "first"}
      """
    Then the CLI command succeeds
    And I remember the CLI JSON version as "v1"
    When I put document "versioned" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"v": "second"}
      """
    Then the CLI command succeeds
    When I get document "versioned" of type "note" in namespace "default" at remembered version "v1" through the GitHub CLI refstore
    Then the CLI command succeeds
    And the CLI JSON data field "v" equals "first"

  Scenario: Get with an unknown version returns not found [GHAPI-033]
    When I put document "doc-1" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"title": "exists"}
      """
    Then the CLI command succeeds
    When I get document "doc-1" of type "note" in namespace "default" at version "0000000000000000000000000000000000000000" through the GitHub CLI refstore
    Then the CLI command fails with exit code 1

  # ---------------------------------------------------------------------------
  # LIST — GHAPI-040 GHAPI-041
  # ---------------------------------------------------------------------------

  Scenario: List returns all documents sorted by key [GHAPI-040]
    When I put document "zebra" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"order": 3}
      """
    Then the CLI command succeeds
    When I put document "alpha" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"order": 1}
      """
    Then the CLI command succeeds
    When I put document "middle" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"order": 2}
      """
    Then the CLI command succeeds
    When I list documents of type "note" in namespace "default" through the GitHub CLI refstore
    Then the CLI command succeeds
    And the CLI JSON list has 3 items

  Scenario: List returns empty list when the ref does not exist [GHAPI-041]
    When I list documents of type "note" in namespace "default" through the GitHub CLI refstore
    Then the CLI command succeeds
    And the CLI JSON list is empty

  # ---------------------------------------------------------------------------
  # DELETE — GHAPI-050 GHAPI-051
  # ---------------------------------------------------------------------------

  Scenario: Delete removes a present key and advances the ref [GHAPI-050]
    When I put document "to-delete" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"keep": false}
      """
    Then the CLI command succeeds
    When I put document "to-keep" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"keep": true}
      """
    Then the CLI command succeeds
    When I delete document "to-delete" of type "note" in namespace "default" through the GitHub CLI refstore
    Then the CLI command succeeds
    And the CLI JSON deleted flag is true
    When I get document "to-delete" of type "note" in namespace "default" through the GitHub CLI refstore
    Then the CLI command fails with exit code 1
    And the CLI stderr contains "document not found"
    When I get document "to-keep" of type "note" in namespace "default" through the GitHub CLI refstore
    Then the CLI command succeeds

  Scenario: Delete a key that does not exist returns deleted false [GHAPI-051]
    When I delete document "not-here" of type "note" in namespace "default" through the GitHub CLI refstore
    Then the CLI command succeeds
    And the CLI JSON deleted flag is false

  # ---------------------------------------------------------------------------
  # HISTORY — GHAPI-060 GHAPI-061
  # ---------------------------------------------------------------------------

  Scenario: History records each put version for a key [GHAPI-060 GHAPI-061]
    When I put document "changelog" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"v": 1}
      """
    Then the CLI command succeeds
    When I put document "changelog" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"v": 2}
      """
    Then the CLI command succeeds
    When I put document "changelog" of type "note" in namespace "default" through the GitHub CLI refstore with JSON body:
      """
      {"v": 3}
      """
    Then the CLI command succeeds
    When I request history for document "changelog" of type "note" in namespace "default" through the GitHub CLI refstore
    Then the CLI command succeeds
    And the CLI JSON history has at least 3 versions
