import type {
  GetSuccess,
  LoadSideshowdbClientOptions,
  OperationFailure,
  OperationSuccess,
  SideshowdbClientError,
  SideshowdbCoreClient,
  SideshowdbDeleteRequest,
  SideshowdbDeleteResult,
  SideshowdbDocumentEnvelope,
  SideshowdbHistoryRequest,
  SideshowdbHistoryResult,
  SideshowdbListRequest,
  SideshowdbListResult,
  SideshowdbPutDocumentRequest,
  SideshowdbPutRequest,
  SideshowdbRefHostBridge,
  SideshowdbWasmExports,
} from './types'

const encoder = new TextEncoder()
const decoder = new TextDecoder()
const wasmDiagnostics = new WeakMap<SideshowdbWasmExports, WasmDiagnostics>()

type WasmDiagnostics = {
  clearLastFailure: () => void
  getLastFailure: () => SideshowdbClientError | undefined
}

type InvokeOptions = {
  allowNotFound?: boolean
}

export type {
  GetSuccess,
  LoadSideshowdbClientOptions,
  OperationFailure,
  OperationSuccess,
  SideshowdbClientError,
  SideshowdbCoreClient,
  SideshowdbDeleteRequest,
  SideshowdbDeleteResult,
  SideshowdbDocumentEnvelope,
  SideshowdbHistoryRequest,
  SideshowdbHistoryResult,
  SideshowdbListRequest,
  SideshowdbListResult,
  SideshowdbPutRequest,
  SideshowdbRefHostBridge,
  SideshowdbWasmExports,
} from './types'

