@cli
Feature: CLI event and snapshot lifecycle

  # EARS:
  # - When a caller invokes event append with a valid JSONL batch and valid stream identity flags, the CLI shall append the batch and return success output with the resulting stream revision.
  # - When a caller invokes event append with a valid JSON batch and valid stream identity flags, the CLI shall append the batch and return success output with the resulting stream revision.
  # - If event append receives malformed, empty, mixed-stream, or otherwise invalid batch input, then the CLI shall fail with exit code 1 and shall not mutate the stream.
  # - If event append is called with --expected-revision N and the current stream revision is not N, then the CLI shall fail with exit code 1 and a WrongExpectedRevision error without mutating the stream.
  # - When a caller invokes event load with valid stream identity flags and --from-revision R, the CLI shall return events whose revisions are greater than or equal to R.
  # - When a caller invokes snapshot get --latest for a stream with snapshots, the CLI shall return the highest revision snapshot.
  # - When a caller invokes snapshot get --at-or-before R, the CLI shall return the highest snapshot revision less than or equal to R.

  Scenario: Append and load stream events through the CLI
    Given a temporary git-backed CLI repository
    And an event JSONL file "events.jsonl" with events:
      | event_id | event_type   | timestamp            | title  |
      | evt-1    | IssueOpened  | 2026-04-30T12:00:00Z | first  |
      | evt-2    | IssueRenamed | 2026-04-30T12:01:00Z | second |
    When I append events from file "events.jsonl" in format "jsonl" with expected revision 0 through the CLI
    Then the CLI command succeeds
    And the CLI JSON revision is 2
    When I load events from revision 2 through the CLI
    Then the CLI command succeeds
    And the CLI JSON contains event ids:
      | event_id |
      | evt-2    |

  Scenario: Append JSON event batch and fail on wrong expected revision
    Given a temporary git-backed CLI repository
    And an event JSON batch file "batch.json" with events:
      | event_id | event_type   | timestamp            | title  |
      | evt-1    | IssueOpened  | 2026-04-30T12:00:00Z | first  |
    When I append events from file "batch.json" in format "json" with expected revision 0 through the CLI
    Then the CLI command succeeds
    When I append events from file "batch.json" in format "json" with expected revision 0 through the CLI
    Then the CLI command fails with exit code 1
    And the CLI stderr contains "WrongExpectedRevision"

  Scenario: Reject invalid event batch input
    Given a temporary git-backed CLI repository
    And an invalid event batch file "invalid-batch.json" containing:
      """
      {"events":[{"event_type":"missing-id"}]}
      """
    When I append events from file "invalid-batch.json" in format "json" with expected revision 0 through the CLI
    Then the CLI command fails with exit code 1
    And the CLI stderr contains "InvalidEvent"

  Scenario: Put and query snapshots through latest and at-or-before lookups
    Given a temporary git-backed CLI repository
    When I put snapshot revision 2 up to event "evt-2" with state:
      """
      {"status":"open"}
      """
    Then the CLI command succeeds
    When I put snapshot revision 5 up to event "evt-5" with state:
      """
      {"status":"closed"}
      """
    Then the CLI command succeeds
    When I get the latest snapshot through the CLI
    Then the CLI command succeeds
    And the CLI JSON revision is 5
    When I get snapshot at or before revision 4 through the CLI
    Then the CLI command succeeds
    And the CLI JSON revision is 2
