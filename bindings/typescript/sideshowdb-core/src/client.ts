import type {
  GetSuccess,
  LoadSideshowDbClientOptions,
  OperationFailure,
  OperationSuccess,
  SideshowDbClientError,
  SideshowDbCoreClient,
  SideshowDbDeleteRequest,
  SideshowDbDeleteResult,
  SideshowDbDocumentEnvelope,
  SideshowDbFetchLike,
  SideshowDbHistoryRequest,
  SideshowDbHistoryResult,
  SideshowDbListRequest,
  SideshowDbListResult,
  SideshowDbPutDocumentRequest,
  SideshowDbPutRequest,
  SideshowDbHostStore,
  SideshowDbWasmExports,
} from './types.js'
import { createIndexedDbHostStore } from './indexeddb-store.js'

const encoder = new TextEncoder()
const decoder = new TextDecoder()
const wasmDiagnostics = new WeakMap<SideshowDbWasmExports, WasmDiagnostics>()
const DOCUMENT_GET_NOT_FOUND_STATUS = 2

type WasmDiagnostics = {
  clearLastFailure: () => void
  getLastFailure: () => SideshowDbClientError | undefined
}

type InvokeOptions = {
  allowNotFound?: boolean
}

export type {
  GetSuccess,
  LoadSideshowDbClientOptions,
  OperationFailure,
  OperationSuccess,
  SideshowDbClientError,
  SideshowDbCoreClient,
  SideshowDbDeleteRequest,
  SideshowDbDeleteResult,
  SideshowDbDocumentEnvelope,
  SideshowDbFetchLike,
  SideshowDbHistoryRequest,
  SideshowDbHistoryResult,
  SideshowDbListRequest,
  SideshowDbListResult,
  SideshowDbPutRequest,
  SideshowDbHostStore,
  SideshowDbWasmExports,
} from './types.js'

export function createSideshowDbClientFromExports(
  exports: SideshowDbWasmExports,
  hostStore: SideshowDbHostStore | undefined,
): SideshowDbCoreClient {
  const banner = readUtf8(
    exports.memory,
    exports.sideshowdb_banner_ptr(),
    exports.sideshowdb_banner_len(),
  )
  const version = [
    exports.sideshowdb_version_major(),
    exports.sideshowdb_version_minor(),
    exports.sideshowdb_version_patch(),
  ].join('.')

  async function invoke<T>(
    exportFn: (ptr: number, len: number) => number,
    request: unknown,
    options?: InvokeOptions,
  ): Promise<OperationSuccess<T> | OperationFailure | GetSuccess<T>> {
    try {
      const diagnostics = wasmDiagnostics.get(exports)
      diagnostics?.clearLastFailure()

      const { ptr, len } = writeRequest(exports, request)
      const status = exportFn(ptr, len)
      const hostFailure = diagnostics?.getLastFailure()

      if (status !== 0) {
        if (
          options?.allowNotFound &&
          status === DOCUMENT_GET_NOT_FOUND_STATUS &&
          hostFailure === undefined
        ) {
          return {
            ok: true,
            found: false,
          }
        }

        return {
          ok: false,
          error:
            hostFailure ??
            clientError(
              hostStore ? 'wasm-export' : 'host-store',
              'WASM document operation failed',
            ),
        }
      }

      const value = JSON.parse(readResult(exports)) as T
      return {
        ok: true,
        value,
      }
    } catch (cause) {
      return {
        ok: false,
        error: clientError('decode', 'failed to encode or decode wasm payload', cause),
      }
    }
  }

  async function invokeOperation<T>(
    exportFn: (ptr: number, len: number) => number,
    request: unknown,
  ): Promise<OperationSuccess<T> | OperationFailure> {
    const result = await invoke<T>(exportFn, request)
    if (!result.ok) {
      return result
    }

    if (!('value' in result)) {
      return {
        ok: false,
        error: clientError('wasm-export', 'WASM operation returned an unexpected result'),
      }
    }

    return result
  }

  return {
    banner,
    version,
    put<T = unknown>(request: SideshowDbPutRequest<T>) {
      return invokeOperation<SideshowDbDocumentEnvelope<T>>(
        exports.sideshowdb_document_put,
        normalizePutRequest(request),
      )
    },
    async get<T = unknown>(request: Parameters<SideshowDbCoreClient['get']>[0]) {
      const result = await invoke<SideshowDbDocumentEnvelope<T>>(
        exports.sideshowdb_document_get,
        request,
        {
          allowNotFound: true,
        },
      )

      if (!result.ok || !('value' in result)) {
        return result
      }

      return {
        ok: true,
        found: true,
        value: result.value,
      }
    },
    list<T = unknown>(request: SideshowDbListRequest) {
      return invokeOperation<SideshowDbListResult<T>>(
        exports.sideshowdb_document_list,
        request,
      )
    },
    delete(request: SideshowDbDeleteRequest) {
      return invokeOperation<SideshowDbDeleteResult>(
        exports.sideshowdb_document_delete,
        request,
      )
    },
    history<T = unknown>(request: SideshowDbHistoryRequest) {
      return invokeOperation<SideshowDbHistoryResult<T>>(
        exports.sideshowdb_document_history,
        request,
      )
    },
  }
}

