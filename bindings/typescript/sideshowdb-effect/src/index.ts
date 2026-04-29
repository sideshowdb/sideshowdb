import { Effect } from 'effect'

import {
  createIndexedDbHostStore,
  type GetSuccess,
  type IndexedDbStoreOptions,
  loadSideshowdbClient,
  type LoadSideshowdbClientOptions,
  type OperationFailure,
  type OperationSuccess,
  type SideshowdbClientError,
  type SideshowdbCoreClient,
  type SideshowdbDeleteRequest,
  type SideshowdbDeleteResult,
  type SideshowdbDocumentEnvelope,
  type SideshowdbGetRequest,
  type SideshowdbHistoryRequest,
  type SideshowdbHistoryResult,
  type SideshowdbListRequest,
  type SideshowdbListResult,
  type SideshowdbPutRequest,
  type SideshowdbHostStore,
} from '@sideshowdb/core'

export type {
  IndexedDbStoreOptions,
  LoadSideshowdbClientOptions,
  SideshowdbCoreClient,
  SideshowdbHostStore,
} from '@sideshowdb/core'

function intoEffect<TResult extends { ok: true }, TValue>(
  promise: () => Promise<TResult | OperationFailure>,
  mapSuccess: (result: TResult) => TValue,
): Effect.Effect<TValue, SideshowdbClientError> {
  return Effect.flatMap(Effect.promise(promise), (result) => {
    if (!result.ok) {
      return Effect.fail(result.error)
    }

    return Effect.succeed(mapSuccess(result))
  })
}

function isClientError(cause: unknown): cause is SideshowdbClientError {
  return (
    typeof cause === 'object' &&
    cause !== null &&
    'kind' in cause &&
    'message' in cause
  )
}

export function fromCoreClient(client: SideshowdbCoreClient) {
  return {
    banner: client.banner,
    version: client.version,
    put: <T = unknown>(request: SideshowdbPutRequest<T>) =>
      intoEffect<OperationSuccess<SideshowdbDocumentEnvelope<T>>, SideshowdbDocumentEnvelope<T>>(
        () => client.put<T>(request),
        (result) => result.value,
      ),
    get: <T = unknown>(request: SideshowdbGetRequest) =>
      intoEffect<
        GetSuccess<SideshowdbDocumentEnvelope<T>>,
        GetSuccess<SideshowdbDocumentEnvelope<T>>
      >(() => client.get<T>(request), (result) => result),
    list: <T = unknown>(request: SideshowdbListRequest) =>
      intoEffect<OperationSuccess<SideshowdbListResult<T>>, SideshowdbListResult<T>>(
        () => client.list<T>(request),
        (result) => result.value,
      ),
    delete: (request: SideshowdbDeleteRequest) =>
      intoEffect<OperationSuccess<SideshowdbDeleteResult>, SideshowdbDeleteResult>(
        () => client.delete(request),
        (result) => result.value,
      ),
    history: <T = unknown>(request: SideshowdbHistoryRequest) =>
      intoEffect<OperationSuccess<SideshowdbHistoryResult<T>>, SideshowdbHistoryResult<T>>(
        () => client.history<T>(request),
        (result) => result.value,
      ),
  }
}

export const loadSideshowdbEffectClient = (options: LoadSideshowdbClientOptions) =>
  Effect.tryPromise({
    try: async () => fromCoreClient(await loadSideshowdbClient(options)),
    catch: (cause) =>
      isClientError(cause)
        ? cause
        : {
            kind: 'runtime-load',
            message: 'Failed to load the SideshowDB WASM runtime.',
            cause,
          },
  })

export const createIndexedDbHostStoreEffect = (
  options?: IndexedDbStoreOptions,
): Effect.Effect<
  Awaited<ReturnType<typeof createIndexedDbHostStore>>,
  SideshowdbClientError
> =>
  Effect.tryPromise({
    try: () => createIndexedDbHostStore(options),
    // The IndexedDB store throws plain Error values; map every failure to runtime-load.
    catch: (cause) => ({
      kind: 'runtime-load',
      message: 'Failed to initialize the SideshowDB IndexedDB host store.',
      cause,
    }),
  })
