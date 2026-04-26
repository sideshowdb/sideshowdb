# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

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
- Use `shall` (normative). Avoid `should`, `may`, `might`, `try to`.
- One responsibility per statement. Split compound requirements.
- Make the response observable — assertable from outside the system.
- Store EARS requirements alongside the feature: in the `bd` issue (`--description` or `--acceptance`), in the PR body, or in a `docs/requirements/` markdown file when long-lived.
- A PR adding a user-facing change without EARS statements is incomplete.

## Build & Test

_Add your build and test commands here_

```bash
# Example:
# npm install
# npm test
```

## Architecture Overview

_Add a brief overview of your project architecture_

## Conventions & Patterns

_Add your project-specific conventions here_