export function createSideshowdbClientFromExports(
  exports: SideshowdbWasmExports,
  hostBridge: SideshowdbRefHostBridge | undefined,
): SideshowdbCoreClient {
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
        if (options?.allowNotFound && status === 1 && hostFailure === undefined) {
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
              hostBridge ? 'wasm-export' : 'host-bridge',
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
    put<T = unknown>(request: SideshowdbPutRequest<T>) {
      return invokeOperation<SideshowdbDocumentEnvelope<T>>(
        exports.sideshowdb_document_put,
        normalizePutRequest(request),
      )
    },
    async get<T = unknown>(request: Parameters<SideshowdbCoreClient['get']>[0]) {
      const result = await invoke<SideshowdbDocumentEnvelope<T>>(
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
    list<T = unknown>(request: SideshowdbListRequest) {
      return invokeOperation<SideshowdbListResult<T>>(
        exports.sideshowdb_document_list,
        request,
      )
    },
    delete(request: SideshowdbDeleteRequest) {
      return invokeOperation<SideshowdbDeleteResult>(
        exports.sideshowdb_document_delete,
        request,
      )
    },
    history<T = unknown>(request: SideshowdbHistoryRequest) {
      return invokeOperation<SideshowdbHistoryResult<T>>(
        exports.sideshowdb_document_history,
        request,
      )
    },
  }
}

export async function loadSideshowdbClient(
  options: LoadSideshowdbClientOptions,
): Promise<SideshowdbCoreClient> {
  const fetchImpl = options.fetchImpl ?? fetch

  try {
    const response = await fetchImpl(options.wasmPath)
    if (!response.ok) {
      throw clientError(
        'runtime-load',
        'The SideshowDB WASM runtime is unavailable right now.',
      )
    }

    const bytes = await response.arrayBuffer()
    const hostImports = createHostImports(options.hostBridge)
    const { instance } = await WebAssembly.instantiate(bytes, hostImports.imports)
    const exports = instance.exports as SideshowdbWasmExports

    hostImports.attach(exports)
    return createSideshowdbClientFromExports(exports, options.hostBridge)
  } catch (cause) {
    if (isClientError(cause)) {
      throw cause
    }

    throw clientError('runtime-load', 'Failed to load the SideshowDB WASM runtime.', cause)
  }
}

function createHostImports(hostBridge?: SideshowdbRefHostBridge) {
  let wasmExports: SideshowdbWasmExports | undefined
  let hostResultBytes = new Uint8Array(0)
  let hostVersionBytes = new Uint8Array(0)
  let scratchBase = 0
  let scratchCapacity = 0
  let lastFailure: SideshowdbClientError | undefined

  function recordFailure(message: string, cause?: unknown) {
    hostResultBytes = new Uint8Array(0)
    hostVersionBytes = new Uint8Array(0)
    lastFailure = clientError('host-bridge', message, cause)
  }

  function clearFailure() {
    lastFailure = undefined
  }

  function requireExports(): SideshowdbWasmExports {
    if (wasmExports === undefined) {
      throw new Error('WASM exports are not attached to the host bridge yet.')
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

  function requireSyncValue<T>(value: T | Promise<T>, operation: string): T {
    if (isPromiseLike(value)) {
      throw new Error(
        `The ${operation} host bridge returned a Promise, but synchronous WASM host imports are required.`,
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

        if (hostBridge === undefined) {
          recordFailure('Document operations require a ref host bridge.')
          return 2
        }

        try {
          const version = requireSyncValue(
            hostBridge.put(readGuestBytes(keyPtr, keyLen), readGuestBytes(valuePtr, valueLen)),
            'put',
          )
          setHostBuffers('', version)
          return 0
        } catch (cause) {
          recordFailure('The ref host bridge failed during put.', cause)
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

        if (hostBridge === undefined) {
          recordFailure('Document operations require a ref host bridge.')
          return 2
        }

        try {
          const version =
            versionPtr === 0 || versionLen === 0
              ? undefined
              : readGuestBytes(versionPtr, versionLen)
          const read = requireSyncValue(
            hostBridge.get(readGuestBytes(keyPtr, keyLen), version),
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
          recordFailure('The ref host bridge failed during get.', cause)
          return 2
        }
      },
      sideshowdb_host_ref_delete(keyPtr: number, keyLen: number) {
        clearFailure()

        if (hostBridge === undefined) {
          recordFailure('Document operations require a ref host bridge.')
          return 2
        }

        try {
          requireSyncValue(hostBridge.delete(readGuestBytes(keyPtr, keyLen)), 'delete')
          hostResultBytes = new Uint8Array(0)
          hostVersionBytes = new Uint8Array(0)
          return 0
        } catch (cause) {
          recordFailure('The ref host bridge failed during delete.', cause)
          return 2
        }
      },
      sideshowdb_host_ref_list() {
        clearFailure()

        if (hostBridge === undefined) {
          recordFailure('Document operations require a ref host bridge.')
          return 2
        }

        try {
          const keys = requireSyncValue(hostBridge.list(), 'list')
          setHostBuffers(JSON.stringify(keys), '')
          return 0
        } catch (cause) {
          recordFailure('The ref host bridge failed during list.', cause)
          return 2
        }
      },
      sideshowdb_host_ref_history(keyPtr: number, keyLen: number) {
        clearFailure()

        if (hostBridge === undefined) {
          recordFailure('Document operations require a ref host bridge.')
          return 2
        }

        try {
          const versions = requireSyncValue(
            hostBridge.history(readGuestBytes(keyPtr, keyLen)),
            'history',
          )
          setHostBuffers(JSON.stringify(versions), '')
          return 0
        } catch (cause) {
          recordFailure('The ref host bridge failed during history.', cause)
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
    },
  } satisfies WebAssembly.Imports

  return {
    imports,
    attach(exports: SideshowdbWasmExports) {
      wasmExports = exports
      wasmDiagnostics.set(exports, {
        clearLastFailure: clearFailure,
        getLastFailure: () => lastFailure,
      })
    },
  }
}

function normalizePutRequest<T>(request: SideshowdbPutRequest<T>) {
  if ('json' in request) {
    return request
  }

  return {
    json: JSON.stringify(toEnvelope(request)),
  }
}

function toEnvelope<T>(request: SideshowdbPutDocumentRequest<T>) {
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
  exports: SideshowdbWasmExports,
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

function readResult(exports: SideshowdbWasmExports): string {
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
  kind: SideshowdbClientError['kind'],
  message: string,
  cause?: unknown,
): SideshowdbClientError {
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

function isClientError(value: unknown): value is SideshowdbClientError {
  return (
    typeof value === 'object' &&
    value !== null &&
    'kind' in value &&
    'message' in value
  )
}
