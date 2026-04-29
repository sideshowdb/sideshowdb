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
  createIndexedDbHostStoreEffect,
  loadSideshowDbEffectClient,
} from '@sideshowdb/effect'

const program = Effect.gen(function* () {
  const hostStore = yield* createIndexedDbHostStoreEffect({
    dbName: 'sideshowdb-refstore',
    onPersistenceError: (error) => {
      // Async write-behind failures and connection-loss events surface here.
      console.error('sideshowdb persistence warning', error)
    },
  })
  const client = yield* loadSideshowDbEffectClient({
    wasmPath: '/wasm/sideshowdb.wasm',
    hostCapabilities: { store: hostStore },
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
store creation.

### Durability and lifecycle

The IndexedDB store applies writes to an in-memory cache synchronously, then
persists them to IndexedDB via a write-behind queue. If a queued write fails or
another tab closes the connection via `versionchange`, the store invokes the
`onPersistenceError` callback (or logs to `console.error` when none is
provided). The cache keeps the latest values, but they are not durable until a
successful write follows. Treat the callback as a durability warning and
re-create the store if you need to resume persistence.

Call `hostStore.close()` when finished (for example on tab unload) to drain
pending writes and release the IndexedDB connection.
