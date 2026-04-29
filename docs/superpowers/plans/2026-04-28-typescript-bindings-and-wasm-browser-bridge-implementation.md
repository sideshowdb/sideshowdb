# TypeScript Bindings And WASM Browser Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class TypeScript bindings for the shipped WASM artifact, move the docs site onto the public binding package, and integrate the new Bun workspace under `build.zig`.

**Architecture:** Introduce a root Bun workspace that owns `site` plus two public TypeScript packages under `bindings/typescript/`. Keep the Zig WASM module as the source of truth for document behavior, add an explicit request-buffer export for safe browser writes, implement the vanilla TypeScript binding against that export and the imported ref-store host ABI, then layer an Effect package and site consumption on top. Keep Zig as the top-level build orchestrator by making `build.zig` drive the Bun workspace tasks.

**Tech Stack:** Zig 0.16, Bun workspaces, TypeScript 5, Vitest, SvelteKit 5, Effect, `build.zig`, `zwasm`, beads (`bd`)

**Tracked follow-up issues already filed:**
- `sideshowdb-28n` — TypeScript Cucumber acceptance layer for CLI and WASM
- `sideshowdb-2hw` — release automation for TypeScript binding packages

---

## File Map

- Create: `docs/development/specs/typescript-bindings-and-wasm-browser-bridge-ears.md`
  Responsibility: long-lived EARS requirements for the user-facing JS/TS binding and browser bridge contract.
- Create: `scripts/verify-js-workspace.sh`
  Responsibility: smoke-check the root Bun workspace and package manifests.
- Create: `package.json`
  Responsibility: root Bun workspace manifest and cross-project scripts.
- Create: `tsconfig.base.json`
  Responsibility: shared TypeScript compiler baseline for the binding packages.
- Create: `bindings/typescript/sideshowdb-core/package.json`
  Responsibility: public vanilla TypeScript binding package manifest.
- Create: `bindings/typescript/sideshowdb-core/tsconfig.json`
  Responsibility: build/test compiler settings for the core package.
- Create: `bindings/typescript/sideshowdb-core/src/index.ts`
  Responsibility: public exports for the core package.
- Create: `bindings/typescript/sideshowdb-core/src/types.ts`
  Responsibility: request/response/error/host-bridge public types.
- Create: `bindings/typescript/sideshowdb-core/src/client.ts`
  Responsibility: load the WASM module, wire host imports, write request buffers, decode results, expose document operations.
- Create: `bindings/typescript/sideshowdb-core/src/client.test.ts`
  Responsibility: unit and integration-style tests for the vanilla TypeScript client.
- Create: `bindings/typescript/sideshowdb-effect/package.json`
  Responsibility: public Effect binding package manifest.
- Create: `bindings/typescript/sideshowdb-effect/tsconfig.json`
  Responsibility: build/test compiler settings for the Effect package.
- Create: `bindings/typescript/sideshowdb-effect/src/index.ts`
  Responsibility: Effect-native wrapper over the vanilla TypeScript client.
- Create: `bindings/typescript/sideshowdb-effect/src/index.test.ts`
  Responsibility: tests for Effect wrappers and error conversion.
- Modify: `site/package.json`
  Responsibility: depend on the workspace binding package instead of a private site-only WASM helper.
- Delete or replace: `site/src/lib/playground/wasm.ts`
  Responsibility: remove the app-local metadata-only wrapper from the canonical path.
- Create: `site/src/lib/playground/demo-ref-host-bridge.ts`
  Responsibility: site-local in-memory host bridge used to demonstrate the public binding package without inventing a browser Git backend.
- Create: `site/src/lib/playground/demo-ref-host-bridge.test.ts`
  Responsibility: verify the demo bridge is good enough to back the WASM document operations used in the playground.
- Modify: `site/src/routes/playground/+page.svelte`
  Responsibility: consume `@sideshowdb/core`, show runtime metadata from the public package, and run a small document-flow demo through the binding.
- Modify: `site/src/routes/playground-page.test.ts`
  Responsibility: prove the route consumes the public binding package and still renders fallback UI when bridging is unavailable.
- Modify: `src/wasm/root.zig`
  Responsibility: expose an explicit guest request buffer for browser-side request writes.
- Modify: `tests/wasm_exports_test.zig`
  Responsibility: lock down the explicit request-buffer export and continued document export behavior.
