# IndexedDB Acceptance Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tighten IndexedDB EARS and acceptance coverage so the public browser persistence contract, usable bridge behavior, and reload durability boundary are all explicitly tested.

**Architecture:** Keep the change localized to requirements docs and the TypeScript acceptance workspace. Add failing acceptance scenarios first, then minimally extend the IndexedDB Cucumber steps/support helpers so the new scenarios assert real public behavior instead of only object creation or same-process visibility.

**Tech Stack:** Markdown specs, Cucumber, Bun, TypeScript, fake-indexeddb, `@sideshowdb/core`, `@sideshowdb/effect`

---

### Task 1: Tighten the requirements mapping

**Files:**
- Modify: `docs/development/specs/indexeddb-host-store-ears.md`
- Modify: `docs/development/specs/typescript-bindings-and-wasm-browser-bridge-ears.md`

- [ ] Add EARS covering the documented default `loadSideshowdbClient` IndexedDB behavior and its acceptance mapping.
- [ ] Keep the existing bridge-constructor EARS, but clarify that the acceptance suite proves observable, user-facing behavior.

### Task 2: Add failing acceptance scenarios first

**Files:**
- Modify: `acceptance/typescript/features/indexeddb-host-store.feature`

- [ ] Strengthen the “usable host store” scenario so it performs a real `put`/`get` through the Effect-created store.
- [ ] Replace the loose durability scenario with one that crosses a close/reopen boundary.
- [ ] Add acceptance coverage for the documented default `loadSideshowdbClient` browser persistence path.

### Task 3: Extend acceptance steps minimally

**Files:**
- Modify: `acceptance/typescript/src/steps/indexeddb.steps.ts`
- Modify: `acceptance/typescript/src/support/world.ts`
- Modify: `acceptance/typescript/src/support/hooks.ts`
- Inspect as needed: `acceptance/typescript/src/support/wasm.ts`

- [ ] Add step helpers needed to close/reopen bridges deterministically.
- [ ] Add step helpers needed to load the public client without an explicit `hostCapabilities.store` and assert persisted reads after reopen.
- [ ] Preserve isolation by cleaning up any extra IndexedDB handles in the After hook.

### Task 4: Verify targeted coverage

**Files:**
- No source changes expected.

- [ ] Run the targeted IndexedDB acceptance tag suite and confirm the strengthened scenarios pass.
- [ ] Run the relevant TypeScript unit suites that cover the same public surfaces when possible in the current workspace state.
- [ ] Report any remaining verification gap clearly if a prerequisite artifact such as `zig-out/wasm/sideshowdb.wasm` is still missing.
