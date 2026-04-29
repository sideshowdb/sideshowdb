import { cleanup, render, screen } from '@testing-library/svelte'
import { afterEach, describe, expect, it, vi } from 'vitest'

const { loadSideshowdbClient } = vi.hoisted(() => ({
  loadSideshowdbClient: vi.fn(),
}))

vi.mock('@sideshowdb/core', () => ({
  loadSideshowdbClient,
}))

import PlaygroundPage from './playground/+page.svelte'

function createRuntime(overrides: Record<string, unknown> = {}) {
  return {
    banner: 'sideshowdb',
    version: '0.1.0',
    list: async () => ({
      ok: true,
      value: {
        kind: 'summary',
        items: [{ namespace: 'default', type: 'issue', id: 'demo-1', version: 'mem-1' }],
        next_cursor: null,
      },
    }),
    history: async () => ({
      ok: true,
      value: {
        kind: 'summary',
        items: [
          { namespace: 'default', type: 'issue', id: 'demo-1', version: 'mem-2' },
          { namespace: 'default', type: 'issue', id: 'demo-1', version: 'mem-1' },
        ],
        next_cursor: null,
      },
    }),
    delete: async () => ({
      ok: true,
      value: { namespace: 'default', type: 'issue', id: 'demo-1', deleted: true },
    }),
    put: async () => ({
      ok: true,
      value: { namespace: 'default', type: 'issue', id: 'demo-1', version: 'mem-1', data: { title: 'demo issue' } },
    }),
    get: async () => ({ ok: true, found: false }),
    ...overrides,
  }
}

describe('playground page', () => {
  afterEach(() => {
    cleanup()
    loadSideshowdbClient.mockReset()
    vi.unstubAllGlobals()
    window.history.replaceState({}, '', '/')
  })

  it('renders wasm-backed document demo details from the public binding package', async () => {
    loadSideshowdbClient.mockResolvedValue(createRuntime())

    render(PlaygroundPage)

    expect(await screen.findByText(/mem-2/i)).toBeTruthy()
    expect(screen.getByText(/v0\.1\.0/i)).toBeTruthy()
    expect(loadSideshowdbClient).toHaveBeenCalledWith(
      expect.objectContaining({
        hostCapabilities: {
          store: expect.objectContaining({
            put: expect.any(Function),
            get: expect.any(Function),
            list: expect.any(Function),
            history: expect.any(Function),
            delete: expect.any(Function),
          }),
        },
      }),
    )
  })

  it('renders fallback guidance when the public binding runtime is unavailable', async () => {
    loadSideshowdbClient.mockRejectedValue({
      kind: 'runtime-load',
      message: 'no wasm today',
    })

    render(PlaygroundPage)

    expect(
      await screen.findByText(/the shipped sideshowdb wasm module is unavailable/i),
    ).toBeTruthy()
  })

  it('renders store-unavailable fallback guidance when demo document operations cannot use the host store', async () => {
    loadSideshowdbClient.mockResolvedValue(
      createRuntime({
        list: async () => ({
          ok: true,
          value: { kind: 'summary', items: [], next_cursor: null },
        }),
        history: async () => ({
          ok: true,
          value: { kind: 'summary', items: [], next_cursor: null },
        }),
        put: async () => ({
          ok: false,
          error: { kind: 'host-store', message: 'store missing' },
        }),
      }),
    )

    render(PlaygroundPage)

    expect(await screen.findByText(/the playground demo could not access its ref host store/i)).toBeTruthy()
    expect(screen.getByText(/public github explorer is still available/i)).toBeTruthy()
  })

  it('renders fallback guidance when a demo operation fails for a non-store reason', async () => {
    loadSideshowdbClient.mockResolvedValue(
      createRuntime({
        list: async () => ({
          ok: false,
          error: { kind: 'decode', message: 'bad result payload' },
        }),
      }),
    )

    render(PlaygroundPage)

    expect(
      await screen.findByText(/the shipped sideshowdb wasm module loaded, but the document walkthrough could not complete/i),
    ).toBeTruthy()
    expect(screen.queryByText(/mem-2/i)).toBeNull()
  })

  it('does not report a store failure while the runtime is still loading for a selected repository', async () => {
    loadSideshowdbClient.mockImplementation(
      () =>
        new Promise(() => {
          // Keep the runtime pending so repo loading wins the race.
        }),
    )
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: string | URL) => {
        const url = String(input)

        if (url.endsWith('/git/matching-refs/heads')) {
          return new Response(
            JSON.stringify([{ ref: 'refs/heads/main', object: { sha: '0123456789abcdef' } }]),
            { status: 200, headers: { 'Content-Type': 'application/json' } },
          )
        }

        return new Response(
          JSON.stringify({
            full_name: 'acme/widgets',
            description: 'Repo pending runtime',
            default_branch: 'main',
            visibility: 'public',
          }),
          { status: 200, headers: { 'Content-Type': 'application/json' } },
        )
      }),
    )
    window.history.replaceState({}, '', '/playground/?repo=acme/widgets')

    render(PlaygroundPage)

    expect(await screen.findByText(/repo pending runtime/i)).toBeTruthy()
    expect(screen.queryByText(/the playground demo could not access its ref host store/i)).toBeNull()
  })
})
