import { describe, expect, it } from 'vitest'

import { parseRepoInput } from './repo-input'

describe('parseRepoInput', () => {
  it('accepts owner/repo pairs', () => {
    expect(parseRepoInput('sideshowdb/sideshowdb')).toEqual({
      owner: 'sideshowdb',
      repo: 'sideshowdb',
    })
  })

  it('rejects empty input', () => {
    expect(() => parseRepoInput('')).toThrow(/owner\/repo/i)
  })

  it('rejects extra path segments', () => {
    expect(() => parseRepoInput('a/b/c')).toThrow(/owner\/repo/i)
  })

  it('trims surrounding whitespace', () => {
    expect(parseRepoInput('  octocat/Hello-World  ')).toEqual({
      owner: 'octocat',
      repo: 'Hello-World',
    })
  })
})
