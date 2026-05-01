import { describe, expect, it } from 'vitest'

import { createBrowserHttpTransport } from './http'

function makeFakeFetch(
  status: number,
  responseHeaders: Record<string, string>,
  body: Uint8Array,
): {
  fetch: typeof fetch
  requests: Array<{ method: string; url: string; headers: Record<string, string>; body: Uint8Array | null }>
} {
  const requests: Array<{ method: string; url: string; headers: Record<string, string>; body: Uint8Array | null }> = []

  const fakeFetch = async (url: string, init?: RequestInit): Promise<Response> => {
    const reqHeaders: Record<string, string> = {}
    if (init?.headers) {
      for (const [k, v] of Object.entries(init.headers as Record<string, string>)) {
        reqHeaders[k] = v
      }
    }
    let reqBody: Uint8Array | null = null
    if (init?.body instanceof Uint8Array) {
      reqBody = init.body
    }
    requests.push({ method: init?.method ?? 'GET', url, headers: reqHeaders, body: reqBody })

    const respHeaders = new Headers(responseHeaders)
    return new Response(body, { status, headers: respHeaders })
  }

  return { fetch: fakeFetch as unknown as typeof fetch, requests }
}

describe('createBrowserHttpTransport', () => {
  it('round-trips status, headers, and body through fetch', async () => {
    const { fetch: fakeFetch } = makeFakeFetch(
      200,
      { 'content-type': 'application/json', etag: '"abc123"' },
      new Uint8Array([1, 2, 3]),
    )

    const transport = createBrowserHttpTransport(fakeFetch)
    const result = await transport('GET', 'https://api.github.com/repos/a/b/git/refs', {}, null)

    expect(result.status).toBe(200)
    expect(result.headers['content-type']).toBe('application/json')
    expect(result.headers['etag']).toBe('"abc123"')
    expect(result.body).toEqual(new Uint8Array([1, 2, 3]))
  })

  it('passes request headers to fetch', async () => {
    const { fetch: fakeFetch, requests } = makeFakeFetch(200, {}, new Uint8Array())

    const transport = createBrowserHttpTransport(fakeFetch)
    await transport(
      'POST',
      'https://api.github.com/repos/a/b/git/commits',
      { Authorization: 'Bearer ghp_test', 'Content-Type': 'application/json' },
      null,
    )

    expect(requests[0]?.headers['Authorization']).toBe('Bearer ghp_test')
    expect(requests[0]?.headers['Content-Type']).toBe('application/json')
  })

  it('passes body bytes to fetch', async () => {
    const { fetch: fakeFetch, requests } = makeFakeFetch(201, {}, new Uint8Array())
    const body = new Uint8Array([104, 101, 108, 108, 111]) // "hello"

    const transport = createBrowserHttpTransport(fakeFetch)
    await transport('POST', 'https://api.github.com/test', {}, body)

    expect(requests[0]?.method).toBe('POST')
    expect(requests[0]?.body).toEqual(body)
  })

  it('passes null body as null to fetch', async () => {
    const { fetch: fakeFetch, requests } = makeFakeFetch(200, {}, new Uint8Array())

    const transport = createBrowserHttpTransport(fakeFetch)
    await transport('GET', 'https://api.github.com/test', {}, null)

    expect(requests[0]?.body).toBeNull()
  })

  it('handles non-200 responses without throwing', async () => {
    const { fetch: fakeFetch } = makeFakeFetch(404, { 'content-type': 'application/json' }, new Uint8Array())

    const transport = createBrowserHttpTransport(fakeFetch)
    const result = await transport('GET', 'https://api.github.com/missing', {}, null)

    expect(result.status).toBe(404)
  })
})
