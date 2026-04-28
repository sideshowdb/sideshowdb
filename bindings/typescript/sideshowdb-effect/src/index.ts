import { Effect } from 'effect'

import {
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
} from '@sideshowdb/core'

export type { LoadSideshowdbClientOptions, SideshowdbCoreClient } from '@sideshowdb/core'

function intoEffect<T>(
  promise: Promise<OperationSuccess<T> | OperationFailure>,
): Effect.Effect<T, SideshowdbClientError> {
  return Effect.flatMap(Effect.promise(() => promise), (result) => {
    if (!result.ok) {
      return Effect.fail(result.error)
    }

    return Effect.succeed(result.value)
  })
}

export function fromCoreClient(client: SideshowdbCoreClient) {
  return {
    banner: client.banner,
    version: client.version,
    put: <T = unknown>(request: SideshowdbPutRequest<T>) =>
      intoEffect<SideshowdbDocumentEnvelope<T>>(client.put<T>(request)),
    get: <T = unknown>(request: SideshowdbGetRequest) =>
      Effect.promise(() => client.get<T>(request)),
    list: <T = unknown>(request: SideshowdbListRequest) =>
      intoEffect<SideshowdbListResult<T>>(client.list<T>(request)),
    delete: (request: SideshowdbDeleteRequest) =>
      intoEffect<SideshowdbDeleteResult>(client.delete(request)),
    history: <T = unknown>(request: SideshowdbHistoryRequest) =>
      intoEffect<SideshowdbHistoryResult<T>>(client.history<T>(request)),
  }
}

export const loadSideshowdbEffectClient = (options: LoadSideshowdbClientOptions) =>
  Effect.promise(async () => fromCoreClient(await loadSideshowdbClient(options)))
