export type SideshowDbClientErrorKind =
  | 'runtime-load'
  | 'host-store'
  | 'wasm-export'
  | 'decode'

export type SideshowDbClientError = {
  kind: SideshowDbClientErrorKind
  message: string
  cause?: unknown
}

export type OperationFailure = {
  ok: false
  error: SideshowDbClientError
}

export type OperationSuccess<T> = {
  ok: true
  value: T
}

export type GetSuccess<T> =
  | { ok: true; found: false }
  | { ok: true; found: true; value: T }

export interface SideshowDbHostStore {
  put(key: string, value: string): string
  get(
    key: string,
    version?: string,
  ): { value: string; version: string } | null
  delete(key: string): void
  list(): string[]
  history(key: string): string[]
}

// ---------------------------------------------------------------------------
// RefStore backend selection
// ---------------------------------------------------------------------------

export type GitHubRefStoreSpec = {
  kind: 'github'
  owner: string
  repo: string
  /** Git ref name. Defaults to `refs/sideshowdb/documents`. */
  ref?: string
  /** GitHub REST API base URL. Defaults to `https://api.github.com`. */
  apiBase?: string
}

export type MemoryRefStoreSpec = { kind: 'memory' }

/** Union of all selectable backend specifications. */
export type RefStoreSpec = GitHubRefStoreSpec | MemoryRefStoreSpec

// ---------------------------------------------------------------------------
// Host capability callbacks (async-friendly)
// ---------------------------------------------------------------------------

/**
 * Async HTTP transport callback provided by the host.
 * The WASM module calls this for every GitHub API request.
 * On success, resolve with status, headers, and body bytes.
 * On failure, reject — the WASM side will surface a transport error.
 *
 * Note: in-browser use requires SharedArrayBuffer + a worker thread to bridge
 * the async callback into the synchronous WASM import boundary. See
 * `createBrowserHttpTransport` for a ready-made implementation.
 */
export type SideshowDbHostHttpTransportCallback = (
  method: string,
  url: string,
  headers: Record<string, string>,
  body: Uint8Array | null,
) => Promise<{
  status: number
  headers: Record<string, string>
  body: Uint8Array
}>

/**
 * Async credentials resolver callback provided by the host.
 * `provider` is `"github"`, `scope` is currently always `""`.
 * Resolve with a bearer token string, or `null` when no credential is
 * available (the WASM side returns `AuthMissing`).
 */
export type SideshowDbHostCredentialsResolverCallback = (
  provider: string,
  scope: string,
) => string | null | Promise<string | null>

export type SideshowDbHostCapabilities = {
  store?: SideshowDbHostStore
  transport?: {
    http?: SideshowDbHostHttpTransportCallback
  }
  credentials?: SideshowDbHostCredentialsResolverCallback
}

export type SideshowDbDocumentEnvelope<T = unknown> = {
  namespace: string
  type: string
  id: string
  version: string
  data: T
}

export type SideshowDbDocumentMetadata = {
  namespace: string
  type: string
  id: string
  version: string
}

export type SideshowDbCollectionMode = 'summary' | 'detailed'

export type SideshowDbSummaryCollectionResult = {
  kind: 'summary'
  items: SideshowDbDocumentMetadata[]
  next_cursor: string | null
}

export type SideshowDbDetailedCollectionResult<T = unknown> = {
  kind: 'detailed'
  items: SideshowDbDocumentEnvelope<T>[]
  next_cursor: string | null
}

export type SideshowDbListResult<T = unknown> =
  | SideshowDbSummaryCollectionResult
  | SideshowDbDetailedCollectionResult<T>

export type SideshowDbHistoryResult<T = unknown> =
  | SideshowDbSummaryCollectionResult
  | SideshowDbDetailedCollectionResult<T>

export type SideshowDbDeleteResult = {
  namespace: string
  type: string
  id: string
  deleted: boolean
}

export type SideshowDbPutDocumentRequest<T = unknown> = {
  namespace?: string
  type: string
  id: string
  data: T
}

export type SideshowDbPutJsonRequest = {
  json: string
  namespace?: string
  type?: string
  id?: string
}

export type SideshowDbPutRequest<T = unknown> =
  | SideshowDbPutDocumentRequest<T>
  | SideshowDbPutJsonRequest

export type SideshowDbGetRequest = {
  namespace?: string
  type: string
  id: string
  version?: string
}

export type SideshowDbListRequest = {
  namespace?: string
  type?: string
  limit?: number
  cursor?: string
  mode?: SideshowDbCollectionMode
}

export type SideshowDbDeleteRequest = {
  namespace?: string
  type: string
  id: string
}

export type SideshowDbHistoryRequest = {
  namespace?: string
  type: string
  id: string
  limit?: number
  cursor?: string
  mode?: SideshowDbCollectionMode
}

export type SideshowDbWasmExports = WebAssembly.Exports & {
  memory: WebAssembly.Memory
  sideshowdb_banner_ptr: () => number
  sideshowdb_banner_len: () => number
  sideshowdb_version_major: () => number
  sideshowdb_version_minor: () => number
  sideshowdb_version_patch: () => number
  sideshowdb_request_ptr: () => number
  sideshowdb_request_len: () => number
  sideshowdb_result_ptr: () => number
  sideshowdb_result_len: () => number
  sideshowdb_document_put: (ptr: number, len: number) => number
  sideshowdb_document_get: (ptr: number, len: number) => number
  sideshowdb_document_list: (ptr: number, len: number) => number
  sideshowdb_document_delete: (ptr: number, len: number) => number
  sideshowdb_document_history: (ptr: number, len: number) => number
  sideshowdb_use_imported_ref_store?: () => void
  sideshowdb_use_memory_ref_store?: () => void
  sideshowdb_use_github_ref_store?: (
    ownerPtr: number,
    ownerLen: number,
    repoPtr: number,
    repoLen: number,
    refPtr: number,
    refLen: number,
    apiBasePtr: number,
    apiBaseLen: number,
  ) => number
}

export type SideshowDbFetchLikeResponse = {
  ok: boolean
  arrayBuffer(): Promise<ArrayBuffer>
}

export type SideshowDbFetchLike = (
  input: string,
) => Promise<SideshowDbFetchLikeResponse>

export type LoadSideshowDbClientOptions = {
  wasmPath: string
  /** Select the RefStore backend. Defaults to in-WASM memory store. */
  refstore?: RefStoreSpec
  hostCapabilities?: SideshowDbHostCapabilities
  indexedDb?:
    | false
    | {
        dbName?: string
        storeName?: string
      }
  fetchImpl?: SideshowDbFetchLike
}

export interface SideshowDbCoreClient {
  banner: string
  version: string
  put<T = unknown>(
    request: SideshowDbPutRequest<T>,
  ): Promise<OperationSuccess<SideshowDbDocumentEnvelope<T>> | OperationFailure>
  get<T = unknown>(
    request: SideshowDbGetRequest,
  ): Promise<GetSuccess<SideshowDbDocumentEnvelope<T>> | OperationFailure>
  list<T = unknown>(
    request: SideshowDbListRequest,
  ): Promise<OperationSuccess<SideshowDbListResult<T>> | OperationFailure>
  delete(
    request: SideshowDbDeleteRequest,
  ): Promise<OperationSuccess<SideshowDbDeleteResult> | OperationFailure>
  history<T = unknown>(
    request: SideshowDbHistoryRequest,
  ): Promise<OperationSuccess<SideshowDbHistoryResult<T>> | OperationFailure>
}
