<script module lang="ts">
  export const frontmatter = {
    title: 'Playground',
  }
</script>

<script lang="ts">
  import { base } from '$app/paths'
  import { page } from '$app/stores'
  import { sampleRepos } from '$lib/content/sample-repos'
  import { parseRepoInput, type RepoRef } from '$lib/playground/repo-input'

  let requestedRepo = $derived($page.url.searchParams.get('repo') ?? '')
  let selectedRepo: RepoRef | null = $derived.by(() => {
    if (!requestedRepo) {
      return null
    }

    try {
      return parseRepoInput(requestedRepo)
    } catch {
      return null
    }
  })
  let invalidRepoMessage = $derived.by(() => {
    if (!requestedRepo) {
      return ''
    }

    try {
      parseRepoInput(requestedRepo)
      return ''
    } catch (error) {
      return error instanceof Error ? error.message : 'Repository must use owner/repo format.'
    }
  })
</script>

<section class="docs-shell">
  <h1>Playground</h1>
  <p>Explore a public GitHub repository through the Sideshowdb model.</p>
  <p>This first release stays evaluator-first and only supports public GitHub repositories.</p>

  {#if selectedRepo}
    <p>
      Selected repo:
      <code>{selectedRepo.owner}/{selectedRepo.repo}</code>
    </p>
    <p>Task 4 will load GitHub data for this validated repository selection.</p>
  {:else if invalidRepoMessage}
    <p role="alert">{invalidRepoMessage}</p>
    <p>Try one of the sample repositories below to keep exploring.</p>
  {/if}

  <h2>Start with a sample repository</h2>
  <ul>
    {#each sampleRepos as repo}
      <li>
        <a href={`${base}/playground/?repo=${encodeURIComponent(repo.fullName)}`}>{repo.label}</a>
        <span> {repo.description}</span>
      </li>
    {/each}
  </ul>
</section>
