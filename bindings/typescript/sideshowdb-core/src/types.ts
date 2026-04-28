export type SideshowdbClientErrorKind =
  | 'runtime-load'
  | 'host-bridge'
  | 'wasm-export'
  | 'decode'

export type SideshowdbClientError = {
  kind: SideshowdbClientErrorKind
  message: string
  cause?: unknown
}

export type OperationFailure = {
  ok: false
  error: SideshowdbClientError
}

export type OperationSuccess<T> = {
  ok: true
  value: T
}

export type GetSuccess<T> =
  | { ok: true; found: false }
  | { ok: true; found: true; value: T }

export interface SideshowdbRefHostBridge {
  put(key: string, value: string): string
  get(
    key: string,
    version?: string,
  ): { value: string; version: string } | null
  delete(key: string): void
  list(): string[]
  history(key: string): string[]
}

export type SideshowdbDocumentEnvelope<T = unknown> = {
  namespace: string
  type: string
  id: string
  version: string
  data: T
}

export type SideshowdbDocumentMetadata = {
  namespace: string
  type: string
  id: string
  version: string
}

export type SideshowdbCollectionMode = 'summary' | 'detailed'

export type SideshowdbSummaryCollectionResult = {
  kind: 'summary'
  items: SideshowdbDocumentMetadata[]
  next_cursor: string | null
}

export type SideshowdbDetailedCollectionResult<T = unknown> = {
  kind: 'detailed'
  items: SideshowdbDocumentEnvelope<T>[]
  next_cursor: string | null
}

export type SideshowdbListResult<T = unknown> =
  | SideshowdbSummaryCollectionResult
  | SideshowdbDetailedCollectionResult<T>

export type SideshowdbHistoryResult<T = unknown> =
  | SideshowdbSummaryCollectionResult
  | SideshowdbDetailedCollectionResult<T>

export type SideshowdbDeleteResult = {
  namespace: string
  type: string
  id: string
  deleted: boolean
}

export type SideshowdbPutDocumentRequest<T = unknown> = {
  namespace?: string
  type: string
  id: string
  data: T
}

export type SideshowdbPutJsonRequest = {
  json: string
  namespace?: string
  type?: string
  id?: string
}

export type SideshowdbPutRequest<T = unknown> =
  | SideshowdbPutDocumentRequest<T>
  | SideshowdbPutJsonRequest

export type SideshowdbGetRequest = {
  namespace?: string
  type: string
  id: string
  version?: string
}

export type SideshowdbListRequest = {
  namespace?: string
  type?: string
  limit?: number
  cursor?: string
  mode?: SideshowdbCollectionMode
}

export type SideshowdbDeleteRequest = {
  namespace?: string
  type: string
  id: string
}

export type SideshowdbHistoryRequest = {
  namespace?: string
  type: string
  id: string
  limit?: number
  cursor?: string
  mode?: SideshowdbCollectionMode
}

export type SideshowdbWasmExports = WebAssembly.Exports & {
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
}

export type SideshowdbFetchLikeResponse = {
  ok: boolean
  arrayBuffer(): Promise<ArrayBuffer>
}

export type SideshowdbFetchLike = (
  input: string,
) => Promise<SideshowdbFetchLikeResponse>

export type LoadSideshowdbClientOptions = {
  wasmPath: string
  hostBridge?: SideshowdbRefHostBridge
  fetchImpl?: SideshowdbFetchLike
}

export interface SideshowdbCoreClient {
  banner: string
  version: string
  put<T = unknown>(
    request: SideshowdbPutRequest<T>,
  ): Promise<OperationSuccess<SideshowdbDocumentEnvelope<T>> | OperationFailure>
  get<T = unknown>(
    request: SideshowdbGetRequest,
  ): Promise<GetSuccess<SideshowdbDocumentEnvelope<T>> | OperationFailure>
  list<T = unknown>(
    request: SideshowdbListRequest,
  ): Promise<OperationSuccess<SideshowdbListResult<T>> | OperationFailure>
  delete(
    request: SideshowdbDeleteRequest,
  ): Promise<OperationSuccess<SideshowdbDeleteResult> | OperationFailure>
  history<T = unknown>(
    request: SideshowdbHistoryRequest,
  ): Promise<OperationSuccess<SideshowdbHistoryResult<T>> | OperationFailure>
}
