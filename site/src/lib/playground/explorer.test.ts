import { describe, expect, it } from 'vitest'

import { buildExplorerModel } from './explorer'

describe('buildExplorerModel', () => {
  it('keeps the selected repo name and refs in the view model', () => {
    const model = buildExplorerModel({
      summary: {
        fullName: 'sideshowdb/sideshowdb',
        description: 'Git-backed database',
        defaultBranch: 'main',
        visibility: 'public',
      },
      refs: [{ name: 'refs/heads/main', target: 'abc1234def5678' }],
    })

    expect(model.fullName).toBe('sideshowdb/sideshowdb')
    expect(model.defaultBranch).toBe('main')
    expect(model.refs[0]).toMatchObject({
      name: 'refs/heads/main',
      target: 'abc1234def5678',
      shortTarget: 'abc1234',
    })
  })

  it('limits the explorer list to the first eight refs', () => {
    const model = buildExplorerModel({
      summary: {
        fullName: 'octocat/Hello-World',
        description: '',
        defaultBranch: 'main',
        visibility: 'public',
      },
      refs: Array.from({ length: 10 }, (_, index) => ({
        name: `refs/heads/branch-${index + 1}`,
        target: `${index}`.repeat(10),
      })),
    })

    expect(model.refs).toHaveLength(8)
    expect(model.refs.at(-1)?.name).toBe('refs/heads/branch-8')
  })
})
