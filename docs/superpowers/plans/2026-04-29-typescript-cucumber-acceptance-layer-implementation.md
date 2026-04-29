# TypeScript Cucumber Acceptance Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated `acceptance/typescript` Cucumber workspace that exercises one minimal document lifecycle through the CLI `--json` contract and the shipped WASM TypeScript binding surface, with a Zig-owned `js:acceptance` entrypoint.

**Architecture:** The acceptance harness lives in its own Bun workspace package and compiles TypeScript step definitions to `dist/` before running Cucumber over `.feature` files. CLI scenarios invoke `zig-out/bin/sideshowdb` as a subprocess, while WASM scenarios load `zig-out/wasm/sideshowdb.wasm` through `@sideshowdb/core` with a public in-memory host bridge. Root scripts and `build.zig` own prerequisite bootstrapping so the suite is runnable from a clean checkout and from CI.

**Tech Stack:** Bun workspace scripts, TypeScript, `@cucumber/cucumber`, Node stdlib subprocess/fs helpers, Zig build steps, GitHub Actions CI

---

## File Map

- Create: `acceptance/typescript/package.json`
- Create: `acceptance/typescript/tsconfig.json`
- Create: `acceptance/typescript/cucumber.js`
- Create: `acceptance/typescript/features/cli-document-lifecycle.feature`
- Create: `acceptance/typescript/features/wasm-document-lifecycle.feature`
- Create: `acceptance/typescript/src/support/world.ts`
- Create: `acceptance/typescript/src/support/hooks.ts`
- Create: `acceptance/typescript/src/support/cli.ts`
- Create: `acceptance/typescript/src/support/wasm.ts`
- Create: `acceptance/typescript/src/support/memory-ref-host-bridge.ts`
- Create: `acceptance/typescript/src/steps/cli.steps.ts`
- Create: `acceptance/typescript/src/steps/wasm.steps.ts`
- Create: `scripts/run-js-acceptance.sh`
- Create: `scripts/verify-js-acceptance.sh`
- Modify: `.gitignore`
- Modify: `package.json`
- Modify: `build.zig`
- Modify: `README.md`
- Modify: `.github/workflows/ci.yml`

### Task 1: Scaffold The Acceptance Workspace

**Files:**
- Create: `acceptance/typescript/package.json`
- Create: `acceptance/typescript/tsconfig.json`
- Create: `acceptance/typescript/cucumber.js`
- Create: `acceptance/typescript/features/cli-document-lifecycle.feature`
- Create: `acceptance/typescript/features/wasm-document-lifecycle.feature`
- Create: `acceptance/typescript/src/support/world.ts`
- Create: `acceptance/typescript/src/support/hooks.ts`
- Modify: `.gitignore`

- [x] **Step 1: Write the failing acceptance package scaffold and feature files**

```json
{
  "name": "@sideshowdb/acceptance",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "acceptance:raw": "cucumber-js"
  },
  "dependencies": {
    "@sideshowdb/core": "workspace:*"
  },
  "devDependencies": {
    "@cucumber/cucumber": "^11.0.0",
    "@types/node": "^24.3.1",
    "typescript": "^5.0.0"
  }
}
```

```json
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "rootDir": "src",
    "outDir": "dist",
    "lib": ["ES2022", "DOM"],
    "types": ["node"]
  },
  "include": ["src/**/*.ts"]
}
```

```js
export default {
  default: {
    import: ['dist/**/*.js'],
    paths: ['features/**/*.feature'],
    format: ['progress'],
    publishQuiet: true,
  },
}
```

```gherkin
@cli @happy
Scenario: CLI JSON document lifecycle
  Given a temporary git-backed document repo
  When I put document "cli-1" of type "issue" with JSON body through the CLI:
    """
    {"title":"first"}
    """
  Then the CLI command succeeds
```

```gherkin
@wasm @happy
Scenario: WASM binding document lifecycle
  Given a loaded Sideshowdb WASM client with an in-memory host bridge
  When I put document "wasm-1" of type "issue" with JSON body through the WASM client:
    """
    {"title":"first"}
    """
  Then the WASM operation succeeds
```