export async function loadSideshowDbClient(
  options: LoadSideshowDbClientOptions,
): Promise<SideshowDbCoreClient> {
  try {
    const resolvedHostStore =
      options.hostCapabilities?.store ??
      (await maybeCreateDefaultIndexedDbStore(options.indexedDb))
    const fetchImpl = options.fetchImpl ?? getGlobalFetch()
    if (typeof fetchImpl !== 'function') {
      throw new ReferenceError('global fetch is unavailable')
    }

    const response = await fetchImpl(options.wasmPath)
    if (!response.ok) {
      throw clientError(
        'runtime-load',
        'The SideshowDB WASM runtime is unavailable right now.',
      )
    }

    const bytes = await response.arrayBuffer()
    const hostImports = createHostImports(resolvedHostStore)
    const { instance } = await WebAssembly.instantiate(bytes, hostImports.imports)
    const exports = instance.exports as SideshowDbWasmExports

    hostImports.attach(exports)
    if (resolvedHostStore !== undefined) {
      exports.sideshowdb_use_imported_ref_store?.()
    }
    return createSideshowDbClientFromExports(exports, resolvedHostStore)
  } catch (cause) {
    if (isClientError(cause)) {
      throw cause
    }

    throw clientError('runtime-load', 'Failed to load the SideshowDB WASM runtime.', cause)
  }
}

async function maybeCreateDefaultIndexedDbStore(
  indexedDbOption: LoadSideshowDbClientOptions['indexedDb'],
): Promise<SideshowDbHostStore | undefined> {
  if (indexedDbOption === false) {
    return undefined
  }

  if (!hasIndexedDb()) {
    return undefined
  }

  return createIndexedDbHostStore(indexedDbOption)
}

