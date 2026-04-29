# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Design documentation

Long-lived design rationale (ADRs, RFCs) is indexed in
[`docs/design/README.md`](docs/design/README.md). Link new decisions from PRs
and from `bd` issues (`--design`, `--description`, or `--notes`) so the trace
survives search and `bd prime`.

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BEADS INTEGRATION v:1 profile:full hash:f65d5d33 -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Dolt-powered version control with native sync
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update <id> --claim --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task atomically**: `bd update <id> --claim`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Quality
- Use `--acceptance` and `--design` fields when creating issues
- Use `--validate` to check description completeness

### Lifecycle
- `bd defer <id>` / `bd supersede <id>` for issue management
- `bd stale` / `bd orphans` / `bd lint` for hygiene
- `bd human <id>` to flag for human decisions
- `bd formula list` / `bd mol pour <name>` for structured workflows

### Auto-Sync

bd automatically syncs via Dolt:

- Each write auto-commits to Dolt history
- Use `bd dolt push`/`bd dolt pull` for remote sync
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

<!-- END BEADS INTEGRATION -->

## Test-Driven Development (TDD)

This project follows **TDD with the Red-Green-Refactor cycle**. Tests are not optional, and they are not an afterthought.

### Red-Green-Refactor

1. **Red** — Write a failing test first. Confirm it fails for the *right reason* (not a typo, missing import, or compile error masking intent).
2. **Green** — Write the minimal production code needed to make the test pass. No more.
3. **Refactor** — Clean up code and tests with the safety net of green tests. Re-run after every change.

### Test Quality Bar

Every change must include high-quality tests. A passing happy-path test alone is **not sufficient**. Tests must cover:

- **Happy path** — the canonical, expected-success scenario.
- **Negative tests** — invalid input, error paths, failure modes, permission denials, malformed data, missing dependencies. Assert on the *specific* error/behavior, not just "it failed".
- **Edge cases** — empty inputs, single-element collections, maximum/minimum values, unicode, whitespace, duplicates, ordering, concurrency where relevant.
- **Boundaries** — off-by-one (`n-1`, `n`, `n+1`), zero, negative numbers, overflow/underflow, capacity limits, first/last element, threshold transitions.

### TDD Rules

- No production code without a failing test that demands it.
- A PR with only happy-path tests is incomplete — request or add negative + boundary coverage before merging.
- When fixing a bug, write a regression test that fails on the bug *first*, then fix.
- Prefer many small focused tests over one large test that exercises many things.
- Test names must describe behavior (`returns_error_when_key_is_empty`), not implementation.
- Do not delete or skip tests to make a build green. Fix the underlying issue or file a `bd` issue.

## Acceptance Test Coverage

**User-facing features must ship with acceptance tests.** Unit and integration tests prove the implementation works in isolation; acceptance tests prove the feature works the way a user actually invokes it (CLI binary on disk, WASM artifact loaded into a TS client, etc.).

### When acceptance tests are required

- Any new CLI command, flag, exit code, error message, or output format users observe.
- Any new WASM/TypeScript-binding API surface (new methods, new options, new error kinds).
- Any user-facing behavior change to an existing surface (e.g. precedence rules, defaults, new failure modes).
- A flipped contract (e.g. an operation that previously failed now succeeds, or vice versa) — update the existing scenarios in the same PR; do not leave them asserting the old behavior.

Internal refactors with no observable behavior change do not need new acceptance scenarios, but must not break existing ones.

### Where acceptance tests live

- TypeScript Cucumber suite: [acceptance/typescript/features/](acceptance/typescript/features/) — feature files; [acceptance/typescript/src/steps/](acceptance/typescript/src/steps/) — step definitions; [acceptance/typescript/src/support/](acceptance/typescript/src/support/) — shared world/helpers.
- Run via `zig build js:acceptance`.

### Authoring rules

- **Every EARS statement on a user-facing surface MUST have at least one corresponding Gherkin acceptance scenario.** This is bidirectional: every EARS gets a scenario, and every scenario lists the EARS it covers in the feature file's comment block. If you cannot phrase a scenario for an EARS statement, the EARS is too vague — rewrite it before implementing.
- The EARS-to-scenario mapping is part of the PR — reviewers should be able to walk from each EARS line in the description (or `bd` issue) to a specific scenario in `acceptance/typescript/features/` and back.
- Acceptance scenarios are **in addition to** unit/integration tests, not a substitute. Unit tests prove the implementation; acceptance tests prove the user-visible contract.
- Negative paths (invalid input, missing files, unsupported flags) need their own scenarios — do not bundle them into a happy-path scenario with conditional steps.
- Reuse existing steps when the language matches; introduce new steps only when no existing step expresses the new behavior. Keep step phrasing user-facing ("the CLI command succeeds", not "the spawn returned 0").
- A PR adding a user-facing change without acceptance coverage is incomplete — same bar as missing EARS or missing negative tests.

## EARS Requirements

All **user-facing features** require requirements written in **EARS** (Easy Approach to Requirements Syntax) before implementation. EARS turns vague intent into testable, unambiguous statements that map directly onto TDD test cases.

### When EARS is Required

- Any feature, behavior, or API surface a user (CLI consumer, library caller, admin, end user) interacts with.
- Bug fixes that change observable behavior — capture the corrected requirement.
- Configuration, error messages, exit codes, and output formats users depend on.

Internal-only refactors with no behavior change do not require new EARS statements, but must not violate existing ones.

### EARS Patterns

Use one of the five canonical forms. Each statement names the system under discussion (e.g., `the RefStore`).

1. **Ubiquitous** — always true.
   - `The <system> shall <response>.`
   - Example: `The RefStore shall reject keys longer than 255 bytes.`
2. **Event-driven** — triggered by an event.
   - `When <trigger>, the <system> shall <response>.`
   - Example: `When a put is called with an empty key, the RefStore shall return InvalidKey.`
3. **State-driven** — active while in a state.
   - `While <state>, the <system> shall <response>.`
   - Example: `While the store is read-only, the RefStore shall reject all put operations with ReadOnly.`
4. **Optional feature** — only when feature present.
   - `Where <feature>, the <system> shall <response>.`
   - Example: `Where signing is enabled, the RefStore shall verify signatures before returning a ref.`
5. **Unwanted behavior** — recovery / refusal.
   - `If <unwanted condition>, then the <system> shall <response>.`
   - Example: `If the underlying file is corrupt, then the RefStore shall return Corrupt and not mutate state.`

Combine forms when needed (`When ... while ..., the system shall ...`), but keep one requirement per statement.

### Authoring Rules

- Each EARS statement maps to **at least one test** (happy path, negative, edge, or boundary as appropriate).
- **Each EARS statement on a user-facing surface also maps to at least one Gherkin acceptance scenario** under `acceptance/typescript/features/`. See the "Acceptance Test Coverage" section above; the unit/integration test and the acceptance scenario are both required, not interchangeable.
- Use `shall` (normative). Avoid `should`, `may`, `might`, `try to`.
- One responsibility per statement. Split compound requirements.
- Make the response observable — assertable from outside the system.
- Store EARS requirements alongside the feature: in the `bd` issue (`--description` or `--acceptance`), in the PR body, or in a `docs/requirements/` markdown file when long-lived.
- A PR adding a user-facing change without EARS statements is incomplete.
