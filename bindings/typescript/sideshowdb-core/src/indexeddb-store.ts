import type { SideshowdbHostStore } from './types.js'

type StoredVersion = {
  version: string
  value: string
}

type StoredRecord = {
  key: string
  versions: StoredVersion[]
}

export type IndexedDbStoreOptions = {
  dbName?: string
  storeName?: string
  /**
   * Invoked when async write-behind persistence fails or the underlying
   * database is closed by another tab via `versionchange`. The store's
   * in-memory cache stays at the most recent value, so callers should treat
   * this as a durability warning: any pending and subsequent writes have not
   * reached storage and will be lost on reload until a new store is created.
   */
  onPersistenceError?: (error: Error) => void
}

export type IndexedDbHostStore = SideshowdbHostStore & {
  /**
   * Drains the pending write-behind queue, then closes the IndexedDB
   * connection. After close(), all subsequent operations behave on the
   * in-memory cache only and will not persist.
   */
  close(): Promise<void>
}

const DEFAULT_DB_NAME = 'sideshowdb-refstore'
const DEFAULT_STORE_NAME = 'refs'

export async function createIndexedDbHostStore(
  options?: IndexedDbStoreOptions,
): Promise<IndexedDbHostStore> {
  const dbName = options?.dbName ?? DEFAULT_DB_NAME
  const storeName = options?.storeName ?? DEFAULT_STORE_NAME
  const db = await openDatabase(dbName, storeName, options?.onPersistenceError)
  const cache = await loadCache(db, storeName)

  let writeChain = Promise.resolve()
  let closed = false

  db.onversionchange = () => {
    db.close()
    closed = true
    reportPersistenceError(
      new Error('IndexedDB connection closed by another tab via versionchange.'),
      options?.onPersistenceError,
    )
  }

  return {
    put(key, value) {
      const record = cache.get(key) ?? []
      const version = nextVersion(record)
      record.push({ version, value })
      cache.set(key, record)
      enqueueWrite(() => persistRecord(db, storeName, key, record))
      return version
    },
    get(key, version) {
      const record = cache.get(key)
      if (!record || record.length === 0) {
        return null
      }

      if (version === undefined) {
        const latest = record[record.length - 1]
        return latest ? { value: latest.value, version: latest.version } : null
      }

      const entry = record.find((item) => item.version === version)
      return entry ? { value: entry.value, version: entry.version } : null
    },
    delete(key) {
      cache.delete(key)
      enqueueWrite(() => deleteRecord(db, storeName, key))
    },
    list() {
      return Array.from(cache.keys()).sort()
    },
    history(key) {
      const record = cache.get(key) ?? []
      return record.map((entry) => entry.version).reverse()
    },
    async close() {
      await writeChain
      if (!closed) {
        db.close()
        closed = true
      }
    },
  }

  function enqueueWrite(write: () => Promise<void>) {
    // Run regardless of prior outcome so a single failed write does not stall
    // subsequent writes; report failures through the persistence error channel.
    writeChain = writeChain.then(write, write).catch((error) => {
      reportPersistenceError(
        toError(error, 'IndexedDB write-behind persistence failed.'),
        options?.onPersistenceError,
      )
    })
  }
}

async function openDatabase(
  dbName: string,
  storeName: string,
  onPersistenceError?: (error: Error) => void,
): Promise<IDBDatabase> {
  const initial = await openDatabaseVersion(dbName, undefined, storeName)
  if (initial.objectStoreNames.contains(storeName)) {
    return initial
  }
  const nextSchemaVersion = initial.version + 1
  initial.close()

  try {
    return await openDatabaseVersion(dbName, nextSchemaVersion, storeName)
  } catch (error) {
    const asError = toError(error, 'Failed to upgrade IndexedDB schema.')
    reportPersistenceError(asError, onPersistenceError)
    throw asError
  }
}

async function openDatabaseVersion(
  dbName: string,
  version: number | undefined,
  storeName: string,
): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request =
      version === undefined ? indexedDB.open(dbName) : indexedDB.open(dbName, version)
    request.onupgradeneeded = () => {
      const db = request.result
      if (!db.objectStoreNames.contains(storeName)) {
        db.createObjectStore(storeName, { keyPath: 'key' })
      }
    }
    request.onsuccess = () => {
      resolve(request.result)
    }
    request.onerror = () => reject(request.error ?? new Error('Failed to open IndexedDB.'))
    request.onblocked = () => reject(new Error('IndexedDB open request was blocked.'))
  })
}

async function loadCache(
  db: IDBDatabase,
  storeName: string,
): Promise<Map<string, StoredVersion[]>> {
  const records = await readAllRecords(db, storeName)
  const map = new Map<string, StoredVersion[]>()
  for (const record of records) {
    map.set(record.key, record.versions)
  }
  return map
}

async function readAllRecords(db: IDBDatabase, storeName: string): Promise<StoredRecord[]> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(storeName, 'readonly')
    const store = tx.objectStore(storeName)
    const request = store.getAll()
    request.onsuccess = () => resolve((request.result as StoredRecord[]) ?? [])
    request.onerror = () => reject(request.error ?? new Error('Failed to read IndexedDB.'))
  })
}

async function persistRecord(
  db: IDBDatabase,
  storeName: string,
  key: string,
  versions: StoredVersion[],
): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(storeName, 'readwrite')
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error ?? new Error('Failed to persist IndexedDB record.'))
    tx.objectStore(storeName).put({
      key,
      versions,
    } satisfies StoredRecord)
  })
}

async function deleteRecord(db: IDBDatabase, storeName: string, key: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(storeName, 'readwrite')
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error ?? new Error('Failed to delete IndexedDB record.'))
    tx.objectStore(storeName).delete(key)
  })
}

function nextVersion(versions: StoredVersion[]): string {
  let max = 0
  let sawNumeric = false
  for (const entry of versions) {
    const match = /^v(\d+)$/.exec(entry.version)
    if (match) {
      sawNumeric = true
      const parsed = Number.parseInt(match[1]!, 10)
      if (parsed > max) {
        max = parsed
      }
    }
  }
  if (sawNumeric) {
    return `v${max + 1}`
  }
  return `v${versions.length + 1}`
}

function reportPersistenceError(
  error: Error,
  onPersistenceError?: (error: Error) => void,
): void {
  if (onPersistenceError) {
    onPersistenceError(error)
    return
  }
  console.error(error)
}

function toError(value: unknown, fallbackMessage: string): Error {
  if (value instanceof Error) {
    return value
  }
  return new Error(fallbackMessage)
}