- Modify: `build.zig`
  Responsibility: integrate root Bun workspace install/test/check/build steps while preserving Zig as the top-level orchestrator.
- Modify: `README.md`
  Responsibility: explain the root Bun workspace and how the bindings fit into repo-level builds.
- Modify: `site/src/routes/docs/getting-started/+page.md`
  Responsibility: document the updated JS/TS workspace and build entrypoints for developers.

## Task 1: Lock The User-Facing Contract And Scaffold The Root Workspace

**Files:**
- Create: `docs/development/specs/typescript-bindings-and-wasm-browser-bridge-ears.md`
- Create: `scripts/verify-js-workspace.sh`
- Create: `package.json`
- Create: `tsconfig.base.json`
- Create: `bindings/typescript/sideshowdb-core/package.json`
- Create: `bindings/typescript/sideshowdb-core/tsconfig.json`
- Create: `bindings/typescript/sideshowdb-effect/package.json`
- Create: `bindings/typescript/sideshowdb-effect/tsconfig.json`
- Modify: `site/package.json`

- [x] **Step 1: Write the long-lived EARS file**

```md
# TypeScript Bindings And WASM Browser Bridge EARS

- When the repo’s JavaScript and TypeScript projects are installed, the repo
  shall provide a top-level Bun workspace that includes `site`,
  `bindings/typescript/sideshowdb-core`, and
  `bindings/typescript/sideshowdb-effect`.
- When a browser consumer uses the core TypeScript binding package, the package
  shall expose first-class document `put`, `get`, `list`, `history`, and
  `delete` operations backed by the shipped `sideshowdb.wasm` artifact.
- When the core TypeScript binding invokes a WASM document operation, the
  binding shall manage request-buffer writes and result-buffer reads internally
  rather than requiring application code to manipulate raw guest memory.
- When a WASM-backed `get` request does not resolve a document, the TypeScript
  binding shall report a distinct not-found outcome rather than a generic
  operational failure.
- If the WASM runtime cannot be loaded, then the TypeScript binding shall
  report a runtime-load failure with explicit error signaling.
- If the host bridge required by the WASM module is unavailable or incomplete,
  then the TypeScript binding shall report a host-bridge failure with explicit
  error signaling.
- When the docs site uses browser-side SideshowDB bindings, the site shall
  consume the public `bindings/typescript/sideshowdb-core` package rather than
  treating a site-local WASM wrapper as the canonical client.
- When repo-wide JS/TS build tasks run, the repo shall keep `build.zig` as the
  top-level orchestrator for those tasks.
- Where the Effect binding package is provided, the repo shall expose the same
  document operation capabilities through an Effect-native API without changing
  the underlying request/response contract.
```

- [x] **Step 2: Write the failing workspace smoke script**

```bash
#!/usr/bin/env bash
set -euo pipefail

test -f package.json
grep -q '"workspaces"' package.json
test -f tsconfig.base.json
test -f bindings/typescript/sideshowdb-core/package.json
test -f bindings/typescript/sideshowdb-effect/package.json
test -f bindings/typescript/sideshowdb-core/tsconfig.json
test -f bindings/typescript/sideshowdb-effect/tsconfig.json
test -f docs/development/specs/typescript-bindings-and-wasm-browser-bridge-ears.md
```

- [ ] **Step 3: Run the workspace smoke script to prove the scaffold does not exist yet**

Run: `bash scripts/verify-js-workspace.sh`
Expected: FAIL because the root workspace files and binding package manifests do not exist yet.

- [x] **Step 4: Add the root Bun workspace and package skeletons**