function createHostImports(hostStore?: SideshowDbHostStore) {
  let wasmExports: SideshowDbWasmExports | undefined
  let hostResultBytes = new Uint8Array(0)
  let hostVersionBytes = new Uint8Array(0)
  let scratchBase = 0
  let scratchCapacity = 0
  let lastFailure: SideshowDbClientError | undefined

  function recordFailure(message: string, cause?: unknown) {
    hostResultBytes = new Uint8Array(0)
    hostVersionBytes = new Uint8Array(0)
    lastFailure = clientError('host-store', message, cause)
  }

  function clearFailure() {
    lastFailure = undefined
  }

  function requireExports(): SideshowDbWasmExports {
    if (wasmExports === undefined) {
      throw new Error('WASM exports are not attached to the host store yet.')
    }

    return wasmExports
  }

  function setHostBuffers(result: string, version: string) {
    hostResultBytes = encoder.encode(result)
    hostVersionBytes = encoder.encode(version)
  }

  function readGuestBytes(ptr: number, len: number): string {
    if (len === 0) {
      return ''
    }

    const memory = requireExports().memory
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len))
  }

  function writeHostBytes(slot: 'result' | 'version'): number {
    const exports = requireExports()
    const resultSize = align(Math.max(hostResultBytes.length, 1))
    const versionSize = Math.max(hostVersionBytes.length, 1)
    const required = resultSize + versionSize

    if (scratchBase === 0 || scratchCapacity < required) {
      const pageSize = 64 * 1024
      const previousSize = exports.memory.buffer.byteLength
      const pageCount = Math.max(1, Math.ceil(required / pageSize))
      exports.memory.grow(pageCount)
      scratchBase = previousSize
      scratchCapacity = pageCount * pageSize
    }

    const pointer = slot === 'result' ? scratchBase : scratchBase + resultSize
    const bytes = slot === 'result' ? hostResultBytes : hostVersionBytes

    if (bytes.length > 0) {
      new Uint8Array(exports.memory.buffer, pointer, bytes.length).set(bytes)
    }

    return pointer
  }

  function requireSyncValue<T>(value: T, operation: string): T {
    if (isPromiseLike(value)) {
      throw new Error(
        `The ${operation} host store returned a Promise, but synchronous WASM host imports are required.`,
      )
    }

    return value
  }

  const imports = {
    env: {
      sideshowdb_host_ref_put(
        keyPtr: number,
        keyLen: number,
        valuePtr: number,
        valueLen: number,
      ) {
        clearFailure()

        if (hostStore === undefined) {
          recordFailure('Document operations require a ref host store.')
          return 2
        }

        try {
          const version = requireSyncValue(
            hostStore.put(readGuestBytes(keyPtr, keyLen), readGuestBytes(valuePtr, valueLen)),
            'put',
          )
          setHostBuffers('', version)
          return 0
        } catch (cause) {
          recordFailure('The ref host store failed during put.', cause)
          return 2
        }
      },
      sideshowdb_host_ref_get(
        keyPtr: number,
        keyLen: number,
        versionPtr: number,
        versionLen: number,
      ) {
        clearFailure()

        if (hostStore === undefined) {
          recordFailure('Document operations require a ref host store.')
          return 2
        }

        try {
          const version =
            versionPtr === 0 || versionLen === 0
              ? undefined
              : readGuestBytes(versionPtr, versionLen)
          const read = requireSyncValue(
            hostStore.get(readGuestBytes(keyPtr, keyLen), version),
            'get',
          )
          if (read === null) {
            hostResultBytes = new Uint8Array(0)
            hostVersionBytes = new Uint8Array(0)
            return 1
          }

          setHostBuffers(read.value, read.version)
          return 0
        } catch (cause) {
          recordFailure('The ref host store failed during get.', cause)
          return 2
        }
      },
      sideshowdb_host_ref_delete(keyPtr: number, keyLen: number) {
        clearFailure()

        if (hostStore === undefined) {
          recordFailure('Document operations require a ref host store.')
          return 2
        }

        try {
          requireSyncValue(hostStore.delete(readGuestBytes(keyPtr, keyLen)), 'delete')
          hostResultBytes = new Uint8Array(0)
          hostVersionBytes = new Uint8Array(0)
          return 0
        } catch (cause) {
          recordFailure('The ref host store failed during delete.', cause)
          return 2
        }
      },
      sideshowdb_host_ref_list() {
        clearFailure()

        if (hostStore === undefined) {
          recordFailure('Document operations require a ref host store.')
          return 2
        }

        try {
          const keys = requireSyncValue(hostStore.list(), 'list')
          setHostBuffers(JSON.stringify(keys), '')
          return 0
        } catch (cause) {
          recordFailure('The ref host store failed during list.', cause)
          return 2
        }
      },
      sideshowdb_host_ref_history(keyPtr: number, keyLen: number) {
        clearFailure()

        if (hostStore === undefined) {
          recordFailure('Document operations require a ref host store.')
          return 2
        }

        try {
          const versions = requireSyncValue(
            hostStore.history(readGuestBytes(keyPtr, keyLen)),
            'history',
          )
          setHostBuffers(JSON.stringify(versions), '')
          return 0
        } catch (cause) {
          recordFailure('The ref host store failed during history.', cause)
          return 2
        }
      },
      sideshowdb_host_result_ptr() {
        return writeHostBytes('result')
      },
      sideshowdb_host_result_len() {
        return hostResultBytes.length
      },
      sideshowdb_host_version_ptr() {
        return writeHostBytes('version')
      },
      sideshowdb_host_version_len() {
        return hostVersionBytes.length
      },
      sideshowdb_host_http_request(
        _method: number,
        _urlPtr: number,
        _urlLen: number,
        _headersPtr: number,
        _headersLen: number,
        _bodyPtr: number,
        _bodyLen: number,
        _responseBufPtr: number,
        _responseBufCapacity: number,
        _responseActualLenOutPtr: number,
      ): number {
        recordFailure(
          'GitHubApiRefStore HTTP transport is not yet wired into the host capabilities for this client.',
        )
        return -1
      },
    },
  } satisfies WebAssembly.Imports

  return {
    imports,
    attach(exports: SideshowDbWasmExports) {
      wasmExports = exports
      wasmDiagnostics.set(exports, {
        clearLastFailure: clearFailure,
        getLastFailure: () => lastFailure,
      })
    },
  }
}