```ts
import { World, setWorldConstructor } from '@cucumber/cucumber'
import type {
  OperationFailure,
  OperationSuccess,
  SideshowdbCoreClient,
} from '@sideshowdb/core'

export class AcceptanceWorld extends World {
  repoDir?: string
  cliExitCode?: number
  cliStdout = ''
  cliStderr = ''
  cliJson: unknown
  wasmClient?: SideshowdbCoreClient
  wasmResult?: OperationFailure | OperationSuccess<unknown> | unknown
}

setWorldConstructor(AcceptanceWorld)
```

```ts
import { After } from '@cucumber/cucumber'
import { rm } from 'node:fs/promises'

import type { AcceptanceWorld } from './world'

After(async function (this: AcceptanceWorld) {
  if (this.repoDir) {
    await rm(this.repoDir, { recursive: true, force: true })
  }
})
```

- [x] **Step 2: Run the acceptance package to verify it fails before step definitions exist**

Run: `bun install && bun run --cwd acceptance/typescript build && bun run --cwd acceptance/typescript acceptance:raw`
Expected: FAIL before step definitions exist. In practice, the first red run may fail earlier on missing local package binaries until the workspace is wired into the root workspace.

- [x] **Step 3: Wire the new workspace into the repo root**

```json
{
  "workspaces": [
    "site",
    "bindings/typescript/sideshowdb-core",
    "bindings/typescript/sideshowdb-effect",
    "acceptance/typescript"
  ],
  "scripts": {
    "build:acceptance": "bun run --cwd acceptance/typescript build"
  }
}
```

- [x] **Step 4: Re-run the compile and acceptance command**

Run: `bun run --cwd acceptance/typescript build && bun run --cwd acceptance/typescript acceptance:raw`
Expected: FAIL with undefined steps, but the workspace package should compile and Cucumber should discover the feature files.

- [x] **Step 5: Commit**

```bash
git add package.json acceptance/typescript/package.json acceptance/typescript/tsconfig.json acceptance/typescript/cucumber.js acceptance/typescript/features/cli-document-lifecycle.feature acceptance/typescript/features/wasm-document-lifecycle.feature acceptance/typescript/src/support/world.ts acceptance/typescript/src/support/hooks.ts
git commit -m "test(acceptance): scaffold TS cucumber workspace"
```

### Task 2: Implement The CLI Acceptance Slice

**Files:**
- Modify: `acceptance/typescript/features/cli-document-lifecycle.feature`
- Create: `acceptance/typescript/src/support/cli.ts`
- Create: `acceptance/typescript/src/steps/cli.steps.ts`

- [ ] **Step 1: Expand the CLI feature with happy-path and failure-path scenarios**

```gherkin
@cli @happy
Scenario: CLI JSON document lifecycle
  Given a temporary git-backed document repo
  When I put document "cli-1" of type "issue" with JSON body through the CLI:
    """
    {"title":"first"}
    """
  And I put document "cli-1" of type "issue" with JSON body through the CLI:
    """
    {"title":"second"}
    """
  And I get document "cli-1" of type "issue" through the CLI
  Then the CLI command succeeds
  And the CLI JSON field "data.title" equals "second"
  When I list documents of type "issue" through the CLI
  Then the CLI command succeeds
  And the CLI JSON field "kind" equals "summary"
  And the CLI JSON field "items.0.id" equals "cli-1"
  When I request detailed history for document "cli-1" of type "issue" through the CLI
  Then the CLI command succeeds
  And the CLI JSON field "kind" equals "detailed"
  And the CLI JSON array at "items" has length 2
  When I delete document "cli-1" of type "issue" through the CLI
  Then the CLI command succeeds
  And the CLI JSON field "deleted" equals true

@cli @failure
Scenario: CLI invalid arguments return usage failure
  When I run the CLI with invalid put arguments
  Then the CLI command fails
  And stderr contains "usage: sideshowdb"
```

- [ ] **Step 2: Run only the CLI scenarios to verify they fail**

Run: `bun run --cwd acceptance/typescript build && bun run --cwd acceptance/typescript acceptance:raw -- --tags '@cli'`
Expected: FAIL with undefined CLI steps.

- [ ] **Step 3: Implement the CLI helper and step definitions**

