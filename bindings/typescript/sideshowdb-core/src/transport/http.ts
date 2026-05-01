/**
 * Default browser HTTP transport for the WASM GitHub API RefStore.
 *
 * The transport callback is async-friendly. At the WASM import boundary the
 * host implementation must return synchronously; callers that target browsers
 * need to pair this with a SharedArrayBuffer + worker-thread bridge. For
 * Node / Bun environments where synchronous-over-async is achievable via
 * worker_threads + Atomics.wait, the callback can be used directly.
 *
 * The callback signature matches `SideshowDbHostHttpTransportCallback`.
 */

import type { SideshowDbHostHttpTransportCallback } from '../types.js'

/**
 * Creates a default HTTP transport callback backed by the global `fetch`.
 * The returned callback is async; wire it into the WASM import layer via
 * the `hostCapabilities.transport.http` option on `loadSideshowDbClient`.
 */
export function createBrowserHttpTransport(
  fetchImpl: typeof fetch = globalThis.fetch,
): SideshowDbHostHttpTransportCallback {
  return async (method, url, headers, body) => {
    const response = await fetchImpl(url, {
      method,
      headers,
      body: body as BodyInit | null,
    })

    const buffer = await response.arrayBuffer()
    const responseHeaders: Record<string, string> = {}
    response.headers.forEach((value, key) => {
      responseHeaders[key] = value
    })

    return {
      status: response.status,
      headers: responseHeaders,
      body: new Uint8Array(buffer),
    }
  }
}
