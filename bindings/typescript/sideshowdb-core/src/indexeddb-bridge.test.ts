import 'fake-indexeddb/auto'
import { describe, expect, it } from 'vitest'

import { createIndexedDbRefHostBridge } from './indexeddb-bridge'

// Each test that opens IndexedDB uses a unique dbName so state cannot bleed
// between tests — fake-indexeddb persists for the lifetime of the module.
let dbSeq = 0
function uniqueDb(label: string) {
  return `idb-bridge-test-${label}-${++dbSeq}`
}

describe('createIndexedDbRefHostBridge', () => {
  // ---------------------------------------------------------------------------
  // put
  // ---------------------------------------------------------------------------

  describe('put', () => {
    it('returns v1 for the first value stored under a key', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('put-v1') })

      const version = bridge.put('k1', 'hello')

      expect(version).toBe('v1')
    })

    it('returns v2 for the second value stored under the same key', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('put-v2') })
      bridge.put('k1', 'hello')

      const version = bridge.put('k1', 'world')

      expect(version).toBe('v2')
    })

    it('increments versions independently per key', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('put-per-key') })

      bridge.put('a', 'one')
      bridge.put('a', 'two')
      const versionA = bridge.put('a', 'three')
      const versionB = bridge.put('b', 'first')

      expect(versionA).toBe('v3')
      expect(versionB).toBe('v1')
    })
  })

  // ---------------------------------------------------------------------------
  // get
  // ---------------------------------------------------------------------------

  describe('get', () => {
    it('returns null for a key that has never been written', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('get-null') })

      expect(bridge.get('missing')).toBeNull()
    })

    it('returns the latest value when no version is specified', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('get-latest') })
      bridge.put('k', 'first')
      bridge.put('k', 'second')

      const result = bridge.get('k')

      expect(result).toEqual({ value: 'second', version: 'v2' })
    })

    it('returns the value for a specific version', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('get-version') })
      const v1 = bridge.put('k', 'alpha')
      bridge.put('k', 'beta')

      const result = bridge.get('k', v1)

      expect(result).toEqual({ value: 'alpha', version: 'v1' })
    })

    it('returns null for a version that does not exist on the key', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('get-bad-version') })
      bridge.put('k', 'hello')

      expect(bridge.get('k', 'v999')).toBeNull()
    })

    it('returns null after the key has been deleted', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('get-after-delete') })
      bridge.put('k', 'hello')
      bridge.delete('k')

      expect(bridge.get('k')).toBeNull()
    })
  })

  // ---------------------------------------------------------------------------
  // delete
  // ---------------------------------------------------------------------------

  describe('delete', () => {
    it('removes the key so subsequent gets return null', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('del-existing') })
      bridge.put('k', 'value')

      bridge.delete('k')

      expect(bridge.get('k')).toBeNull()
    })

    it('removes the key from list after deletion', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('del-from-list') })
      bridge.put('a', 'one')
      bridge.put('b', 'two')

      bridge.delete('a')

      expect(bridge.list()).toEqual(['b'])
    })

    it('silently succeeds when the key does not exist', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('del-missing') })

      expect(() => bridge.delete('no-such-key')).not.toThrow()
    })
  })

  // ---------------------------------------------------------------------------
  // list
  // ---------------------------------------------------------------------------

  describe('list', () => {
    it('returns an empty array when no keys have been written', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('list-empty') })

      expect(bridge.list()).toEqual([])
    })

    it('returns all written keys in sorted order', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('list-sorted') })
      bridge.put('zebra', '1')
      bridge.put('apple', '2')
      bridge.put('mango', '3')

      expect(bridge.list()).toEqual(['apple', 'mango', 'zebra'])
    })

    it('reflects deletions immediately', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('list-delete') })
      bridge.put('x', '1')
      bridge.put('y', '2')
      bridge.delete('x')

      expect(bridge.list()).toEqual(['y'])
    })

    it('shows a key only once even after multiple puts', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('list-dedup') })
      bridge.put('k', 'a')
      bridge.put('k', 'b')
      bridge.put('k', 'c')

      expect(bridge.list()).toEqual(['k'])
    })
  })

  // ---------------------------------------------------------------------------
  // history
  // ---------------------------------------------------------------------------

  describe('history', () => {
    it('returns an empty array for a key that has never been written', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('hist-empty') })

      expect(bridge.history('missing')).toEqual([])
    })

    it('returns versions in reverse chronological order (newest first)', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('hist-order') })
      bridge.put('k', 'one')
      bridge.put('k', 'two')
      bridge.put('k', 'three')

      expect(bridge.history('k')).toEqual(['v3', 'v2', 'v1'])
    })

    it('returns an empty array after the key has been deleted', async () => {
      const bridge = await createIndexedDbRefHostBridge({ dbName: uniqueDb('hist-del') })
      bridge.put('k', 'value')
      bridge.delete('k')

      expect(bridge.history('k')).toEqual([])
    })
  })

  // ---------------------------------------------------------------------------
  // persistence (cache loading from IndexedDB on second open)
  // ---------------------------------------------------------------------------

  describe('persistence', () => {
    it('loads data written by a first instance when a second instance opens the same DB', async () => {
      const dbName = uniqueDb('persist-reload')
      const first = await createIndexedDbRefHostBridge({ dbName })

      first.put('doc', 'payload')
      // Allow the async write chain to flush before opening a second connection
      await flushWrites()

      const second = await createIndexedDbRefHostBridge({ dbName })

      expect(second.get('doc')).toEqual({ value: 'payload', version: 'v1' })
    })

    it('continues version numbering from the persisted state in the second instance', async () => {
      const dbName = uniqueDb('persist-version')
      const first = await createIndexedDbRefHostBridge({ dbName })
      first.put('doc', 'v1-value')
      await flushWrites()

      const second = await createIndexedDbRefHostBridge({ dbName })
      const version = second.put('doc', 'v2-value')

      expect(version).toBe('v2')
    })

    it('isolates data between different dbName values', async () => {
      const dbA = uniqueDb('iso-a')
      const dbB = uniqueDb('iso-b')
      const bridgeA = await createIndexedDbRefHostBridge({ dbName: dbA })
      const bridgeB = await createIndexedDbRefHostBridge({ dbName: dbB })

      bridgeA.put('shared-key', 'from-a')

      expect(bridgeB.get('shared-key')).toBeNull()
    })

    it('honours a custom storeName when the database is created fresh', async () => {
      const dbName = uniqueDb('custom-store')
      const bridge = await createIndexedDbRefHostBridge({ dbName, storeName: 'my-custom-store' })

      bridge.put('k', 'value')
      await flushWrites()

      // Re-open with the same dbName+storeName to confirm persistence
      const reloaded = await createIndexedDbRefHostBridge({ dbName, storeName: 'my-custom-store' })
      expect(reloaded.get('k')).toEqual({ value: 'value', version: 'v1' })
    })
  })
})

/**
 * Give the IndexedDB write chain a chance to flush by yielding to the
 * microtask queue. The writeChain is resolved through Promise.then so
 * a couple of awaited microtasks are sufficient.
 */
async function flushWrites(ticks = 10) {
  for (let i = 0; i < ticks; i++) {
    await Promise.resolve()
  }
}
