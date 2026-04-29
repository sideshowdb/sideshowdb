# TypeScript Cucumber Acceptance Layer Design

## Goal

Add a repo-level TypeScript Cucumber acceptance harness that exercises
Sideshowdb through stable public contracts rather than implementation seams.
The first slice should stay intentionally small: one end-to-end document
lifecycle through the native CLI and one equivalent lifecycle through the
shipped WASM TypeScript binding surface.

This design covers `sideshowdb-28n`.

Related follow-up:

- `sideshowdb-4py` — expand acceptance coverage beyond the minimal lifecycle
  slice into namespace, version, and broader parity scenarios

## Scope

### In scope

- A dedicated `acceptance/typescript` Bun workspace package
- Cucumber-based acceptance scenarios
- CLI acceptance via subprocess execution of the built `sideshowdb` binary
- WASM acceptance via the public `@sideshowdb/core` package and shipped
  `sideshowdb.wasm` artifact
- One happy-path document lifecycle scenario per surface
- One failure-path scenario per surface
- Zig-orchestrated execution through a dedicated `build.zig` step

### Out of scope

- Exhaustive parity coverage for all document features
- Human-readable CLI output formatting coverage
- npm publishability checks beyond the release automation already added
- Namespace/version edge-case breadth beyond the first slice

## Requirements Mapping

The issue requires:

- CLI acceptance coverage through command execution and observable
  stdout/stderr behavior
- WASM acceptance coverage through the shipped artifact and stable public
  binding contracts
- document `put`, `get`, `list`, `history`, and `delete` assertions through
  published TypeScript interfaces where those are exposed
- a Zig-owned entrypoint for the acceptance suite

This design maps those requirements directly onto two scenario families:

1. CLI contract scenarios using `--json`
2. WASM binding contract scenarios using `@sideshowdb/core`

## Recommended Approach

Create one dedicated workspace package at `acceptance/typescript`.

Why this is the best fit:

- It keeps acceptance tests separate from implementation-unit tests.
- It lets CLI and WASM scenarios share fixtures and common language.
- It preserves a clear “external contract” boundary for future growth.
- It matches the repo’s existing root Bun workspace and Zig orchestration
  model.

Alternatives considered:

### Split acceptance by surface

Separate CLI and WASM acceptance packages would isolate concerns, but they
would duplicate setup and make cross-surface parity harder to maintain.

### Layer Cucumber into existing packages

This is cheaper short term, but it blurs the boundary between implementation
tests and public acceptance tests, which weakens the purpose of `sideshowdb-28n`.

## Architecture

The acceptance layer will live in a new root workspace package:

```text
acceptance/
  typescript/
    package.json
    tsconfig.json
    cucumber.js
    features/
    src/
      support/
      steps/
```

The root `package.json` workspace list will include `acceptance/typescript`.

`build.zig` will gain a dedicated step, likely `js:acceptance`, that runs the
underlying Bun command from the repo root. Zig remains the top-level
orchestrator.

## Scenario Shape

The first acceptance slice will cover one logical document identity and one
single lifecycle:

1. `put`
2. `get`
3. `list` or `history`
4. `delete`

This lifecycle will be exercised twice:

- once through the CLI using `--json`
- once through the WASM binding API via `@sideshowdb/core`

### CLI happy path

The CLI scenario will:

- create an isolated temporary repo/work directory
- run the built CLI executable as a subprocess
- call `doc put`, `doc get`, `doc list` or `doc history`, and `doc delete`
- assert JSON response payloads only

### CLI failure path

The first failure path will cover one invalid or incomplete request and assert:

- non-zero exit status
- observable stderr output

It will not assert presentation formatting beyond the public failure contract.

### WASM happy path

The WASM scenario will:

- load the shipped `sideshowdb.wasm`
- construct the public `@sideshowdb/core` client
- drive the same minimal document lifecycle through the public client methods
- assert typed success payloads from the binding surface

### WASM failure path

The first failure path will assert one typed client-side failure outcome
through the public API, without relying on internal host-import or request
buffer details.

## Components

### `features/`

