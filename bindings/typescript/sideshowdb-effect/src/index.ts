import { Effect } from 'effect'

import {
  createIndexedDbHostStore,
  type GetSuccess,
  type IndexedDbStoreOptions,
  loadSideshowDbClient,
  type LoadSideshowDbClientOptions,
  type OperationFailure,
  type OperationSuccess,
  type SideshowDbClientError,
  type SideshowDbCoreClient,
  type SideshowDbDeleteRequest,
  type SideshowDbDeleteResult,
  type SideshowDbDocumentEnvelope,
  type SideshowDbGetRequest,
  type SideshowDbHistoryRequest,
  type SideshowDbHistoryResult,
  type SideshowDbListRequest,
  type SideshowDbListResult,
  type SideshowDbPutRequest,
  type SideshowDbHostStore,
} from '@sideshowdb/core'

export type {
  IndexedDbStoreOptions,
  LoadSideshowDbClientOptions,
  SideshowDbCoreClient,
  SideshowDbHostStore,
} from '@sideshowdb/core'

function intoEffect<TResult extends { ok: true }, TValue>(
  promise: () => Promise<TResult | OperationFailure>,
  mapSuccess: (result: TResult) => TValue,
): Effect.Effect<TValue, SideshowDbClientError> {
  return Effect.flatMap(Effect.promise(promise), (result) => {
    if (!result.ok) {
      return Effect.fail(result.error)
    }

    return Effect.succeed(mapSuccess(result))
  })
}

function isClientError(cause: unknown): cause is SideshowDbClientError {
  return (
    typeof cause === 'object' &&
    cause !== null &&
    'kind' in cause &&
    'message' in cause
  )
}

export function fromCoreClient(client: SideshowDbCoreClient) {
  return {
    banner: client.banner,
    version: client.version,
    put: <T = unknown>(request: SideshowDbPutRequest<T>) =>
      intoEffect<OperationSuccess<SideshowDbDocumentEnvelope<T>>, SideshowDbDocumentEnvelope<T>>(
        () => client.put<T>(request),
        (result) => result.value,
      ),
    get: <T = unknown>(request: SideshowDbGetRequest) =>
      intoEffect<
        GetSuccess<SideshowDbDocumentEnvelope<T>>,
        GetSuccess<SideshowDbDocumentEnvelope<T>>
      >(() => client.get<T>(request), (result) => result),
    list: <T = unknown>(request: SideshowDbListRequest) =>
      intoEffect<OperationSuccess<SideshowDbListResult<T>>, SideshowDbListResult<T>>(
        () => client.list<T>(request),
        (result) => result.value,
      ),
    delete: (request: SideshowDbDeleteRequest) =>
      intoEffect<OperationSuccess<SideshowDbDeleteResult>, SideshowDbDeleteResult>(
        () => client.delete(request),
        (result) => result.value,
      ),
    history: <T = unknown>(request: SideshowDbHistoryRequest) =>
      intoEffect<OperationSuccess<SideshowDbHistoryResult<T>>, SideshowDbHistoryResult<T>>(
        () => client.history<T>(request),
        (result) => result.value,
      ),
  }
}

export const loadSideshowDbEffectClient = (options: LoadSideshowDbClientOptions) =>
  Effect.tryPromise({
    try: async () => fromCoreClient(await loadSideshowDbClient(options)),
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
  SideshowDbClientError
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