```ts
import { mkdtemp } from 'node:fs/promises'
import { spawn } from 'node:child_process'
import { tmpdir } from 'node:os'
import path from 'node:path'

export type CliRunResult = {
  exitCode: number
  stdout: string
  stderr: string
  json?: unknown
}

export async function createTempRepo(): Promise<string> {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'sideshowdb-acceptance-'))
  await runCommand('git', ['init', '--quiet', repoDir], process.cwd())
  return repoDir
}

export async function runSideshowdb(
  repoDir: string,
  args: string[],
  stdin = '',
): Promise<CliRunResult> {
  const cliPath = path.resolve('zig-out/bin/sideshowdb')
  const { exitCode, stdout, stderr } = await runCommand(cliPath, args, repoDir, stdin)
  const trimmed = stdout.trim()

  return {
    exitCode,
    stdout,
    stderr,
    json: trimmed.startsWith('{') ? JSON.parse(trimmed) : undefined,
  }
}
```

```ts
import { Given, Then, When } from '@cucumber/cucumber'
import assert from 'node:assert/strict'

import type { AcceptanceWorld } from '../support/world'
import { createTempRepo, runSideshowdb } from '../support/cli'

Given('a temporary git-backed document repo', async function (this: AcceptanceWorld) {
  this.repoDir = await createTempRepo()
})

When(
  'I put document {string} of type {string} with JSON body through the CLI:',
  async function (this: AcceptanceWorld, id: string, type: string, body: string) {
    assert.ok(this.repoDir)
    const result = await runSideshowdb(
      this.repoDir,
      ['--json', 'doc', 'put', '--type', type, '--id', id],
      body,
    )
    this.cliExitCode = result.exitCode
    this.cliStdout = result.stdout
    this.cliStderr = result.stderr
    this.cliJson = result.json
  },
)
```

```ts
When('I run the CLI with invalid put arguments', async function (this: AcceptanceWorld) {
  const result = await runSideshowdb(process.cwd(), ['doc', 'put', '--type'], '')
  this.cliExitCode = result.exitCode
  this.cliStdout = result.stdout
  this.cliStderr = result.stderr
  this.cliJson = result.json
})

Then('the CLI command succeeds', function (this: AcceptanceWorld) {
  assert.equal(this.cliExitCode, 0)
})

Then('the CLI command fails', function (this: AcceptanceWorld) {
  assert.notEqual(this.cliExitCode, 0)
})
```

- [ ] **Step 4: Run the CLI scenarios again**

Run: `bun run --cwd acceptance/typescript build && bun run --cwd acceptance/typescript acceptance:raw -- --tags '@cli'`
Expected: PASS for the CLI happy-path and failure-path scenarios.

- [ ] **Step 5: Commit**

```bash
git add acceptance/typescript/features/cli-document-lifecycle.feature acceptance/typescript/src/support/cli.ts acceptance/typescript/src/steps/cli.steps.ts
git commit -m "test(acceptance): add CLI cucumber slice"
```

### Task 3: Implement The WASM Acceptance Slice

**Files:**
- Modify: `acceptance/typescript/features/wasm-document-lifecycle.feature`
- Create: `acceptance/typescript/src/support/memory-ref-host-bridge.ts`
- Create: `acceptance/typescript/src/support/wasm.ts`
- Create: `acceptance/typescript/src/steps/wasm.steps.ts`

- [ ] **Step 1: Expand the WASM feature with happy-path and failure-path scenarios**

```gherkin
@wasm @happy
Scenario: WASM binding document lifecycle
  Given a loaded Sideshowdb WASM client with an in-memory host bridge
  When I put document "wasm-1" of type "issue" with JSON body through the WASM client:
    """
    {"title":"first"}
    """
  And I put document "wasm-1" of type "issue" with JSON body through the WASM client:
    """
    {"title":"second"}
    """
  And I get document "wasm-1" of type "issue" through the WASM client
  Then the WASM operation succeeds
  And the WASM document title is "second"
  When I list documents of type "issue" through the WASM client
  Then the WASM operation succeeds
  And the WASM result kind is "summary"
  When I request detailed history for document "wasm-1" of type "issue" through the WASM client
  Then the WASM operation succeeds
  And the WASM history contains 2 entries
  When I delete document "wasm-1" of type "issue" through the WASM client
  Then the WASM operation succeeds
  And the WASM delete result is true

@wasm @failure
Scenario: WASM document writes fail without a host bridge
  Given a loaded Sideshowdb WASM client without a host bridge
  When I put document "wasm-missing-bridge" of type "issue" with JSON body through the WASM client:
    """
    {"title":"missing bridge"}
    """
  Then the WASM operation fails with kind "host-bridge"
```