Owns the Gherkin scenarios for the minimal public contract. These files should
stay readable to someone who understands the product but not the internals.

### `src/steps/cli/`

Owns CLI-specific step definitions. These translate Gherkin steps into CLI
subprocess calls and JSON/stderr assertions.

### `src/steps/wasm/`

Owns WASM-specific step definitions. These translate Gherkin steps into
operations over the public `@sideshowdb/core` client.

### `src/support/`

Owns shared fixtures:

- temp directory setup/teardown
- temporary git repo initialization
- CLI executable discovery
- WASM artifact discovery
- shared document identities and payload builders
- scenario-local state container

## Data Flow

### CLI path

1. Scenario fixture creates an isolated temp repo.
2. Step definitions invoke the built CLI executable.
3. CLI responses are captured from stdout/stderr/exit code.
4. Assertions validate only the documented public contract.

### WASM path

1. Scenario fixture locates the shipped `.wasm` artifact.
2. Step definitions load the public TypeScript binding.
3. The binding drives operations through the public API surface.
4. Assertions validate typed results and observable failures.

## Isolation Strategy

Each scenario gets fresh state:

- its own temp directory
- its own initialized backing repo when needed
- its own lifecycle document identity
- no shared mutable state across scenarios

This avoids test bleed and keeps failures attributable to one public behavior.

## Boundary Rules

This suite must remain a public-contract harness, not a second copy of the
implementation tests.

### CLI boundary

Allowed assertions:

- JSON stdout
- stderr presence/content
- exit status

Not allowed:

- refstore internals
- temp file layout
- implementation-only helper output

### WASM boundary

Allowed assertions:

- behavior through `@sideshowdb/core`
- behavior against the shipped `sideshowdb.wasm`
- typed success/failure results

Not allowed:

- direct assertions on request-buffer mechanics
- internal import/export plumbing details
- implementation-only hooks

## Failure Handling

The acceptance suite should fail loudly when prerequisites are missing:

- if the CLI executable cannot be located
- if the shipped WASM artifact is unavailable
- if the acceptance workspace is not wired into the root Bun workspace
- if the Zig acceptance step is missing

These should surface as clear harness/setup failures, not confusing scenario
mismatches.

## Build Integration

The acceptance package will expose a Bun command that runs the Cucumber suite.

`build.zig` will add a dedicated step that shells out to that command from the
repo root. The step should depend on the prerequisites needed to make the
public surfaces testable, similar to the existing `js:*` orchestration.

Recommended flow:

- root workspace includes acceptance package
- package exposes an acceptance script
- `build.zig` exposes `js:acceptance`

This keeps acceptance coverage opt-in and clearly separated from the existing
unit/integration test steps.

## Testing Plan

The first implementation should verify:

- the acceptance package is part of the root Bun workspace
- a minimal CLI happy-path scenario passes
- a minimal CLI failure-path scenario passes
- a minimal WASM happy-path scenario passes
- a minimal WASM failure-path scenario passes
- the Zig acceptance step runs the suite from the repo root

## Risks And Mitigations

### Risk: the suite drifts into implementation testing

Mitigation:
keep step definitions limited to public boundaries and move shared mechanics
into fixture helpers.

### Risk: scenario setup becomes brittle

Mitigation:
centralize temp repo, CLI path, and WASM path discovery in `src/support/`
rather than duplicating setup logic in steps.

### Risk: the first slice tries to cover too much

Mitigation:
keep the initial suite to one lifecycle plus one failure path per surface and
push breadth expansion into `sideshowdb-4py`.

## Follow-Up Work

After the first harness lands, `sideshowdb-4py` should expand the suite into:

- namespace-aware document flows
- version-targeted retrieval coverage
- broader parity scenarios across CLI and WASM surfaces

## Acceptance Summary

This design satisfies `sideshowdb-28n` by introducing a dedicated TypeScript
Cucumber acceptance workspace that:

- exercises the CLI through subprocess execution and observable outputs
- exercises the WASM surface through the shipped artifact and public binding
  API
- keeps Zig as the top-level orchestrator
- starts with a minimal lifecycle slice and defers breadth expansion to a
  tracked follow-up issue
