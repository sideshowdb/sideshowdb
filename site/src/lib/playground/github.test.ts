import { afterEach, describe, expect, it, vi } from 'vitest'

import { fetchRepoRefs, fetchRepoSummary, mapGitHubError } from './github'

describe('mapGitHubError', () => {
  it('maps 404 to a plain-language missing repo message', () => {
    expect(mapGitHubError(404)).toMatch(/not found/i)
  })

  it('maps 403 to a public access or rate-limit message', () => {
    expect(mapGitHubError(403)).toMatch(/public|rate/i)
  })
})

describe('fetchRepoSummary', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('returns the parsed repository summary for a public repo', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        full_name: 'sideshowdb/sideshowdb',
        description: 'Git-backed database',
        default_branch: 'main',
        visibility: 'public',
      }),
    })

    vi.stubGlobal('fetch', fetchMock)

    await expect(
      fetchRepoSummary({ owner: 'sideshowdb', repo: 'sideshowdb' }),
    ).resolves.toMatchObject({
      fullName: 'sideshowdb/sideshowdb',
      defaultBranch: 'main',
    })
    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.github.com/repos/sideshowdb/sideshowdb',
      expect.any(Object),
    )
  })

  it('throws a friendly fallback message when GitHub returns 404', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 404,
      }),
    )

    await expect(fetchRepoSummary({ owner: 'missing', repo: 'repo' })).rejects.toThrow(/sample repo/i)
  })
})

describe('fetchRepoRefs', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('throws a friendly unsupported-shape message when GitHub ref data is malformed', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: true,
        json: async () => [{ ref: 'refs/heads/main', object: null }],
      }),
    )

    await expect(fetchRepoRefs({ owner: 'octocat', repo: 'Hello-World' })).rejects.toThrow(
      /sample repo|support/i,
    )
  })
})
