export type RepoRef = {
  owner: string
  repo: string
}

const repoFormatMessage = 'Repository must use owner/repo format.'

export function parseRepoInput(input: string): RepoRef {
  const trimmed = input.trim()
  const parts = trimmed.split('/').filter(Boolean)

  if (parts.length !== 2) {
    throw new Error(repoFormatMessage)
  }

  const [owner, repo] = parts

  if (!owner || !repo) {
    throw new Error(repoFormatMessage)
  }

  return { owner, repo }
}