```json
{
  "name": "@sideshowdb/workspace",
  "private": true,
  "type": "module",
  "workspaces": [
    "site",
    "bindings/typescript/sideshowdb-core",
    "bindings/typescript/sideshowdb-effect"
  ],
  "scripts": {
    "build": "bun run --cwd bindings/typescript/sideshowdb-core build && bun run --cwd bindings/typescript/sideshowdb-effect build && bun run --cwd site build",
    "check": "bun run --cwd bindings/typescript/sideshowdb-core check && bun run --cwd bindings/typescript/sideshowdb-effect check && bun run --cwd site check",
    "test": "bun run --cwd bindings/typescript/sideshowdb-core test && bun run --cwd bindings/typescript/sideshowdb-effect test && bun run --cwd site test"
  }
}
```

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "skipLibCheck": true,
    "verbatimModuleSyntax": true
  }
}
```

```json
{
  "name": "@sideshowdb/core",
  "version": "0.0.0",
  "type": "module",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "default": "./dist/index.js"
    }
  },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "check": "tsc -p tsconfig.json --noEmit",
    "test": "vitest run"
  },
  "devDependencies": {
    "typescript": "^5.0.0",
    "vitest": "^4.1.5"
  }
}
```

```json
{
  "extends": "../../../tsconfig.base.json",
  "compilerOptions": {
    "rootDir": "src",
    "outDir": "dist",
    "lib": ["ES2022", "DOM"]
  },
  "include": ["src/**/*.ts"]
}
```

```json
{
  "name": "@sideshowdb/effect",
  "version": "0.0.0",
  "type": "module",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "default": "./dist/index.js"
    }
  },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "check": "tsc -p tsconfig.json --noEmit",
    "test": "vitest run"
  },
  "dependencies": {
    "@sideshowdb/core": "workspace:*",
    "effect": "^3.13.0"
  },
  "devDependencies": {
    "typescript": "^5.0.0",
    "vitest": "^4.1.5"
  }
}
```

```json
{
  "extends": "../../../tsconfig.base.json",
  "compilerOptions": {
    "rootDir": "src",
    "outDir": "dist",
    "lib": ["ES2022", "DOM"]
  },
  "include": ["src/**/*.ts"]
}
```

```json
{
  "name": "@sideshowdb/site",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite dev",
    "build": "vite build",
    "build:site": "vite build",
    "build:pages": "bun run build:site",
    "check": "svelte-kit sync && svelte-check --tsconfig ./tsconfig.json",
    "test": "vitest run"
  },
  "dependencies": {
    "@sideshowdb/core": "workspace:*"
  },
  "devDependencies": {
    "@sveltejs/adapter-static": "^3.0.0",
    "@sveltejs/kit": "^2.0.0",
    "@sveltejs/vite-plugin-svelte": "^6.2.4",
    "@sveltepress/theme-default": "^7.3.2",
    "@sveltepress/vite": "^1.3.11",
    "@testing-library/svelte": "^5.0.0",
    "@types/node": "^24.3.1",
    "jsdom": "^25.0.0",
    "svelte": "^5.0.0",
    "svelte-check": "^4.0.0",
    "typescript": "^5.0.0",
    "vite": "^7.2.4",
    "vitest": "^4.1.5"
  }
}
```

- [x] **Step 5: Install the root workspace**

Run: `bun install`
Expected: PASS and create a root `bun.lock` that resolves the three-workspace install graph.

- [ ] **Step 6: Re-run the workspace smoke script**

Run: `bash scripts/verify-js-workspace.sh`
Expected: PASS because the root workspace, package skeletons, and EARS doc now exist.

- [ ] **Step 7: Commit**

```bash
git add docs/development/specs/typescript-bindings-and-wasm-browser-bridge-ears.md scripts/verify-js-workspace.sh package.json tsconfig.base.json bindings/typescript/sideshowdb-core/package.json bindings/typescript/sideshowdb-core/tsconfig.json bindings/typescript/sideshowdb-effect/package.json bindings/typescript/sideshowdb-effect/tsconfig.json site/package.json bun.lock
git commit -m "build: scaffold TS bindings workspace"
```

## Task 2: Export An Explicit WASM Request Buffer

**Files:**
- Modify: `src/wasm/root.zig`
- Modify: `tests/wasm_exports_test.zig`

- [x] **Step 1: Add a failing WASM export test for the request buffer**

```zig
test "compiled wasm exposes explicit request buffer exports" {
    var harness = try WasmHarness.init(std.testing.allocator, std.testing.io);
    defer harness.deinit();

    const request_ptr = try harness.invokeScalar("sideshowdb_request_ptr");
    const request_len = try harness.invokeScalar("sideshowdb_request_len");

    try std.testing.expect(request_ptr > 0);
    try std.testing.expect(request_len >= 4096);
}
```

- [ ] **Step 2: Run the focused WASM export test and confirm it fails**

Run: `zig test tests/wasm_exports_test.zig`
Expected: FAIL because `sideshowdb_request_ptr` and `sideshowdb_request_len` are not exported yet.

- [x] **Step 3: Add an explicit static request buffer export**

```zig
var request_buf: [64 * 1024]u8 align(16) = undefined;