- [ ] **Step 2: Run only the WASM scenarios to verify they fail**

Run: `zig build wasm && bun run build:bindings && bun run --cwd acceptance/typescript build && bun run --cwd acceptance/typescript acceptance:raw -- --tags '@wasm'`
Expected: FAIL with undefined WASM steps.

- [ ] **Step 3: Implement the in-memory host bridge, WASM loader, and step definitions**

```ts
import type { SideshowdbRefHostBridge } from '@sideshowdb/core'

export function createMemoryRefHostBridge(): SideshowdbRefHostBridge {
  const store = new Map<string, Array<{ version: string; value: string }>>()
  let versionCounter = 0

  return {
    put(key, value) {
      versionCounter += 1
      const version = `v${versionCounter}`
      const history = store.get(key) ?? []
      history.unshift({ version, value })
      store.set(key, history)
      return version
    },
    get(key, version) {
      const history = store.get(key) ?? []
      if (!version) return history[0] ?? null
      return history.find((item) => item.version === version) ?? null
    },
    delete(key) {
      store.delete(key)
    },
    list() {
      return Array.from(store.keys()).sort()
    },
    history(key) {
      return (store.get(key) ?? []).map((item) => item.version)
    },
  }
}
```

```ts
import { readFile } from 'node:fs/promises'
import path from 'node:path'

import { loadSideshowdbClient } from '@sideshowdb/core'
import type { SideshowdbCoreClient, SideshowdbRefHostBridge } from '@sideshowdb/core'

export async function loadAcceptanceClient(
  hostBridge?: SideshowdbRefHostBridge,
): Promise<SideshowdbCoreClient> {
  const wasmPath = path.resolve('zig-out/wasm/sideshowdb.wasm')
  const bytes = await readFile(wasmPath)

  return loadSideshowdbClient({
    wasmPath,
    hostBridge,
    fetchImpl: async () => ({
      ok: true,
      arrayBuffer: async () =>
        bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
    }),
  })
}
```

```ts
import { Given, Then, When } from '@cucumber/cucumber'
import assert from 'node:assert/strict'

import type { AcceptanceWorld } from '../support/world'
import { createMemoryRefHostBridge } from '../support/memory-ref-host-bridge'
import { loadAcceptanceClient } from '../support/wasm'

Given(
  'a loaded Sideshowdb WASM client with an in-memory host bridge',
  async function (this: AcceptanceWorld) {
    this.wasmClient = await loadAcceptanceClient(createMemoryRefHostBridge())
  },
)

Given('a loaded Sideshowdb WASM client without a host bridge', async function (this: AcceptanceWorld) {
  this.wasmClient = await loadAcceptanceClient()
})

Then('the WASM operation fails with kind {string}', function (this: AcceptanceWorld, kind: string) {
  assert.ok(this.wasmResult && typeof this.wasmResult === 'object')
  assert.equal((this.wasmResult as { ok: boolean; error: { kind: string } }).error.kind, kind)
})
```

- [ ] **Step 4: Run the WASM scenarios again**

Run: `zig build wasm && bun run build:bindings && bun run --cwd acceptance/typescript build && bun run --cwd acceptance/typescript acceptance:raw -- --tags '@wasm'`
Expected: PASS for the WASM happy-path and failure-path scenarios.

- [ ] **Step 5: Commit**

```bash
git add acceptance/typescript/features/wasm-document-lifecycle.feature acceptance/typescript/src/support/memory-ref-host-bridge.ts acceptance/typescript/src/support/wasm.ts acceptance/typescript/src/steps/wasm.steps.ts
git commit -m "test(acceptance): add WASM cucumber slice"
```

### Task 4: Add Root Orchestration, Zig Entry Point, And CI Coverage

**Files:**
- Create: `scripts/run-js-acceptance.sh`
- Create: `scripts/verify-js-acceptance.sh`
- Modify: `package.json`
- Modify: `build.zig`
- Modify: `README.md`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the failing root-level acceptance verification script**

