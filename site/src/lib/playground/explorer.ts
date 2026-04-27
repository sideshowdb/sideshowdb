import type { GitHubRepoRef, GitHubRepoSummary } from './github'

export type ExplorerModel = {
  fullName: string
  description: string
  defaultBranch: string
  visibility: string
  explanation: string
  refs: Array<{
    name: string
    target: string
    shortTarget: string
  }>
}

export function buildExplorerModel(input: {
  summary: GitHubRepoSummary
  refs: GitHubRepoRef[]
}): ExplorerModel {
  return {
    fullName: input.summary.fullName,
    description: input.summary.description,
    defaultBranch: input.summary.defaultBranch,
    visibility: input.summary.visibility,
    explanation:
      'GitHub is the source of the public repo data. SideshowDB turns those repository structures into focused derived views.',
    refs: input.refs.slice(0, 8).map((ref) => ({
      ...ref,
      shortTarget: ref.target.slice(0, 7),
    })),
  }
}