export fn sideshowdb_request_ptr() [*]u8 {
    return &request_buf;
}

export fn sideshowdb_request_len() usize {
    return request_buf.len;
}
```

- [ ] **Step 4: Re-run the focused WASM export test**

Run: `zig test tests/wasm_exports_test.zig`
Expected: PASS, including the new request-buffer export test and the existing document export boundary tests.

- [x] **Step 5: Re-run the full Zig suite to ensure the export addition is safe**

Run: `zig build test --summary all`
Expected: PASS with the existing CLI, document, and WASM tests still green.

- [ ] **Step 6: Commit**

```bash
git add src/wasm/root.zig tests/wasm_exports_test.zig
git commit -m "feat(wasm): export request buffer"
```

## Task 3: Implement The Vanilla TypeScript Binding Package

**Files:**
- Create: `bindings/typescript/sideshowdb-core/src/index.ts`
- Create: `bindings/typescript/sideshowdb-core/src/types.ts`
- Create: `bindings/typescript/sideshowdb-core/src/client.ts`
- Create: `bindings/typescript/sideshowdb-core/src/client.test.ts`

- [x] **Step 1: Write the failing core-package tests for metadata, document operations, and error mapping**

```ts
import { describe, expect, it } from 'vitest'

import {
  createSideshowDbClientFromExports,
  type SideshowDbRefHostBridge,
} from './client'

describe('sideshowdb core client', () => {
  it('maps not-found get results distinctly from operational failures', async () => {
    const client = createSideshowDbClientFromExports(makeFakeExports({ getStatus: 1 }), undefined)
    const result = await client.get({ type: 'issue', id: 'missing' })

    expect(result.ok).toBe(true)
    if (!result.ok) throw new Error('expected success')
    expect(result.found).toBe(false)
  })

  it('exposes list, history, and delete through the public client surface', async () => {
    const bridge = makeMemoryBridge()
    const client = createSideshowDbClientFromExports(makeFakeExports(), bridge)

    await client.put({ type: 'issue', id: 'a', data: { title: 'one' } })
    const list = await client.list({ type: 'issue' })
    const history = await client.history({ type: 'issue', id: 'a' })
    const deleted = await client.delete({ type: 'issue', id: 'a' })

    expect(list.ok).toBe(true)
    expect(history.ok).toBe(true)
    expect(deleted.ok).toBe(true)
  })

  it('returns a host-bridge failure when document operations are used without bridge support', async () => {
    const client = createSideshowDbClientFromExports(makeFakeExports(), undefined)
    const result = await client.put({ type: 'issue', id: 'a', data: { title: 'x' } })

    expect(result.ok).toBe(false)
    if (result.ok) throw new Error('expected failure')
    expect(result.error.kind).toBe('host-bridge')
  })
})
```

- [ ] **Step 2: Run the core-package tests to confirm they fail**

Run: `cd bindings/typescript/sideshowdb-core && bun run test`
Expected: FAIL because the package sources and client implementation do not exist yet.

- [x] **Step 3: Define the public types**

```ts
export type SideshowDbClientErrorKind =
  | 'runtime-load'
  | 'host-bridge'
  | 'wasm-export'
  | 'decode'

export type SideshowDbClientError = {
  kind: SideshowDbClientErrorKind
  message: string
  cause?: unknown
}

export type OperationFailure = {
  ok: false
  error: SideshowDbClientError
}

export type OperationSuccess<T> = {
  ok: true
  value: T
}

export type GetSuccess<T> =
  | { ok: true; found: false }
  | { ok: true; found: true; value: T }

export interface SideshowDbRefHostBridge {
  put(key: string, value: string): Promise<string> | string
  get(key: string, version?: string): Promise<{ value: string; version: string } | null> | { value: string; version: string } | null
  delete(key: string): Promise<void> | void
  list(): Promise<string[]> | string[]
  history(key: string): Promise<string[]> | string[]
}
```

- [x] **Step 4: Implement the core client around the explicit request buffer and imported host bridge**

```ts
const encoder = new TextEncoder()
const decoder = new TextDecoder()

