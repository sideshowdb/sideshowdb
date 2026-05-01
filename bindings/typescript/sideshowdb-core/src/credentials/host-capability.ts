/**
 * Browser / host credential resolver for the WASM GitHub API RefStore.
 *
 * The resolver callback is called synchronously at the WASM import boundary.
 * If an async resolver is required, the caller must block the calling thread
 * with Atomics.wait (or equivalent) until the async result is available.
 *
 * For simple use-cases (static PAT, pre-resolved token), a synchronous
 * resolver is sufficient.
 */

import type { SideshowDbHostCredentialsResolverCallback } from '../types.js'

/**
 * Creates a credential resolver that always returns the provided static token.
 * Suitable for environments where the token is known at load time (e.g. CI,
 * server-side rendering, or browser apps that prompt the user once on startup).
 */
export function createStaticCredentialsResolver(
  token: string,
): SideshowDbHostCredentialsResolverCallback {
  return (_provider, _scope) => token
}

/**
 * Creates a credential resolver from a callback that may be async.
 * The underlying WASM import requires a synchronous value; this helper
 * wraps an async callback and resolves it before each WASM operation.
 * Use `preloadCredential` to eagerly resolve and cache the result.
 */
export function createBrowserCredentialsResolver(
  resolveToken: () => string | null | Promise<string | null>,
): SideshowDbHostCredentialsResolverCallback {
  return (_provider, _scope) => {
    const result = resolveToken()
    if (result instanceof Promise) {
      // The WASM import boundary is synchronous; async resolvers must be
      // pre-resolved before calling WASM operations. Log a warning and
      // return null so the WASM side surfaces AuthMissing rather than hanging.
      console.warn(
        '[sideshowdb] Async credential resolver returned a Promise at the synchronous WASM boundary. ' +
          'Pre-resolve the token with preloadCredential() before calling WASM operations.',
      )
      return null
    }
    return result
  }
}
