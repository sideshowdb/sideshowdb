import 'fake-indexeddb/auto'

import { describe, expect, it, vi } from 'vitest'

import { createIndexedDbHostStore } from './indexeddb-store'

function uniqueDbName(label: string): string {
  return `${label}-${crypto.randomUUID()}`
}

describe('indexeddb connector', () => {
  it('adds a missing storeName by upgrading an existing database version', async () => {
    const dbName = uniqueDbName('bridge-upgrade')
    const a = await createIndexedDbHostStore({ dbName, storeName: 'refs-a' })
    await a.close()
    const connector = await createIndexedDbHostStore({ dbName, storeName: 'refs-b' })

    const version = connector.put('k1', 'v1')
    expect(version).toBe('v1')
    await connector.close()

    const reopened = await createIndexedDbHostStore({ dbName, storeName: 'refs-b' })
    expect(reopened.get('k1')).toEqual({ value: 'v1', version: 'v1' })
    await reopened.close()
  })

  it('reports blocked schema-upgrade failures through onPersistenceError', async () => {
    const dbName = uniqueDbName('bridge-upgrade-failure')
    const onPersistenceError = vi.fn<(error: Error) => void>()
    const seed = await createIndexedDbHostStore({ dbName, storeName: 'refs-a' })
    await seed.close()
    const blocker = await openRawDb(dbName)

    await expect(
      createIndexedDbHostStore({
        dbName,
        storeName: 'refs-b',
        onPersistenceError,
      }),
    ).rejects.toBeInstanceOf(Error)
    expect(onPersistenceError).toHaveBeenCalledTimes(1)
    const firstArg = onPersistenceError.mock.calls[0]?.[0]
    expect(firstArg).toBeInstanceOf(Error)

    blocker.close()
  })

  it('persists writes across close and reopen', async () => {
    const dbName = uniqueDbName('bridge-persist-cycle')
    const writer = await createIndexedDbHostStore({ dbName })
    writer.put('k1', 'one')
    writer.put('k1', 'two')
    writer.put('k2', 'two-only')
    writer.delete('k2')
    await writer.close()

    const reader = await createIndexedDbHostStore({ dbName })
    expect(reader.list()).toEqual(['k1'])
    expect(reader.get('k1')).toEqual({ value: 'two', version: 'v2' })
    expect(reader.history('k1')).toEqual(['v2', 'v1'])
    expect(reader.get('k1', 'v1')).toEqual({ value: 'one', version: 'v1' })
    await reader.close()
  })

  it('reports persistence errors when another tab triggers versionchange', async () => {
    const dbName = uniqueDbName('bridge-versionchange')
    const onPersistenceError = vi.fn<(error: Error) => void>()
    const connector = await createIndexedDbHostStore({
      dbName,
      onPersistenceError,
    })

    // Force a versionchange by opening the same DB at a higher version.
    await new Promise<void>((resolve, reject) => {
      const request = indexedDB.open(dbName, 99)
      request.onsuccess = () => {
        request.result.close()
        resolve()
      }
      request.onerror = () => reject(request.error ?? new Error('open failed'))
      request.onblocked = () => reject(new Error('open blocked'))
    })

    expect(onPersistenceError).toHaveBeenCalled()
    const firstArg = onPersistenceError.mock.calls[0]?.[0]
    expect(firstArg).toBeInstanceOf(Error)
    expect((firstArg as Error).message).toMatch(/versionchange/i)

    await connector.close()
  })

  it('uses monotonically increasing numeric versions when stored versions are malformed', async () => {
    const dbName = uniqueDbName('bridge-version-malformed')
    const storeName = 'refs'
    await seedRecord(dbName, storeName, {
      key: 'k1',
      versions: [
        { version: 'corrupt', value: 'a' },
        { version: 'v3', value: 'b' },
      ],
    })

    const connector = await createIndexedDbHostStore({ dbName, storeName })
    const next = connector.put('k1', 'c')
    expect(next).toBe('v4')
    await connector.close()
  })
})

async function openRawDb(dbName: string): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(dbName)
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error('Unable to open raw IndexedDB.'))
  })
}

async function seedRecord(
  dbName: string,
  storeName: string,
  record: { key: string; versions: Array<{ version: string; value: string }> },
): Promise<void> {
  const db = await new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open(dbName, 1)
    request.onupgradeneeded = () => {
      const upgrading = request.result
      if (!upgrading.objectStoreNames.contains(storeName)) {
        upgrading.createObjectStore(storeName, { keyPath: 'key' })
      }
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error('Unable to seed IndexedDB.'))
  })

  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(storeName, 'readwrite')
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error ?? new Error('Unable to write seed record.'))
    tx.objectStore(storeName).put(record)
  })

  db.close()
}
