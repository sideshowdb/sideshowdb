<script module lang="ts">
  export const frontmatter = {
    title: 'Playground',
  }
</script>

<script lang="ts">
  import { browser } from '$app/environment'
  import { afterNavigate } from '$app/navigation'
  import { base } from '$app/paths'
  import HeroRepoForm from '../../lib/components/HeroRepoForm.svelte'
  import PlaygroundStatus from '../../lib/components/PlaygroundStatus.svelte'
  import ProjectionPanel from '../../lib/components/ProjectionPanel.svelte'
  import RepoExplorer from '../../lib/components/RepoExplorer.svelte'
  import { sampleRepos } from '../../lib/content/sample-repos'
  import { buildExplorerModel, type ExplorerModel } from '../../lib/playground/explorer'
  import { fetchRepoRefs, fetchRepoSummary } from '../../lib/playground/github'
  import { parseRepoInput, type RepoRef } from '../../lib/playground/repo-input'
  import { loadSideshowdbWasm, type SideshowdbWasmRuntime } from '../../lib/playground/wasm'

  const featuredRepo = sampleRepos[0]?.fullName ?? 'sideshowdb/sideshowdb'
  let requestedRepo = $state('')
  let model = $state<ExplorerModel | null>(null)
  let loadingMessage = $state('')
  let errorMessage = $state('')
  let wasmRuntime = $state<SideshowdbWasmRuntime | null>(null)
  let requestVersion = 0

  function syncRequestedRepo() {
    if (!browser) {
      requestedRepo = ''
      return
    }

    requestedRepo = new URL(window.location.href).searchParams.get('repo') ?? ''
  }

  if (browser) {
    syncRequestedRepo()
    afterNavigate(syncRequestedRepo)
  }

  $effect(() => {
    if (!browser) {
      return
    }

    let cancelled = false

    void loadSideshowdbWasm(`${base}/wasm/sideshowdb.wasm`)
      .then((runtime) => {
        if (!cancelled) {
          wasmRuntime = runtime
        }
      })
      .catch(() => {
        if (!cancelled) {
          wasmRuntime = null
        }
      })

    return () => {
      cancelled = true
    }
  })

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

  async function loadRepo(repo: RepoRef) {
    const currentRequest = ++requestVersion

    loadingMessage = `Loading ${repo.owner}/${repo.repo} from GitHub...`
    errorMessage = ''
    model = null

    try {
      const [summary, refs] = await Promise.all([fetchRepoSummary(repo), fetchRepoRefs(repo)])

      if (currentRequest !== requestVersion) {
        return
      }

      model = buildExplorerModel({ summary, refs })
      loadingMessage = ''
    } catch (error) {
      if (currentRequest !== requestVersion) {
        return
      }

      loadingMessage = ''
      model = null
      errorMessage =
        error instanceof Error
          ? error.message
          : 'GitHub data could not be loaded right now. Try again or use the sample repo.'
    }
  }

  $effect(() => {
    if (!browser) {
      return
    }

    const repo = selectedRepo
    const invalidMessage = invalidRepoMessage

    if (!requestedRepo) {
      requestVersion += 1
      loadingMessage = ''
      errorMessage = ''
      model = null
      return
    }

    if (!repo) {
      requestVersion += 1
      loadingMessage = ''
      errorMessage = invalidMessage
      model = null
      return
    }

    void loadRepo(repo)
  })
</script>

<section class="docs-shell">
  <h1>Playground</h1>
  <p>Explore a public GitHub repository through the Sideshowdb model.</p>
  <p>This first release stays evaluator-first and only supports public GitHub repositories.</p>
  <HeroRepoForm />

  {#if !requestedRepo}
    <PlaygroundStatus
      title="Start with a public GitHub repository"
      message="Enter an owner/repo pair from the homepage or choose one of the sample repositories below."
      detail="Private repositories are out of scope for this first static GitHub Pages release."
    />
  {:else if loadingMessage}
    <PlaygroundStatus
      title="Loading repository data"
      message={loadingMessage}
      detail="The playground fetches public GitHub data directly in your browser."
      tone="loading"
    />
  {:else if errorMessage}
    <PlaygroundStatus
      title="This repository is not available in the playground right now"
      message={errorMessage}
      detail="Try one of the sample repositories below to keep exploring the public-repo flow."
      tone="error"
    />
  {:else if model}
    <RepoExplorer {model} />
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

  <ProjectionPanel
    repoName={featuredRepo}
    body={model
      ? wasmRuntime
        ? 'The browser runtime is ready to interpret fetched repository data with the shipped Sideshowdb WASM module.'
        : 'The public GitHub explorer is ready, but the shipped Sideshowdb WASM module is unavailable so the playground is showing fetch-first fallback guidance.'
      : 'Use the featured sample path or enter your own public owner/repo pair to compare GitHub refs with the Sideshowdb interpretation layer.'}
    runtimeBanner={wasmRuntime?.banner ?? ''}
    runtimeVersion={wasmRuntime?.version ?? ''}
  />
</section>
