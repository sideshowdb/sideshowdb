import type { RepoRef } from './repo-input'

export type GitHubRepoSummary = {
  fullName: string
  description: string
  defaultBranch: string
  visibility: string
}

export type GitHubRepoRef = {
  name: string
  target: string
}

const unsupportedShapeMessage =
  'GitHub returned repository data the playground does not support yet. Try the sample repo.'

export function mapGitHubError(status: number): string {
  if (status === 404) {
    return 'Repository not found. Try a public owner/repo or use the sample repo.'
  }

  if (status === 403) {
    return 'GitHub could not serve that public repository right now. You may have hit a public API rate limit. Try the sample repo.'
  }

  return 'GitHub data could not be loaded right now. Try again or use the sample repo.'
}

async function fetchGitHubJson(url: string) {
  const response = await fetch(url, {
    headers: {
      Accept: 'application/vnd.github+json',
    },
  })

  if (!response.ok) {
    throw new Error(mapGitHubError(response.status))
  }

  return response.json()
}

export async function fetchRepoSummary(repo: RepoRef): Promise<GitHubRepoSummary> {
  const data = await fetchGitHubJson(`https://api.github.com/repos/${repo.owner}/${repo.repo}`)

  if (
    typeof data !== 'object' ||
    data === null ||
    typeof data.full_name !== 'string' ||
    typeof data.default_branch !== 'string'
  ) {
    throw new Error(unsupportedShapeMessage)
  }

  return {
    fullName: data.full_name,
    description: typeof data.description === 'string' ? data.description : '',
    defaultBranch: data.default_branch,
    visibility: typeof data.visibility === 'string' ? data.visibility : 'public',
  }
}

export async function fetchRepoRefs(repo: RepoRef): Promise<GitHubRepoRef[]> {
  const data = await fetchGitHubJson(
    `https://api.github.com/repos/${repo.owner}/${repo.repo}/git/matching-refs/heads`,
  )

  if (!Array.isArray(data)) {
    throw new Error(unsupportedShapeMessage)
  }

  return data.map((entry) => {
    if (
      typeof entry !== 'object' ||
      entry === null ||
      typeof entry.ref !== 'string' ||
      typeof entry.object !== 'object' ||
      entry.object === null ||
      typeof entry.object.sha !== 'string'
    ) {
      throw new Error(unsupportedShapeMessage)
    }

    return {
      name: entry.ref,
      target: entry.object.sha,
    }
  })
}
