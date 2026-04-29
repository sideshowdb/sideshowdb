import type { SideshowdbRefHostBridge } from './types.js'

type StoredVersion = {
  version: string
  value: string
}

type StoredRecord = {
  key: string
  versions: StoredVersion[]
}

export type IndexedDbBridgeOptions = {
  dbName?: string
  storeName?: string
  onPersistenceError?: (error: Error) => void
}

const DEFAULT_DB_NAME = 'sideshowdb-refstore'
const DEFAULT_STORE_NAME = 'refs'

export async function createIndexedDbRefHostBridge(
  options?: IndexedDbBridgeOptions,
): Promise<SideshowdbRefHostBridge> {
  const dbName = options?.dbName ?? DEFAULT_DB_NAME
  const storeName = options?.storeName ?? DEFAULT_STORE_NAME
  const db = await openDatabase(dbName, storeName, options?.onPersistenceError)
  const cache = await loadCache(db, storeName)

  let writeChain = Promise.resolve()

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
  }

  function enqueueWrite(write: () => Promise<void>) {
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
  const nextVersion = initial.version + 1
  initial.close()

  try {
    return await openDatabaseVersion(dbName, nextVersion, storeName)
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
      const db = request.result
      db.onversionchange = () => {
        db.close()
      }
      resolve(db)
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
  const latest = versions[versions.length - 1]
  if (!latest) {
    return 'v1'
  }

  const parsed = Number.parseInt(latest.version.replace(/^v/, ''), 10)
  if (!Number.isFinite(parsed)) {
    return `${latest.version}-next`
  }

  return `v${parsed + 1}`
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