type WasmExports = WebAssembly.Exports & {
  memory: WebAssembly.Memory
  sideshowdb_banner_ptr: () => number
  sideshowdb_banner_len: () => number
  sideshowdb_version_major: () => number
  sideshowdb_version_minor: () => number
  sideshowdb_version_patch: () => number
  sideshowdb_request_ptr: () => number
  sideshowdb_request_len: () => number
  sideshowdb_result_ptr: () => number
  sideshowdb_result_len: () => number
  sideshowdb_document_put: (ptr: number, len: number) => number
  sideshowdb_document_get: (ptr: number, len: number) => number
  sideshowdb_document_list: (ptr: number, len: number) => number
  sideshowdb_document_delete: (ptr: number, len: number) => number
  sideshowdb_document_history: (ptr: number, len: number) => number
}

function writeRequest(exports: WasmExports, request: unknown): { ptr: number; len: number } {
  const json = JSON.stringify(request)
  const bytes = encoder.encode(json)
  const ptr = exports.sideshowdb_request_ptr()
  const cap = exports.sideshowdb_request_len()
  if (bytes.length > cap) {
    throw new Error(`request exceeds wasm request buffer: ${bytes.length} > ${cap}`)
  }

  new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes)
  return { ptr, len: bytes.length }
}

function readResult(exports: WasmExports): string {
  const ptr = exports.sideshowdb_result_ptr()
  const len = exports.sideshowdb_result_len()
  return decoder.decode(new Uint8Array(exports.memory.buffer, ptr, len))
}
```

```ts
export function createSideshowDbClientFromExports(
  exports: WasmExports,
  hostBridge: SideshowDbRefHostBridge | undefined,
) {
  const banner = readUtf8(exports.memory, exports.sideshowdb_banner_ptr(), exports.sideshowdb_banner_len())
  const version = `${exports.sideshowdb_version_major()}.${exports.sideshowdb_version_minor()}.${exports.sideshowdb_version_patch()}`

  async function invoke<T>(
    exportFn: (ptr: number, len: number) => number,
    request: unknown,
    decode: (json: string) => T,
    options?: { allowNotFound?: boolean },
  ): Promise<OperationSuccess<T> | OperationFailure | GetSuccess<T>> {
    try {
      const { ptr, len } = writeRequest(exports, request)
      const status = exportFn(ptr, len)
      if (options?.allowNotFound && status == 1) {
        return { ok: true, found: false }
      }
      if (status != 0) {
        return { ok: false, error: { kind: hostBridge ? 'wasm-export' : 'host-bridge', message: 'WASM document operation failed' } }
      }
      return { ok: true, value: decode(readResult(exports)) }
    } catch (cause) {
      return { ok: false, error: { kind: 'decode', message: 'failed to decode wasm result', cause } }
    }
  }

  return {
    banner,
    version,
    put: (request: unknown) => invoke(exports.sideshowdb_document_put, request, JSON.parse),
    get: (request: unknown) => invoke(exports.sideshowdb_document_get, request, JSON.parse, { allowNotFound: true }),
    list: (request: unknown) => invoke(exports.sideshowdb_document_list, request, JSON.parse),
    delete: (request: unknown) => invoke(exports.sideshowdb_document_delete, request, JSON.parse),
    history: (request: unknown) => invoke(exports.sideshowdb_document_history, request, JSON.parse),
  }
}
```

```ts
export async function loadSideshowDbClient(options: {
  wasmPath: string
  hostBridge?: SideshowDbRefHostBridge
  fetchImpl?: typeof fetch
}): Promise<ReturnType<typeof createSideshowDbClientFromExports>> {
  const fetchImpl = options.fetchImpl ?? fetch
  const response = await fetchImpl(options.wasmPath)
  if (!response.ok) {
    throw new Error('The SideshowDB WASM runtime is unavailable right now.')
  }

  const bytes = await response.arrayBuffer()
  const { instance } = await WebAssembly.instantiate(bytes, makeImports(options.hostBridge))
  return createSideshowDbClientFromExports(instance.exports as WasmExports, options.hostBridge)
}
```

- [x] **Step 5: Export the public API**

```ts
export * from './types'
export {
  createSideshowDbClientFromExports,
  loadSideshowDbClient,
} from './client'
```

- [x] **Step 6: Re-run the core-package test, typecheck, and build**

Run: `cd bindings/typescript/sideshowdb-core && bun run test && bun run check && bun run build`
Expected: PASS, producing `dist/` output and green Vitest coverage for the core package.

- [ ] **Step 7: Commit**

```bash
git add bindings/typescript/sideshowdb-core/src/index.ts bindings/typescript/sideshowdb-core/src/types.ts bindings/typescript/sideshowdb-core/src/client.ts bindings/typescript/sideshowdb-core/src/client.test.ts
git commit -m "feat(bindings): add core TS client"
```

## Task 4: Add The Effect Binding Package

**Files:**
- Create: `bindings/typescript/sideshowdb-effect/src/index.ts`
- Create: `bindings/typescript/sideshowdb-effect/src/index.test.ts`

- [x] **Step 1: Write the failing Effect-package tests**

```ts
import { describe, expect, it } from 'vitest'
import { Effect } from 'effect'

