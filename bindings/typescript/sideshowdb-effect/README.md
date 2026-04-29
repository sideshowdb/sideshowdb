# `@sideshowdb/effect`

Effect-native bindings layered on top of `@sideshowdb/core`.

## Install

```bash
npm install @sideshowdb/effect @sideshowdb/core effect
```

## Usage

```ts
import { Effect } from 'effect'
import { loadSideshowdbEffectClient } from '@sideshowdb/effect'

const client = await Effect.runPromise(
  loadSideshowdbEffectClient({ wasmPath: '/wasm/sideshowdb.wasm' }),
)
```

The package preserves the document API from `@sideshowdb/core` while returning
Effect values for document operations and runtime loading.
