import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import type {
  LoadSideshowdbClientOptions,
  SideshowdbCoreClient,
  SideshowdbDeleteResult,
  SideshowdbDocumentEnvelope,
  SideshowdbListResult,
} from '@sideshowdb/core'

import {
  createIndexedDbHostStoreEffect,
  fromCoreClient,
  loadSideshowdbEffectClient,
} from './index'

describe('sideshowdb effect client', () => {
  it('wraps successful core operations in Effect', async () => {
    const client = fromCoreClient(
      makeCoreClient({
        list: async () => ({
          ok: true,
          value: {
            kind: 'summary',
            items: [],
            next_cursor: null,
          } satisfies SideshowdbListResult,
        }),
      }),
    )

    const result = await Effect.runPromise(client.list({ type: 'issue' }))
    expect(result.items).toEqual([])
  })

  it('defers core operations until the Effect is run', async () => {
    let calls = 0
    const client = fromCoreClient(
      makeCoreClient({
        list: async () => {
          calls += 1

          return {
            ok: true,
            value: {
              kind: 'summary',
              items: [],
              next_cursor: null,
            } satisfies SideshowdbListResult,
          }
        },
      }),
    )

    const effect = client.list({ type: 'issue' })

    expect(calls).toBe(0)

    await Effect.runPromise(effect)

    expect(calls).toBe(1)
  })

  it('fails the effect when the core client returns an operation failure', async () => {
    const client = fromCoreClient(
      makeCoreClient({
        delete: async () => ({
          ok: false,
          error: { kind: 'host-store', message: 'missing store' },
        }),
      }),
    )

    const exit = await Effect.runPromiseExit(
      client.delete({ type: 'issue', id: 'a' }),
    )

    expect(JSON.parse(JSON.stringify(exit))).toMatchObject({
      _tag: 'Failure',
      cause: {
        _tag: 'Fail',
        failure: {
          kind: 'host-store',
        },
      },
    })
  })

  it('fails get in the Effect error channel when the core client returns an operation failure', async () => {
    const client = fromCoreClient(
      makeCoreClient({
        get: async () => ({
          ok: false,
          error: { kind: 'decode', message: 'bad payload' },
        }),
      }),
    )

    const exit = await Effect.runPromiseExit(
      client.get({ type: 'issue', id: 'issue-1' }),
    )

    expect(JSON.parse(JSON.stringify(exit))).toMatchObject({
      _tag: 'Failure',
      cause: {
        _tag: 'Fail',
        failure: {
          kind: 'decode',
        },
      },
    })
  })

  it('supports monadic chaining across put and get', async () => {
    const client = fromCoreClient(makeCoreClient())

    const title = await Effect.runPromise(
      Effect.gen(function* () {
        const put = yield* client.put({
          type: 'issue',
          id: 'issue-1',
          data: { title: 'Issue 1' },
        })
        const got = yield* client.get<{ title: string }>({
          type: put.type,
          id: put.id,
        })

        if (!got.found) {
          return yield* Effect.fail({
            kind: 'decode' as const,
            message: 'Expected a document after put.',
          })
        }

        return got.value.data.title
      }),
    )

    expect(title).toBe('Issue 1')
  })

  it('preserves successful get not-found results', async () => {
    const client = fromCoreClient(
      makeCoreClient({
        get: async () => ({
          ok: true,
          found: false,
        }),
      }),
    )

    const result = await Effect.runPromise(
      client.get({ type: 'issue', id: 'missing' }),
    )

    expect(result).toEqual({
      ok: true,
      found: false,
    })
  })

  it('fails the loader in the Effect error channel when the runtime cannot be loaded', async () => {
    const exit = await Effect.runPromiseExit(
      loadSideshowdbEffectClient({
        wasmPath: '/missing/sideshowdb.wasm',
        fetchImpl: async () => ({
          ok: false,
          arrayBuffer: async () => new ArrayBuffer(0),
        }),
      }),
    )

    expect(JSON.parse(JSON.stringify(exit))).toMatchObject({
      _tag: 'Failure',
      cause: {
        _tag: 'Fail',
        failure: {
          kind: 'runtime-load',
        },
      },
    })
  })

  it('fails IndexedDB store creation in the Effect error channel when IndexedDB is unavailable', async () => {
    const originalIndexedDb = (globalThis as { indexedDB?: unknown }).indexedDB
    delete (globalThis as { indexedDB?: unknown }).indexedDB

    try {
      const exit = await Effect.runPromiseExit(createIndexedDbHostStoreEffect())
      expect(JSON.parse(JSON.stringify(exit))).toMatchObject({
        _tag: 'Failure',
        cause: {
          _tag: 'Fail',
          failure: {
            kind: 'runtime-load',
          },
        },
      })
    } finally {
      ;(globalThis as { indexedDB?: unknown }).indexedDB = originalIndexedDb
    }
  })
})

function makeCoreClient(
  overrides: Partial<SideshowdbCoreClient> = {},
): SideshowdbCoreClient {
  const defaultDocument = <T>(data: T): SideshowdbDocumentEnvelope<T> => ({
    namespace: 'default',
    type: 'issue',
    id: 'issue-1',
    version: 'v1',
    data,
  })

  const summaryItem = {
    namespace: 'default',
    type: 'issue',
    id: 'issue-1',
    version: 'v1',
  }

  const defaultListResult: SideshowdbListResult = {
    kind: 'summary',
    items: [summaryItem],
    next_cursor: null,
  }

  const defaultDeleteResult: SideshowdbDeleteResult = {
    namespace: summaryItem.namespace,
    type: summaryItem.type,
    id: summaryItem.id,
    deleted: true,
  }

  const baseClient: SideshowdbCoreClient = {
    banner: 'sideshowdb',
    version: '0.0.0',
    put: async <T = unknown>() => ({
      ok: true,
      value: defaultDocument({ title: 'Issue 1' } as T),
    }),
    get: async <T = unknown>() => ({
      ok: true,
      found: true,
      value: defaultDocument({ title: 'Issue 1' } as T),
    }),
    list: async () => ({
      ok: true,
      value: defaultListResult,
    }),
    delete: async () => ({
      ok: true,
      value: defaultDeleteResult,
    }),
    history: async () => ({
      ok: true,
      value: defaultListResult,
    }),
  }

  return {
    ...baseClient,
    ...overrides,
  }
}