import { fromCoreClient } from './index'

describe('sideshowdb effect client', () => {
  it('wraps successful core operations in Effect', async () => {
    const client = fromCoreClient({
      list: async () => ({ ok: true, value: { items: [] } }),
    } as never)

    const result = await Effect.runPromise(client.list({ type: 'issue' }))
    expect(result.items).toEqual([])
  })

  it('fails the effect when the core client returns an operation failure', async () => {
    const client = fromCoreClient({
      delete: async () => ({ ok: false, error: { kind: 'host-bridge', message: 'missing store' } }),
    } as never)

    await expect(Effect.runPromise(client.delete({ type: 'issue', id: 'a' }))).rejects.toMatchObject({
      kind: 'host-bridge',
    })
  })
})
```

- [ ] **Step 2: Run the Effect-package tests to confirm they fail**

Run: `cd bindings/typescript/sideshowdb-effect && bun run test`
Expected: FAIL because the wrapper implementation does not exist yet.

- [x] **Step 3: Implement a thin Effect wrapper over the core client**

```ts
import { Effect } from 'effect'
import type {
  OperationFailure,
  OperationSuccess,
} from '@sideshowdb/core'

import { loadSideshowDbClient } from '@sideshowdb/core'

function unwrap<T>(result: OperationSuccess<T> | OperationFailure): T {
  if (!result.ok) throw result.error
  return result.value
}

export function fromCoreClient(client: Awaited<ReturnType<typeof loadSideshowDbClient>>) {
  return {
    banner: client.banner,
    version: client.version,
    put: (request: unknown) => Effect.promise(() => client.put(request).then(unwrap)),
    list: (request: unknown) => Effect.promise(() => client.list(request).then(unwrap)),
    delete: (request: unknown) => Effect.promise(() => client.delete(request).then(unwrap)),
    history: (request: unknown) => Effect.promise(() => client.history(request).then(unwrap)),
    get: (request: unknown) => Effect.promise(() => client.get(request)),
  }
}

export const loadSideshowDbEffectClient = (options: Parameters<typeof loadSideshowDbClient>[0]) =>
  Effect.promise(async () => fromCoreClient(await loadSideshowDbClient(options)))
```

- [x] **Step 4: Re-run the Effect-package test, typecheck, and build**

Run: `cd bindings/typescript/sideshowdb-effect && bun run test && bun run check && bun run build`
Expected: PASS with the wrapper package producing `dist/` output.

- [ ] **Step 5: Commit**

```bash
git add bindings/typescript/sideshowdb-effect/src/index.ts bindings/typescript/sideshowdb-effect/src/index.test.ts
git commit -m "feat(bindings): add effect client"
```

## Task 5: Move The Site Onto The Public Binding Package

**Files:**
- Create: `site/src/lib/playground/demo-ref-host-bridge.ts`
- Create: `site/src/lib/playground/demo-ref-host-bridge.test.ts`
- Modify: `site/src/routes/playground/+page.svelte`
- Modify: `site/src/routes/playground-page.test.ts`
- Delete or replace: `site/src/lib/playground/wasm.ts`

- [x] **Step 1: Write the failing site-side bridge and route tests**

```ts
import { describe, expect, it } from 'vitest'

import { createDemoRefHostBridge } from './demo-ref-host-bridge'

describe('demo ref host bridge', () => {
  it('supports put, list, history, and delete for the wasm document demo', async () => {
    const bridge = createDemoRefHostBridge()

    const first = await bridge.put('documents/default/issue/demo.json', '{"title":"one"}')
    await bridge.put('documents/default/issue/demo.json', '{"title":"two"}')

    expect(await bridge.list()).toContain('documents/default/issue/demo.json')
    expect(await bridge.history('documents/default/issue/demo.json')).toEqual([expect.any(String), first])

    await bridge.delete('documents/default/issue/demo.json')
    expect(await bridge.get('documents/default/issue/demo.json')).toBeNull()
  })
})
```

```ts
import { render, screen } from '@testing-library/svelte'
import { describe, expect, it, vi } from 'vitest'

