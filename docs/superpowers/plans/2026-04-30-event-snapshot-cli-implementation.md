# Event And Snapshot CLI Implementation Plan

**Goal:** Ship the public native CLI surface for `EventStore` and `SnapshotStore` that was explicitly deferred as a non-goal in the core store design, so operators and scripts can append/load events and manage snapshots over Git-backed refs without going through WASM or TypeScript first.

**Architecture:** CLI subcommands use dedicated `SubprocessGitRefStore` instances rooted at `refs/sideshowdb/events` and `refs/sideshowdb/snapshots`, independent of the document ref (`refs/sideshowdb/documents`). Handlers call the same core `EventStore` / `SnapshotStore` APIs as unit tests. JSON output is stable, line-oriented objects for scripting.

**Tech Stack:** Zig 0.16, canonical KDL usage spec (`src/cli/usage/sideshowdb.usage.kdl`), generated `sideshowdb_cli_generated_usage`, Cucumber (`@cli`), beads (`sideshowdb-v71`).

---

## Context

### Approved design (source of scope)

- [Event and snapshot store design](https://github.com/sideshowdb/sideshowdb/blob/main/docs/superpowers/specs/2026-04-30-event-and-snapshot-store-design.md) — § Non-Goals listed “Adding CLI commands for event append/load or snapshot management”; this PR implements the follow-up tracked as `sideshowdb-v71`.

### User-facing requirements (EARS)

- [Event and snapshot CLI EARS](../../development/specs/event-and-snapshot-cli-ears.md) — EVT-CLI-001–009 and SNAP-CLI-001–005; Cucumber scenarios reference these IDs in feature comments.

### Tracking

- Beads: **`sideshowdb-v71`** — Public CLI surface for event and snapshot stores (child of epic `sideshowdb-asz`).

### Worktree

- Implemented in: `.worktrees/sideshowdb-v71-superpowers` on branch `feature/sideshowdb-v71-superpowers`.

---

## Delivered surface

### Commands (KDL → generated parser → `app.zig`)

| Command | Behavior |
|--------|------------|
| `event append` | JSONL or JSON (`events` array) batch; `--namespace`, `--aggregate-type`, `--aggregate-id`; optional `--expected-revision`; optional `--data-file` (wins over stdin). |
| `event load` | Stream replay in append order; optional `--from-revision` (inclusive). |
| `snapshot put` | Revision + `--up-to-event-id` + state JSON (stdin or `--state-file`); optional `--metadata-file`. |
| `snapshot get` | `--latest` or default latest behavior; `--at-or-before <rev>` for bounded lookup; mutually exclusive combination of latest + at-or-before rejected as usage error. |
| `snapshot list` | Newest-first metadata list as JSON `items` array. |

### Refstore policy (this PR)

- **Subprocess:** Fully supported for event and snapshot commands.
- **GitHub (`--refstore github`):** Event and snapshot commands return a clear error string (`event and snapshot commands require --refstore subprocess`) because the GitHub native path is not yet wired for alternate refs for these stores in the same invocation model as documents. Follow-up can align with `sideshowdb-idg` / GitHub refstore roadmap.

---

## Files touched

| Area | Path |
|------|------|
| Usage spec | `src/cli/usage/sideshowdb.usage.kdl` |
| CLI runtime | `src/cli/app.zig` (handlers, JSON encoders, subprocess-only guard for github) |
| Generated docs | `site/src/routes/docs/cli/+page.md` (via `zig build cli:sync-docs`) |
| Site test | `site/src/routes/docs/cli-reference.test.ts` |
| Acceptance | `acceptance/typescript/features/cli-event-snapshot-lifecycle.feature` |
| Steps | `acceptance/typescript/src/steps/cli.steps.ts` |
| EARS | `docs/development/specs/event-and-snapshot-cli-ears.md` |

---

## Verification

- [x] `zig build` / `zig build test`
- [x] `bash scripts/run-js-acceptance.sh -- --tags "@cli"` (includes new scenarios)
- [x] `bun run --cwd site test` (CLI reference doc contract)

---

## Follow-ups (out of scope here)

- Wire `event` / `snapshot` CLI to `--refstore github` with correct ref and credential flow (see beads `sideshowdb-idg` and related refstore issues).
- WASM / TypeScript APIs for the same stores (`sideshowdb-2mv`).
- Docs/playground walkthrough for end-to-end event-sourced workflow (`sideshowdb-fed`).
