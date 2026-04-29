import { readFile } from 'node:fs/promises'

import 'fake-indexeddb/auto'
import { describe, expect, it } from 'vitest'

import {
  createSideshowdbClientFromExports,
  loadSideshowdbClient,
  type SideshowdbHostStore,
  type SideshowdbWasmExports,
} from './client'

const wasmFixturePath = new URL('../../../../zig-out/wasm/sideshowdb.wasm', import.meta.url)

describe('sideshowdb core client', () => {
  it('emits explicit .js extensions for runtime ESM entrypoint specifiers', async () => {
    const builtIndexPath = new URL('../dist/index.js', import.meta.url)
    const builtIndex = await readFile(builtIndexPath, 'utf8')

    expect(builtIndex).toContain("export * from './types.js';")
    expect(builtIndex).toContain("export { loadSideshowdbClient } from './client.js';")

    await expect(import(builtIndexPath.href)).resolves.toMatchObject({
      loadSideshowdbClient: expect.any(Function),
    })
  })

  it('keeps the root package public exports focused on the supported API', async () => {
    const root = await import('./index')

    expect(root.loadSideshowdbClient).toBeTypeOf('function')
    expect('createSideshowdbClientFromExports' in root).toBe(false)
  })

  it('loads runtime metadata from the wasm client', async () => {
    const client = await loadFixtureClient(makeMemoryConnector())

    expect(client.banner).toContain('sideshowdb')
    expect(client.version).toMatch(/^\d+\.\d+\.\d+$/)
  })

  it('maps the distinct get not-found status to a not-found success result', async () => {
    const client = createSideshowdbClientFromExports(
      makeFakeExports({ getStatus: 2, resultJson: '' }),
      makeMemoryConnector(),
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
      makeMemoryConnector(),
    )
    const result = await client.get({ id: 'missing' } as never)

    expect(result.ok).toBe(false)
    if (result.ok) {
      throw new Error('expected failure')
    }

    expect(result.error.kind).toBe('wasm-export')
  })

  it('exposes put, list, history, and delete through the public client surface', async () => {
    const client = await loadFixtureClient(makeMemoryConnector())

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

  it('round-trips documents through the in-WASM memory backend without a host store', async () => {
    const client = await loadFixtureClient(undefined, { indexedDb: false })

    const put = await client.put({
      type: 'issue',
      id: 'issue-mem',
      data: { title: 'no-bridge' },
    })
    if (!put.ok) {
      throw new Error(`expected put success, received ${put.error.kind}: ${put.error.message}`)
    }

    const got = await client.get<{ title: string }>({
      type: 'issue',
      id: 'issue-mem',
    })
    expect(got.ok).toBe(true)
    if (!got.ok) throw new Error('expected get success')
    expect(got.found).toBe(true)
    if (!got.found) throw new Error('expected document to exist')
    expect(got.value.data).toEqual({ title: 'no-bridge' })
  })

  it('defaults to IndexedDB persistence in browser-like runtimes', async () => {
    const dbName = `sideshowdb-core-test-${Date.now()}`
    const firstClient = await loadFixtureClient(undefined, { indexedDb: { dbName } })
    const firstPut = await firstClient.put({
      type: 'issue',
      id: 'issue-idb-default',
      data: { title: 'persisted' },
    })
    expect(firstPut.ok).toBe(true)

    const secondClient = await loadFixtureClient(undefined, { indexedDb: { dbName } })
    const persisted = await secondClient.get<{ title: string }>({
      type: 'issue',
      id: 'issue-idb-default',
    })

    expect(persisted.ok).toBe(true)
    if (!persisted.ok) {
      throw new Error('expected get success')
    }
    expect(persisted.found).toBe(true)
    if (!persisted.found) {
      throw new Error('expected persisted document')
    }
    expect(persisted.value.data).toEqual({ title: 'persisted' })
  })

  it('raises a runtime-load failure when the wasm runtime cannot be fetched', async () => {
    await expect(
      loadSideshowdbClient({
        wasmPath: '/missing/sideshowdb.wasm',
        fetchImpl: async () => ({
          ok: false,
          arrayBuffer: async () => new ArrayBuffer(0),
        }),
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

  it('prefers an explicit host store over the default IndexedDB store when both are supplied', async () => {
    const calls: string[] = []
    const store = new Map<string, Array<{ version: string; value: string }>>()
    const explicitStore: SideshowdbHostStore = {
      put(key, value) {
        calls.push(`put:${key}`)
        const history = store.get(key) ?? []
        const version = `v${history.length + 1}`
        history.unshift({ version, value })
        store.set(key, history)
        return version
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
    }

    const client = await loadFixtureClient(explicitStore, {
      indexedDb: { dbName: `sideshowdb-precedence-test-${Date.now()}` },
    })
    await client.put({ type: 'issue', id: 'prec-1', data: { title: 'x' } })

    expect(calls).toContain('put:default/issue/prec-1.json')
  })

  it('rejects promise-returning host store implementations from untyped callers', async () => {
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

    expect(result.error.kind).toBe('host-store')
    expect(result.error.message).toContain('put')
  })
})

async function loadFixtureClient(
  hostStore?: SideshowdbHostStore,
  options?: { indexedDb?: false | { dbName?: string; storeName?: string } },
) {
  const bytes = await readFile(wasmFixturePath)

  return loadSideshowdbClient({
    wasmPath: '/fixtures/sideshowdb.wasm',
    hostCapabilities: { store: hostStore },
    indexedDb: options?.indexedDb,
    fetchImpl: async () =>
      ({
        ok: true,
        arrayBuffer: async () =>
          bytes.buffer.slice(
            bytes.byteOffset,
            bytes.byteOffset + bytes.byteLength,
          ) as ArrayBuffer,
      }),
  })
}

function makeMemoryConnector(): SideshowdbHostStore {
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
