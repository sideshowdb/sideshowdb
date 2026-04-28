import { readFile } from 'node:fs/promises'

import { describe, expect, it } from 'vitest'

import {
  createSideshowdbClientFromExports,
  loadSideshowdbClient,
  type SideshowdbRefHostBridge,
  type SideshowdbWasmExports,
} from './client'

const wasmFixturePath = new URL('../../../../zig-out/wasm/sideshowdb.wasm', import.meta.url)

describe('sideshowdb core client', () => {
  it('loads runtime metadata from the wasm client', async () => {
    const client = await loadFixtureClient(makeMemoryBridge())

    expect(client.banner).toContain('sideshowdb')
    expect(client.version).toMatch(/^\d+\.\d+\.\d+$/)
  })

  it('maps the distinct get not-found status to a not-found success result', async () => {
    const client = createSideshowdbClientFromExports(
      makeFakeExports({ getStatus: 2, resultJson: '' }),
      makeMemoryBridge(),
    )
    const result = await client.get({ type: 'issue', id: 'missing' })

    expect(result.ok).toBe(true)
    if (!result.ok) {
      throw new Error('expected success')
    }

    expect(result.found).toBe(false)
  })

  it('treats failed get statuses as operational failures instead of not-found', async () => {
    const client = createSideshowdbClientFromExports(
      makeFakeExports({ getStatus: 1, resultJson: '' }),
      makeMemoryBridge(),
    )
    const result = await client.get({ id: 'missing' } as never)

    expect(result.ok).toBe(false)
    if (result.ok) {
      throw new Error('expected failure')
    }

    expect(result.error.kind).toBe('wasm-export')
  })

  it('exposes put, list, history, and delete through the public client surface', async () => {
    const client = await loadFixtureClient(makeMemoryBridge())

    const firstPut = await client.put({
      type: 'issue',
      id: 'issue-1',
      data: { title: 'one' },
    })
    const secondPut = await client.put({
      type: 'issue',
      id: 'issue-1',
      data: { title: 'two' },
    })
    const current = await client.get<{ title: string }>({ type: 'issue', id: 'issue-1' })
    const list = await client.list({ type: 'issue' })
    const history = await client.history<{ title: string }>({
      type: 'issue',
      id: 'issue-1',
      mode: 'detailed',
    })
    const deleted = await client.delete({ type: 'issue', id: 'issue-1' })

    expect(firstPut.ok).toBe(true)
    expect(secondPut.ok).toBe(true)

    expect(current.ok).toBe(true)
    if (!current.ok) {
      throw new Error('expected get success')
    }
    expect(current.found).toBe(true)
    if (!current.found) {
      throw new Error('expected document to exist')
    }
    expect(current.value.data).toEqual({ title: 'two' })

    expect(list.ok).toBe(true)
    if (!list.ok) {
      throw new Error('expected list success')
    }
    expect(list.value.kind).toBe('summary')
    expect(list.value.items).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          namespace: 'default',
          type: 'issue',
          id: 'issue-1',
          version: expect.any(String),
        }),
      ]),
    )

    expect(history.ok).toBe(true)
    if (!history.ok) {
      throw new Error('expected history success')
    }
    expect(history.value.kind).toBe('detailed')
    if (history.value.kind !== 'detailed') {
      throw new Error('expected detailed history')
    }
    expect(history.value.items).toHaveLength(2)
    expect(history.value.items[0]?.data).toEqual({ title: 'two' })
    expect(history.value.items[1]?.data).toEqual({ title: 'one' })

    expect(deleted.ok).toBe(true)
    if (!deleted.ok) {
      throw new Error('expected delete success')
    }
    expect(deleted.value).toMatchObject({
      namespace: 'default',
      type: 'issue',
      id: 'issue-1',
      deleted: true,
    })
  })

  it('returns a host-bridge failure when document operations are used without bridge support', async () => {
    const client = await loadFixtureClient()
    const result = await client.put({
      type: 'issue',
      id: 'issue-1',
      data: { title: 'x' },
    })

    expect(result.ok).toBe(false)
    if (result.ok) {
      throw new Error('expected failure')
    }

    expect(result.error.kind).toBe('host-bridge')
  })

  it('raises a runtime-load failure when the wasm runtime cannot be fetched', async () => {
    await expect(
      loadSideshowdbClient({
        wasmPath: '/missing/sideshowdb.wasm',
        fetchImpl: async () => new Response(null, { status: 404 }),
      }),
    ).rejects.toMatchObject({
      kind: 'runtime-load',
    })
  })

  it('raises a typed runtime-load failure when fetch is unavailable', async () => {
    await expect(
      loadSideshowdbClient({
        wasmPath: '/fixtures/sideshowdb.wasm',
        fetchImpl: undefined,
      }),
    ).rejects.toMatchObject({
      kind: 'runtime-load',
      cause: expect.any(Error),
    })
  })

  it('rejects promise-returning host bridge implementations from untyped callers', async () => {
    const client = await loadFixtureClient({
      put() {
        return Promise.resolve('v1')
      },
      get() {
        return null
      },
      delete() {},
      list() {
        return []
      },
      history() {
        return []
      },
    } as never)

    const result = await client.put({
      type: 'issue',
      id: 'issue-1',
      data: { title: 'x' },
    })

    expect(result.ok).toBe(false)
    if (result.ok) {
      throw new Error('expected failure')
    }

    expect(result.error.kind).toBe('host-bridge')
    expect(result.error.message).toContain('put')
  })
})

