import 'fake-indexeddb/auto'

import { beforeEach, describe, expect, it, vi } from 'vitest'

import { createIndexedDbRefHostBridge } from './indexeddb-bridge'

describe('indexeddb bridge', () => {
  beforeEach(async () => {
    await clearDatabase('sideshowdb-refstore')
  })

  it('adds a missing storeName by upgrading an existing database version', async () => {
    const dbName = `bridge-upgrade-${Date.now()}`
    await createIndexedDbRefHostBridge({ dbName, storeName: 'refs-a' })
    const bridge = await createIndexedDbRefHostBridge({ dbName, storeName: 'refs-b' })

    const version = bridge.put('k1', 'v1')
    expect(version).toBe('v1')
    await tick()

    const reopened = await createIndexedDbRefHostBridge({ dbName, storeName: 'refs-b' })
    expect(reopened.get('k1')).toEqual({ value: 'v1', version: 'v1' })
  })

  it('reports blocked schema-upgrade failures through onPersistenceError', async () => {
    const dbName = `bridge-upgrade-failure-${Date.now()}`
    const onPersistenceError = vi.fn<(error: Error) => void>()
    await createIndexedDbRefHostBridge({ dbName, storeName: 'refs-a' })
    const blocker = await openRawDb(dbName)

    await expect(
      createIndexedDbRefHostBridge({
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
})

async function openRawDb(dbName: string): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(dbName)
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error('Unable to open raw IndexedDB.'))
  })
}

async function clearDatabase(dbName: string): Promise<void> {
  const db = await openRawDb(dbName)
  db.close()

  await new Promise<void>((resolve, reject) => {
    const request = indexedDB.deleteDatabase(dbName)
    request.onsuccess = () => resolve()
    request.onerror = () => reject(request.error ?? new Error('Unable to clear IndexedDB.'))
    request.onblocked = () => reject(new Error('Unable to clear IndexedDB (blocked).'))
  })
}

async function tick(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0))
}

