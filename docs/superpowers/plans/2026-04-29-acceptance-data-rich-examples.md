# Acceptance Data-Rich Examples Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand the TypeScript Cucumber acceptance suite with richer docstring- and table-driven examples that cover real document payloads, namespace-aware flows, and version-sensitive reads without weakening the existing safety net during refactoring.

**Architecture:** Add new requirement-first scenarios before rewriting the minimal lifecycle scenarios. Extend the Cucumber step layer with shared docstring/table parsing helpers and public-contract assertions for CLI, WASM, and IndexedDB/default-client flows, then refactor older scenarios to reuse the richer vocabulary after the stronger suite is green.

**Tech Stack:** Cucumber, Bun, TypeScript, Zig CLI/WASM artifacts, `@sideshowdb/core`, `fake-indexeddb`

---

### Task 1: Add rich CLI acceptance scenarios first

**Files:**
- Modify: `acceptance/typescript/features/cli-document-lifecycle.feature`
- Modify: `acceptance/typescript/src/steps/cli.steps.ts`
- Inspect as needed: `acceptance/typescript/src/support/cli.ts`

- [ ] Add new CLI scenarios that use JSON docstrings for document bodies and Cucumber tables for expected list/history results.
- [ ] Cover at least one namespace-aware flow and one version-targeted retrieval flow through the public CLI contract.
- [ ] Keep the existing minimal CLI scenarios intact until the richer scenarios pass.

### Task 2: Add rich WASM acceptance scenarios first

**Files:**
- Modify: `acceptance/typescript/features/wasm-document-lifecycle.feature`
- Modify: `acceptance/typescript/src/steps/wasm.steps.ts`
- Inspect as needed: `acceptance/typescript/src/support/wasm.ts`

- [ ] Add new WASM scenarios that use docstrings for realistic JSON payloads and tables for collection/history expectations.
- [ ] Cover namespace-aware and version-targeted public API reads through `@sideshowdb/core`.
- [ ] Keep the existing minimal WASM scenarios intact until the richer scenarios pass.

### Task 3: Extend IndexedDB/default-client examples where the richer data helps

**Files:**
- Modify: `acceptance/typescript/features/indexeddb-host-store.feature`
- Modify: `acceptance/typescript/src/steps/indexeddb.steps.ts`

- [ ] Upgrade the default-client persistence example to use richer document payloads.
- [ ] Add table-driven assertions only where they strengthen the public persistence contract instead of adding noise.

### Task 4: Refactor the step vocabulary after the richer scenarios are green

**Files:**
- Modify: `acceptance/typescript/src/steps/cli.steps.ts`
- Modify: `acceptance/typescript/src/steps/wasm.steps.ts`
- Modify: `acceptance/typescript/src/steps/indexeddb.steps.ts`
- Modify if needed: `acceptance/typescript/src/support/world.ts`

- [ ] Extract shared helpers for JSON docstrings, expected table rows, and repeated document assertions.
- [ ] Rewrite or expand the older minimal scenarios to use the richer step language only after the new scenarios are stable.
- [ ] Preserve public-contract assertions and avoid assertions on internal bridge/storage seams.

### Task 5: Verify the expanded acceptance harness

**Files:**
- No source changes expected.

- [ ] Run the targeted acceptance workspace build and rich scenario slices during each red-green-refactor loop.
- [ ] Finish with the relevant acceptance suite plus targeted binding tests needed to prove the expanded harness still passes end to end.
- [ ] Report any remaining coverage gap explicitly if a requirement still lacks a rich scenario.