async function loadFixtureClient(hostBridge?: SideshowdbRefHostBridge) {
  const bytes = await readFile(wasmFixturePath)

  return loadSideshowdbClient({
    wasmPath: '/fixtures/sideshowdb.wasm',
    hostBridge,
    fetchImpl: async () =>
      new Response(bytes, {
        status: 200,
        headers: {
          'content-type': 'application/wasm',
        },
      }),
  })
}

function makeMemoryBridge(): SideshowdbRefHostBridge {
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
      if (!version) {
        const latest = history[0]
        return latest ? { value: latest.value, version: latest.version } : null
      }

      const entry = history.find((item) => item.version === version)
      return entry ? { value: entry.value, version: entry.version } : null
    },
    delete(key) {
      store.delete(key)
    },
    list() {
      return Array.from(store.keys()).sort()
    },
    history(key) {
      const entries = store.get(key) ?? []
      return entries.map((entry) => entry.version)
    },
  }
}

function makeFakeExports(options?: {
  getStatus?: number
  resultJson?: string
}): SideshowdbWasmExports {
  const memory = new WebAssembly.Memory({ initial: 1 })
  const requestPtr = 0
  const requestLen = 1024
  const banner = 'sideshowdb'
  const bannerBytes = new TextEncoder().encode(banner)
  const bannerPtr = 2048
  new Uint8Array(memory.buffer, bannerPtr, bannerBytes.length).set(bannerBytes)

  let result = options?.resultJson ?? '{}'

  function writeResult(value: string) {
    result = value
    const bytes = new TextEncoder().encode(value)
    const resultPtr = 3072
    new Uint8Array(memory.buffer, resultPtr, bytes.length).set(bytes)
    return { resultPtr, resultLen: bytes.length }
  }

  return {
    memory,
    sideshowdb_banner_ptr: () => bannerPtr,
    sideshowdb_banner_len: () => bannerBytes.length,
    sideshowdb_version_major: () => 0,
    sideshowdb_version_minor: () => 1,
    sideshowdb_version_patch: () => 0,
    sideshowdb_request_ptr: () => requestPtr,
    sideshowdb_request_len: () => requestLen,
    sideshowdb_result_ptr: () => writeResult(result).resultPtr,
    sideshowdb_result_len: () => writeResult(result).resultLen,
    sideshowdb_document_put: () => 0,
    sideshowdb_document_get: () => options?.getStatus ?? 0,
    sideshowdb_document_list: () => 0,
    sideshowdb_document_delete: () => 0,
    sideshowdb_document_history: () => 0,
  }
}
