import { Effect } from 'effect'
import { describe, expect, it } from 'vitest'

import { fromCoreClient } from './index'

describe('sideshowdb effect client', () => {
  it('wraps successful core operations in Effect', async () => {
    const client = fromCoreClient({
      banner: 'sideshowdb',
      version: '0.0.0',
      put: async () => ({ ok: true, value: {} }),
      get: async () => ({ ok: true, found: false }),
      list: async () => ({ ok: true, value: { items: [] } }),
      delete: async () => ({ ok: true, value: {} }),
      history: async () => ({ ok: true, value: { items: [] } }),
    } as never)

    const result = await Effect.runPromise(client.list({ type: 'issue' }))
    expect(result.items).toEqual([])
  })

  it('fails the effect when the core client returns an operation failure', async () => {
    const client = fromCoreClient({
      banner: 'sideshowdb',
      version: '0.0.0',
      put: async () => ({ ok: true, value: {} }),
      get: async () => ({ ok: true, found: false }),
      list: async () => ({ ok: true, value: { items: [] } }),
      delete: async () => ({
        ok: false,
        error: { kind: 'host-bridge', message: 'missing bridge' },
      }),
      history: async () => ({ ok: true, value: { items: [] } }),
    } as never)

    const exit = await Effect.runPromiseExit(
      client.delete({ type: 'issue', id: 'a' }),
    )

    expect(JSON.parse(JSON.stringify(exit))).toMatchObject({
      _tag: 'Failure',
      cause: {
        _tag: 'Fail',
        failure: {
          kind: 'host-bridge',
        },
      },
    })
  })
})