function normalizePutRequest<T>(request: SideshowDbPutRequest<T>) {
  if ('json' in request) {
    return request
  }

  return {
    json: JSON.stringify(toEnvelope(request)),
  }
}

function toEnvelope<T>(request: SideshowDbPutDocumentRequest<T>) {
  const envelope: Record<string, unknown> = {
    type: request.type,
    id: request.id,
    data: request.data,
  }

  if (request.namespace !== undefined) {
    envelope.namespace = request.namespace
  }

  return envelope
}

function writeRequest(
  exports: SideshowDbWasmExports,
  request: unknown,
): { ptr: number; len: number } {
  const json = JSON.stringify(request)
  const bytes = encoder.encode(json)
  const ptr = exports.sideshowdb_request_ptr()
  const capacity = exports.sideshowdb_request_len()

  if (bytes.length > capacity) {
    throw new Error(
      `request exceeds wasm request buffer: ${bytes.length} > ${capacity}`,
    )
  }

  new Uint8Array(exports.memory.buffer, ptr, bytes.length).set(bytes)
  return {
    ptr,
    len: bytes.length,
  }
}

function readResult(exports: SideshowDbWasmExports): string {
  const ptr = exports.sideshowdb_result_ptr()
  const len = exports.sideshowdb_result_len()
  return readUtf8(exports.memory, ptr, len)
}

function readUtf8(memory: WebAssembly.Memory, ptr: number, len: number): string {
  if (len === 0) {
    return ''
  }

  return decoder.decode(new Uint8Array(memory.buffer, ptr, len))
}

function align(value: number, boundary = 8): number {
  return Math.ceil(value / boundary) * boundary
}

function clientError(
  kind: SideshowDbClientError['kind'],
  message: string,
  cause?: unknown,
): SideshowDbClientError {
  return cause === undefined ? { kind, message } : { kind, message, cause }
}

function isPromiseLike<T>(value: T | Promise<T>): value is Promise<T> {
  return (
    typeof value === 'object' &&
    value !== null &&
    'then' in value &&
    typeof value.then === 'function'
  )
}

function isClientError(value: unknown): value is SideshowDbClientError {
  return (
    typeof value === 'object' &&
    value !== null &&
    'kind' in value &&
    'message' in value
  )
}

function getGlobalFetch(): SideshowDbFetchLike | undefined {
  const fetchValue = (globalThis as { fetch?: unknown }).fetch
  if (typeof fetchValue !== 'function') {
    return undefined
  }

  return fetchValue as SideshowDbFetchLike
}

function hasIndexedDb(): boolean {
  return 'indexedDB' in globalThis && globalThis.indexedDB !== undefined
}
