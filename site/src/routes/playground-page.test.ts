import { cleanup, render, screen } from '@testing-library/svelte'
import { afterEach, describe, expect, it, vi } from 'vitest'

const { loadSideshowdbClient } = vi.hoisted(() => ({
  loadSideshowdbClient: vi.fn(),
}))

vi.mock('@sideshowdb/core', () => ({
  loadSideshowdbClient,
}))

import PlaygroundPage from './playground/+page.svelte'

describe('playground page', () => {
  afterEach(() => {
    cleanup()
    loadSideshowdbClient.mockReset()
  })

  it('renders wasm-backed document demo details from the public binding package', async () => {
    loadSideshowdbClient.mockResolvedValue({
      banner: 'sideshowdb',
      version: '0.1.0',
      list: async () => ({
        ok: true,
        value: { kind: 'summary', items: [{ namespace: 'default', type: 'issue', id: 'demo-1', version: 'mem-1' }], next_cursor: null },
      }),
      history: async () => ({
        ok: true,
        value: { kind: 'summary', items: [{ namespace: 'default', type: 'issue', id: 'demo-1', version: 'mem-2' }, { namespace: 'default', type: 'issue', id: 'demo-1', version: 'mem-1' }], next_cursor: null },
      }),
      delete: async () => ({ ok: true, value: { namespace: 'default', type: 'issue', id: 'demo-1', deleted: true } }),
      put: async () => ({
        ok: true,
        value: { namespace: 'default', type: 'issue', id: 'demo-1', version: 'mem-1', data: { title: 'demo issue' } },
      }),
      get: async () => ({ ok: true, found: false }),
    })

    render(PlaygroundPage)

    expect(await screen.findByText(/mem-2/i)).toBeTruthy()
    expect(screen.getByText(/v0\.1\.0/i)).toBeTruthy()
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

  it('renders bridge-unavailable fallback guidance when demo document operations cannot use the host bridge', async () => {
    loadSideshowdbClient.mockResolvedValue({
      banner: 'sideshowdb',
      version: '0.1.0',
      list: async () => ({
        ok: true,
        value: { kind: 'summary', items: [], next_cursor: null },
      }),
      history: async () => ({
        ok: true,
        value: { kind: 'summary', items: [], next_cursor: null },
      }),
      delete: async () => ({
        ok: true,
        value: { namespace: 'default', type: 'issue', id: 'demo-1', deleted: true },
      }),
      put: async () => ({
        ok: false,
        error: { kind: 'host-bridge', message: 'bridge missing' },
      }),
      get: async () => ({ ok: true, found: false }),
    })

    render(PlaygroundPage)

    expect(await screen.findByText(/the playground demo could not access its ref host bridge/i)).toBeTruthy()
    expect(screen.getByText(/public github explorer is still available/i)).toBeTruthy()
  })
})