vi.mock('@sideshowdb/core', () => ({
  loadSideshowDbClient: vi.fn(async () => ({
    banner: 'sideshowdb',
    version: '0.1.0',
    list: async () => ({ ok: true, value: { items: [{ id: 'demo-1' }] } }),
    history: async () => ({ ok: true, value: { items: ['mem-2', 'mem-1'] } }),
    delete: async () => ({ ok: true, value: { deleted: true } }),
    put: async () => ({ ok: true, value: { version: 'mem-1' } }),
    get: async () => ({ ok: true, found: false }),
  })),
}))

it('renders wasm-backed document demo details from the public binding package', async () => {
  render(PlaygroundPage)
  expect(await screen.findByText(/mem-2/i)).toBeTruthy()
  expect(screen.getByText(/sideshowdb/i)).toBeTruthy()
})
```

- [ ] **Step 2: Run the site test slice to confirm it fails**

Run: `cd site && bun run test -- src/lib/playground/demo-ref-host-bridge.test.ts src/routes/playground-page.test.ts`
Expected: FAIL because the demo bridge and binding-based route integration do not exist yet.

- [x] **Step 3: Implement a small in-memory ref host bridge for the playground**

```ts
type StoredVersion = { version: string; value: string }

export function createDemoRefHostBridge() {
  const latest = new Map<string, string>()
  const versions = new Map<string, StoredVersion[]>()
  let nextVersion = 0

  const makeVersion = () => `mem-${++nextVersion}`

  return {
    async put(key: string, value: string) {
      const version = makeVersion()
      const history = versions.get(key) ?? []
      history.unshift({ version, value })
      versions.set(key, history)
      latest.set(key, version)
      return version
    },
    async get(key: string, version?: string) {
      const history = versions.get(key) ?? []
      if (!version) {
        const live = history.find((entry) => entry.version === latest.get(key))
        return live ? { value: live.value, version: live.version } : null
      }
      const match = history.find((entry) => entry.version === version)
      return match ? { value: match.value, version: match.version } : null
    },
    async delete(key: string) {
      latest.delete(key)
    },
    async list() {
      return [...latest.keys()].sort()
    },
    async history(key: string) {
      return (versions.get(key) ?? []).map((entry) => entry.version)
    },
  }
}
```

- [x] **Step 4: Replace the site-local metadata-only wrapper with the public binding package**

```ts
import { loadSideshowDbClient, type SideshowDbRefHostBridge } from '@sideshowdb/core'
```

```ts
const demoBridge = createDemoRefHostBridge()

void loadSideshowDbClient({
  wasmPath: `${base}/wasm/sideshowdb.wasm`,
  hostBridge: demoBridge,
}).then((client) => {
  wasmRuntime = client
})
```

```ts
const demoList = await client.list({ type: 'issue' })
const demoHistory = await client.history({ type: 'issue', id: 'demo-1' })
```

- [x] **Step 5: Re-run the focused site test slice**

Run: `cd site && bun run test -- src/lib/playground/demo-ref-host-bridge.test.ts src/routes/playground-page.test.ts`
Expected: PASS with the route now consuming the public binding package and rendering document-demo output from the binding-backed runtime.

- [x] **Step 6: Re-run the full site test and typecheck commands**

Run: `cd site && bun run test && bun run check`
Expected: PASS across the site workspace.

- [ ] **Step 7: Commit**

```bash
git add site/src/lib/playground/demo-ref-host-bridge.ts site/src/lib/playground/demo-ref-host-bridge.test.ts site/src/routes/playground/+page.svelte site/src/routes/playground-page.test.ts site/src/lib/playground/wasm.ts
git commit -m "feat(site): use public TS wasm client"
```

## Task 6: Integrate The Root Workspace Into `build.zig` And Update Docs

**Files:**
- Modify: `build.zig`
- Modify: `README.md`
- Modify: `site/src/routes/docs/getting-started/+page.md`

- [ ] **Step 1: Add a failing build-graph verification command**

Run: `zig build js:test`
Expected: FAIL because `build.zig` does not expose a `js:test` step yet.

- [x] **Step 2: Add root-workspace Zig steps and retarget site install to the repo root**

```zig
fn buildJsInstall(b: *std.Build) *std.Build.Step {
    const step = b.step("js:install", "Install Bun workspace dependencies");
    const bun = b.addSystemCommand(&.{ "bun", "install" });
    bun.setCwd(b.path("."));
    bun.has_side_effects = true;
    step.dependOn(&bun.step);
    return step;
}