```bash
#!/usr/bin/env bash
set -euo pipefail

rm -rf acceptance/typescript/dist
rm -f zig-out/wasm/sideshowdb.wasm
rm -rf bindings/typescript/sideshowdb-core/dist
rm -rf bindings/typescript/sideshowdb-effect/dist

bun run acceptance
zig build js:acceptance
```

- [ ] **Step 2: Run the verification script and confirm it fails**

Run: `bash scripts/verify-js-acceptance.sh`
Expected: FAIL because the repo root does not yet expose `acceptance` / `acceptance:raw` scripts or a `js:acceptance` Zig step.

- [ ] **Step 3: Add the root scripts, Zig step, CI job, and README entry**

```json
{
  "scripts": {
    "build:acceptance": "bun run --cwd acceptance/typescript build",
    "acceptance": "bash scripts/run-js-acceptance.sh",
    "acceptance:raw": "bun run --cwd acceptance/typescript acceptance:raw"
  }
}
```

```bash
#!/usr/bin/env bash
set -euo pipefail

source scripts/ensure-js-workspace-prereqs.sh

ensure_wasm_artifact
ensure_binding_outputs

if [ ! -f zig-out/bin/sideshowdb ]; then
  zig build
fi

bun run build:acceptance
bun run acceptance:raw "$@"
```

```zig
const js_acceptance_build_step = buildJsScriptStep(
    b,
    "js:build-acceptance",
    "Build the TypeScript acceptance workspace from the repo root",
    "build:acceptance",
    js_install_step,
);
_ = buildJsAcceptanceStep(
    b,
    js_install_step,
    wasm_step,
    js_bindings_build_step,
    js_acceptance_build_step,
);
```

```zig
fn buildJsAcceptanceStep(
    b: *std.Build,
    js_install_step: *std.Build.Step,
    wasm_step: *std.Build.Step,
    js_bindings_build_step: *std.Build.Step,
    js_acceptance_build_step: *std.Build.Step,
) *std.Build.Step {
    const step = b.step("js:acceptance", "Run the TypeScript acceptance suite from the repo root");
    const bun = b.addSystemCommand(&.{ "bun", "run", "acceptance:raw" });
    bun.setCwd(b.path("."));
    bun.step.dependOn(js_install_step);
    bun.step.dependOn(js_bindings_build_step);
    bun.step.dependOn(js_acceptance_build_step);
    bun.step.dependOn(wasm_step);
    bun.step.dependOn(b.getInstallStep());
    step.dependOn(&bun.step);
    return step;
}
```

```yaml
  js-acceptance:
    name: JS Acceptance
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Zig
        uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0
          use-cache: true
          cache-key: ${{ github.job }}

      - name: Setup Bun
        uses: oven-sh/setup-bun@v2

      - name: Run public acceptance suite
        run: zig build js:acceptance -Doptimize=ReleaseSafe
```

```md
zig build js:acceptance # run the TypeScript Cucumber public-contract suite
```

- [ ] **Step 4: Run the full acceptance verification and repo JS checks**

Run: `bash scripts/verify-js-acceptance.sh`
Expected: PASS from a wiped acceptance/build state.

Run: `bun run check && bun run test`
Expected: PASS unchanged for the existing root JS workspace lanes after adding the acceptance workspace.

Run: `zig build js:acceptance -Doptimize=ReleaseSafe`
Expected: PASS through the Zig-owned acceptance step.

- [ ] **Step 5: Commit**

```bash
git add package.json build.zig README.md .github/workflows/ci.yml scripts/run-js-acceptance.sh scripts/verify-js-acceptance.sh
git commit -m "ci(acceptance): wire TS cucumber suite"
```

## Self-Review Checklist

- [ ] Spec coverage: the plan adds a dedicated TypeScript Cucumber workspace, covers CLI and WASM public-contract scenarios, keeps the first slice minimal, and exposes a Zig-owned acceptance step.
- [ ] Completeness scan: every code-changing step includes exact file paths, concrete code, and runnable commands, with no unresolved placeholder markers.
- [ ] Type consistency: the plan consistently uses `@sideshowdb/core`, `acceptance/typescript`, `js:acceptance`, and the public document operations `put/get/list/history/delete`.
- [ ] Follow-up breadth work stays tracked out of scope: `sideshowdb-4py` remains the explicit expansion issue for namespace/version and broader parity coverage.
