# `@sideshowdb/effect`

Effect-native bindings layered on top of `@sideshowdb/core`.

## Install

```bash
npm install @sideshowdb/effect @sideshowdb/core effect
```

## Usage

```ts
import { Effect } from 'effect'
import {
  createIndexedDbRefHostBridgeEffect,
  loadSideshowdbEffectClient,
} from '@sideshowdb/effect'

const program = Effect.gen(function* () {
  const hostBridge = yield* createIndexedDbRefHostBridgeEffect({
    dbName: 'sideshowdb-refstore',
  })
  const client = yield* loadSideshowdbEffectClient({
    wasmPath: '/wasm/sideshowdb.wasm',
    hostBridge,
  })

  const put = yield* client.put({
    type: 'note',
    id: 'n1',
    data: { title: 'hello' },
  })
  return yield* client.get<{ title: string }>({
    type: put.type,
    id: put.id,
  })
})

const result = await Effect.runPromise(program)
```

The package preserves the document API from `@sideshowdb/core` while returning
Effect values for document operations, runtime loading, and IndexedDB host
bridge creation.
