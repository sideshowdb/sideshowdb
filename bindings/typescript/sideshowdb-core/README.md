# `@sideshowdb/core`

Browser-side TypeScript bindings for the Sideshowdb WASM runtime.

## Install

```bash
npm install @sideshowdb/core
```

## Usage

```ts
import { loadSideshowdbClient } from '@sideshowdb/core'

const client = await loadSideshowdbClient({
  wasmPath: '/wasm/sideshowdb.wasm',
})
```

The package exposes `put`, `get`, `list`, `history`, and `delete` document
operations plus runtime metadata like `banner` and `version`.

In browser environments, `loadSideshowdbClient` now defaults to an
IndexedDB-backed ref host bridge for persistence across reloads. Set
`indexedDb: false` to force volatile in-WASM memory storage.