fn buildJsCheck(b: *std.Build, js_install: *std.Build.Step) *std.Build.Step {
    const step = b.step("js:check", "Typecheck the Bun workspace");
    const bun = b.addSystemCommand(&.{ "bun", "run", "check" });
    bun.setCwd(b.path("."));
    bun.step.dependOn(js_install);
    step.dependOn(&bun.step);
    return step;
}

fn buildJsTest(b: *std.Build, js_install: *std.Build.Step) *std.Build.Step {
    const step = b.step("js:test", "Run the Bun workspace tests");
    const bun = b.addSystemCommand(&.{ "bun", "run", "test" });
    bun.setCwd(b.path("."));
    bun.step.dependOn(js_install);
    step.dependOn(&bun.step);
    return step;
}
```

```zig
const js_install_step = buildJsInstall(b);
const js_check_step = buildJsCheck(b, js_install_step);
const js_test_step = buildJsTest(b, js_install_step);
const site_only_step = buildSiteOnly(b, site_assets_step, js_install_step);
_ = js_check_step;
_ = js_test_step;
```

- [x] **Step 3: Update the repo docs for the root Bun workspace**

```md
## JavaScript / TypeScript Workspace

The repo’s JS/TS projects now live under a root Bun workspace:

- `site`
- `bindings/typescript/sideshowdb-core`
- `bindings/typescript/sideshowdb-effect`

Use `bun install` from the repo root, or let `zig build js:install` do it for
you.
```

```md
```bash
bun install
zig build js:test
zig build js:check
zig build site:build
```bash
bun install
zig build js:test
zig build js:check
zig build site:build
```
```

- [ ] **Step 4: Verify the new Zig workspace steps**

Run: `zig build js:install`
Expected: PASS and reuse the root Bun workspace install.

Run: `zig build js:test`
Expected: PASS by running the binding-package tests and the site test suite through the root workspace.

Run: `zig build js:check`
Expected: PASS by typechecking the binding packages and the site through the root workspace.

Run: `zig build site:build`
Expected: PASS with the site still building through the Zig-orchestrated path.

- [ ] **Step 5: Run the final full verification pass**

Run: `zig build test --summary all && zig build js:test && zig build js:check && zig build site:build`
Expected: PASS across the Zig suite, the Bun workspace, and the site build.

- [ ] **Step 6: Commit**

```

- [ ] **Step 4: Verify the new Zig workspace steps**

Run: `zig build js:install`
Expected: PASS and reuse the root Bun workspace install.

Run: `zig build js:test`
Expected: PASS by running the binding-package tests and the site test suite through the root workspace.

Run: `zig build js:check`
Expected: PASS by typechecking the binding packages and the site through the root workspace.

Run: `zig build site:build`
Expected: PASS with the site still building through the Zig-orchestrated path.

- [ ] **Step 5: Run the final full verification pass**

Run: `zig build test --summary all && zig build js:test && zig build js:check && zig build site:build`
Expected: PASS across the Zig suite, the Bun workspace, and the site build.

- [ ] **Step 6: Commit**

```bash
git add build.zig README.md site/src/routes/docs/getting-started/+page.md
git commit -m "build: wire bun workspace into zig"
```

## Self-Review Checklist

- [ ] Spec coverage: the plan covers the root Bun workspace, the core package, the Effect package, the site consuming the public package, explicit request-buffer handling, and `build.zig` orchestration.
- [ ] Placeholder scan: every code-changing step includes exact file paths, concrete code, and explicit verification commands.
- [ ] Type consistency: `@sideshowdb/core` is the canonical package name throughout the plan, `bindings/typescript/` is the stable root, and the public document operations stay `put/get/list/history/delete` across Zig, TypeScript, and site usage.
- [ ] Follow-up work is tracked: `sideshowdb-28n` and `sideshowdb-2hw` exist as out-of-scope beads tasks instead of being left as undocumented future work.
